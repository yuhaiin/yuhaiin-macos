import Foundation

struct YuhaiinAppSettings: Codable {
    var autoStartYuhaiin = false
    var showSpeed = true
    var apiPort = 50051
    var apiAuthenticationEnabled = false
    var customBinaryPath = ""
    var uploadedBinaryInstalled = false

    private enum CodingKeys: String, CodingKey {
        case autoStartYuhaiin
        case showSpeed
        case apiPort
        case apiAuthenticationEnabled
        case customBinaryPath
        case uploadedBinaryInstalled
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        autoStartYuhaiin = try container.decodeIfPresent(Bool.self, forKey: .autoStartYuhaiin) ?? false
        showSpeed = try container.decodeIfPresent(Bool.self, forKey: .showSpeed) ?? true
        apiPort = try container.decodeIfPresent(Int.self, forKey: .apiPort) ?? 50051
        apiAuthenticationEnabled = try container.decodeIfPresent(Bool.self, forKey: .apiAuthenticationEnabled) ?? false
        customBinaryPath = try container.decodeIfPresent(String.self, forKey: .customBinaryPath) ?? ""
        uploadedBinaryInstalled = try container.decodeIfPresent(Bool.self, forKey: .uploadedBinaryInstalled) ?? false
    }
}

final class YuhaiinSettingsStore {
    private(set) var settings: YuhaiinAppSettings
    let fileURL: URL

    init() {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let directory = applicationSupport.appendingPathComponent("YuhaiinMacOS", isDirectory: true)
        fileURL = directory.appendingPathComponent("settings.json")

        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(YuhaiinAppSettings.self, from: data) {
            settings = decoded
        } else {
            var migrated = YuhaiinAppSettings()
            let defaults = UserDefaults.standard
            migrated.autoStartYuhaiin = defaults.bool(forKey: "yuhaiin.autoStart")
            migrated.showSpeed = defaults.object(forKey: "yuhaiin.showSpeed") as? Bool ?? true
            let savedPort = defaults.integer(forKey: "yuhaiin.port")
            if (1...65535).contains(savedPort) { migrated.apiPort = savedPort }
            migrated.apiAuthenticationEnabled = defaults.bool(forKey: "yuhaiin.apiAuth")
            settings = migrated
            save()
        }
    }

    func update(_ mutate: (inout YuhaiinAppSettings) -> Void) {
        mutate(&settings)
        save()
    }

    private func save() {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let data = try JSONEncoder().encode(settings)
            try data.write(to: fileURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            // Settings failures are surfaced when a feature operation fails;
            // keeping the in-memory value avoids interrupting the UI.
        }
    }
}
