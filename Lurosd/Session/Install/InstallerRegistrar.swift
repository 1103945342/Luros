import Foundation
import IrisinInstaller
import IrisinProtocol

/// What the installer asks when it has to tell the system about a bundle, or
/// restart the home screen. Luros answers with the tools its bootstrap ships
/// — `uicache` for LaunchServices, `sbreload` for the graceful respring — and
/// with nothing else: no icli, no LaunchServices library of its own.
///
/// The bundle paths arrive as kernel paths; `ApplicationInstall` spells them
/// the way `uicache` reads them (`toolPath`), exactly as it does for an
/// `.ipa`.
enum InstallerRegistrar {
    /// A request Luros does not carry out. The installer prints the sentence.
    struct Refusal: Error, CustomStringConvertible {
        var description: String

        init(_ description: String) {
            self.description = description
        }
    }

    static func perform(
        installRoot: String,
        emit: @escaping (InstallerEvent) -> Void
    ) -> (ApplicationRegistrar.Request) throws -> [String: Any] {
        let layout = ApplicationInstall.Layout(installRoot: installRoot)
        let root = installRoot == "/" ? "" : installRoot
        return { request in
            switch request {
            case let .register(bundle):
                try ApplicationInstall.register(
                    URL(fileURLWithPath: bundle),
                    layout: layout,
                    installRoot: installRoot,
                )
                emit(.notice("Registered \(bundle)"))
                return [:]
            case let .unregister(bundle):
                try ApplicationInstall.unregister(bundle, layout: layout, installRoot: installRoot)
                emit(.notice("Unregistered \(bundle)"))
                return [:]
            case .refresh:
                // Irisin's own app asks for this when it registers itself;
                // no job Luros sends carries it.
                throw Refusal("Luros does not refresh the whole applications directory")
            case .respring:
                try respring(root: root, emit: emit)
                return [:]
            }
        }
    }

    /// `sbreload`, the bootstrap's own graceful restart, then the home
    /// screen's new pid as the receipt. Refusing here lets the installer fall
    /// back to the signal it sends itself (`backboardd`).
    private static func respring(root: String, emit: @escaping (InstallerEvent) -> Void) throws {
        let tool = root + "/usr/bin/sbreload"
        guard FileManager.default.isExecutableFile(atPath: tool) else {
            throw Refusal("sbreload is not installed")
        }
        let before = springBoardPIDs()
        let result = try ApplicationInstall.run(tool, [])
        guard result.status == 0 else {
            throw Refusal("sbreload answered \(result.status): \(result.output)")
        }
        guard waitForAFreshHomeScreen(since: before, within: 20) else {
            throw Refusal("the home screen did not come back after sbreload")
        }
        emit(.notice("The home screen restarted"))
    }

    /// Whether SpringBoard came back with another pid, checked every 200 ms
    /// for `seconds`. The pid is the receipt: `sbreload` may answer before
    /// the home screen is back, so its exit status alone is not one.
    static func waitForAFreshHomeScreen(since before: Set<Int32>, within seconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            usleep(200_000)
            let now = springBoardPIDs()
            if !now.isEmpty, now != before { return true }
        }
        return false
    }

    /// SpringBoard's pids, by the executable the kernel names.
    static func springBoardPIDs() -> Set<Int32> {
        Set(processIDs().filter { executablePath(pid: $0)?.hasSuffix("/SpringBoard") == true })
    }
}
