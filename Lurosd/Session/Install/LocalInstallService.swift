import Darwin
import Foundation
import IrisinInstaller
import IrisinProtocol

/// `InstallService` over the installer this same executable carries in its
/// `--installer` mode: Luros spawns it, reads its journal from the
/// transaction's directory, and there is no Mach service, no name to look up
/// and no daemon to wait for.
///
/// The transaction's shape is Irisin's (`ExternalTransaction`): a directory
/// named by the transaction id, root's alone, whose `request.json` says what
/// was asked, whose `events.jsonl` is the installer's transcript, and whose
/// lock says whether it is still running. The host writes the request and
/// takes the journal's lock before it spawns; the child inherits both.
final class LocalInstallService: InstallService, @unchecked Sendable {
    /// Where the installer is: this executable, started again in its
    /// installer mode.
    private let hostPath: String
    private let root: String
    private let transactions: String
    private let reaping = DispatchQueue(label: "com.fluoxetine.luros.installer-reaper")
    private let lock = NSLock()
    /// The pid of each transaction's installer that has not been reaped.
    private var running: [String: pid_t] = [:]

    init(installRoot: String, hostPath: String) {
        self.hostPath = hostPath
        root = installRoot == "/" ? "" : installRoot
        transactions = root + IrisinWire.transactionsPath
    }

    // MARK: - InstallService

    func serviceInfo() async throws -> InstallServiceInfo {
        InstallServiceInfo(
            externalVersion: IrisinWire.externalVersion,
            capabilities: Set(InstallServiceRequirement.capabilities),
            installRoot: root.isEmpty ? "/" : root,
        )
    }

    func submitInstall(transaction: UUID, descriptor: Int32, sha256: String) async throws -> InstallTransactionStatus {
        try submit(
            transaction: transaction,
            request: ExternalTransaction.Request(
                kind: .install,
                sha256: sha256,
                created: Date().timeIntervalSince1970,
                client: hostPath,
            ),
            action: .install(sha256: sha256),
            packageDescriptor: descriptor,
        )
    }

    func removePackage(transaction: UUID, packageID: String) async throws -> InstallTransactionStatus {
        try submit(
            transaction: transaction,
            request: ExternalTransaction.Request(
                kind: .remove,
                identity: packageID,
                created: Date().timeIntervalSince1970,
                client: hostPath,
            ),
            action: .remove(identity: packageID),
            packageDescriptor: nil,
        )
    }

    /// A maintenance job, not a transaction: the installer is started for it
    /// and waited for, because the answer is its exit status.
    func respring(transaction: UUID) async throws -> InstallTransactionStatus {
        let pid = try start(job: .respring, packageDescriptor: nil, journal: nil)
        let status = waitForExit(pid, within: 30)
        guard status == 0 else {
            throw InstallServiceError(.refused, "The home screen did not restart (exit status \(status)).")
        }
        return InstallTransactionStatus(
            transaction: transaction,
            kind: "respring",
            state: .succeeded,
            nextSequence: 1,
            exitStatus: Int64(status),
            packageID: nil,
            version: nil,
            failure: nil,
            failureText: nil,
            duplicate: false,
        )
    }

    func status(of transaction: UUID) async throws -> InstallTransactionStatus {
        try currentStatus(of: transaction.uuidString.lowercased(), duplicate: false)
    }

    func events(
        of transaction: UUID,
        after: UInt64,
    ) async throws -> (status: InstallTransactionStatus, events: [InstallTransactionEvent]) {
        let identifier = transaction.uuidString.lowercased()
        let record = try record(of: identifier)
        return (
            try currentStatus(of: identifier, duplicate: false),
            record.events(after: after, limit: IrisinWire.maximumEventsPerReply).map(Self.event),
        )
    }

    func cancel(_ transaction: UUID) {
        let identifier = transaction.uuidString.lowercased()
        let pid = lock.withLock { running[identifier] }
        guard let pid, pid > 1 else { return }
        // The installer leads its own session, so its group is its own.
        kill(-pid, SIGKILL)
        kill(pid, SIGKILL)
    }

    // MARK: - Transactions

    private func submit(
        transaction: UUID,
        request: ExternalTransaction.Request,
        action: InstallerJob.External.Action,
        packageDescriptor: Int32?,
    ) throws -> InstallTransactionStatus {
        let identifier = transaction.uuidString.lowercased()
        let directory = ExternalTransaction.directory(installRoot: root, transaction: identifier)
        try makeDirectory(directory)
        let requestPath = directory + "/" + ExternalTransaction.File.request
        if let existing = try? record(of: identifier) {
            guard existing.request.isSameRequest(as: request) else {
                throw InstallServiceError(.conflict, "That transaction id is already a different request.")
            }
            switch existing.state {
            case .succeeded, .failed:
                return try currentStatus(of: identifier, duplicate: true)
            case .running:
                return try currentStatus(of: identifier, duplicate: true)
            case .interrupted:
                // Nobody holds the journal and there is no exit: the run died
                // with the host or the device. Submitting it again resumes it.
                break
            }
        } else {
            let data: Data
            do {
                data = try JSONEncoder().encode(request)
            } catch {
                throw InstallServiceError(.refused, "The transaction could not be written: \(error)")
            }
            guard (try? data.write(to: URL(fileURLWithPath: requestPath), options: .atomic)) != nil else {
                throw InstallServiceError(.refused, "The transaction could not be written to \(requestPath).")
            }
            _ = chmod(requestPath, 0o600)
        }

        let journal = directory + "/" + ExternalTransaction.File.journal
        _ = try start(
            job: .external(.init(transaction: identifier, action: action)),
            packageDescriptor: packageDescriptor,
            journal: journal,
        )
        return InstallTransactionStatus(
            transaction: transaction,
            kind: request.kind.rawValue,
            state: .running,
            nextSequence: (try? record(of: identifier).nextSequence) ?? 1,
            exitStatus: nil,
            packageID: request.identity,
            version: nil,
            failure: nil,
            failureText: nil,
            duplicate: false,
        )
    }

    private func record(of transaction: String) throws -> ExternalTransaction.Record {
        let directory = ExternalTransaction.directory(installRoot: root, transaction: transaction)
        do {
            return try ExternalTransaction.Record.load(directory: directory, transaction: transaction)
        } catch {
            throw InstallServiceError(.notFound, "No transaction \(transaction) was started.")
        }
    }

    /// The record, with a run this host is still watching read as running: the
    /// journal's lock is taken by the child a moment after the spawn, and a
    /// submission that raced that moment must not read as an interrupted run.
    private func currentStatus(of transaction: String, duplicate: Bool) throws -> InstallTransactionStatus {
        let record = try record(of: transaction)
        var state = record.state
        if state == .interrupted, lock.withLock({ running[transaction] }) != nil {
            state = .running
        }
        return InstallTransactionStatus(
            transaction: UUID(uuidString: record.transaction) ?? UUID(),
            kind: record.request.kind.rawValue,
            state: InstallTransactionState(rawValue: state.rawValue) ?? .failed,
            nextSequence: record.nextSequence,
            exitStatus: record.exitStatus.map(Int64.init),
            packageID: record.package?.identity,
            version: record.package?.version,
            failure: record.failure?.problem,
            failureText: record.failure?.text,
            duplicate: duplicate,
        )
    }

    private static func event(_ event: ExternalTransaction.Event) -> InstallTransactionEvent {
        InstallTransactionEvent(
            sequence: event.sequence,
            kind: event.kind,
            text: event.text,
            phase: event.phase,
            step: event.step,
            packageID: event.identity,
            version: event.version,
            completed: event.completed,
            total: event.total,
            exitStatus: event.exitStatus,
            problem: event.problem,
        )
    }

    // MARK: - Starting the installer

    /// The transaction's directory: root's, open to nobody else.
    private func makeDirectory(_ directory: String) throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: transactions) {
            try? manager.createDirectory(
                atPath: transactions,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700],
            )
            _ = chmod(transactions, 0o700)
        }
        if !manager.fileExists(atPath: directory) {
            do {
                try manager.createDirectory(
                    atPath: directory,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700],
                )
            } catch {
                throw InstallServiceError(.refused, "The transaction's directory could not be made: \(error)")
            }
        }
        _ = chmod(directory, 0o700)
    }

    /// Starts this executable in installer mode, with the job on its standard
    /// input, the journal on its output and the package on descriptor 3 —
    /// Irisin's spawn contract, without the daemon that used to make it.
    private func start(
        job: InstallerJob,
        packageDescriptor: Int32?,
        journal: String?,
    ) throws -> pid_t {
        let payload: Data
        do {
            payload = try JSONEncoder().encode(job)
        } catch {
            throw InstallServiceError(.refused, "The job could not be encoded: \(error)")
        }

        // The journal takes an exclusive lock this process passes on to the
        // child with the descriptor: while that lock is held the run is
        // `running`, and when nobody holds it and there is no `exit`, it is
        // `interrupted`.
        var journalDescriptor: Int32 = -1
        if let journal {
            journalDescriptor = open(journal, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
            guard journalDescriptor >= 0 else {
                throw InstallServiceError(.refused, "The journal could not be opened: \(String(cString: strerror(errno)))")
            }
            guard flock(journalDescriptor, LOCK_EX) == 0 else {
                let reason = String(cString: strerror(errno))
                close(journalDescriptor)
                throw InstallServiceError(.refused, "The journal could not be locked: \(reason)")
            }
        }
        defer { if journalDescriptor >= 0 { close(journalDescriptor) } }

        var input: [Int32] = [-1, -1]
        guard pipe(&input) == 0 else {
            throw InstallServiceError(.refused, "A pipe could not be made: \(String(cString: strerror(errno)))")
        }
        defer {
            close(input[0])
            close(input[1])
        }

        var descriptors: [ProcessSpawn.Descriptor] = [.duplicate(input[0], as: STDIN_FILENO)]
        if journalDescriptor >= 0 {
            descriptors.append(.duplicate(journalDescriptor, as: STDOUT_FILENO))
            descriptors.append(.duplicate(journalDescriptor, as: STDERR_FILENO))
        } else {
            // A maintenance job with no journal still talks on standard
            // output: it goes to the installer's own log, not to the host.
            descriptors.append(.open(root + IrisinWire.installerLogPath, flags: O_WRONLY | O_CREAT | O_APPEND, as: STDOUT_FILENO))
            descriptors.append(.open(root + IrisinWire.installerLogPath, flags: O_WRONLY | O_CREAT | O_APPEND, as: STDERR_FILENO))
        }
        if let packageDescriptor {
            descriptors.append(.duplicate(packageDescriptor, as: InstallerJob.External.packageDescriptor))
        }

        let pid: pid_t
        do {
            pid = try ProcessSpawn.spawn(
                hostPath,
                arguments: [hostPath, InstallerMode.argument],
                environment: [],
                descriptors: descriptors,
                newSession: true,
            )
        } catch {
            throw InstallServiceError(.refused, "The installer could not be started: \(error)")
        }

        payload.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = write(input[1], bytes.baseAddress! + offset, bytes.count - offset)
                if written < 0, errno == EINTR {
                    continue
                }
                guard written > 0 else { return }
                offset += written
            }
        }

        let transaction: String? = if case let .external(external) = job { external.transaction } else { nil }
        if let transaction {
            lock.withLock { running[transaction] = pid }
        }
        reapWhenExited(pid, queue: reaping) { [weak self] _ in
            guard let self, let transaction else { return }
            self.lock.withLock {
                if self.running[transaction] == pid { self.running[transaction] = nil }
            }
        }
        return pid
    }

    /// The installer's exit status, or 70 when it outlasts `seconds`.
    private func waitForExit(_ pid: pid_t, within seconds: TimeInterval) -> Int32 {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            var status: Int32 = 0
            let answer = waitpid(pid, &status, WNOHANG)
            if answer == pid {
                return (status & 0x7F) == 0 ? (status >> 8) & 0xFF : 70
            }
            usleep(50_000)
        }
        kill(-pid, SIGKILL)
        kill(pid, SIGKILL)
        var status: Int32 = 0
        _ = waitpid(pid, &status, 0)
        return 70
    }
}
