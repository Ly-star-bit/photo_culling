import Foundation
import SwiftUI

@MainActor
final class LabelStore: ObservableObject {
    @Published var photos: [Photo] = []
    @Published var labels: [String: LabelRow] = [:]
    @Published var currentIndex: Int = 0
    @Published var loadError: String?

    var layer1ById: [String: Layer1Result] = [:]
    var layer2ById: [String: Layer2Result] = [:]

    private(set) var dataDir: URL
    var labelsPath: URL { dataDir.appendingPathComponent("labels.csv") }
    private let csvColumns = ["id", "blur", "closed_eyes", "group_id", "composition_issue", "exposure_issue", "human_score"]

    init(dataDir: URL) {
        self.dataDir = dataDir
        load()
        // Fresh analysis / session switch from the batch tab: follow the session
        // dir carried in the notification and reload.
        NotificationCenter.default.addObserver(forName: .analysisDidFinish, object: nil, queue: .main) { [weak self] note in
            let dir = note.userInfo?["dir"] as? URL
            MainActor.assumeIsolated {
                guard let self else { return }
                if let dir { self.dataDir = dir }
                self.load()
            }
        }
    }

    var currentPhoto: Photo? {
        guard photos.indices.contains(currentIndex) else { return nil }
        return photos[currentIndex]
    }

    var labeledCount: Int {
        labels.values.filter { $0.isComplete }.count
    }

    func layer1(for id: String) -> Layer1Result? { layer1ById[id] }
    func layer2(for id: String) -> Layer2Result? { layer2ById[id] }

    func binding(for id: String) -> LabelRow {
        labels[id] ?? defaultRow(for: id)
    }

    private func defaultRow(for id: String) -> LabelRow {
        var row = LabelRow()
        if let group = layer1ById[id]?.burstGroup {
            row.groupId = String(group)
        }
        return row
    }

    func update(_ id: String, _ mutate: (inout LabelRow) -> Void) {
        var row = labels[id] ?? defaultRow(for: id)
        mutate(&row)
        labels[id] = row
        save()
    }

    func goTo(_ index: Int) {
        guard photos.indices.contains(index) else { return }
        currentIndex = index
    }

    func next() { goTo(currentIndex + 1) }
    func previous() { goTo(currentIndex - 1) }

    // MARK: - Loading

    /// manifest.json stores preview paths relative to the culling-poc project root
    /// (where prepare.py runs); absolute paths (like raw_path) pass through untouched.
    static func resolve(_ path: String, against root: URL) -> String {
        if path.hasPrefix("/") { return path }
        return root.appendingPathComponent(path).path
    }

    func load() {
        let decoder = JSONDecoder()
        loadError = nil
        photos = []
        layer1ById = [:]
        layer2ById = [:]
        // 必须清空：loadLabels 是"合并写入"，不清的话上一场的标注会跟着 id
        // （文件名 stem，跨场次大量重复）串进这一场，并被 save() 写进它的 labels.csv。
        labels = [:]
        currentIndex = 0

        let manifestPath = dataDir.appendingPathComponent("manifest.json")
        // No manifest = analysis simply hasn't run yet; the empty state (with its
        // "先跑一次分析" hint) covers that. Only an unreadable/corrupt file is an error.
        guard FileManager.default.fileExists(atPath: manifestPath.path) else { return }
        do {
            let manifestData = try Data(contentsOf: manifestPath)
            let manifest = try decoder.decode(Manifest.self, from: manifestData)
            let projectRoot = dataDir.deletingLastPathComponent()
            photos = manifest.photos.map { photo in
                var photo = photo
                photo.previewPath = Self.resolve(photo.previewPath, against: projectRoot)
                photo.rawPath = Self.resolve(photo.rawPath, against: projectRoot)
                return photo
            }
        } catch {
            loadError = "读取 manifest.json 失败: \(error.localizedDescription)"
            return
        }

        let layer1Path = dataDir.appendingPathComponent("layer1_results.json")
        if let data = try? Data(contentsOf: layer1Path),
           let file = try? decoder.decode(Layer1File.self, from: data) {
            for r in file.results where r.error == nil {
                layer1ById[r.id] = r
            }
        }

        let layer2Path = dataDir.appendingPathComponent("layer2_results.json")
        if let data = try? Data(contentsOf: layer2Path),
           let file = try? decoder.decode(Layer2File.self, from: data) {
            for r in file.results where r.error == nil {
                layer2ById[r.id] = r
            }
        }

        loadLabels()
    }

    private func loadLabels() {
        guard let text = try? String(contentsOf: labelsPath, encoding: .utf8) else { return }
        let rows = CSV.parseRows(text)
        guard let header = rows.first else { return }
        let colIndex: [String: Int] = Dictionary(uniqueKeysWithValues: header.enumerated().map { ($1, $0) })
        guard let idIdx = colIndex["id"] else { return }

        for fields in rows.dropFirst() {
            guard idIdx < fields.count else { continue }
            let id = fields[idIdx]
            var row = LabelRow()
            if let i = colIndex["blur"], i < fields.count, !fields[i].isEmpty { row.blur = fields[i] == "1" }
            if let i = colIndex["closed_eyes"], i < fields.count, !fields[i].isEmpty { row.closedEyes = fields[i] == "1" }
            if let i = colIndex["group_id"], i < fields.count { row.groupId = fields[i] }
            if let i = colIndex["composition_issue"], i < fields.count { row.compositionIssue = fields[i] }
            if let i = colIndex["exposure_issue"], i < fields.count, !fields[i].isEmpty { row.exposureIssue = fields[i] == "1" }
            if let i = colIndex["human_score"], i < fields.count, let v = Int(fields[i]) { row.humanScore = v }
            labels[id] = row
        }
    }

    // MARK: - Saving

    func save() {
        var lines = [CSV.writeRow(csvColumns)]
        for photo in photos {
            guard let row = labels[photo.id] else { continue }
            let fields = [
                photo.id,
                row.blur.map { $0 ? "1" : "0" } ?? "",
                row.closedEyes.map { $0 ? "1" : "0" } ?? "",
                row.groupId,
                row.compositionIssue,
                row.exposureIssue.map { $0 ? "1" : "0" } ?? "",
                row.humanScore.map(String.init) ?? "",
            ]
            lines.append(CSV.writeRow(fields))
        }
        let text = lines.joined(separator: "\n") + "\n"
        try? text.write(to: labelsPath, atomically: true, encoding: .utf8)
    }
}
