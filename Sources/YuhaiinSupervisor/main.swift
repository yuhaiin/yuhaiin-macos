import Darwin
import CryptoKit
import Foundation
import Security
import YuhaiinShared

private final class SupervisorCore: @unchecked Sendable {
    private static let maxUpdateBytes: Int64 = 512 * 1024 * 1024
    private static let legacyService = "com.asutorufa.yuhaiin"
    private static let legacyPlist = "/Library/LaunchDaemons/com.asutorufa.yuhaiin.plist"
    private let queue = DispatchQueue(label: "com.asutorufa.yuhaiin.supervisor.core")
    private let leaseTimer: DispatchSourceTimer
    private var process: Process?
    private var state = "stopped"
    private var lastError = ""
    private var leaseIDs = Set<String>()
    private var leaseRenewedAt: [String: Date] = [:]
    private var startedAt: Date?
    private var updateRunning = false
    private var configuredHost: String
    private var configuredUsername = ""
    private var configuredPassword = ""
    private var configuredBinaryPath = ""
    private var pendingStop: DispatchWorkItem?

    init() {
        configuredHost = ProcessInfo.processInfo.environment["YUHAIIN_HOST"] ?? "127.0.0.1:50051"
        leaseTimer = DispatchSource.makeTimerSource(queue: queue)
        leaseTimer.schedule(deadline: .now() + 1, repeating: 1)
        leaseTimer.setEventHandler { [weak self] in
            self?.expireLeasesLocked()
        }
        leaseTimer.resume()
    }

    deinit {
        leaseTimer.cancel()
    }

    func snapshot() -> NSDictionary {
        queue.sync { snapshotLocked() }
    }

    func acquireLease() -> NSDictionary {
        queue.sync {
            pendingStop?.cancel()
            pendingStop = nil
            let leaseID = UUID().uuidString
            leaseIDs.insert(leaseID)
            leaseRenewedAt[leaseID] = Date()
            return responseLocked(ok: true, extra: [SupervisorResponseKey.leaseID: leaseID])
        }
    }

    func renewLease(_ leaseID: String) -> NSDictionary {
        queue.sync {
            guard leaseIDs.contains(leaseID) else {
                return responseLocked(ok: false, message: "lease is no longer valid", errorCode: "lease_expired")
            }
            leaseRenewedAt[leaseID] = Date()
            return responseLocked(ok: true)
        }
    }

    func releaseLease(_ leaseID: String, grace: Bool = false) -> NSDictionary {
        queue.sync {
            leaseIDs.remove(leaseID)
            leaseRenewedAt.removeValue(forKey: leaseID)
            if leaseIDs.isEmpty, process?.isRunning == true {
                if grace {
                    scheduleGracefulStopLocked()
                } else {
                    stopLocked()
                }
            }
            clearCredentialsIfUnleasedLocked()
            return responseLocked(ok: true)
        }
    }

    func start(
        host: String,
        username: String,
        password: String,
        binaryPath: String,
        reply: @escaping (NSDictionary) -> Void
    ) {
        queue.async {
            let binaryPath = binaryPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.isValidLocalHost(host) else {
                reply(self.responseLocked(ok: false, message: "host must be a localhost address with a valid port", errorCode: "invalid_host"))
                return
            }
            guard binaryPath.utf8.count <= 2048 else {
                reply(self.responseLocked(ok: false, message: "custom yuhaiin binary path is too long", errorCode: "invalid_binary_path"))
                return
            }
            guard Self.isValidCredentials(username: username, password: password) else {
                reply(self.responseLocked(ok: false, message: "API credentials are invalid", errorCode: "invalid_credentials"))
                return
            }
            guard !self.leaseIDs.isEmpty else {
                reply(self.responseLocked(ok: false, message: "no active application lease", errorCode: "no_lease"))
                return
            }

            if let process = self.process, process.isRunning {
                if self.configuredHost == host,
                   self.configuredUsername == username,
                   self.configuredPassword == password,
                   self.configuredBinaryPath == binaryPath {
                    self.state = "running"
                    reply(self.snapshotLocked())
                    return
                }
                self.stopLocked()
            }

            if let legacyPID = self.legacyServicePID() {
                reply(self.responseLocked(
                    ok: false,
                    message: "Legacy yuhaiin service is still running (PID \(legacyPID)); migrate it first",
                    errorCode: "legacy_service_conflict"
                ))
                return
            }

            do {
                try self.startProcessLocked(
                    host: host,
                    username: username,
                    password: password,
                    binaryPath: binaryPath
                )
                reply(self.snapshotLocked())
            } catch {
                self.state = "failed"
                self.lastError = error.localizedDescription
                reply(self.responseLocked(ok: false, message: self.lastError, errorCode: "start_failed"))
            }
        }
    }

    func stop(reply: @escaping (NSDictionary) -> Void) {
        queue.async {
            self.stopLocked()
            reply(self.snapshotLocked())
        }
    }

    func diagnostics() -> NSDictionary {
        queue.sync {
            let dataPath = ProcessInfo.processInfo.environment["YUHAIIN_DATA_PATH"] ?? "/Library/Application Support/yuhaiin"
            let legacyPlist = Self.legacyPlist
            let runtimeBinary = configuredBinaryPath.isEmpty
                ? URL(fileURLWithPath: dataPath).appendingPathComponent("bin/yuhaiin").path
                : configuredBinaryPath
            let runtimeBinarySource = runtimeSource(
                dataPath: dataPath,
                configuredBinaryPath: configuredBinaryPath
            )
            var values: [String: Any] = [
                "supervisorPID": NSNumber(value: getpid()),
                "supervisorUID": NSNumber(value: getuid()),
                "dataPath": dataPath,
                "runtimeBinary": runtimeBinary,
                "runtimeBinarySource": runtimeBinarySource,
                "host": configuredHost,
                "architecture": Self.currentArchitecture,
                "binaryPath": configuredBinaryPath.isEmpty ? "embedded" : configuredBinaryPath,
                "apiAuthenticationEnabled": !configuredUsername.isEmpty,
                "legacyServiceInstalled": FileManager.default.fileExists(atPath: legacyPlist),
                "state": state,
                "childPID": process?.isRunning == true ? NSNumber(value: process!.processIdentifier) : NSNull()
            ]
            values["legacyServicePID"] = legacyServicePID().map(NSNumber.init(value:)) ?? NSNull()
            return NSDictionary(dictionary: values)
        }
    }

    func readLogs() -> NSDictionary {
        queue.sync {
            let dataPath = ProcessInfo.processInfo.environment["YUHAIIN_DATA_PATH"] ?? "/Library/Application Support/yuhaiin"
            let candidates = [
                URL(fileURLWithPath: dataPath).appendingPathComponent("logs/yuhaiin.log"),
                URL(fileURLWithPath: "/var/log/yuhaiin.log")
            ]
            guard let logURL = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
                  let handle = try? FileHandle(forReadingFrom: logURL) else {
                return NSDictionary(dictionary: [SupervisorResponseKey.ok: true, SupervisorResponseKey.logs: ""])
            }
            defer { try? handle.close() }
            let maxBytes: UInt64 = 64 * 1024
            let size = (try? handle.seekToEnd()) ?? 0
            let offset = size > maxBytes ? size - maxBytes : 0
            try? handle.seek(toOffset: offset)
            let data = (try? handle.readToEnd()) ?? Data()
            let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            return NSDictionary(dictionary: [
                SupervisorResponseKey.ok: true,
                SupervisorResponseKey.logs: text
            ])
        }
    }

    func adoptLegacyService(reply: @escaping (NSDictionary) -> Void) {
        queue.async {
            guard self.process?.isRunning != true else {
                reply(self.responseLocked(ok: false, message: "Stop the current yuhaiin instance before migration", errorCode: "running"))
                return
            }
            guard FileManager.default.fileExists(atPath: Self.legacyPlist) else {
                reply(self.responseLocked(ok: true, message: "No legacy service found"))
                return
            }

            let migrationDirectory = self.dataPathURL().appendingPathComponent("migration", isDirectory: true)
            let backup = migrationDirectory.appendingPathComponent("com.asutorufa.yuhaiin.\(Int(Date().timeIntervalSince1970)).plist")
            var bootedOut = false
            do {
                try self.ensurePrivateDirectory(at: migrationDirectory)
                if let pid = self.legacyServicePID() {
                    try self.runLaunchctl(["bootout", "system", Self.legacyPlist])
                    bootedOut = true
                    try self.waitForProcessExit(pid)
                } else if self.launchctlPrintSucceeds() {
                    try self.runLaunchctl(["bootout", "system", Self.legacyPlist])
                    bootedOut = true
                }
                try FileManager.default.moveItem(atPath: Self.legacyPlist, toPath: backup.path)
                reply(self.responseLocked(ok: true, extra: ["legacyBackup": backup.path]))
            } catch {
                if bootedOut {
                    try? self.runLaunchctl(["bootstrap", "system", Self.legacyPlist])
                    try? self.runLaunchctl(["kickstart", "system/\(Self.legacyService)"])
                }
                reply(self.responseLocked(ok: false, message: "Legacy service migration failed: \(error.localizedDescription)", errorCode: "legacy_migration_failed"))
            }
        }
    }

    func installBinary(sourcePath: String, reply: @escaping (NSDictionary) -> Void) {
        queue.async {
            guard !self.leaseIDs.isEmpty else {
                reply(self.responseLocked(ok: false, message: "no active application lease", errorCode: "no_lease"))
                return
            }
            guard self.process?.isRunning != true else {
                reply(self.responseLocked(ok: false, message: "stop yuhaiin before installing a binary", errorCode: "running"))
                return
            }
            let sourcePath = sourcePath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sourcePath.isEmpty, sourcePath.utf8.count <= 4096 else {
                reply(self.responseLocked(ok: false, message: "binary source path is invalid", errorCode: "invalid_binary_path"))
                return
            }

            do {
                let target = try self.installUploadedBinaryLocked(sourcePath: sourcePath)
                self.state = "stopped"
                reply(self.responseLocked(ok: true, extra: ["runtimeBinary": target.path]))
            } catch {
                self.state = "failed"
                self.lastError = error.localizedDescription
                reply(self.responseLocked(ok: false, message: self.lastError, errorCode: "binary_install_failed"))
            }
        }
    }

    func applyYuhaiinUpdate(assetURL: String, sha256: String, targetVersion: String, reply: @escaping (NSDictionary) -> Void) {
        queue.async {
            guard !self.leaseIDs.isEmpty else {
                reply(self.responseLocked(ok: false, message: "no active application lease", errorCode: "no_lease"))
                return
            }
            guard !self.updateRunning else {
                reply(self.responseLocked(ok: false, message: "an update is already running", errorCode: "update_running"))
                return
            }
            guard let url = URL(string: assetURL), url.scheme?.lowercased() == "https", url.host != nil else {
                reply(self.responseLocked(ok: false, message: "update URL must use HTTPS", errorCode: "invalid_update_url"))
                return
            }
            guard assetURL.utf8.count <= 2048, targetVersion.utf8.count <= 128 else {
                reply(self.responseLocked(ok: false, message: "update request is too large", errorCode: "invalid_update_request"))
                return
            }
            guard Self.isValidSHA256(sha256) else {
                reply(self.responseLocked(ok: false, message: "update checksum is invalid", errorCode: "invalid_checksum"))
                return
            }

            self.updateRunning = true
            self.state = "maintenance"
            self.lastError = ""
            let stagingDirectory = self.dataPathURL().appendingPathComponent("updates/.staging", isDirectory: true)
            let stagingURL = stagingDirectory.appendingPathComponent("yuhaiin-\(UUID().uuidString)", isDirectory: false)

            // Capture strongly: the task must always run to completion so
            // `updateRunning` is reset and `reply` is called.
            Task { [self] in
                do {
                    try self.ensurePrivateDirectory(at: stagingDirectory)
                    try await Self.download(url: url, to: stagingURL)
                    self.queue.async {
                        guard !self.leaseIDs.isEmpty else {
                            try? FileManager.default.removeItem(at: stagingURL)
                            self.updateRunning = false
                            self.state = "stopped"
                            reply(self.responseLocked(ok: false, message: "application lease expired during update", errorCode: "lease_expired"))
                            return
                        }
                        do {
                            let response = try self.installUpdateLocked(
                                stagedURL: stagingURL,
                                expectedSHA256: sha256,
                                targetVersion: targetVersion
                            )
                            self.updateRunning = false
                            reply(response)
                        } catch {
                            self.updateRunning = false
                            self.state = self.process?.isRunning == true ? "running" : "failed"
                            self.lastError = error.localizedDescription
                            reply(self.responseLocked(ok: false, message: error.localizedDescription, errorCode: "update_failed"))
                        }
                    }
                } catch {
                    self.queue.async {
                        try? FileManager.default.removeItem(at: stagingURL)
                        self.updateRunning = false
                        self.state = self.process?.isRunning == true ? "running" : "failed"
                        self.lastError = error.localizedDescription
                        reply(self.responseLocked(ok: false, message: error.localizedDescription, errorCode: "update_failed"))
                    }
                }
            }
        }
    }

    private func startProcessLocked(
        host: String,
        username: String,
        password: String,
        binaryPath: String
    ) throws {
        guard !updateRunning else {
            throw SupervisorError.updateInProgress
        }
        state = "starting"
        lastError = ""
        let previousHost = configuredHost
        let previousUsername = configuredUsername
        let previousPassword = configuredPassword
        let previousBinaryPath = configuredBinaryPath
        configuredHost = host
        configuredUsername = username
        configuredPassword = password
        configuredBinaryPath = binaryPath
        let child: Process
        do {
            child = try makeProcess(
                host: host,
                username: username,
                password: password,
                binaryPath: binaryPath
            )
        } catch {
            configuredHost = previousHost
            configuredUsername = previousUsername
            configuredPassword = previousPassword
            configuredBinaryPath = previousBinaryPath
            throw error
        }
        process = child
        startedAt = Date()
        child.terminationHandler = { [weak self] process in
            guard let self else { return }
            self.queue.async {
                if self.process?.processIdentifier == process.processIdentifier {
                    self.process = nil
                    if self.state != "stopping" && process.terminationStatus != 0 {
                        self.state = "failed"
                        self.lastError = "yuhaiin exited with status \(process.terminationStatus)"
                    } else if self.state != "stopping" && self.state != "maintenance" {
                        self.state = "stopped"
                    }
                }
            }
        }
        try child.run()
        guard waitForPort(host: host), child.isRunning else {
            stopLocked()
            configuredHost = previousHost
            configuredUsername = previousUsername
            configuredPassword = previousPassword
            configuredBinaryPath = previousBinaryPath
            throw SupervisorError.readinessTimeout
        }
        state = "running"
    }

    private func makeProcess(
        host: String,
        username: String,
        password: String,
        binaryPath: String
    ) throws -> Process {
        let binary = try runtimeBinaryURL(binaryPath: binaryPath.isEmpty ? nil : binaryPath)
        guard Self.hasCurrentArchitecture(at: binary), Self.hasValidCodeSignature(at: binary) else {
            throw SupervisorError.invalidUpdatedBinary
        }
        let dataPath = dataPathURL()

        try ensurePrivateDirectory(at: dataPath)
        let logDirectory = dataPath.appendingPathComponent("logs", isDirectory: true)
        try ensurePrivateDirectory(at: logDirectory)
        let logURL = logDirectory.appendingPathComponent("yuhaiin.log")
        guard !Self.isSymbolicLink(at: logURL.path) else {
            throw SupervisorError.unsafeDataPath(logURL.path)
        }
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)

        let output = try FileHandle(forWritingTo: logURL)
        try output.seekToEnd()

        let child = Process()
        child.executableURL = binary
        child.arguments = [
            "run",
            "-host", host,
            "-path", dataPath.path
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["YUHAIIN_PARENT_PID"] = String(getpid())
        environment["YUHAIIN_API_USERNAME"] = username.isEmpty ? nil : username
        environment["YUHAIIN_API_PASSWORD"] = password.isEmpty ? nil : password
        child.environment = environment
        child.standardOutput = output
        child.standardError = output
        return child
    }

    private func yuhaiinBinaryURL(pathOverride: String? = nil) throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let configured = pathOverride ?? environment["YUHAIIN_BINARY_PATH"]
        if let configured, !configured.isEmpty {
            let url = URL(fileURLWithPath: configured)
            guard !Self.isSymbolicLink(at: url.path),
                  FileManager.default.isExecutableFile(atPath: url.path) else {
                throw SupervisorError.binaryUnavailable(url.path)
            }
            return url
        }

        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        let contents = executable.deletingLastPathComponent().deletingLastPathComponent()
        #if arch(arm64)
        let name = "yuhaiin-darwin-arm64"
        #else
        let name = "yuhaiin-darwin-amd64"
        #endif
        let url = contents.appendingPathComponent("Resources", isDirectory: true).appendingPathComponent(name)
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw SupervisorError.binaryUnavailable(url.path)
        }
        return url
    }

    private func dataPathURL() -> URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["YUHAIIN_DATA_PATH"] ?? "/Library/Application Support/yuhaiin", isDirectory: true)
    }

    private func ensurePrivateDirectory(at url: URL) throws {
        guard !Self.isSymbolicLink(at: url.path) else {
            throw SupervisorError.unsafeDataPath(url.path)
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func legacyServicePID() -> Int32? {
        guard let output = runLaunchctlOutput(["print", "system/\(Self.legacyService)"]) else { return nil }
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("pid = "), let pid = Int32(trimmed.dropFirst("pid = ".count)), pid > 0 else { continue }
            return pid
        }
        return nil
    }

    private func launchctlPrintSucceeds() -> Bool {
        runLaunchctlOutput(["print", "system/\(Self.legacyService)"]) != nil
    }

    private func runLaunchctl(_ arguments: [String]) throws {
        guard runLaunchctlOutput(arguments) != nil else {
            throw SupervisorError.launchctlFailed(arguments.joined(separator: " "))
        }
    }

    private func runLaunchctlOutput(_ arguments: [String]) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }

    private func waitForProcessExit(_ pid: Int32) throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if kill(pid, 0) != 0 { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw SupervisorError.legacyProcessDidNotExit(pid)
    }

    private func runtimeBinaryURL(binaryPath: String? = nil) throws -> URL {
        if let binaryPath, !binaryPath.isEmpty {
            return try yuhaiinBinaryURL(pathOverride: binaryPath)
        }
        if let configured = ProcessInfo.processInfo.environment["YUHAIIN_BINARY_PATH"], !configured.isEmpty {
            return try yuhaiinBinaryURL(pathOverride: configured)
        }

        let dataPath = dataPathURL()
        let binDirectory = dataPath.appendingPathComponent("bin", isDirectory: true)
        let target = binDirectory.appendingPathComponent("yuhaiin", isDirectory: false)
        if FileManager.default.isExecutableFile(atPath: target.path) {
            guard !Self.isSymbolicLink(at: target.path) else {
                throw SupervisorError.unsafeUpdatePath
            }
            if Self.hasCurrentArchitecture(at: target), Self.hasValidCodeSignature(at: target) {
                return target
            }
            // A previous test or manual install may have left an unsigned or
            // wrong-architecture runtime behind. Re-seed it from the bundled
            // resource before reporting an invalid runtime.
            try FileManager.default.removeItem(at: target)
        }

        try ensurePrivateDirectory(at: binDirectory)
        let source = try yuhaiinBinaryURL()
        let temporary = binDirectory.appendingPathComponent(".yuhaiin-bootstrap-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: source, to: temporary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.path)
        try FileManager.default.moveItem(at: temporary, to: target)
        try? writeRuntimeSource("bundled", in: binDirectory)
        return target
    }

    private func installUploadedBinaryLocked(sourcePath: String) throws -> URL {
        let source = URL(fileURLWithPath: sourcePath)
        let fileManager = FileManager.default
        guard !Self.isSymbolicLink(at: source.path) else {
            throw SupervisorError.unsafeUpdatePath
        }
        guard let attributes = try? fileManager.attributesOfItem(atPath: source.path),
              attributes[.type] as? FileAttributeType == .typeRegular else {
            throw SupervisorError.uploadedBinaryNotRegular(source.path)
        }
        guard let size = attributes[.size] as? NSNumber,
              size.int64Value > 0,
              size.int64Value <= Self.maxUpdateBytes else {
            throw SupervisorError.uploadedBinaryTooLarge
        }
        guard let architectures = Self.architectures(at: source) else {
            throw SupervisorError.uploadedBinaryNotMachO(
                "\(source.path) (\(Self.binaryHeaderDescription(at: source)))"
            )
        }
        guard architectures.contains(Self.currentArchitecture) else {
            throw SupervisorError.uploadedBinaryWrongArchitecture(architectures.joined(separator: ", "))
        }

        let binDirectory = dataPathURL().appendingPathComponent("bin", isDirectory: true)
        try ensurePrivateDirectory(at: binDirectory)
        let staging = binDirectory.appendingPathComponent(".yuhaiin-upload-\(UUID().uuidString)")
        let target = binDirectory.appendingPathComponent("yuhaiin", isDirectory: false)
        let backup = binDirectory.appendingPathComponent(".yuhaiin-upload-backup-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: staging) }

        guard !Self.isSymbolicLink(at: target.path) else {
            throw SupervisorError.unsafeUpdatePath
        }
        try fileManager.copyItem(at: source, to: staging)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging.path)
        try Self.signAdHoc(at: staging)
        guard let stagingArchitectures = Self.architectures(at: staging),
              stagingArchitectures.contains(Self.currentArchitecture) else {
            throw SupervisorError.uploadedBinaryWrongArchitecture(
                Self.architectures(at: staging)?.joined(separator: ", ") ?? "unknown"
            )
        }
        guard Self.hasValidCodeSignature(at: staging) else {
            throw SupervisorError.uploadedBinarySignatureInvalid
        }

        var movedExisting = false
        do {
            if fileManager.fileExists(atPath: target.path) {
                try fileManager.moveItem(at: target, to: backup)
                movedExisting = true
            }
            try fileManager.moveItem(at: staging, to: target)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
            guard fileManager.isExecutableFile(atPath: target.path),
                  let targetArchitectures = Self.architectures(at: target),
                  targetArchitectures.contains(Self.currentArchitecture) else {
                throw SupervisorError.uploadedBinaryWrongArchitecture(
                    Self.architectures(at: target)?.joined(separator: ", ") ?? "unknown"
                )
            }
            guard Self.hasValidCodeSignature(at: target) else {
                throw SupervisorError.uploadedBinarySignatureInvalid
            }
            try writeRuntimeSource("uploaded", in: binDirectory)
            try? fileManager.removeItem(at: backup)
            return target
        } catch {
            try? fileManager.removeItem(at: target)
            if movedExisting, fileManager.fileExists(atPath: backup.path) {
                try? fileManager.moveItem(at: backup, to: target)
            }
            throw error
        }
    }

    private func runtimeSource(dataPath: String, configuredBinaryPath: String) -> String {
        if !configuredBinaryPath.isEmpty { return "custom" }

        let binDirectory = URL(fileURLWithPath: dataPath, isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
        let target = binDirectory.appendingPathComponent("yuhaiin", isDirectory: false)
        guard FileManager.default.isExecutableFile(atPath: target.path),
              !Self.isSymbolicLink(at: target.path) else {
            return "missing"
        }

        let marker = binDirectory.appendingPathComponent(".yuhaiin-runtime-source", isDirectory: false)
        if let value = try? String(contentsOf: marker, encoding: .utf8) {
            let source = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if source == "bundled" || source == "uploaded" { return source }
        }

        // Migrate binaries installed by older builds that did not write a
        // source marker. A different hash from the bundled resource means it
        // was externally installed, which is the persisted upload behavior.
        guard let bundled = try? yuhaiinBinaryURL(),
              let targetHash = try? Self.sha256(of: target),
              let bundledHash = try? Self.sha256(of: bundled) else {
            return "unknown"
        }
        return targetHash == bundledHash ? "bundled" : "uploaded"
    }

    private func writeRuntimeSource(_ source: String, in binDirectory: URL) throws {
        let marker = binDirectory.appendingPathComponent(".yuhaiin-runtime-source", isDirectory: false)
        try Data(source.utf8).write(to: marker, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
    }

    private func installUpdateLocked(stagedURL: URL, expectedSHA256: String, targetVersion: String) throws -> NSDictionary {
        defer { try? FileManager.default.removeItem(at: stagedURL) }
        guard try Self.sha256(of: stagedURL) == expectedSHA256.lowercased() else {
            throw SupervisorError.checksumMismatch
        }
        guard FileManager.default.isExecutableFile(atPath: stagedURL.path),
              Self.hasCurrentArchitecture(at: stagedURL),
              Self.hasValidCodeSignature(at: stagedURL) else {
            throw SupervisorError.invalidUpdatedBinary
        }

        let target = try runtimeBinaryURL(binaryPath: configuredBinaryPath.isEmpty ? nil : configuredBinaryPath)
        guard !Self.isSymbolicLink(at: target.path), !Self.isSymbolicLink(at: stagedURL.path) else {
            throw SupervisorError.unsafeUpdatePath
        }
        let backup = target.deletingLastPathComponent().appendingPathComponent(".yuhaiin-backup-\(UUID().uuidString)")
        let wasRunning = process?.isRunning == true
        if wasRunning { stopLocked() }

        do {
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.moveItem(at: target, to: backup)
            }
            try FileManager.default.moveItem(at: stagedURL, to: target)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
            guard FileManager.default.isExecutableFile(atPath: target.path),
                  Self.hasCurrentArchitecture(at: target),
                  Self.hasValidCodeSignature(at: target) else {
                throw SupervisorError.invalidUpdatedBinary
            }

            if wasRunning {
                try startProcessLocked(
                    host: configuredHost,
                    username: configuredUsername,
                    password: configuredPassword,
                    binaryPath: configuredBinaryPath
                )
            } else {
                state = "stopped"
            }
            try? FileManager.default.removeItem(at: backup)
            return responseLocked(ok: true, extra: [SupervisorResponseKey.targetVersion: targetVersion])
        } catch {
            try? FileManager.default.removeItem(at: target)
            if FileManager.default.fileExists(atPath: backup.path) {
                try? FileManager.default.moveItem(at: backup, to: target)
            }
            state = "failed"
            lastError = error.localizedDescription
            if wasRunning {
                try? startProcessLocked(
                    host: configuredHost,
                    username: configuredUsername,
                    password: configuredPassword,
                    binaryPath: configuredBinaryPath
                )
            }
            throw error
        }
    }

    private static func download(url: URL, to destination: URL) async throws {
        let (temporary, response) = try await URLSession.shared.download(from: url)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              http.url?.scheme?.lowercased() == "https" else {
            throw SupervisorError.downloadFailed
        }
        if http.expectedContentLength > maxUpdateBytes {
            throw SupervisorError.updateTooLarge
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: temporary.path)
        guard let size = attributes[.size] as? NSNumber, size.int64Value > 0,
              size.int64Value <= maxUpdateBytes else {
            throw SupervisorError.updateTooLarge
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    private static func isValidSHA256(_ value: String) -> Bool {
        value.count == SHA256.Digest.byteCount * 2 && value.allSatisfy { $0.isHexDigit }
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func hasValidCodeSignature(at url: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        if let requirementString = ProcessInfo.processInfo.environment["YUHAIIN_BINARY_CODE_REQUIREMENT"],
           !requirementString.isEmpty {
            var requirement: SecRequirement?
            guard SecRequirementCreateWithString(requirementString as CFString, [], &requirement) == errSecSuccess,
                  let requirement else { return false }
            return SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
        }
        return SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess
    }

    private static func signAdHoc(at url: URL) throws {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", "-", url.path]
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw SupervisorError.binarySigningFailed(output ?? "codesign failed")
        }
    }

    private static func hasCurrentArchitecture(at url: URL) -> Bool {
        architectures(at: url)?.contains(currentArchitecture) == true
    }

    private static func architectures(at url: URL) -> [String]? {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            return nil
        }
        defer { close(descriptor) }

        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = bytes.withUnsafeMutableBytes { buffer -> Int in
            guard let baseAddress = buffer.baseAddress else { return -1 }
            return Darwin.read(descriptor, baseAddress, buffer.count)
        }
        guard count >= 8 else { return nil }
        let data = Data(bytes.prefix(count))

        let bigMagic = readUInt32(data, at: 0, bigEndian: true)
        let littleMagic = readUInt32(data, at: 0, bigEndian: false)
        if bigMagic == 0xfeedfacf || littleMagic == 0xfeedfacf {
            let bigEndian = bigMagic == 0xfeedfacf
            guard let cpuType = readUInt32(data, at: 4, bigEndian: bigEndian) else { return nil }
            return [architectureName(cpuType)]
        }

        let isFat32 = bigMagic == 0xcafebabe || littleMagic == 0xbebafeca
        let isFat64 = bigMagic == 0xcafebabf || littleMagic == 0xbfbafeca
        guard isFat32 || isFat64 else { return nil }
        let bigEndian = isFat32 ? bigMagic == 0xcafebabe : bigMagic == 0xcafebabf
        guard let count = readUInt32(data, at: 4, bigEndian: bigEndian), count <= 64 else { return nil }

        let entrySize = isFat64 ? 32 : 20
        var result: [String] = []
        for index in 0..<Int(count) {
            let offset = 8 + index * entrySize
            guard let cpuType = readUInt32(data, at: offset, bigEndian: bigEndian) else { return nil }
            result.append(architectureName(cpuType))
        }
        return result.isEmpty ? nil : result
    }

    private static func binaryHeaderDescription(at url: URL) -> String {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return "open errno=\(errno)" }
        defer { close(descriptor) }

        var bytes = [UInt8](repeating: 0, count: 8)
        let count = bytes.withUnsafeMutableBytes { buffer -> Int in
            guard let baseAddress = buffer.baseAddress else { return -1 }
            return Darwin.read(descriptor, baseAddress, buffer.count)
        }
        let hex = bytes.prefix(max(0, min(count, bytes.count)))
            .map { String(format: "%02x", $0) }
            .joined()
        return "read=\(count) magic=\(hex)"
    }

    private static func readUInt32(_ data: Data, at offset: Int, bigEndian: Bool) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        let b0 = UInt32(data[offset])
        let b1 = UInt32(data[offset + 1])
        let b2 = UInt32(data[offset + 2])
        let b3 = UInt32(data[offset + 3])
        if bigEndian {
            return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
        }
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }

    private static func architectureName(_ cpuType: UInt32) -> String {
        switch cpuType {
        case 0x0100000c: return "arm64"
        case 0x01000007: return "x86_64"
        case 0x0000000c: return "arm"
        case 0x00000007: return "i386"
        default: return String(format: "cpu-0x%08x", cpuType)
        }
    }

    private static func isSymbolicLink(at path: String) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
    }

    private func waitForPort(host: String) -> Bool {
        let pieces = host.split(separator: ":", maxSplits: 1).map(String.init)
        guard pieces.count == 2, let port = UInt16(pieces[1]) else {
            return false
        }
        let address = pieces[0] == "localhost" ? "127.0.0.1" : pieces[0]
        let deadline = Date().addingTimeInterval(15)

        while Date() < deadline {
            let socketFD = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            if socketFD >= 0 {
                var endpoint = sockaddr_in()
                endpoint.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                endpoint.sin_family = sa_family_t(AF_INET)
                endpoint.sin_port = port.bigEndian
                let parsed = address.withCString {
                    inet_pton(AF_INET, $0, &endpoint.sin_addr)
                }
                if parsed == 1 {
                    let connected = withUnsafePointer(to: &endpoint) { pointer in
                        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            Darwin.connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                    Darwin.close(socketFD)
                    if connected == 0 { return true }
                } else {
                    Darwin.close(socketFD)
                    return false
                }
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    private func stopLocked() {
        guard let process, process.isRunning else {
            self.process = nil
            if state != "failed" { state = "stopped" }
            return
        }

        state = "stopping"
        process.terminate()
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
        self.process = nil
        state = "stopped"
    }

    private func expireLeasesLocked() {
        let cutoff = Date().addingTimeInterval(-6)
        let expired = leaseRenewedAt.compactMap { leaseID, renewedAt in
            renewedAt < cutoff ? leaseID : nil
        }
        guard !expired.isEmpty else { return }
        for leaseID in expired {
            leaseIDs.remove(leaseID)
            leaseRenewedAt.removeValue(forKey: leaseID)
        }
        if leaseIDs.isEmpty, process?.isRunning == true {
            scheduleGracefulStopLocked()
        }
        clearCredentialsIfUnleasedLocked()
    }

    private func scheduleGracefulStopLocked() {
        pendingStop?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.leaseIDs.isEmpty, self.process?.isRunning == true else { return }
            self.pendingStop = nil
            self.stopLocked()
        }
        pendingStop = work
        queue.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func clearCredentialsIfUnleasedLocked() {
        guard leaseIDs.isEmpty else { return }
        configuredUsername = ""
        configuredPassword = ""
    }

    private func snapshotLocked() -> NSDictionary {
        var extra: [String: Any] = [:]
        if let process, process.isRunning {
            extra[SupervisorResponseKey.pid] = NSNumber(value: process.processIdentifier)
        }
        if let startedAt {
            extra["startedAt"] = startedAt.timeIntervalSince1970
        }
        if !lastError.isEmpty {
            extra[SupervisorResponseKey.message] = lastError
        }
        extra[SupervisorResponseKey.updateRunning] = updateRunning
        return responseLocked(ok: state != "failed", extra: extra)
    }

    private func responseLocked(ok: Bool, message: String? = nil, errorCode: String? = nil, extra: [String: Any] = [:]) -> NSDictionary {
        var values: [String: Any] = [
            SupervisorResponseKey.ok: ok,
            SupervisorResponseKey.state: state,
            SupervisorResponseKey.protocolVersion: yuhaiinSupervisorProtocolVersion
        ]
        if let message { values[SupervisorResponseKey.message] = message }
        if let errorCode { values[SupervisorResponseKey.errorCode] = errorCode }
        for (key, value) in extra { values[key] = value }
        return NSDictionary(dictionary: values)
    }

    private static func isValidLocalHost(_ host: String) -> Bool {
        let pieces = host.split(separator: ":", maxSplits: 1).map(String.init)
        guard pieces.count == 2,
              (pieces[0] == "127.0.0.1" || pieces[0] == "localhost"),
              let port = Int(pieces[1]),
              (1...65535).contains(port) else { return false }
        return true
    }

    private static var currentArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    private static func isValidCredentials(username: String, password: String) -> Bool {
        if username.isEmpty && password.isEmpty { return true }
        guard !username.isEmpty, !password.isEmpty,
              !username.contains(":"),
              username.utf8.count <= 128,
              password.utf8.count <= 512 else { return false }
        return true
    }
}

private enum SupervisorError: LocalizedError {
    case binaryUnavailable(String)
    case uploadedBinaryNotRegular(String)
    case uploadedBinaryTooLarge
    case uploadedBinaryNotMachO(String)
    case uploadedBinaryWrongArchitecture(String)
    case uploadedBinarySignatureInvalid
    case binarySigningFailed(String)
    case updateInProgress
    case readinessTimeout
    case checksumMismatch
    case invalidUpdatedBinary
    case unsafeUpdatePath
    case unsafeDataPath(String)
    case downloadFailed
    case updateTooLarge
    case launchctlFailed(String)
    case legacyProcessDidNotExit(Int32)

    private static var currentArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    var errorDescription: String? {
        switch self {
        case let .binaryUnavailable(path):
            return "yuhaiin binary is unavailable at \(path)"
        case let .uploadedBinaryNotRegular(path):
            return "uploaded file is not a regular file: \(path)"
        case .uploadedBinaryTooLarge:
            return "uploaded yuhaiin binary is empty or larger than 512 MB"
        case let .uploadedBinaryNotMachO(path):
            return "uploaded file is not a macOS Mach-O binary: \(path)"
        case let .uploadedBinaryWrongArchitecture(architectures):
            return "uploaded yuhaiin binary contains [\(architectures)], but this Mac requires \(Self.currentArchitecture)"
        case .uploadedBinarySignatureInvalid:
            return "uploaded yuhaiin binary could not pass code-signing validation after installation"
        case let .binarySigningFailed(message):
            return "uploaded yuhaiin binary could not be signed: \(message)"
        case .updateInProgress:
            return "yuhaiin update is already in progress"
        case .readinessTimeout:
            return "yuhaiin did not open the management port"
        case .checksumMismatch:
            return "downloaded yuhaiin binary checksum does not match"
        case .invalidUpdatedBinary:
            return "downloaded yuhaiin binary failed executable or signature validation"
        case .unsafeUpdatePath:
            return "update path contains a symbolic link"
        case let .unsafeDataPath(path):
            return "data path contains a symbolic link: \(path)"
        case .downloadFailed:
            return "yuhaiin update download failed"
        case .updateTooLarge:
            return "downloaded yuhaiin update is too large"
        case let .launchctlFailed(arguments):
            return "launchctl failed: \(arguments)"
        case let .legacyProcessDidNotExit(pid):
            return "legacy yuhaiin process \(pid) did not exit"
        }
    }
}

private final class SupervisorService: NSObject, YuhaiinSupervisorProtocol {
    private let core: SupervisorCore
    private var leaseID: String?

    init(core: SupervisorCore) {
        self.core = core
    }

    func status(withReply reply: @escaping (NSDictionary) -> Void) {
        reply(core.snapshot())
    }

    func acquireLease(withReply reply: @escaping (NSDictionary) -> Void) {
        let response = core.acquireLease()
        leaseID = response[SupervisorResponseKey.leaseID] as? String
        reply(response)
    }

    func renewLease(withReply reply: @escaping (NSDictionary) -> Void) {
        guard let leaseID else {
            reply(NSDictionary(dictionary: [SupervisorResponseKey.ok: false, SupervisorResponseKey.errorCode: "no_lease"]))
            return
        }
        reply(core.renewLease(leaseID))
    }

    func releaseLease(withReply reply: @escaping (NSDictionary) -> Void) {
        guard let leaseID else {
            reply(NSDictionary(dictionary: [SupervisorResponseKey.ok: true]))
            return
        }
        self.leaseID = nil
        reply(core.releaseLease(leaseID))
    }

    func start(withReply reply: @escaping (NSDictionary) -> Void) {
        let host = ProcessInfo.processInfo.environment["YUHAIIN_HOST"] ?? "127.0.0.1:50051"
        let binaryPath = ProcessInfo.processInfo.environment["YUHAIIN_BINARY_PATH"] ?? ""
        core.start(host: host, username: "", password: "", binaryPath: binaryPath, reply: reply)
    }

    func start(_ request: NSDictionary, withReply reply: @escaping (NSDictionary) -> Void) {
        let host = request[SupervisorRequestKey.host] as? String
            ?? ProcessInfo.processInfo.environment["YUHAIIN_HOST"]
            ?? "127.0.0.1:50051"
        let username = request[SupervisorRequestKey.username] as? String ?? ""
        let password = request[SupervisorRequestKey.password] as? String ?? ""
        let binaryPath = request[SupervisorRequestKey.binaryPath] as? String
            ?? ProcessInfo.processInfo.environment["YUHAIIN_BINARY_PATH"]
            ?? ""
        core.start(
            host: host,
            username: username,
            password: password,
            binaryPath: binaryPath,
            reply: reply
        )
    }

    func stop(withReply reply: @escaping (NSDictionary) -> Void) {
        core.stop(reply: reply)
    }

    func diagnostics(withReply reply: @escaping (NSDictionary) -> Void) {
        reply(core.diagnostics())
    }

    func readLogs(withReply reply: @escaping (NSDictionary) -> Void) {
        reply(core.readLogs())
    }

    func adoptLegacyService(withReply reply: @escaping (NSDictionary) -> Void) {
        core.adoptLegacyService(reply: reply)
    }

    func installBinary(_ request: NSDictionary, withReply reply: @escaping (NSDictionary) -> Void) {
        guard let sourcePath = request[SupervisorRequestKey.sourcePath] as? String else {
            reply(NSDictionary(dictionary: [
                SupervisorResponseKey.ok: false,
                SupervisorResponseKey.errorCode: "invalid_binary_path",
                SupervisorResponseKey.message: "binary source path is required"
            ]))
            return
        }
        core.installBinary(sourcePath: sourcePath, reply: reply)
    }

    func applyYuhaiinUpdate(_ request: NSDictionary, withReply reply: @escaping (NSDictionary) -> Void) {
        guard let assetURL = request[SupervisorResponseKey.assetURL] as? String,
              let sha256 = request[SupervisorResponseKey.sha256] as? String else {
            reply(NSDictionary(dictionary: [
                SupervisorResponseKey.ok: false,
                SupervisorResponseKey.errorCode: "invalid_update_request",
                SupervisorResponseKey.message: "update URL and checksum are required"
            ]))
            return
        }
        let targetVersion = request[SupervisorResponseKey.targetVersion] as? String ?? ""
        core.applyYuhaiinUpdate(assetURL: assetURL, sha256: sha256, targetVersion: targetVersion, reply: reply)
    }

    func connectionInvalidated() {
        guard let leaseID else { return }
        self.leaseID = nil
        _ = core.releaseLease(leaseID, grace: true)
    }
}

private final class SupervisorHost: NSObject, NSXPCListenerDelegate {
    private let core = SupervisorCore()
    private let listener: NSXPCListener

    override init() {
        listener = NSXPCListener(machServiceName: yuhaiinSupervisorMachService)
        super.init()
    }

    func run() -> Never {
        listener.delegate = self
        listener.resume()
        RunLoop.current.run()
        fatalError("supervisor run loop exited")
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // The daemon is root. Only the signed Yuhaiin app may obtain a lease
        // or control the child process through this connection.
        let requirement = ProcessInfo.processInfo.environment["YUHAIIN_CLIENT_CODE_REQUIREMENT"]
            ?? yuhaiinApplicationCodeSigningRequirement
        newConnection.setCodeSigningRequirement(requirement)

        let service = SupervisorService(core: core)
        newConnection.exportedInterface = NSXPCInterface(with: YuhaiinSupervisorProtocol.self)
        newConnection.exportedObject = service
        newConnection.invalidationHandler = { [weak service] in
            service?.connectionInvalidated()
        }
        newConnection.interruptionHandler = { [weak service] in
            service?.connectionInvalidated()
        }
        newConnection.resume()
        return true
    }
}

private let host = SupervisorHost()
host.run()
