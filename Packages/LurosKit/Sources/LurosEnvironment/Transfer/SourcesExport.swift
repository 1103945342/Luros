import ArchiveKit
import CryptoKit
import Darwin
import Foundation
import LurosCore
import LurosGit
import LurosProject
import LurosProtocol

/// A project exported as sources: a plain zip anyone can open, holding what a
/// Mac needs to work on it — the sources, the resources, the signing
/// entitlements, the Xcode project and the extension support beside it — and
/// nothing that belongs to Luros alone: no description, no repository, no
/// build output.
///
/// What is left out besides those: what the project's ignore rules name, so
/// the zip is the work and not the junk beside it, and `.DS_Store`.
extension TransferService {
    /// Names that never leave, by their path from the project's root.
    static func isLurosOnly(_ path: String) -> Bool {
        path == ProjectStore.projectFileName
    }

    func sourcesContents(
        _ project: ProjectLocator.Project,
        staging: URL,
        reporter: TaskReporter,
    ) throws -> SourcesCollected {
        let root = project.root
        var repository: GitRepository?
        var metadata = stat()
        let gitFolder = root.appendingPathComponent(".git")
        if lstat(gitFolder.path, &metadata) == 0,
           metadata.st_mode & S_IFMT == S_IFDIR,
           let opened = try? GitRepository(at: root)
        {
            repository = opened
        }
        let ignores = try GitIgnoreRules(
            root: root,
            repository: repository,
            scratch: staging.appendingPathComponent("ignore-rules"),
        )
        let rules = TransferTree.Rules(skip: { path, _ in
            let components = path.split(separator: "/")
            if components.last == ".DS_Store" {
                return true
            }
            // The repository is the Luros project's, and a receiver of sources
            // gets a fresh one: history is not what a plain zip is for.
            if components.first == ".git" {
                return true
            }
            if Self.isLurosOnly(path) {
                return true
            }
            return (try? ignores.ignores(path, isDirectory: false)) ?? false
        }, lenient: true)
        let tree = try TransferTree.collect(root, rules: rules, reporter: reporter)
        return SourcesCollected(tree: tree, name: project.name, warnings: tree.leftOut.map { "left out \($0)" })
    }

    /// A collected tree and the name its zip takes.
    struct SourcesCollected {
        var tree: TransferTree
        var name: String
        var warnings: [String] = []
    }

    /// Writes the project's sources as `Exports/sources-<id>/<name>.zip` and
    /// answers what the app shares. The folder is this export's alone, so an
    /// earlier export of the same project is replaced whole.
    func exportSources(
        _ prepared: PreparedExport,
        staging: URL,
        reporter: TaskReporter,
    ) async throws -> TransferExport {
        guard let project = prepared.project else {
            throw LurosError(.badRequest, "a sources export needs a project")
        }
        reporter.stage("collecting")
        let collected = try sourcesContents(project, staging: staging, reporter: reporter)
        try reporter.checkCancelled()

        reporter.stage("packing")
        try layout.make(layout.exports)
        let folderName = "sources-" + Self.fileSafe(prepared.id)
        let folder = layout.exports.appendingPathComponent(folderName, isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try layout.make(folder)
        let fileName = Self.fileSafe(collected.name) + ".zip"
        let partial = folder.appendingPathComponent("." + fileName + ".partial")
        let destination = folder.appendingPathComponent(fileName)
        let digest: String
        let size: Int64
        do {
            try SourcesArchiveWriter(tree: collected.tree, rootName: collected.name)
                .write(to: partial, reporter: reporter)
            reporter.stage("verifying")
            let total = try partial.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init)
            let throttle = ProgressThrottle()
            reporter.progress("verifying", completed: 0, total: total)
            (digest, size) = try TransferDigest.file(partial) { completed in
                try reporter.checkCancelled()
                if throttle.shouldEmit() {
                    reporter.progress("verifying", completed: completed, total: total)
                }
            }
            reporter.progress("verifying", completed: size, total: size)
            try reporter.checkCancelled()
            guard rename(partial.path, destination.path) == 0 else {
                throw ArchiveExtractor.posix("name the export")
            }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        collected.warnings.forEach(reporter.warning)
        return TransferExport(
            path: destination.path,
            exportedPath: folderName + "/" + fileName,
            fileName: fileName,
            size: size,
            sha256: digest,
            summary: TransferSummary(
                formatVersion: TransferManifest.currentFormatVersion,
                kind: .project,
                id: prepared.id,
                name: collected.name,
                createdBy: prepared.createdBy,
                created: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)),
                fileCount: collected.tree.members.count,
                payloadBytes: size,
            ),
        )
    }
}

/// Writes a folder's members into a zip, each file where it sits under the
/// project's own name: the archive unpacks to `<name>/Sources/…`, so two
/// projects unzipped into one folder never mix.
struct SourcesArchiveWriter {
    var tree: TransferTree
    var rootName: String

    /// A time every member carries: a zip of sources is not a record of when
    /// each file happened to be written, and one stamp keeps the archive the
    /// same byte for byte for the same tree.
    static let modificationTime: time_t = 0

    func write(to destination: URL, reporter: TaskReporter) throws {
        guard let archive = archive_write_new() else {
            throw LurosError(.internal, "libarchive: cannot write a zip")
        }
        defer { _ = archive_write_free(archive) }
        try step(archive_write_set_format_zip(archive), archive, "set the zip format")
        // A warning here leaves every member stored, which is a valid zip too.
        _ = archive_write_set_options(archive, "zip:compression=deflate")
        try step(archive_write_open_filename(archive, destination.path), archive, "create \(destination.lastPathComponent)")

        try ArchiveExtractor.withUTF8Names {
            try addFolder(rootName, to: archive)
            for member in tree.members {
                try reporter.checkCancelled()
                switch member.kind {
                case .directory:
                    try addFolder(rootName + "/" + member.path, to: archive)
                case .link:
                    // A zip has no portable link: what it pointed at travels
                    // as its own member when it was inside the project.
                    continue
                case .file:
                    guard let source = tree.sources[member.path] else {
                        throw LurosError(.internal, "\(member.path) has no file behind it")
                    }
                    try addFile(source, as: rootName + "/" + member.path, to: archive)
                }
            }
        }
        try step(archive_write_close(archive), archive, "finish \(destination.lastPathComponent)")
    }

    private func addFolder(_ name: String, to archive: OpaquePointer) throws {
        guard let entry = archive_entry_new() else {
            throw LurosError(.internal, "libarchive: no memory for an entry")
        }
        defer { _ = archive_entry_free(entry) }
        archive_entry_set_pathname_utf8(entry, name)
        archive_entry_set_filetype(entry, numericCast(S_IFDIR))
        archive_entry_set_perm(entry, numericCast(0o755))
        archive_entry_set_size(entry, 0)
        archive_entry_set_mtime(entry, Self.modificationTime, 0)
        try step(archive_write_header(archive, entry), archive, "write \(name)")
        try step(archive_write_finish_entry(archive), archive, "finish \(name)")
    }

    private func addFile(_ url: URL, as name: String, to archive: OpaquePointer) throws {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            throw LurosError(.notFound, "\(url.lastPathComponent) is not there")
        }
        guard let entry = archive_entry_new() else {
            throw LurosError(.internal, "libarchive: no memory for an entry")
        }
        defer { _ = archive_entry_free(entry) }
        archive_entry_set_pathname_utf8(entry, name)
        archive_entry_set_filetype(entry, numericCast(S_IFREG))
        // An executable keeps its bit — a script in Sources/ is still a script
        // on the other side — and everything else is the reader's own.
        let executable = metadata.st_mode & 0o111 != 0
        archive_entry_set_perm(entry, numericCast(executable ? 0o755 : 0o644))
        archive_entry_set_size(entry, numericCast(data.count))
        archive_entry_set_mtime(entry, Self.modificationTime, 0)
        try step(archive_write_header(archive, entry), archive, "write \(name)")
        if !data.isEmpty {
            try data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                guard archive_write_data(archive, base, bytes.count) == bytes.count else {
                    throw LurosError(.internal, "libarchive: \(name) was not written whole")
                }
            }
        }
        try step(archive_write_finish_entry(archive), archive, "finish \(name)")
    }

    private func step(_ status: Int32, _ archive: OpaquePointer, _ what: String) throws {
        guard status >= ARCHIVE_OK else {
            let reason = archive_error_string(archive).map { String(cString: $0) } ?? "libarchive error \(status)"
            throw LurosError(.internal, "cannot \(what): \(reason)")
        }
    }
}