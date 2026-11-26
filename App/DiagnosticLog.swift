import Foundation
import UIKit
#if canImport(Darwin)
import Darwin
#endif

final class DiagnosticLogStore {
    static let shared = DiagnosticLogStore()

    private let lock = NSLock()
    private let fileManager = FileManager.default
    private let rootURL: URL
    private let currentURL: URL
    private let previousURL: URL
    private let crashesURL: URL
    private var handle: FileHandle?

    private init() {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        rootURL = base.appendingPathComponent("CarWithin", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
        currentURL = rootURL.appendingPathComponent("current.log")
        previousURL = rootURL.appendingPathComponent("previous.log")
        crashesURL = rootURL.appendingPathComponent("Crashes", isDirectory: true)
        try? fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: crashesURL, withIntermediateDirectories: true)
    }

    func startSession() {
        lock.lock()
        closeHandleLocked()
        if fileManager.fileExists(atPath: currentURL.path) {
            try? fileManager.removeItem(at: previousURL)
            try? fileManager.moveItem(at: currentURL, to: previousURL)
        }
        fileManager.createFile(atPath: currentURL.path, contents: nil)
        handle = try? FileHandle(forWritingTo: currentURL)
        writeLocked("[session] \(sessionHeader())")
        pruneCrashReportsLocked()
        lock.unlock()
    }

    func append(_ message: String) {
        lock.lock()
        writeLocked("\(timestamp())  \(message)")
        lock.unlock()
    }

    func markCleanExit() {
        append("[session] 正常退出")
    }

    func flush() {
        lock.lock()
        try? handle?.synchronize()
        lock.unlock()
    }

    func prepareCrashReportURL() -> URL {
        lock.lock()
        defer { lock.unlock() }
        try? fileManager.createDirectory(at: crashesURL, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmssSSS"
        let name = "crash-\(formatter.string(from: Date())).log"
        let url = crashesURL.appendingPathComponent(name)
        return url
    }

    func crashHeader() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        var system = utsname()
        uname(&system)
        let model = withUnsafeBytes(of: &system.machine) {
            String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
        }
        return "[CarWithin] version=\(version) build=\(build) device=\(model) iOS=\(UIDevice.current.systemVersion) time=\(timestamp())"
    }

    func currentLogText() -> String {
        lock.lock()
        defer { lock.unlock() }
        return tail(readTextLocked(currentURL))
    }

    func previousLogText() -> String {
        lock.lock()
        defer { lock.unlock() }
        return tail(readTextLocked(previousURL))
    }

    func latestCrashText() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let url = crashReportURLsLocked().first else { return nil }
        return tail(readTextLocked(url))
    }

    func latestCrashSummary() -> String {
        guard let text = latestCrashText() else { return "无" }
        return text.split(separator: "\n").first.map(String.init) ?? "无"
    }

    func exportableText() -> String {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.synchronize()
        var text = "==== CarWithin Diagnostics ====\n"
        text += "\(sessionHeader())\n\n"
        text += "==== Current session log ====\n\(tail(readTextLocked(currentURL), limit: 30_000))\n\n"
        text += "==== Previous session log ====\n\(tail(readTextLocked(previousURL), limit: 30_000))\n\n"
        for url in crashReportURLsLocked() {
            text += "==== Crash report: \(url.lastPathComponent) ====\n\(tail(readTextLocked(url), limit: 20_000))\n\n"
        }
        return text
    }

    func exportableReportURL() -> URL {
        let url = crashesURL.appendingPathComponent("CarWithin-diagnostics.txt")
        try? exportableText().write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func clearLogs() {
        lock.lock()
        closeHandleLocked()
        for url in [currentURL, previousURL] {
            try? fileManager.removeItem(at: url)
        }
        for url in crashReportURLsLocked() {
            try? fileManager.removeItem(at: url)
        }
        fileManager.createFile(atPath: currentURL.path, contents: nil)
        handle = try? FileHandle(forWritingTo: currentURL)
        writeLocked("[session] \(sessionHeader())")
        lock.unlock()
    }

    private func sessionHeader() -> String {
        "session=\(UUID().uuidString) time=\(timestamp()) version=\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")"
    }

    private func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }

    private func writeLocked(_ line: String) {
        guard let handle else { return }
        handle.seekToEndOfFile()
        handle.write(Data((line + "\n").utf8))
    }

    private func closeHandleLocked() {
        try? handle?.synchronize()
        handle?.closeFile()
        handle = nil
    }

    private func readTextLocked(_ url: URL) -> String {
        guard fileManager.fileExists(atPath: url.path) else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private func crashReportURLsLocked() -> [URL] {
        let urls = (try? fileManager.contentsOfDirectory(
            at: crashesURL,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.filter { $0.pathExtension == "log" }.sorted { lhs, rhs in
            let left = (try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let right = (try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return left > right
        }
    }

    private func pruneCrashReportsLocked() {
        let urls = crashReportURLsLocked()
        guard urls.count > 20 else { return }
        for url in urls.dropFirst(20) {
            try? fileManager.removeItem(at: url)
        }
    }

    private func tail(_ text: String, limit: Int = 20_000) -> String {
        guard text.utf16.count > limit else { return text }
        return String(text.suffix(limit))
    }
}

enum CrashReporter {
    private static var installed = false
    private static var crashPath: UnsafeMutablePointer<CChar>?
    private static var headerText = ""
    private static var signalMessages: [Int32: [UInt8]] = [:]
    private static var backtraceFrames = [UnsafeMutableRawPointer?](repeating: nil, count: 64)

    static func install() {
        guard !installed else { return }
        installed = true

        let url = DiagnosticLogStore.shared.prepareCrashReportURL()
        crashPath = strdup(url.path)
        headerText = DiagnosticLogStore.shared.crashHeader()

        let signals = [SIGABRT, SIGSEGV, SIGBUS, SIGFPE, SIGILL]
        for signalNumber in signals {
            signalMessages[signalNumber] = Array("\(headerText)\n==== CarWithin signal \(signalNumber) ====\n".utf8)
        }

        NSSetUncaughtExceptionHandler { exception in
            let reason = exception.reason ?? "unknown"
            let symbols = exception.callStackSymbols.joined(separator: "\n")
            let text = """
            \(headerText)
            ==== CarWithin NSException ====
            name=\(exception.name.rawValue)
            reason=\(reason)
            \(symbols)
            """
            writeString(text)
            _exit(1)
        }

        for signalNumber in signals {
            signal(signalNumber) { received in
                writeSignal(received)
                signal(received, SIG_DFL)
                raise(received)
            }
        }
    }

    private static func writeSignal(_ signalNumber: Int32) {
        guard let path = crashPath else { return }
        let descriptor = open(path, O_WRONLY | O_CREAT | O_APPEND, mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else { return }
        if let bytes = signalMessages[signalNumber] {
            bytes.withUnsafeBytes { raw in
                _ = write(descriptor, raw.baseAddress, raw.count)
            }
        }
        let count = backtrace(&backtraceFrames, Int32(backtraceFrames.count))
        if count > 0 {
            backtrace_symbols_fd(&backtraceFrames, count, descriptor)
        }
        close(descriptor)
    }

    private static func writeString(_ text: String) {
        guard let data = (text + "\n").data(using: .utf8) else { return }
        var bytes = [UInt8](data)
        writeBytes(&bytes)
    }

    private static func writeBytes(_ bytes: inout [UInt8]) {
        guard let path = crashPath else { return }
        let descriptor = open(path, O_WRONLY | O_CREAT | O_APPEND, mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else { return }
        bytes.withUnsafeMutableBytes { raw in
            _ = write(descriptor, raw.baseAddress, raw.count)
        }
        close(descriptor)
    }
}
