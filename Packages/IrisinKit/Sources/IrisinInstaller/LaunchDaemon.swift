import Foundation
import IrisinProtocol

/// The two launchd changes Irisin's own package may make. The plist path is
/// derived by `InstallerRunner`; neither the app nor a package supplies it.
struct LaunchDaemon {
    private static let label = "wiki.qaq.irisind"

    enum Request: Equatable {
        case bootstrap(plist: String, executable: String)
        case bootout(plist: String)
    }

    let perform: (Request) throws -> Void

    /// launchd reads kernel paths; unlike the bootstrap's launchctl, it does
    /// not translate rootful program paths for RootHide.
    ///
    /// RootHide renames the bootstrap root at every jailbreak and its
    /// launchctl then rewrites each plist here (`plistpatch.m`): one marked
    /// `__Patched` has the old root taken off its paths before the new one is
    /// put on, one without the mark only gets the new root in front. A kernel
    /// path written without the mark comes out as new root + old root and the
    /// daemon never starts again. launchd itself ignores the key.
    static func preparePlist(at path: String, executable: String) throws {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        guard var plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        plist["ProgramArguments"] = [executable]
        plist["__Patched"] = true
        let updated = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try updated.write(to: url, options: .atomic)
    }

    #if targetEnvironment(simulator)
        static func live(emit: @escaping (InstallerEvent) -> Void) -> (Request) throws -> Void {
            { request in
                emit(.notice("Simulator: \(request) was not carried out"))
            }
        }

    #else
        /// Luros never sends Irisin's own maintenance jobs: the daemon they
        /// manage is not part of it. A job that asked for one is refused.
        static func live(emit _: @escaping (InstallerEvent) -> Void) -> (Request) throws -> Void {
            { _ in throw CocoaError(.featureUnsupported) }
        }
    #endif
}
