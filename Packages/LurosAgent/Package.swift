// swift-tools-version: 6.1
// kwwk's manifest declares tools 6.1, so a package that depends on it cannot
// declare less.

import PackageDescription

let package = Package(
    name: "LurosAgent",
    platforms: [
        .iOS(.v16),
        // kwwk declares macOS 14, and SwiftPM refuses a product whose floor
        // is below a dependency's. macOS is only the test host here; the
        // product ships on iOS.
        .macOS(.v14),
    ],
    products: [
        .library(name: "LurosAgent", targets: ["LurosAgent"]),
        // What Workers/Agent/main.swift calls: the session over the worker
        // channel, the host backend and the credential inbox.
        .library(name: "LurosAgentWorker", targets: ["LurosAgentWorker"]),
    ],
    dependencies: [
        // yellowplushq/kwwk v0.1.127 with Antigravity restored: the head of
        // pull request #296, branch `claude/restore-antigravity`, which
        // reverts kwwk's removal (#271) and is not released yet. Pinned by
        // commit, so nothing pushed to the branch changes what is built;
        // pin a kwwk release once one contains it (see #73). Bump
        // deliberately.
        .package(
            url: "https://github.com/yellowplushq/kwwk.git",
            revision: "fdd68f4ac22d63ce4c68a77d3f66af33ded77bfc",
        ),
        // kwwk's swift-nio, held below 2.104.0. That release made
        // ByteToMessageHandler's decoder `~Copyable`, and an iOS runtime
        // before 18 cannot find a conformance that carries such a condition:
        // configureHTTPServerPipeline's handler cast fails and the sign-in
        // loopback aborts luros-agent on iOS 17 when Safari connects. kwwk
        // asks for 2.65.0, swift-nio-ssl for 2.98.0. Raise the ceiling only
        // once NIO's noncopyable conformances work on the deployment floor.
        .package(url: "https://github.com/apple/swift-nio.git", "2.98.0" ..< "2.104.0"),
        // Luros's own wire and worker channel. System code only.
        .package(path: "../LurosKit"),
        // The agent tool extensions' manifests and their validation, read
        // to offer their tools. System code only.
        .package(path: "../LurosToolHost"),
    ],
    targets: [
        .target(
            name: "LurosAgent",
            dependencies: [
                .product(name: "KWWKAgent", package: "kwwk"),
                .product(name: "KWWKMCP", package: "kwwk"),
                .product(name: "KWWKAI", package: "kwwk"),
                // Not imported: it binds the swift-nio ceiling above to
                // every build of luros-agent. kwwk links NIOCore already.
                .product(name: "NIOCore", package: "swift-nio"),
                // RunCodePresetRule: the words of a preset, as the host reads them;
                // TokenEstimate: the output a run receives, as the app counts a reply.
                .product(name: "LurosProtocol", package: "LurosKit"),
                // CanonicalPath: the path rules the rest of Luros decides by.
                .product(name: "LurosCore", package: "LurosKit"),
                // The luros-project.json schema the luros-project-description skill serves.
                .product(name: "LurosProject", package: "LurosKit"),
                // ToolManifestValidator: the installed agent tool extensions
                // whose tools a session offers.
                .product(name: "LurosToolCore", package: "LurosToolHost"),
            ],
            path: "Sources/LurosAgent",
        ),
        // luros-agent's worker: AgentHostBackend over LurosService (the
        // worker channel to the session host), keychain credentials and the
        // console's credential inbox.
        .target(
            name: "LurosAgentWorker",
            dependencies: [
                "LurosAgent",
                .product(name: "KWWKAI", package: "kwwk"),
                .product(name: "LurosCore", package: "LurosKit"),
                .product(name: "LurosProtocol", package: "LurosKit"),
            ],
            path: "Sources/LurosAgentWorker",
            swiftSettings: [.enableUpcomingFeature("ConciseMagicFile")],
        ),
        .testTarget(
            name: "LurosAgentWorkerTests",
            dependencies: [
                "LurosAgentWorker",
                "LurosAgent",
                .product(name: "KWWKAI", package: "kwwk"),
                .product(name: "LurosCore", package: "LurosKit"),
                .product(name: "LurosProtocol", package: "LurosKit"),
            ],
            path: "Tests/LurosAgentWorkerTests",
        ),
        .testTarget(
            name: "LurosAgentTests",
            dependencies: [
                "LurosAgent",
                .product(name: "KWWKAgent", package: "kwwk"),
                .product(name: "KWWKAI", package: "kwwk"),
                .product(name: "LurosToolCore", package: "LurosToolHost"),
            ],
            path: "Tests/LurosAgentTests",
        ),
        // Talks to a real provider. Every test here is skipped unless
        // LUROS_LIVE_OAUTH_PATH names a kwwk-format credential file.
        .testTarget(
            name: "LurosAgentLiveTests",
            dependencies: [
                "LurosAgent",
                .product(name: "KWWKAI", package: "kwwk"),
            ],
            path: "Tests/LurosAgentLiveTests",
        ),
    ],
    swiftLanguageModes: [.v6],
)
