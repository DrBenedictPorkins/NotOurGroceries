import Foundation
import OSLog

/// What this phone did, kept where somebody can actually read it.
///
/// The server has had structured telemetry for months. The client had `print()`,
/// which writes to stdout — and on a device stdout reaches no log at all, so
/// nothing a real phone did was recoverable. A whole afternoon of diagnosis was
/// done by screenshotting error banners and reasoning backwards, and three
/// consecutive fixes were built on theory because there was no evidence to build
/// them on.
///
/// So: a ring buffer in memory, mirrored to `os.Logger` (which the unified log
/// and `idevicesyslog` can see), flushed to a file so it survives a crash, and
/// exportable from Settings so it can be sent to us.
///
/// **The no-content rule, same as the server's.** Never log what a person wrote:
/// no item names, no notes, no email addresses, no aisle names. Counts, ids,
/// types and outcomes only. A log somebody is asked to send us must be one they
/// can send without thinking about what is in it.
@MainActor
final class SessionLog: ObservableObject {
    static let shared = SessionLog()

    enum Level: String, Codable {
        case debug, info, warning, error
    }

    struct Entry: Codable, Identifiable {
        let id: UUID
        let at: Date
        let level: Level
        let category: String
        let event: String
        /// Structural detail only — see the no-content rule above.
        let detail: [String: String]

        init(level: Level, category: String, event: String, detail: [String: String]) {
            self.id = UUID()
            self.at = Date()
            self.level = level
            self.category = category
            self.event = event
            self.detail = detail
        }
    }

    /// Enough to cover a launch and a shopping trip, small enough to keep in
    /// memory and to paste into a message.
    private static let capacity = 600

    @Published private(set) var entries: [Entry] = []

    private let logger = Logger(subsystem: "com.byteclub.grocery", category: "session")
    private var pendingWrite: Task<Void, Never>?

    private init() {}

    // MARK: - Writing

    func debug(_ category: String, _ event: String, _ detail: [String: String] = [:]) {
        record(.debug, category, event, detail)
    }

    func info(_ category: String, _ event: String, _ detail: [String: String] = [:]) {
        record(.info, category, event, detail)
    }

    func warning(_ category: String, _ event: String, _ detail: [String: String] = [:]) {
        record(.warning, category, event, detail)
    }

    func error(_ category: String, _ event: String, _ detail: [String: String] = [:]) {
        record(.error, category, event, detail)
    }

    /// A failure, classified. The type is the useful part, not the prose.
    func failure(_ category: String, _ event: String, _ failure: ServiceFailure,
                 _ detail: [String: String] = [:]) {
        var all = detail
        all["kind"] = failure.logKind
        record(.error, category, event, all)
    }

    private func record(_ level: Level, _ category: String, _ event: String,
                        _ detail: [String: String]) {
        let entry = Entry(level: level, category: category, event: event, detail: detail)
        entries.append(entry)
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }

        // Mirrored so `idevicesyslog` and Console can see it live. `print` could
        // not — that is the whole reason this exists.
        let line = Self.line(entry)
        switch level {
        case .debug, .info: logger.info("\(line, privacy: .public)")
        case .warning: logger.warning("\(line, privacy: .public)")
        case .error: logger.error("\(line, privacy: .public)")
        }

        scheduleFlush()
    }

    // MARK: - Reading out

    /// The whole session as text, ready to be shared.
    var transcript: String {
        let header = """
        Got Dill? session log
        \(AppVersion.full)
        \(entries.count) entries

        """
        return header + entries.map(Self.line).joined(separator: "\n")
    }

    private static func line(_ entry: Entry) -> String {
        let time = timeFormatter.string(from: entry.at)
        let detail = entry.detail.isEmpty
            ? ""
            : " " + entry.detail.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
        return "\(time) \(entry.level.rawValue.uppercased()) [\(entry.category)] \(entry.event)\(detail)"
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    func clear() {
        entries = []
        if let url = Self.fileURL { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - Surviving a crash

    /// Debounced, because a burst of entries must not mean a burst of writes.
    private func scheduleFlush() {
        pendingWrite?.cancel()
        pendingWrite = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    private func flush() {
        guard let url = Self.fileURL else { return }
        try? transcript.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    /// The previous run's log, if it ended badly. Read once at launch so a crash
    /// is still readable afterwards.
    static func previousSession() -> String? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static var fileURL: URL? {
        guard let dir = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return dir.appendingPathComponent("session-log.txt")
    }
}

extension ServiceFailure {
    /// A stable, contentless name for the log. The associated message can carry
    /// whatever the server said, so it is deliberately not recorded here.
    var logKind: String {
        switch self {
        case .offline: return "offline"
        case .unauthorized: return "unauthorized"
        case .refused: return "refused"
        case .server: return "server"
        case .malformed: return "malformed"
        }
    }
}
