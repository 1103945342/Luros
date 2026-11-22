// swift-tools-version: 5.9
import PackageDescription

/// Irisin's installer, vendored at v5.1.8 — README.md says what was taken,
/// what was left behind and the patches Luros carries.
///
/// `IrisinProtocol` is the job and its transcript, `IrisinPreparation` turns a
/// `.deb` into the prepared tree, and `IrisinInstaller` is the root
/// transaction: dpkg's database and payload, the maintainer scripts and the
/// home screen. The daemon is not here: Luros spawns the installer itself
/// (`lurosd --installer`), so nothing listens on a Mach service.
let package = Package(
    name: "IrisinKit",
    platforms: [.iOS(.v15), .macOS(.v13)],
    products: [
        .library(name: "IrisinProtocol", targets: ["IrisinProtocol"]),
        .library(name: "IrisinPreparation", targets: ["IrisinPreparation"]),
        // Static, as Irisin links it: what a device links of the installer is
        // its own copy, and nothing here is third-party beyond libarchive.
        .library(name: "IrisinInstaller", type: .static, targets: ["IrisinInstaller"]),
    ],
    dependencies: [
        // The libarchive LurosKit and LurosFormats already name (ArchiveKit),
        // here for `IrisinPreparation`: the same package, so the installer
        // gains no second copy.
        .package(url: "https://github.com/Lakr233/libarchive.xcframework.git", from: "1.0.1"),
    ],
    targets: [
        // libSystem's spawn calls, which the SDK headers mark unavailable for
        // one platform or another; see the shim's comment.
        .systemLibrary(name: "CIrisinSpawn", path: "Sources/CIrisinSpawn"),
        // db(3) from `<db.h>`, which the Darwin module leaves out: the hash
        // files a bootstrap keeps its users in.
        .systemLibrary(name: "CIrisinDB", path: "Sources/CIrisinDB"),

        // The job, its events, the install root and the spawn wrappers. No
        // XPC: the daemon's wire is not in this copy.
        .target(name: "IrisinProtocol", dependencies: ["CIrisinSpawn"]),

        // A `.deb` into the prepared tree the transaction installs from.
        .target(
            name: "IrisinPreparation",
            dependencies: [
                "IrisinProtocol",
                .product(name: "ArchiveKit", package: "libarchive.xcframework"),
            ]
        ),

        // What the installer does as root: the dpkg transaction and the
        // maintenance actions, each with a fixed argv composed here.
        .target(
            name: "IrisinInstaller",
            dependencies: ["CIrisinDB", "IrisinProtocol", "IrisinPreparation"]
        ),

        .testTarget(name: "IrisinProtocolTests", dependencies: ["IrisinProtocol"]),
        .testTarget(
            name: "IrisinInstallerTests",
            dependencies: ["CIrisinDB", "IrisinInstaller", "IrisinPreparation"]
        ),
    ]
)
