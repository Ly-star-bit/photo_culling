import Foundation

/// Machine-specific paths, persisted in Application Support so a migrated
/// install can point at its own runtime folders without rebuilding the app.
struct AppConfig: Codable {
    var pythonRoot: String?

    static let defaultPythonRoot = "/Users/xiaohe/server/Bonsai_photo/culling-poc"

    static func path(in dataDir: URL) -> URL {
        dataDir.appendingPathComponent("settings.json")
    }

    static func load(from dataDir: URL) -> AppConfig {
        guard let data = try? Data(contentsOf: path(in: dataDir)),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            return AppConfig()
        }
        return config
    }

    func save(to dataDir: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) {
            try? data.write(to: Self.path(in: dataDir))
        }
    }

    /// Resolution order: explicit config → imported runtime folder in App
    /// Support (any machine, username-independent) → dev-machine default.
    /// The hardcoded defaults only matter on the machine this app was built on;
    /// a migrated install always hits one of the first two.
    func resolvedPythonRoot(dataDir: URL) -> URL {
        if let pythonRoot { return URL(fileURLWithPath: pythonRoot) }
        let runtime = dataDir.appendingPathComponent("runtime/culling-poc")
        if FileManager.default.fileExists(atPath: runtime.path) { return runtime }
        return URL(fileURLWithPath: Self.defaultPythonRoot)
    }
}
