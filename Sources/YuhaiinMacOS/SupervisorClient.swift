import Foundation
import YuhaiinShared

enum SupervisorClientError: LocalizedError {
    case unavailable
    case malformedResponse
    case timedOut(TimeInterval)
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return L("error.supervisorUnavailable")
        case .malformedResponse:
            return L("error.supervisorMalformedResponse")
        case let .timedOut(seconds):
            return L("error.supervisorTimedOut", String(Int(seconds)))
        case let .rejected(message):
            return message
        }
    }

    var isTimeout: Bool {
        if case .timedOut = self { return true }
        return false
    }
}

final class SupervisorClient {
    private static let startRequestTimeout: TimeInterval = 25
    private static let binaryInstallRequestTimeout: TimeInterval = 60
    private var connection: NSXPCConnection?
    private let lock = NSLock()

    func status() async throws -> NSDictionary {
        try await call { proxy, reply in
            proxy.status(withReply: reply)
        }
    }

    func acquireLease() async throws -> String {
        let response = try await call { proxy, reply in
            proxy.acquireLease(withReply: reply)
        }
        guard response[SupervisorResponseKey.ok] as? Bool == true,
              let leaseID = response[SupervisorResponseKey.leaseID] as? String else {
            throw SupervisorClientError.rejected(message(from: response))
        }
        return leaseID
    }

    func renewLease() async throws {
        let response = try await call { proxy, reply in
            proxy.renewLease(withReply: reply)
        }
        guard response[SupervisorResponseKey.ok] as? Bool == true else {
            throw SupervisorClientError.rejected(message(from: response))
        }
    }

    func releaseLease() async throws {
        let response = try await call { proxy, reply in
            proxy.releaseLease(withReply: reply)
        }
        guard response[SupervisorResponseKey.ok] as? Bool == true else {
            throw SupervisorClientError.rejected(message(from: response))
        }
    }

    func start(
        host: String,
        credentials: YuhaiinAPICredentials?,
        binaryPath: String? = nil
    ) async throws -> NSDictionary {
        var requestValues: [String: String] = [SupervisorRequestKey.host: host]
        if let credentials {
            requestValues[SupervisorRequestKey.username] = credentials.username
            requestValues[SupervisorRequestKey.password] = credentials.password
        }
        if let binaryPath, !binaryPath.isEmpty {
            requestValues[SupervisorRequestKey.binaryPath] = binaryPath
        }
        let request = NSDictionary(dictionary: requestValues)
        do {
            return try await call(timeout: Self.startRequestTimeout) { proxy, reply in
                proxy.start(request, withReply: reply)
            }
        } catch {
            // A Sparkle update can replace the app while an older Supervisor
            // process is still serving the Mach service. Keep the default-port
            // protocol compatible until launchd restarts that older process.
            guard host == "127.0.0.1:50051", credentials == nil,
                  binaryPath == nil,
                  !((error as? SupervisorClientError)?.isTimeout == true) else { throw error }
            return try await call(timeout: Self.startRequestTimeout) { proxy, reply in
                proxy.start(withReply: reply)
            }
        }
    }

    func stop() async throws -> NSDictionary {
        try await call { proxy, reply in
            proxy.stop(withReply: reply)
        }
    }

    func diagnostics() async throws -> NSDictionary {
        try await call { proxy, reply in
            proxy.diagnostics(withReply: reply)
        }
    }

    func readLogs() async throws -> NSDictionary {
        try await call { proxy, reply in
            proxy.readLogs(withReply: reply)
        }
    }

    func adoptLegacyService() async throws -> NSDictionary {
        try await call { proxy, reply in
            proxy.adoptLegacyService(withReply: reply)
        }
    }

    func installBinary(sourcePath: String) async throws -> NSDictionary {
        let request: NSDictionary = [SupervisorRequestKey.sourcePath: sourcePath]
        return try await call(timeout: Self.binaryInstallRequestTimeout) { proxy, reply in
            proxy.installBinary(request, withReply: reply)
        }
    }

    func applyYuhaiinUpdate(assetURL: String, sha256: String, targetVersion: String) async throws -> NSDictionary {
        let request: NSDictionary = [
            SupervisorResponseKey.assetURL: assetURL,
            SupervisorResponseKey.sha256: sha256,
            SupervisorResponseKey.targetVersion: targetVersion
        ]
        return try await call { proxy, reply in
            proxy.applyYuhaiinUpdate(request, withReply: reply)
        }
    }

    func invalidate() {
        lock.lock()
        let current = connection
        connection = nil
        lock.unlock()
        current?.invalidate()
    }

    func stopAndReleaseBlocking() {
        guard let proxy = makeProxyBlocking() else { return }
        let stopSemaphore = DispatchSemaphore(value: 0)
        proxy.stop { _ in stopSemaphore.signal() }
        _ = stopSemaphore.wait(timeout: .now() + 4)

        let releaseSemaphore = DispatchSemaphore(value: 0)
        proxy.releaseLease { _ in releaseSemaphore.signal() }
        _ = releaseSemaphore.wait(timeout: .now() + 2)
        invalidate()
    }

    private func call(
        timeout: TimeInterval = 8,
        _ invoke: @escaping (YuhaiinSupervisorProtocol, @escaping (NSDictionary) -> Void) -> Void
    ) async throws -> NSDictionary {
        let connection = makeConnection()
        let gate = ContinuationGate<NSDictionary>()
        return try await withCheckedThrowingContinuation { continuation in
            let timeoutWorkItem = DispatchWorkItem { [weak self] in
                self?.invalidate()
                gate.resume(continuation, throwing: SupervisorClientError.timedOut(timeout))
            }
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + timeout,
                execute: timeoutWorkItem
            )
            let remote = connection.remoteObjectProxyWithErrorHandler { error in
                timeoutWorkItem.cancel()
                gate.resume(continuation, throwing: error)
            }
            guard let proxy = remote as? YuhaiinSupervisorProtocol else {
                timeoutWorkItem.cancel()
                gate.resume(continuation, throwing: SupervisorClientError.unavailable)
                return
            }
            invoke(proxy) { response in
                timeoutWorkItem.cancel()
                gate.resume(continuation, returning: response)
            }
        }
    }

    private func makeConnection() -> NSXPCConnection {
        lock.lock()
        defer { lock.unlock() }
        if let connection { return connection }

        let newConnection = NSXPCConnection(machServiceName: yuhaiinSupervisorMachService, options: .privileged)
        newConnection.remoteObjectInterface = NSXPCInterface(with: YuhaiinSupervisorProtocol.self)
        newConnection.invalidationHandler = { [weak self] in
            self?.clearConnection(newConnection)
        }
        newConnection.interruptionHandler = { [weak self] in
            self?.clearConnection(newConnection)
        }
        newConnection.resume()
        connection = newConnection
        return newConnection
    }

    private func makeProxyBlocking() -> YuhaiinSupervisorProtocol? {
        let connection = makeConnection()
        let remote = connection.remoteObjectProxyWithErrorHandler { _ in }
        return remote as? YuhaiinSupervisorProtocol
    }

    private func clearConnection(_ disconnected: NSXPCConnection) {
        lock.lock()
        if connection === disconnected {
            connection = nil
        }
        lock.unlock()
    }

    private static func responseMessage(_ response: NSDictionary) -> String {
        response[SupervisorResponseKey.message] as? String ?? L("error.supervisorRejected")
    }

    private func message(from response: NSDictionary) -> String {
        Self.responseMessage(response)
    }
}

private final class ContinuationGate<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func resume(_ continuation: CheckedContinuation<Value, any Error>, returning value: Value) {
        lock.lock()
        guard !resumed else {
            lock.unlock()
            return
        }
        resumed = true
        lock.unlock()
        continuation.resume(returning: value)
    }

    func resume(_ continuation: CheckedContinuation<Value, any Error>, throwing error: any Error) {
        lock.lock()
        guard !resumed else {
            lock.unlock()
            return
        }
        resumed = true
        lock.unlock()
        continuation.resume(throwing: error)
    }
}
