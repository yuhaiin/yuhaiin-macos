import AppKit
import Foundation
import Security
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import YuhaiinShared

private final class AppTerminationCoordinator: @unchecked Sendable {
    private let supervisor: SupervisorClient

    init(supervisor: SupervisorClient) {
        self.supervisor = supervisor
    }

    func shutdown() {
        supervisor.stopAndReleaseBlocking()
    }
}

enum YuhaiinServiceState: String {
    case unavailable
    case awaitingApproval
    case stopped
    case starting
    case running
    case stopping
    case failed

    var title: String {
        switch self {
        case .unavailable: return L("state.unavailable")
        case .awaitingApproval: return L("state.awaitingApproval")
        case .stopped: return L("state.stopped")
        case .starting: return L("state.starting")
        case .running: return L("state.running")
        case .stopping: return L("state.stopping")
        case .failed: return L("state.failed")
        }
    }

    var symbol: String {
        switch self {
        case .running: return "checkmark.circle.fill"
        case .starting, .stopping: return "arrow.triangle.2.circlepath"
        case .failed: return "exclamationmark.triangle.fill"
        case .awaitingApproval: return "lock.fill"
        case .unavailable: return "questionmark.circle"
        case .stopped: return "power"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    private static let defaultAPIPort = 50051
    private static let expectedSupervisorURL = URL(fileURLWithPath: "/Applications/Yuhaiin.app/Contents/MacOS/YuhaiinSupervisor")

    @Published private(set) var state: YuhaiinServiceState = .unavailable
    @Published private(set) var apiAvailable = false
    @Published private(set) var uploadRate = 0.0
    @Published private(set) var downloadRate = 0.0
    @Published private(set) var yuhaiinVersion = L("version.unknown")
    @Published private(set) var yuhaiinUpdate: YuhaiinUpdateCheck?
    @Published private(set) var yuhaiinUpdateStatus: YuhaiinUpdateStatus?
    @Published private(set) var lastError = ""
    @Published private(set) var diagnostics: [String: String] = [:]
    @Published private(set) var recentLogs = ""
    @Published private(set) var supervisorAuthorized = false
    @Published private(set) var launchAtLogin = false
    @Published private(set) var binaryUploadInProgress = false
    @Published private(set) var uploadedBinaryInstalled = false
    @Published var autoStartYuhaiin: Bool {
        didSet { settingsStore.update { $0.autoStartYuhaiin = autoStartYuhaiin } }
    }
    @Published var showSpeed: Bool {
        didSet { settingsStore.update { $0.showSpeed = showSpeed } }
    }
    @Published var apiPortText: String
    @Published var apiAuthenticationEnabled: Bool
    @Published var apiUsernameText: String
    @Published var apiPasswordText: String
    @Published var customBinaryPathText: String

    private let supervisor = SupervisorClient()
    private let terminationCoordinator: AppTerminationCoordinator
    private let api = YuhaiinAPIClient()
    private let keychain = YuhaiinKeychain()
    private let settingsStore = YuhaiinSettingsStore()
    private var leaseID: String?
    private var desiredRunning = false
    private var activeAPICredentials: YuhaiinAPICredentials?
    private var activeBinaryPath: String?
    private var monitorTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var terminationObserver: NSObjectProtocol?

    init() {
        terminationCoordinator = AppTerminationCoordinator(supervisor: supervisor)
        let settings = settingsStore.settings
        autoStartYuhaiin = settings.autoStartYuhaiin
        showSpeed = settings.showSpeed
        apiPortText = String(Self.validatedAPIPort(settings.apiPort))
        api.setPort(Self.validatedAPIPort(settings.apiPort))
        let storedCredentials = try? keychain.read()
        apiAuthenticationEnabled = settings.apiAuthenticationEnabled && storedCredentials != nil
        apiUsernameText = storedCredentials?.username ?? ""
        apiPasswordText = storedCredentials?.password ?? ""
        customBinaryPathText = settings.customBinaryPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
        uploadedBinaryInstalled = settings.uploadedBinaryInstalled
        activeAPICredentials = apiAuthenticationEnabled ? storedCredentials : nil
        activeBinaryPath = customBinaryPathText.isEmpty ? nil : customBinaryPathText
        api.setCredentials(activeAPICredentials)
        desiredRunning = autoStartYuhaiin
        let terminationCoordinator = self.terminationCoordinator
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            terminationCoordinator.shutdown()
        }
        Task { [weak self] in
            await self?.bootstrap()
        }
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    var isBusy: Bool {
        state == .starting || state == .stopping || binaryUploadInProgress
    }

    var isRunning: Bool {
        state == .running
    }

    var formattedDownloadRate: String { Self.formatRate(downloadRate) }
    var formattedUploadRate: String { Self.formatRate(uploadRate) }
    var apiBaseAddress: String { api.baseURL.absoluteString }
    var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? L("version.unknown") }
    var appBuild: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? L("version.unknown") }
    var appSignatureStatus: String { Self.currentAppSignatureStatus }
    private var supervisorHost: String { "127.0.0.1:\(Self.validatedAPIPort(Int(apiPortText) ?? 0))" }

    func bootstrap() async {
        guard ensureSupervisorBundleIsInstalled() else { return }
        refreshServiceManagementState()
        do {
            let response = try await supervisor.status()
            updateState(from: response)
            await refreshDiagnostics()
        } catch {
            state = supervisorAuthorized ? .stopped : .awaitingApproval
            lastError = error.localizedDescription
        }

        if autoStartYuhaiin && desiredRunning {
            await startAsync()
        }
    }

    func installSupervisor() {
        guard ensureSupervisorBundleIsInstalled() else { return }
        do {
            let service = SMAppService.daemon(plistName: yuhaiinSupervisorLaunchDaemon)
            try service.register()
            refreshServiceManagementState()
            lastError = ""
            Task { await waitForSupervisorAuthorization() }
        } catch {
            lastError = L("error.installSupervisor", error.localizedDescription)
            state = .awaitingApproval
        }
    }

    func openSystemLoginItems() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refreshServiceManagementState()
        } catch {
            lastError = L("error.launchAtLogin", error.localizedDescription)
            refreshServiceManagementState()
        }
    }

    func applyAPIPort() {
        guard let port = Int(apiPortText.trimmingCharacters(in: .whitespacesAndNewlines)), (1...65535).contains(port) else {
            apiPortText = String(Self.validatedAPIPort(settingsStore.settings.apiPort))
            lastError = L("error.invalidPort")
            return
        }
        settingsStore.update { $0.apiPort = port }
        api.setPort(port)
        apiPortText = String(port)
        lastError = ""
        if isRunning {
            restart()
        }
    }

    func applyAPIAuthentication() {
        if !apiAuthenticationEnabled {
            do {
                try keychain.delete()
                activeAPICredentials = nil
                api.setCredentials(nil)
                settingsStore.update { $0.apiAuthenticationEnabled = false }
                lastError = ""
                if isRunning { restart() }
            } catch {
                lastError = L("error.disableAuthentication", error.localizedDescription)
            }
            return
        }

        let username = apiUsernameText.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = apiPasswordText
        guard !username.isEmpty, !username.contains(":"), username.utf8.count <= 128,
              !password.isEmpty, password.utf8.count <= 512 else {
            lastError = L("error.invalidCredentials")
            return
        }

        let credentials = YuhaiinAPICredentials(username: username, password: password)
        do {
            try keychain.save(credentials)
            apiUsernameText = username
            activeAPICredentials = credentials
            api.setCredentials(credentials)
            settingsStore.update { $0.apiAuthenticationEnabled = true }
            lastError = ""
            if isRunning { restart() }
        } catch {
            lastError = L("error.saveCredentials", error.localizedDescription)
        }
    }

    func applyCustomBinaryPath() {
        let path = customBinaryPathText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.isEmpty || FileManager.default.isExecutableFile(atPath: path) else {
            lastError = L("error.binaryUnavailable", path)
            return
        }
        customBinaryPathText = path
        activeBinaryPath = path.isEmpty ? nil : path
        uploadedBinaryInstalled = false
        settingsStore.update {
            $0.customBinaryPath = path
            $0.uploadedBinaryInstalled = false
        }
        lastError = ""
        if isRunning { restart() }
    }

    func useBundledBinary() {
        customBinaryPathText = ""
        applyCustomBinaryPath()
    }

    func handleBinaryImport(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }
            uploadBinary(from: url)
        case let .failure(error):
            let nsError = error as NSError
            if nsError.code != NSUserCancelledError {
                lastError = error.localizedDescription
            }
        }
    }

    func uploadBinary(from url: URL) {
        guard url.isFileURL, !isBusy else { return }
        let hasSecurityScope = url.startAccessingSecurityScopedResource()
        binaryUploadInProgress = true
        lastError = ""

        Task { [weak self] in
            guard let self else { return }
            defer {
                if hasSecurityScope { url.stopAccessingSecurityScopedResource() }
                self.binaryUploadInProgress = false
            }

            let wasRunning = self.isRunning
            if wasRunning {
                await self.stopAsync()
                guard self.state == .stopped else { return }
            }

            do {
                if self.leaseID == nil {
                    self.leaseID = try await self.supervisor.acquireLease()
                }
                // The privileged LaunchDaemon cannot directly read protected
                // user folders such as Downloads because of macOS TCC. Copy
                // the security-scoped selection into a private, random /tmp
                // directory while this user process still has access to it.
                let stagingDirectory = URL(fileURLWithPath: "/tmp", isDirectory: true)
                    .appendingPathComponent(".yuhaiin-upload-\(UUID().uuidString)", isDirectory: true)
                let stagedURL = stagingDirectory.appendingPathComponent(url.lastPathComponent, isDirectory: false)
                try FileManager.default.createDirectory(
                    at: stagingDirectory,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
                defer { try? FileManager.default.removeItem(at: stagingDirectory) }
                try FileManager.default.copyItem(at: url, to: stagedURL)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: stagedURL.path
                )

                let response = try await self.supervisor.installBinary(sourcePath: stagedURL.path)
                guard response[SupervisorResponseKey.ok] as? Bool == true else {
                    throw SupervisorClientError.rejected(response[SupervisorResponseKey.message] as? String ?? L("error.binaryInstall"))
                }

                customBinaryPathText = ""
                activeBinaryPath = nil
                uploadedBinaryInstalled = true
                settingsStore.update {
                    $0.customBinaryPath = ""
                    $0.uploadedBinaryInstalled = true
                }
                lastError = ""

                if wasRunning {
                    await self.startAsync()
                } else {
                    if self.leaseID != nil { _ = try? await self.supervisor.releaseLease() }
                    self.leaseID = nil
                }
            } catch {
                lastError = error.localizedDescription
                if wasRunning {
                    await self.startAsync()
                } else {
                    if self.leaseID != nil { _ = try? await self.supervisor.releaseLease() }
                    self.leaseID = nil
                }
            }
        }
    }

    func start() {
        desiredRunning = true
        Task { await startAsync() }
    }

    func stop() {
        desiredRunning = false
        Task { await stopAsync() }
    }

    func restart() {
        desiredRunning = true
        Task {
            await stopAsync()
            await startAsync()
        }
    }

    func openControlPage() {
        desiredRunning = true
        Task {
            if !isRunning {
                await startAsync()
            }
            guard apiAvailable || isRunning else { return }
            NSWorkspace.shared.open(api.baseURL)
        }
    }

    func refresh() {
        Task { await bootstrap() }
    }

    func refreshDiagnostics() {
        Task {
            await refreshDiagnostics()
            await refreshLogs()
        }
    }

    func exportDiagnostics() {
        let payload: [String: Any] = [
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "appVersion": appVersion,
            "appBuild": appBuild,
            "appSignature": appSignatureStatus,
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "architecture": Self.currentArchitecture,
            "state": state.rawValue,
            "apiAvailable": apiAvailable,
            "apiAddress": apiBaseAddress,
            "apiAuthenticationEnabled": apiAuthenticationEnabled,
            "supervisorAuthorized": supervisorAuthorized,
            "launchAtLogin": launchAtLogin,
            "autoStartYuhaiin": autoStartYuhaiin,
            "yuhaiinVersion": yuhaiinVersion,
            "diagnostics": diagnostics,
            "logs": Self.sanitizeLogs(recentLogs)
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else {
            lastError = L("error.exportDiagnostics")
            return
        }

        let panel = NSSavePanel()
        panel.title = L("diagnostics.exportTitle")
        panel.nameFieldStringValue = "Yuhaiin-diagnostics-\(Int(Date().timeIntervalSince1970)).json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url, options: [.atomic])
                Task { @MainActor in self?.lastError = L("diagnostics.exported", url.path) }
            } catch {
                Task { @MainActor in self?.lastError = L("diagnostics.exportFailed", error.localizedDescription) }
            }
        }
    }

    func uninstallSupervisor() {
        desiredRunning = false
        Task {
            if state != .stopped && state != .unavailable && state != .awaitingApproval {
                await stopAsync()
            }
            do {
                let daemon = SMAppService.daemon(plistName: yuhaiinSupervisorLaunchDaemon)
                if daemon.status == .enabled {
                    try await daemon.unregister()
                }
                if SMAppService.mainApp.status == .enabled {
                    try await SMAppService.mainApp.unregister()
                }
                supervisor.invalidate()
                refreshServiceManagementState()
                state = .awaitingApproval
                lastError = L("status.supervisorUninstalled")
            } catch {
                lastError = L("error.uninstallSupervisor", error.localizedDescription)
                refreshServiceManagementState()
            }
        }
    }

    func checkYuhaiinUpdate() {
        Task {
            guard isRunning else {
                lastError = L("error.startBeforeUpdate")
                return
            }
            do {
                yuhaiinUpdate = try await api.checkYuhaiinUpdate()
                yuhaiinUpdateStatus = try? await api.fetchYuhaiinUpdateStatus()
            } catch {
                lastError = L("error.checkYuhaiinUpdate", error.localizedDescription)
            }
        }
    }

    func applyYuhaiinUpdate() {
        Task {
            guard let update = yuhaiinUpdate, update.updateAvailable,
                  let assetURL = update.assetURL, !assetURL.isEmpty,
                  !update.assetSHA256.isEmpty else {
                lastError = L("error.noApplicableUpdate")
                return
            }
            guard !updateStatusIsRunning else { return }
            do {
                yuhaiinUpdateStatus = YuhaiinUpdateStatus(
                    running: true,
                    stage: "downloading",
                    progress: 0,
                    bytesDownloaded: 0,
                    totalBytes: 0,
                    error: ""
                )
                let response = try await supervisor.applyYuhaiinUpdate(
                    assetURL: assetURL,
                    sha256: update.assetSHA256,
                    targetVersion: update.targetVersion
                )
                guard response[SupervisorResponseKey.ok] as? Bool == true else {
                    throw SupervisorClientError.rejected(response[SupervisorResponseKey.message] as? String ?? L("error.updateYuhaiin"))
                }
                yuhaiinUpdateStatus = try? await api.fetchYuhaiinUpdateStatus()
                _ = try? await refreshAPI()
                lastError = ""
            } catch {
                yuhaiinUpdateStatus = YuhaiinUpdateStatus(
                    running: false,
                    stage: "error",
                    progress: 0,
                    bytesDownloaded: 0,
                    totalBytes: 0,
                    error: error.localizedDescription
                )
                lastError = L("error.applyYuhaiinUpdate", error.localizedDescription)
            }
        }
    }

    var updateStatusIsRunning: Bool {
        yuhaiinUpdateStatus?.running == true
    }

    var hasLegacyService: Bool {
        let value = diagnostics["legacyServiceInstalled"]?.lowercased()
        return value == "1" || value == "true" || value == "yes"
    }

    func adoptLegacyService() {
        Task {
            do {
                let response = try await supervisor.adoptLegacyService()
                guard response[SupervisorResponseKey.ok] as? Bool == true else {
                    throw SupervisorClientError.rejected(response[SupervisorResponseKey.message] as? String ?? L("error.migrateLegacy"))
                }
                await refreshDiagnostics()
                lastError = ""
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func shutdownBlocking() {
        monitorTask?.cancel()
        heartbeatTask?.cancel()
        supervisor.stopAndReleaseBlocking()
        leaseID = nil
    }

    private func startAsync() async {
        guard !isRunning, !isBusy else { return }
        guard ensureSupervisorBundleIsInstalled() else { return }
        state = .starting
        lastError = ""

        do {
            let daemon = SMAppService.daemon(plistName: yuhaiinSupervisorLaunchDaemon)
            if daemon.status != .enabled {
                try daemon.register()
                refreshServiceManagementState()
            }

            if leaseID == nil {
                leaseID = try await supervisor.acquireLease()
            }
            let response = try await supervisor.start(
                host: supervisorHost,
                credentials: activeAPICredentials,
                binaryPath: activeBinaryPath
            )
            guard response[SupervisorResponseKey.ok] as? Bool == true else {
                throw SupervisorClientError.rejected(response[SupervisorResponseKey.message] as? String ?? L("error.startYuhaiin"))
            }
            updateState(from: response)
            startMonitoring()
            try await refreshAPI()
        } catch {
            monitorTask?.cancel()
            heartbeatTask?.cancel()
            monitorTask = nil
            heartbeatTask = nil
            let requestTimedOut = (error as? SupervisorClientError)?.isTimeout == true
            if !requestTimedOut {
                _ = try? await supervisor.stop()
            }
            state = .failed
            lastError = error.localizedDescription
            if !requestTimedOut, leaseID != nil {
                _ = try? await supervisor.releaseLease()
            }
            self.leaseID = nil
        }
    }

    private func stopAsync() async {
        guard state != .stopped && state != .unavailable else { return }
        state = .stopping
        monitorTask?.cancel()
        heartbeatTask?.cancel()
        monitorTask = nil
        heartbeatTask = nil

        do {
            let response = try await supervisor.stop()
            updateState(from: response)
            if leaseID != nil {
                _ = try? await supervisor.releaseLease()
            }
        } catch {
            lastError = error.localizedDescription
            state = .failed
        }
        leaseID = nil
        apiAvailable = false
        uploadRate = 0
        downloadRate = 0
    }

    private func startMonitoring() {
        monitorTask?.cancel()
        heartbeatTask?.cancel()

        monitorTask = Task { [weak self] in
            var previousDownload: UInt64?
            var previousUpload: UInt64?
            var previousDate = Date()

            while !Task.isCancelled {
                guard let self else { return }
                do {
                    let flow = try await self.api.fetchFlow()
                    let now = Date()
                    let elapsed = max(now.timeIntervalSince(previousDate), 0.1)
                    let download = UInt64(flow.download) ?? 0
                    let upload = UInt64(flow.upload) ?? 0
                    if let previousDownload, download >= previousDownload {
                        self.downloadRate = Double(download - previousDownload) / elapsed
                    }
                    if let previousUpload, upload >= previousUpload {
                        self.uploadRate = Double(upload - previousUpload) / elapsed
                    }
                    previousDownload = download
                    previousUpload = upload
                    previousDate = now
                    self.apiAvailable = true
                } catch {
                    self.apiAvailable = false
                    self.uploadRate = 0
                    self.downloadRate = 0
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }

        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled, let self, self.leaseID != nil else { return }
                do {
                    try await self.supervisor.renewLease()
                } catch {
                    self.lastError = error.localizedDescription
                    self.state = .failed
                    return
                }
            }
        }
    }

    private func refreshAPI() async throws {
        let info = try await api.fetchInfo()
        yuhaiinVersion = info.version ?? L("version.unknown")
        apiAvailable = true
    }

    private func refreshDiagnostics() async {
        guard let response = try? await supervisor.diagnostics() else { return }
        var values: [String: String] = [:]
        for (key, value) in response {
            guard let key = key as? String else { continue }
            if let value = value as? String {
                values[key] = value
            } else if let value = value as? NSNumber {
                values[key] = value.stringValue
            } else if let value = value as? Bool {
                values[key] = value ? "true" : "false"
            }
        }
        diagnostics = values
        guard customBinaryPathText.isEmpty,
              let source = values["runtimeBinarySource"] else { return }
        let installed = source == "uploaded"
        if uploadedBinaryInstalled != installed {
            uploadedBinaryInstalled = installed
            settingsStore.update { $0.uploadedBinaryInstalled = installed }
        }
    }

    private func refreshLogs() async {
        guard let response = try? await supervisor.readLogs(),
              let logs = response[SupervisorResponseKey.logs] as? String else { return }
        recentLogs = Self.sanitizeLogs(logs)
    }

    private func ensureSupervisorBundleIsInstalled() -> Bool {
        guard FileManager.default.isExecutableFile(atPath: Self.expectedSupervisorURL.path) else {
            state = .failed
            lastError = L("error.supervisorInstallLocation", Bundle.main.bundleURL.path)
            presentInstallLocationPrompt()
            return false
        }
        return true
    }

    private func presentInstallLocationPrompt() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("installation.title")
        alert.informativeText = L("installation.message", Bundle.main.bundleURL.path)
        alert.addButton(withTitle: L("installation.openApplications"))
        alert.addButton(withTitle: L("common.cancel"))

        let openApplications: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true))
        }
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window, completionHandler: openApplications)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            openApplications(alert.runModal())
        }
    }

    private func refreshServiceManagementState() {
        let daemon = SMAppService.daemon(plistName: yuhaiinSupervisorLaunchDaemon)
        supervisorAuthorized = daemon.status == .enabled
        launchAtLogin = SMAppService.mainApp.status == .enabled
        if !supervisorAuthorized && state == .unavailable {
            state = .awaitingApproval
        }
    }

    private func waitForSupervisorAuthorization() async {
        for _ in 0..<15 {
            refreshServiceManagementState()
            if supervisorAuthorized { return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        refreshServiceManagementState()
    }

    private func updateState(from response: NSDictionary) {
        guard let rawState = response[SupervisorResponseKey.state] as? String,
              let next = YuhaiinServiceState(rawValue: rawState) else { return }
        state = next
        if let message = response[SupervisorResponseKey.message] as? String {
            lastError = message
        }
    }

    private static func formatRate(_ rate: Double) -> String {
        guard rate.isFinite, rate >= 0 else { return "--" }
        if rate < 1_000 { return String(format: "%.0f B/s", rate) }
        if rate < 1_000_000 { return String(format: "%.1f KB/s", rate / 1_000) }
        if rate < 1_000_000_000 { return String(format: "%.1f MB/s", rate / 1_000_000) }
        return String(format: "%.1f GB/s", rate / 1_000_000_000)
    }

    private static func validatedAPIPort(_ port: Int) -> Int {
        (1...65535).contains(port) ? port : defaultAPIPort
    }

    private static var currentArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    private static var currentAppSignatureStatus: String {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess,
              let code else { return L("signature.unavailable") }
        return SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess ? L("signature.valid") : L("signature.invalid")
    }

    private static func sanitizeLogs(_ logs: String) -> String {
        let patterns = [
            #"(?i)(authorization\s*:\s*(?:basic|bearer)\s+)[^\s]+"#,
            #"(?i)((?:password|passwd|token|secret|access[_-]?token)\s*[=:]\s*)[^&\s]+"#
        ]
        var sanitized = logs
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(sanitized.startIndex..<sanitized.endIndex, in: sanitized)
            sanitized = expression.stringByReplacingMatches(
                in: sanitized,
                options: [],
                range: range,
                withTemplate: "$1[REDACTED]"
            )
        }
        return sanitized
    }
}
