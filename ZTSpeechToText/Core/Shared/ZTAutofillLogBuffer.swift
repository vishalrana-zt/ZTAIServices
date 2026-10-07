import Foundation

/// Keeps the last few autofill sessions' debug lines in memory so a tester can share them as text
/// (a long-press on the autofill button opens the share sheet) instead of needing Xcode.
///
/// Only records while `CloudAPIConfiguration.isLoggingEnabled` is on, so nothing is kept — or
/// shareable — for normal users. Lines can contain what was dictated, which is why it is
/// off by default and only leaves the device through an explicit share.
public enum ZTAutofillLogBuffer {
    private static let lock = NSLock()
    /// One entry per autofill session, oldest first. Only the latest `maxSessions` are kept.
    nonisolated(unsafe) private static var sessions: [[String]] = []
    nonisolated(unsafe) private static var _sessionActive = false
    public static let maxSessions = 5
    private static let maxLinesPerSession = 800

    /// True while a form-section or table-row autofill session is open. Only then are lines
    /// kept for export, so other dictation and Customer/Asset/Equipment autofill don't clutter
    /// the log that is shared. The caller that owns the session sets it.
    public static var sessionActive: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _sessionActive }
        set { lock.lock(); _sessionActive = newValue; lock.unlock() }
    }

    /// Starts a new session's log and drops the oldest once more than `maxSessions` are kept.
    public static func beginSession() {
        lock.lock()
        sessions.append([])
        if sessions.count > maxSessions { sessions.removeFirst(sessions.count - maxSessions) }
        _sessionActive = true
        lock.unlock()
    }

    /// Prints the line (as before) and keeps it for export while a session is active.
    public static func log(_ line: String) {
        guard CloudAPIConfiguration.isLoggingEnabled else { return }
        print(line)
        append(line)
    }

    /// Keeps the line for export only (for callers that already printed it).
    public static func append(_ line: String) {
        guard CloudAPIConfiguration.isLoggingEnabled, sessionActive else { return }
        let stamp = timeFormatter.string(from: Date())
        lock.lock()
        if sessions.isEmpty { sessions.append([]) }
        if sessions[sessions.count - 1].count < maxLinesPerSession {
            sessions[sessions.count - 1].append("\(stamp) \(line)")
        }
        lock.unlock()
    }

    public static func clear() {
        lock.lock(); sessions.removeAll(); lock.unlock()
    }

    public static var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return sessions.allSatisfy { $0.isEmpty }
    }

    /// The kept sessions as plain text, oldest first, with a short header saying where they came from.
    public static func exportText() -> String {
        lock.lock(); let snapshot = sessions; lock.unlock()
        let lineCount = snapshot.reduce(0) { $0 + $1.count }
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let header = [
            "Autofill debug log",
            "App \(version) (\(build)) | iOS \(ProcessInfoOS.version) | language \(ZTAIServiceLocalizer.currentLanguageCode ?? "en")",
            "Exported \(ISO8601DateFormatter().string(from: Date())) | last \(snapshot.count) session(s), \(lineCount) lines",
            String(repeating: "-", count: 40)
        ]
        return (header + snapshot.flatMap { $0 }).joined(separator: "\n")
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}

private enum ProcessInfoOS {
    static var version: String { ProcessInfo.processInfo.operatingSystemVersionString }
}
