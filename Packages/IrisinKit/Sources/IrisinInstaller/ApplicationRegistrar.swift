import Foundation
import IrisinProtocol

/// The LaunchServices work a package's bundles need, and the graceful
/// respring: one closed request per operation and a reply dictionary that is
/// read rather than shown.
///
/// Upstream fills this with icli's library. Luros supplies its own
/// implementation (`InstallerRegistrar` in lurosd): bundles are registered
/// with `uicache`, the same tool `ApplicationInstall` runs, and the respring
/// is `sbreload`'s. The request is public so that host can answer it.
public struct ApplicationRegistrar {
    public enum Request: Equatable {
        /// Register, or re-register an updated app at the same path. icli
        /// checks LaunchServices lists it afterwards.
        case register(bundle: String)
        /// Drop the registration, whether or not the bundle is still on
        /// disk. Not being registered is success.
        case unregister(bundle: String)
        /// Register new or moved bundles in the directory, skip unchanged
        /// ones, drop registrations whose bundle is gone.
        case refresh(directory: String)
        /// FrontBoard's relaunch action, the graceful fade `sbreload` sends,
        /// verified by the home screen's pid changing (PineBoard's on tvOS).
        case respring
    }

    enum Outcome {
        /// The reply.
        case done([String: Any])
        /// icli refused: the message it gave.
        case failed(String)

        var succeeded: Bool {
            if case .done = self {
                return true
            }
            return false
        }

        /// What to tell the user, when it went wrong.
        var reason: String {
            switch self {
            case .done: ""
            case let .failed(message): message
            }
        }
    }

    /// A refusal from whatever stands in for icli: the harness, or a platform
    /// icli is not built for.
    struct Refusal: Error {
        let message: String
    }

    /// `ApplicationRegistrar.live`, except in the harness.
    let perform: (Request) throws -> [String: Any]

    func register(bundleAt kernelPath: String) -> Outcome {
        run(.register(bundle: kernelPath))
    }

    func unregister(bundleAt kernelPath: String) -> Outcome {
        run(.unregister(bundle: kernelPath))
    }

    /// A reply that lists failures is a failure.
    func refresh(directory: String) -> Outcome {
        let outcome = run(.refresh(directory: directory))
        guard case let .done(reply) = outcome else { return outcome }
        let failed = (reply["failed"] as? [Any]) ?? []
        let unverified = (reply["unverified"] as? [Any]) ?? []
        guard failed.isEmpty, unverified.isEmpty else {
            return .failed("\(failed.count) failed, \(unverified.count) unverified")
        }
        return outcome
    }

    func respring() -> Outcome {
        run(.respring)
    }

    private func run(_ request: Request) -> Outcome {
        do {
            return try .done(perform(request))
        } catch {
            return .failed(Self.message(of: error))
        }
    }

    private static func message(of error: Error) -> String {
        if let refusal = error as? Refusal {
            return refusal.message
        }
        return String(describing: error)
    }

    #if targetEnvironment(simulator)
        /// The simulator's home screen is not ours to change: every request
        /// is announced and answered as done, with the empty reply the
        /// callers already read as nothing to count.
        static func live(emit: @escaping (InstallerEvent) -> Void) -> (Request) throws -> [String: Any] {
            { request in
                emit(.notice("Simulator: \(request) was not carried out"))
                return [:]
            }
        }

    #else
        /// Luros supplies its own registrar (`InstallBridge`): the home screen
        /// is told about a bundle with `uicache`, and nothing here names
        /// LaunchServices without it.
        static func live(emit _: @escaping (InstallerEvent) -> Void) -> (Request) throws -> [String: Any] {
            { _ in throw Refusal(message: "no application registrar was supplied") }
        }
    #endif
}
