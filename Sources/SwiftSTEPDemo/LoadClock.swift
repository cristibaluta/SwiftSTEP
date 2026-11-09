import Foundation
import SwiftSTEP

/// Times the path from "open" to "pixels on screen" and prints one table to stderr, so the slowest
/// step is obvious. Steps are the gaps between marks: each `mark` closes the step that led up to it.
final class LoadClock: @unchecked Sendable {
    static let shared = LoadClock()

    private struct Row { var label: String; var ms: Double; var isSub: Bool }
    private let lock = NSLock()
    private let clock = ContinuousClock()
    private var start: ContinuousClock.Instant?
    private var last: ContinuousClock.Instant?
    private var name = ""
    private var rows: [Row] = []

    private func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    func begin(_ file: String) {
        lock.lock(); defer { lock.unlock() }
        start = clock.now
        last = start
        name = file
        rows = []
    }

    /// Ends the step that started at the previous mark.
    func mark(_ label: String) {
        lock.lock(); defer { lock.unlock() }
        guard let previous = last else { return }
        let now = clock.now
        rows.append(Row(label: label, ms: ms(previous.duration(to: now)), isSub: false))
        last = now
    }

    /// A breakdown of the step just marked (shown indented, not added to the total again).
    func sub(_ label: String, seconds: Double) {
        lock.lock(); defer { lock.unlock() }
        rows.append(Row(label: label, ms: seconds * 1000, isSub: true))
    }

    /// Prints the table; call once, after the first frame.
    func finish() {
        lock.lock()
        guard let start, !rows.isEmpty else { lock.unlock(); return }
        let total = ms(start.duration(to: clock.now))
        let printed = rows
        let title = name
        self.start = nil
        lock.unlock()

        var lines = ["SwiftSTEPDemo timing: \(title)"]
        let slowest = printed.filter { !$0.isSub }.max { $0.ms < $1.ms }?.label
        for row in printed {
            let share = String(format: "%5.1f%%", row.ms / max(total, 1e-9) * 100)
            let time = String(format: "%9.1f ms", row.ms)
            if row.isSub {
                lines.append("      \(time)  \(row.label)")
            } else {
                lines.append("  \(time)  \(share)  \(row.label)\(row.label == slowest ? "   <- slowest" : "")")
            }
        }
        lines.append(String(format: "  %9.1f ms  total, open to first frame on screen", total))
        FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
    }
}
