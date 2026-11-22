import Darwin
import Foundation
import IrisinInstaller
import IrisinProtocol

/// `lurosd --installer`: one job as root, started by the session host and by
/// nothing else.
///
/// The job arrives as JSON on standard input, the package — when the job has
/// one — on descriptor 3, and the transcript leaves as one event per line on
/// standard output, the way Irisin's own helper wrote it. The same lines go to
/// `<install root>/var/log/luros-install.log`, so a run outlives the host that
/// started it. There is no Mach service and no name to look up: the host that
/// approves an install is the host that spawns this, in a session of its own,
/// so a package whose postinst restarts Luros does not take the install with
/// it.
///
/// Reading a `.deb` links libarchive, and this mode is why the daemon may:
/// an install has to run from the same executable the host already is, and
/// the alternative — a second shipped root binary — is what this work
/// removed. The link is vendored source compiled in this repository
/// (`Packages/IrisinKit`), reviewed in `Licenses/`, and `AGENTS.md` says so.
enum InstallerMode {
    static let argument = "--installer"

    /// Runs one job to completion and never returns: the process ends with it.
    static func run(installRoot: String, ownPath: String) -> Never {
        guard geteuid() == 0 else {
            refuse("it must run as root")
        }
        // Only the session host starts this, and the host is this same
        // executable, running as root. Anything else that got here is refused
        // before a byte of the job is read: a mode anyone could reach would be
        // a root installer nobody approved.
        let parent = getppid()
        guard parent > 1, executablePath(pid: parent) == ownPath,
              ProcessCredentials(pid: parent)?.uid == 0
        else {
            refuse("start it through Luros's session host")
        }

        // A reader that went away turns every write into EPIPE, which must
        // not kill a half-finished install.
        signal(SIGPIPE, SIG_IGN)

        let job = try? InstallerJob.decode(FileHandle.standardInput.readDataToEndOfFile())
        let startsFreshLog: Bool = switch job {
        case .some(.transaction), .some(.external): true
        default: false
        }
        let logDescriptor = openLog(installRoot: installRoot, fresh: startsFreshLog)
        let clock: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
            return formatter
        }()

        func emit(_ event: InstallerEvent) {
            writeAll(STDOUT_FILENO, Data((InstallerOutput.encode(event) + "\n").utf8))
            writeLog(logDescriptor, clock: clock, event)
        }

        guard let job else {
            emit(.failure(.invalidJob))
            emit(.exit(EX_DATAERR))
            exit(EX_DATAERR)
        }
        emit(.started(.init(job: job.name, uid: getuid(), installRoot: installRoot)))
        let runner = InstallerRunner.luros(
            installRoot: installRoot,
            emit: emit,
            registrar: InstallerRegistrar.perform(installRoot: installRoot, emit: emit),
        )
        let status = runner.run(job)
        emit(.exit(status))
        // The reader sees the end of the run before anything that would stop
        // it; what follows goes to the log alone.
        close(STDOUT_FILENO)
        runner.finishAfterExit { event in
            writeLog(logDescriptor, clock: clock, event)
        }
        exit(status)
    }

    /// The transcript file: a fresh one per transaction, keeping the run
    /// before it, and appended to for a maintenance job. -1 when it cannot be
    /// made — the pipe still carries every event.
    private static func openLog(installRoot: String, fresh: Bool) -> Int32 {
        let root = installRoot == "/" ? "" : installRoot
        let path = root + IrisinWire.installerLogPath
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true,
        )
        if fresh {
            _ = rename(path, path + ".previous")
        }
        let flags = fresh
            ? O_WRONLY | O_CREAT | O_TRUNC | O_APPEND | O_CLOEXEC
            : O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC
        return open(path, flags, 0o644)
    }

    /// The log gets the time and the plain-text line; the ring's hundred ticks
    /// are for the screen, not for the record.
    private static func writeLog(_ descriptor: Int32, clock: DateFormatter, _ event: InstallerEvent) {
        guard descriptor >= 0 else { return }
        if case .packageProgress = event {
            return
        }
        writeAll(descriptor, Data((clock.string(from: Date()) + " " + event.description + "\n").utf8))
    }

    private static func writeAll(_ descriptor: Int32, _ data: Data) {
        guard descriptor >= 0 else { return }
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
                if written < 0, errno == EINTR {
                    continue
                }
                guard written > 0 else { return }
                offset += written
            }
        }
    }

    private static func refuse(_ why: String) -> Never {
        FileHandle.standardError.write(Data("lurosd --installer: \(why)\n".utf8))
        exit(EX_CONFIG)
    }
}
