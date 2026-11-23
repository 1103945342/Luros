import LurosCore
@testable import LurosGit
import Foundation
import XCTest

/// The pattern a long press on an untracked file appends: a leading slash
/// anchors it to the work tree's root, which is Git's own rule, so it is a
/// pattern and not a filesystem path to refuse.
final class GitIgnoreTests: XCTestCase {
    private func repository() throws -> GitRepository {
        let base = URL(fileURLWithPath: CanonicalPath.resolve(NSTemporaryDirectory())!, isDirectory: true)
        let url = base.appendingPathComponent("luros-ignore-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return try GitRepository.create(at: url)
    }

    private func gitignore(_ repository: GitRepository) -> String {
        FileManager.default.contents(atPath: repository.workdir.appendingPathComponent(".gitignore").path)
            .map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    func testAnAnchoredPathIsAppended() throws {
        let repository = try repository()
        XCTAssertTrue(try repository.appendIgnore("/Builds/Device/"))
        XCTAssertEqual(gitignore(repository), "/Builds/Device/\n")
    }

    func testTheSameLineIsNotAddedTwice() throws {
        let repository = try repository()
        XCTAssertTrue(try repository.appendIgnore("/Builds/Device/"))
        XCTAssertFalse(try repository.appendIgnore("/Builds/Device/"))
        XCTAssertEqual(gitignore(repository), "/Builds/Device/\n")
    }

    func testANewlineIsRefused() throws {
        let repository = try repository()
        XCTAssertThrowsError(try repository.appendIgnore("Builds\nDevice"))
        XCTAssertEqual(gitignore(repository), "")
    }
}
