import LurosProtocol
import Foundation

/// The programs that building, installing and talking to this device may
/// need, and whether this device has each: the program must be an executable
/// in `usr/bin`, and the package that carries it installed, for the row to say
/// so.
///
/// App registration is the bundled icli's work; `python3` is one of the interpreters a conversation's `run_code`
/// and a project's external build script may name; `dpkg-deb` is no longer
/// Luros's own — its builds write their package and its installer unpacks one
/// without it — but a project's build script may make its package with it.
///
/// Reading only. Installing one is the user's package manager's — the app
/// opens it at the package's page — so nothing here fetches, resolves or
/// installs anything.
enum DevelopmentToolStatus {
    /// The row's name, the program that proves it, and where it lives.
    static let definitions: [(package: String, program: String)] = [
        ("ldid", "ldid"),
        ("git", "git"),
        ("python3", "python3"),
        ("dpkg-deb", "dpkg-deb"),
    ]

    static func rows(installRoot: String) -> [DevelopmentToolRow] {
        let status = installedPackages(installRoot: installRoot)
        let root = installRoot == "/" ? "" : installRoot
        return definitions.map { definition in
            let path = root + "/usr/bin/" + definition.program
            let present = FileManager.default.isExecutableFile(atPath: path)
            return DevelopmentToolRow(
                packageID: definition.package,
                program: definition.program,
                path: present ? path : nil,
                version: present ? status[definition.package] : nil,
            )
        }
    }

    /// The installed version of each package, as dpkg's status file has it.
    private static func installedPackages(installRoot: String) -> [String: String] {
        let root = installRoot == "/" ? "" : installRoot
        guard let text = try? String(contentsOfFile: root + "/var/lib/dpkg/status", encoding: .utf8) else {
            return [:]
        }
        var versions: [String: String] = [:]
        for stanza in text.components(separatedBy: "\n\n") {
            var name: String?
            var version: String?
            var installed = false
            for line in stanza.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = String(line[line.startIndex ..< colon])
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                switch key {
                case "Package": name = value
                case "Version": version = value
                case "Status": installed = value.hasSuffix(" installed")
                default: break
                }
            }
            if let name, installed, let version { versions[name] = version }
        }
        return versions
    }
}
