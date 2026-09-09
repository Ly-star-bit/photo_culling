import Foundation
import SwiftUI
import AppKit

@MainActor
final class LabelStore: ObservableObject {
    @Published var photos: [Photo] = []
    /// Every row of labels.csv, keyed by id — including rows whose id is no
    /// longer in the manifest (trash/purge). Those are written back unchanged.
    @Published var labels: [String: LabelRow] = [:]
    @Published var currentIndex: Int = 0
    /// Fatal for this session: manifest unreadable, or labels.csv exists but
    /// cannot be parsed (saving is disabled so a 1-row write never clobbers it).
    @Published var loadError: String?
    /// Non-fatal: layer1/layer2 JSON present but undecodable — reference
    /// signals show "-" for a reason other than "not analyzed".
    @Published var loadWarning: String?
    /// Last labels.csv write failure; cleared by the next successful save.
    @Published var saveError: String?
    /// Sidebar filter; auto-advance follows it so the next photo stays visible.
    @Published var showOnlyUnlabeled = false

    var layer1ById: [String: Layer1Result] = [:]
    var layer2ById: [String: Layer2Result] = [:]

    private(set) var dataDir: URL
    var labelsPath: URL { dataDir.appendingPathComponent("labels.csv") }
    var backupPath: URL { dataDir.appendingPathComponent("labels.csv.bak") }
    private let csvColumns = ["id", "blur", "closed_eyes", "group_id", "composition_issue", "exposure_issue", "human_score"]

    private var labelsUnreadable = false
    private var dirty = false
    private var saveTask: Task<Void, Never>?
    /// Data rows in labels.csv as last read from or written to disk; a save
    /// that would shrink below this takes a fresh backup first.
    private var persistedRowCount = 0
    private var backedUpSinceLoad = false

    init(dataDir: URL) {
        self.dataDir = dataDir
        load()
        // Fresh analysis / session switch from the batch tab: follow the session
        // dir carried in the notification and reload. Pending edits are flushed
        // first so they land in the dir they were made in.
        NotificationCenter.default.addObserver(forName: .analysisDidFinish, object: nil, queue: .main) { [weak self] note in
            let dir = note.userInfo?["dir"] as? URL
            MainActor.assumeIsolated {
                guard let self else { return }
                self.flush()
                let sameDir = dir.map { $0.standardizedFileURL == self.dataDir.standardizedFileURL } ?? true
                let keepId = self.currentPhoto?.id
                let keepIndex = self.currentIndex
                if let dir { self.dataDir = dir }
                self.load()
                // Same session (VLM finished, trash, re-analysis): stay where the
                // user was instead of yanking them back to photo 1.
                if sameDir, !self.photos.isEmpty {
                    if let keepId, let idx = self.photos.firstIndex(where: { $0.id == keepId }) {
                        self.currentIndex = idx
                    } else {
                        self.currentIndex = min(keepIndex, self.photos.count - 1)
                    }
                }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    var currentPhoto: Photo? {
        guard photos.indices.contains(currentIndex) else { return nil }
        return photos[currentIndex]
    }

    /// Completed rows among the photos of THIS manifest (orphan rows excluded).
    var labeledCount: Int {
        photos.reduce(0) { $0 + (isComplete($1.id) ? 1 : 0) }
    }

    func layer1(for id: String) -> Layer1Result? { layer1ById[id] }
    func layer2(for id: String) -> Layer2Result? { layer2ById[id] }

    func binding(for id: String) -> LabelRow {
        labels[id] ?? defaultRow(for: id)
    }

    func isComplete(_ id: String) -> Bool {
        labels[id]?.isComplete ?? false
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
        scheduleSave()
    }

    func goTo(_ index: Int) {
        guard photos.indices.contains(index) else { return }
        flush()
        currentIndex = index
    }

    func next() { goTo(currentIndex + 1) }
    func previous() { goTo(currentIndex - 1) }

    /// First incomplete photo after the current one, wrapping around; no-op
    /// when everything is labeled.
    func nextUnlabeled() {
        let n = photos.count
        guard n > 0 else { return }
        for step in 1...n {
            let idx = (currentIndex + step) % n
            if !isComplete(photos[idx].id) {
                goTo(idx)
                return
            }
        }
    }

    /// What "advance" means after scoring: with the unlabeled filter on, the
    /// plain next photo may be hidden from the sidebar, so skip to the next
    /// unlabeled one instead.
    func advanceAfterScore() {
        if showOnlyUnlabeled { nextUnlabeled() } else { next() }
    }

    // MARK: - Loading

    /// The native engine writes absolute preview paths; a relative path (older
    /// sessions, hand-edited manifests) is taken relative to the session dir.
    static func resolve(_ path: String, against root: URL) -> String {
        if path.hasPrefix("/") { return path }
        return root.appendingPathComponent(path).path
    }

    func load() {
        let decoder = JSONDecoder()
        loadError = nil
        loadWarning = nil
        saveError = nil
        photos = []
        layer1ById = [:]
        layer2ById = [:]
        // 必须清空：loadLabels 是"合并写入"，不清的话上一场的标注会跟着 id
        // （文件名 stem，跨场次大量重复）串进这一场，并被 save() 写进它的 labels.csv。
        labels = [:]
        currentIndex = 0
        dirty = false
        saveTask?.cancel()
        saveTask = nil
        labelsUnreadable = false
        persistedRowCount = 0
        backedUpSinceLoad = false

        let manifestPath = dataDir.appendingPathComponent("manifest.json")
        // No manifest = analysis simply hasn't run yet; the empty state (with its
        // "先跑一次分析" hint) covers that. Only an unreadable/corrupt file is an error.
        guard FileManager.default.fileExists(atPath: manifestPath.path) else { return }
        do {
            let manifestData = try Data(contentsOf: manifestPath)
            let manifest = try decoder.decode(Manifest.self, from: manifestData)
            photos = manifest.photos.map { photo in
                var photo = photo
                photo.previewPath = Self.resolve(photo.previewPath, against: dataDir)
                photo.rawPath = Self.resolve(photo.rawPath, against: dataDir)
                return photo
            }
        } catch {
            loadError = "读取 manifest.json 失败: \(error.localizedDescription)"
            return
        }

        // A missing layer file is normal (analysis / VLM not run yet); only a
        // file that exists but won't decode is worth telling the user about.
        var warnings: [String] = []
        let layer1Path = dataDir.appendingPathComponent("layer1_results.json")
        if FileManager.default.fileExists(atPath: layer1Path.path) {
            do {
                let file = try decoder.decode(Layer1File.self, from: Data(contentsOf: layer1Path))
                for r in file.results where r.error == nil {
                    layer1ById[r.id] = r
                }
            } catch {
                warnings.append("layer1_results.json 无法解析（\(error.localizedDescription)），算法信号显示为 -")
            }
        }

        let layer2Path = dataDir.appendingPathComponent("layer2_results.json")
        if FileManager.default.fileExists(atPath: layer2Path.path) {
            do {
                let file = try decoder.decode(Layer2File.self, from: Data(contentsOf: layer2Path))
                for r in file.results where r.error == nil {
                    layer2ById[r.id] = r
                }
            } catch {
                warnings.append("layer2_results.json 无法解析（\(error.localizedDescription)），VLM 信号不显示")
            }
        }
        loadWarning = warnings.isEmpty ? nil : warnings.joined(separator: "\n")

        loadLabels()
    }

    private func loadLabels() {
        guard FileManager.default.fileExists(atPath: labelsPath.path) else { return }
        let text: String
        do {
            text = try String(contentsOf: labelsPath, encoding: .utf8)
        } catch {
            refuseLabels("读取 labels.csv 失败: \(error.localizedDescription)")
            return
        }
        let rows = CSV.parseRows(text)
        // Empty / whitespace-only file: nothing to lose, saving is fine.
        guard let header = rows.first else { return }
        let colIndex = CSV.columnIndex(header)
        guard let idIdx = colIndex["id"] else {
            refuseLabels("labels.csv 表头缺少 id 列")
            return
        }

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
        persistedRowCount = labels.count
    }

    private func refuseLabels(_ reason: String) {
        labelsUnreadable = true
        loadError = reason + "\n为避免覆盖已有标注，本场次已禁用保存。请修复或移走 \(labelsPath.path)，然后在批量处理页重新分析或切换一次场次。"
    }

    // MARK: - Saving

    /// TextField edits call this per keystroke; the CSV is rewritten at most
    /// once per 0.5s, and immediately on photo change / app termination.
    private func scheduleSave() {
        dirty = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    /// Write pending edits now (photo change, session switch, quit).
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        if dirty { save() }
    }

    func save() {
        guard !labelsUnreadable else {
            saveError = "labels.csv 无法读取，已禁用保存"
            return
        }
        // Manifest order first, then rows whose photo is gone (sorted so the
        // file doesn't churn between saves).
        let photoIds = photos.map(\.id)
        let known = Set(photoIds)
        let orphanIds = labels.keys.filter { !known.contains($0) }.sorted()
        var lines = [CSV.writeRow(csvColumns)]
        var rowCount = 0
        for id in photoIds + orphanIds {
            guard let row = labels[id] else { continue }
            lines.append(CSV.writeRow(fields(for: id, row)))
            rowCount += 1
        }
        let text = lines.joined(separator: "\n") + "\n"

        let fm = FileManager.default
        do {
            // One backup per load, plus a fresh one whenever a save would drop
            // rows — that is the write a user most wants to be able to undo.
            if fm.fileExists(atPath: labelsPath.path), !backedUpSinceLoad || rowCount < persistedRowCount {
                if fm.fileExists(atPath: backupPath.path) {
                    try fm.removeItem(at: backupPath)
                }
                try fm.copyItem(at: labelsPath, to: backupPath)
                backedUpSinceLoad = true
            }
            try Data(text.utf8).write(to: labelsPath, options: .atomic)
            persistedRowCount = rowCount
            dirty = false
            if saveError != nil { saveError = nil }
        } catch {
            saveError = "保存 labels.csv 失败: \(error.localizedDescription)"
        }
    }

    private func fields(for id: String, _ row: LabelRow) -> [String] {
        [
            id,
            row.blur.map { $0 ? "1" : "0" } ?? "",
            row.closedEyes.map { $0 ? "1" : "0" } ?? "",
            row.groupId,
            row.compositionIssue,
            row.exposureIssue.map { $0 ? "1" : "0" } ?? "",
            row.humanScore.map(String.init) ?? "",
        ]
    }
}
