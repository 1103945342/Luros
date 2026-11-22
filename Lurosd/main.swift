import Darwin
import Foundation

// lurosd is two processes from one executable:
//
// - the launchd job (no arguments): a thin, authenticated proxy, on demand —
//   launchd starts it for a message to its Mach service, and it exits once
//   it has been idle with no connection, request or session work (Proxy,
//   WorkLedger);
// - `lurosd-session` (`--session`, a socketpair as descriptor 3): the
//   session host it starts as its child, which owns tasks and workers
//   (SessionHost).

private let executableSuffix = "/usr/libexec/lurosd"

// No install prefix is written in Swift: the root is whatever this executable
// was started from, and an unrecognised path refuses to start.
guard let ownPath = executablePath(pid: getpid()), ownPath.hasSuffix(executableSuffix) else {
    NSLog("lurosd: refusing to start from an unrecognised path")
    exit(EX_CONFIG)
}

private let installRoot: String = {
    let root = String(ownPath.dropLast(executableSuffix.count))
    return root.isEmpty ? "/" : root
}()

if CommandLine.arguments.dropFirst().first == InstallerMode.argument {
    // One install job as root, spawned by the session host with a job on
    // standard input and its transcript on standard output.
    InstallerMode.run(installRoot: installRoot, ownPath: ownPath)
}

if CommandLine.arguments.dropFirst().first == SessionLink.sessionArgument {
    SessionHost(installRoot: installRoot, ownPath: ownPath).run()
} else {
    Proxy(installRoot: installRoot, ownExecutable: ownPath).run()
}
