import Foundation

/// Runs documented command-line tools safely: an absolute, validated executable path and an
/// argument array (no shell, no string interpolation into a command line, no `sudo`).
public enum ToolRunner {
    public struct Output: Sendable {
        public var status: Int32
        public var stdout: String
        public var stderr: String
        public var timedOut: Bool
    }

    /// Executables PureMac is allowed to launch. Anything else is refused.
    static let allowedExecutableNames: Set<String> = ["pkgutil"]

    public static func isAllowed(_ executable: String) -> Bool {
        guard let normalized = PathTools.normalize(executable), normalized == executable else { return false }
        return allowedExecutableNames.contains((executable as NSString).lastPathComponent)
    }

    /// First existing executable among candidate absolute paths.
    public static func locate(_ candidates: [String]) -> String? {
        candidates.first { path in
            guard isAllowed(path) else { return false }
            return FileManager.default.isExecutableFile(atPath: path)
        }
    }

    /// Runs the tool synchronously (call off the main actor). Returns `nil` if it cannot be launched.
    public static func run(executable: String, arguments: [String], timeout: TimeInterval = 60,
                           environment: [String: String]? = nil) -> Output? {
        guard isAllowed(executable), FileManager.default.isExecutableFile(atPath: executable) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin", "LANG": "en_US.UTF-8"]
        if let home = ProcessInfo.processInfo.environment["HOME"] { env["HOME"] = home }
        if let environment { env.merge(environment) { _, new in new } }
        process.environment = env
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let outBuffer = LockedData()
        let errBuffer = LockedData()
        outPipe.fileHandleForReading.readabilityHandler = { outBuffer.append($0.availableData) }
        errPipe.fileHandleForReading.readabilityHandler = { errBuffer.append($0.availableData) }

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        var timedOut = false
        if done.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            _ = done.wait(timeout: .now() + 5)
        }
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        outBuffer.append(outPipe.fileHandleForReading.readDataToEndOfFile())
        errBuffer.append(errPipe.fileHandleForReading.readDataToEndOfFile())
        return Output(status: process.terminationStatus, stdout: outBuffer.string, stderr: errBuffer.string, timedOut: timedOut)
    }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock(); data.append(chunk); lock.unlock()
    }
    var string: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
