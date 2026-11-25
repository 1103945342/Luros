import Foundation
import QuartzCore
import UIKit
import os

/// Timings for a chat's live updates, and a frame watchdog beside them.
///
/// Only a development copy turns this on: in the app `active` is false, every
/// call costs one comparison, and nothing is logged. What it prints goes to
/// the system log, one line a second while a chat is on screen, where
/// `luros_log_read` on the device reads it:
///
///     frames=58 dropped=6 worst=42.1ms apply=12/38.4ms height=5/121.0ms
///
/// Each measurement reads as its number of calls, then the total time they
/// took in that second. `dropped` counts frames that arrived more than half a
/// slot late, which is what a reader feels as a stutter.
@MainActor
enum ChatPerformance {
    /// Whether this build reports: a development copy only, which is the one
    /// named `…​.dev`.
    static let active = Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true

    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.fluoxetine.luros",
        category: "chat-performance",
    )

    private struct Total {
        var calls = 0
        var milliseconds = 0.0
    }

    private static var totals: [String: Total] = [:]
    private static var frames = 0
    private static var dropped = 0
    private static var worstStall: CFTimeInterval = 0
    private static var windowStart: CFTimeInterval = 0
    private static var lastFrame: CFTimeInterval = 0
    private static var link: CADisplayLink?

    /// How long a batch of measurements is gathered before it is logged.
    private static let window: CFTimeInterval = 1

    /// Reports `body`, under `tag`, to the line this second prints.
    static func measure<T>(_ tag: String, _ body: () -> T) -> T {
        guard active else { return body() }
        let start = CACurrentMediaTime()
        defer {
            var total = totals[tag] ?? Total()
            total.calls += 1
            total.milliseconds += (CACurrentMediaTime() - start) * 1000
            totals[tag] = total
        }
        return body()
    }

    static func start() {
        guard active, link == nil else { return }
        lastFrame = 0
        windowStart = CACurrentMediaTime()
        let link = CADisplayLink(target: Target(), selector: #selector(Target.tick(_:)))
        // A reader's finger is on the list while the frames that matter are
        // drawn, and tracking runs the loop in its own mode.
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    static func stop() {
        link?.invalidate()
        link = nil
        totals.removeAll(keepingCapacity: true)
        frames = 0
        dropped = 0
        worstStall = 0
    }

    fileprivate static func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        if lastFrame > 0 {
            let elapsed = now - lastFrame
            frames += 1
            let slot = link.duration > 0 ? link.duration : 1.0 / 60
            if elapsed > slot * 1.5 {
                dropped += 1
                worstStall = max(worstStall, elapsed)
            }
        }
        lastFrame = now
        guard now - windowStart >= window else { return }
        flush()
    }

    private static func flush() {
        let parts = totals
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.calls)/\(String(format: "%.1f", $0.value.milliseconds))ms" }
        log.notice(
            "frames=\(frames, privacy: .public) dropped=\(dropped, privacy: .public) worst=\(String(format: "%.1f", worstStall * 1000), privacy: .public)ms \(parts.joined(separator: " "), privacy: .public)",
        )
        totals.removeAll(keepingCapacity: true)
        frames = 0
        dropped = 0
        worstStall = 0
        windowStart = CACurrentMediaTime()
    }

    /// The display link's target, held weakly by nothing else: the link keeps
    /// it, and `stop()` invalidating the link releases both.
    @MainActor
    private final class Target: NSObject {
        @objc func tick(_ link: CADisplayLink) {
            ChatPerformance.tick(link)
        }
    }
}