import Foundation

public let yuhaiinSupervisorMachService = "com.asutorufa.yuhaiin.supervisor"
public let yuhaiinSupervisorLaunchDaemon = "com.asutorufa.yuhaiin.supervisor.plist"
public let yuhaiinApplicationBundleIdentifier = "com.asutorufa.yuhaiin.macos"
public let yuhaiinApplicationCodeSigningRequirement = "identifier \"com.asutorufa.yuhaiin.macos\""
public let yuhaiinSupervisorProtocolVersion = 1

@objc(YuhaiinSupervisorProtocol)
public protocol YuhaiinSupervisorProtocol: NSObjectProtocol {
    func status(withReply reply: @escaping (NSDictionary) -> Void)
    func acquireLease(withReply reply: @escaping (NSDictionary) -> Void)
    func renewLease(withReply reply: @escaping (NSDictionary) -> Void)
    func releaseLease(withReply reply: @escaping (NSDictionary) -> Void)
    func start(withReply reply: @escaping (NSDictionary) -> Void)
    func start(_ request: NSDictionary, withReply reply: @escaping (NSDictionary) -> Void)
    func stop(withReply reply: @escaping (NSDictionary) -> Void)
    func diagnostics(withReply reply: @escaping (NSDictionary) -> Void)
    func readLogs(withReply reply: @escaping (NSDictionary) -> Void)
    func adoptLegacyService(withReply reply: @escaping (NSDictionary) -> Void)
    func installBinary(_ request: NSDictionary, withReply reply: @escaping (NSDictionary) -> Void)
    func applyYuhaiinUpdate(_ request: NSDictionary, withReply reply: @escaping (NSDictionary) -> Void)
}

public enum SupervisorResponseKey {
    public static let ok = "ok"
    public static let state = "state"
    public static let message = "message"
    public static let errorCode = "errorCode"
    public static let leaseID = "leaseID"
    public static let pid = "pid"
    public static let version = "version"
    public static let diagnostics = "diagnostics"
    public static let logs = "logs"
    public static let assetURL = "assetURL"
    public static let sha256 = "sha256"
    public static let targetVersion = "targetVersion"
    public static let updateRunning = "updateRunning"
    public static let protocolVersion = "protocolVersion"
}

public enum SupervisorRequestKey {
    public static let host = "host"
    public static let username = "username"
    public static let password = "password"
    public static let binaryPath = "binaryPath"
    public static let sourcePath = "sourcePath"
}
