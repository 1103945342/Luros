import Foundation

// The device tools work on this device may need and its package does not
// carry: `ldid` signs, `git` fetches a repository, `python3` runs what a
// project's build script or a conversation's `run_code` hands it, and Frida
// instruments processes. App registration uses the icli carried by Luros.
// Settings ▸ Environment reads their state; a missing one is installed
// from the user's package manager, which the app opens at the package's page.

/// One tool, as the device has it or not.
public struct DevelopmentToolRow: Codable, Sendable, Equatable, Hashable {
    /// The package the tool comes from, which is also what the row is called.
    public var packageID: String
    /// A short name for the row when the package id is not the name.
    public var displayName: String?
    /// The executable's name whose presence means the package is here.
    public var program: String
    /// Where that program is, when the device has it.
    public var path: String?
    /// The installed package's version, when the device has it.
    public var version: String?

    public var present: Bool { path != nil }

    public init(
        packageID: String,
        program: String,
        displayName: String? = nil,
        path: String? = nil,
        version: String? = nil,
    ) {
        self.packageID = packageID
        self.program = program
        self.displayName = displayName
        self.path = path
        self.version = version
    }
}

/// Reads the tools, and nothing else: installing one is the user's
/// package manager's, which the app opens at that package's page.
public struct DevelopmentToolsRequest: OperationRequest {
    public typealias Response = DevelopmentToolsResponse
    public static let operation = AppOperation.developmentTools

    public init() {}
}

public struct DevelopmentToolsResponse: Codable, Sendable, Equatable {
    public var tools: [DevelopmentToolRow]

    public init(tools: [DevelopmentToolRow] = []) {
        self.tools = tools
    }
}

public extension LurosService {
    func developmentTools() async throws -> DevelopmentToolsResponse {
        try await send(DevelopmentToolsRequest())
    }
}
