import Foundation
import IrisinProtocol

/// Luros starts the installer itself, from the session host: the registrar is
/// Luros's own (`InstallerRegistrar`: its bundled icli and the respring), and the
/// launchd maintenance jobs Irisin's app sends are never asked for. The
/// process table is the kernel's, the same `ProcessTable` upstream signals
/// with.
extension InstallerRunner {
    /// One runner for one job, with the host's own answers.
    public static func luros(
        installRoot: String,
        emit: @escaping (InstallerEvent) -> Void,
        registrar: @escaping (ApplicationRegistrar.Request) throws -> [String: Any]
    ) -> InstallerRunner {
        InstallerRunner(
            installRoot: installRoot,
            layout: nil,
            emit: emit,
            registrar: registrar,
            daemonManager: { _ in throw LurosInstallerRefusal.irisinsOwnJobs },
            signalProcesses: ProcessTable.signal(processesNamed:with:)
        )
    }
}

/// What Luros refuses that Irisin's own helper carries out: the jobs its app
/// sends to register its own bundle and to restart its daemon.
public enum LurosInstallerRefusal: Error, CustomStringConvertible {
    case irisinsOwnJobs

    public var description: String {
        "Luros never sends Irisin's own maintenance jobs"
    }
}
