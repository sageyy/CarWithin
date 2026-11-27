import Foundation
import UIKit
#if canImport(Darwin)
import Darwin
#endif

private var carWithinCrashURL: URL?
private var carWithinCrashHeader = ""

private func carWithinWriteReport(_ text: String) {
    guard let url = carWithinCrashURL else { return }
    let report = text + "\n"
    try? report.write(to: url, atomically: true, encoding: .utf8)
}

private let carWithinExceptionHandler: @convention(c) (NSException) -> Void = { exception in
    let reason = exception.reason ?? "unknown"
    let symbols = exception.callStackSymbols.joined(separator: "\n")
    carWithinWriteReport("""
    \(carWithinCrashHeader)
    ==== CarWithin NSException ====
    name=\(exception.name.rawValue)
    reason=\(reason)
    \(symbols)
    """)
    _exit(1)
}

private let carWithinSignalHandler: @convention(c) (Int32) -> Void = { received in
    let symbols = Thread.callStackSymbols.joined(separator: "\n")
    carWithinWriteReport("""
    \(carWithinCrashHeader)
    ==== CarWithin signal \(received) ====
    \(symbols)
    """)
    signal(received, SIG_DFL)
    raise(received)
}

enum AppMemoryUsage {
    static var footprintMB: Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        return Double(info.phys_footprint) / 1024 / 1024
    }
}

final class DiagnosticLogStore {
    static let shared = DiagnosticLogStore()

    private let lock = NSLock()
    private let fileManager = FileManager.default
    private let rootURL: URL
    private let currentURL: URL
    private let previousURL: URL
    private let crashesURL: URL
    private var handle: FileHandle?
    private var memoryLogCounter = 0
    /// Keep the on-disk session log bounded. Export already tail-truncates, so trimming the
    /// oldest bytes loses nothing that would be shown to the user.
    private var writtenBytesSinceTrim = 0
    private static let trimCheckBytes = 256 * 1024
    private static let maxLogBytes = 2 * 1024 * 1024
    private static let keptLogBytes = 1 * 1024 * 1024

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
        let lastSessionText = readTextLocked(currentURL)
        if !lastSessionText.isEmpty && isAbnormalExit(lastSessionText) {
            writeAbnormalExitReportLocked(lastSessionText)
        }
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
        memoryLogCounter += 1
        if memoryLogCounter % 30 == 0 {
            writeLocked(String(format: "[memory] phys_footprint=%.1f MB", AppMemoryUsage.footprintMB))
        }
        lock.unlock()
    }

    func markBackground() {
        append("[session] 已进入后台")
    }

    func markForeground() {
        append("[session] 已回到前台")
    }

    func markCleanExit() {
        append("[session] 正常退出")
    }

    private func isAbnormalExit(_ text: String) -> Bool {
        if text.contains("[session] 正常退出") { return false }
        let enteredBackground = text.contains("[session] 已进入后台")
        let returnedForeground = text.contains("[session] 已回到前台")
        // 进入后台后未再回到前台属于 iOS 后台回收，不算异常退出。
        return !enteredBackground || returnedForeground
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
        clearCrashReportsLocked()
        fileManager.createFile(atPath: currentURL.path, contents: nil)
        handle = try? FileHandle(forWritingTo: currentURL)
        writeLocked("[session] \(sessionHeader())")
        lock.unlock()
    }

    func clearCrashReports() {
        lock.lock()
        clearCrashReportsLocked()
        lock.unlock()
    }

    private func clearCrashReportsLocked() {
        for url in crashReportURLsLocked() {
            try? fileManager.removeItem(at: url)
        }
        try? fileManager.removeItem(at: crashesURL.appendingPathComponent("CarWithin-diagnostics.txt"))
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
        let data = Data((line + "\n").utf8)
        handle.seekToEndOfFile()
        handle.write(data)
        writtenBytesSinceTrim += data.count
        guard writtenBytesSinceTrim >= Self.trimCheckBytes else { return }
        writtenBytesSinceTrim = 0
        trimLogIfNeededLocked()
    }

    /// 磁盘日志超过 2MB 时保留尾部 1MB，避免长时间运行或高频日志导致文件无限增长。
    private func trimLogIfNeededLocked() {
        guard let size = try? fileManager.attributesOfItem(atPath: currentURL.path)[.size] as? NSNumber,
              size.intValue > Self.maxLogBytes else { return }
        guard let text = try? String(contentsOf: currentURL, encoding: .utf8),
              text.utf8.count > Self.keptLogBytes else { return }
        let kept = String(text.suffix(Self.keptLogBytes))
        closeHandleLocked()
        try? ("[session] 日志已自动裁剪（保留最近内容）\n" + kept).write(to: currentURL, atomically: true, encoding: .utf8)
        handle = try? FileHandle(forWritingTo: currentURL)
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

    private func writeAbnormalExitReportLocked(_ lastSessionText: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmssSSS"
        let name = "crash-detected-\(formatter.string(from: Date())).log"
        let url = crashesURL.appendingPathComponent(name)
        let text = """
        \(crashHeader())
        ==== CarWithin abnormal exit detected ====
        reason=上次会话没有写入“正常退出”标记，可能发生了闪退或被系统强杀。
        ==== Last session log tail ====
        \(tail(lastSessionText, limit: 20_000))
        """
        try? (text + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func tail(_ text: String, limit: Int = 20_000) -> String {
        guard text.utf16.count > limit else { return text }
        return String(text.suffix(limit))
    }
}

enum CrashReporter {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        carWithinCrashURL = DiagnosticLogStore.shared.prepareCrashReportURL()
        carWithinCrashHeader = DiagnosticLogStore.shared.crashHeader()

        NSSetUncaughtExceptionHandler(carWithinExceptionHandler)
        for signalNumber in [SIGABRT, SIGSEGV, SIGBUS, SIGFPE, SIGILL] {
            signal(signalNumber, carWithinSignalHandler)
        }
    }
}
