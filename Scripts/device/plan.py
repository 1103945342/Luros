"""What the device build compiles, in one place.

The Mac builds this project with Xcode, from Luros.xcodeproj. The
device has neither xcodebuild nor SwiftPM, so this table plays the
part their target descriptions played: each entry is one Swift module
or C target, with its sources and the modules it imports. The
dependency graph is the manifests' — keep it in step with
Packages/*/Package.swift when a target gains a dependency.

Modules provided by a package the repository does not carry (kwwk,
swift-nio, libgit2, libarchive, icli, capstone, keystone, GhosttyKit,
SnapKit, …) are marked `external`; the driver skips them until they
are vendored under Vendor/packages/ and the entry names their folder.
"""

from dataclasses import dataclass, field


@dataclass(frozen=True)
class Module:
    """One Swift module or C target."""

    name: str
    # Folder holding the sources, relative to the project root.
    path: str
    kind: str = "swift"  # "swift" or "c"
    # Module names this one imports, compiled before it.
    deps: tuple = ()
    # For "c": the public headers folder, relative to `path` (the
    # SwiftPM publicHeadersPath). A module map is written for it.
    headers: str = "include"
    # For "c": private header folders, relative to `path` (SwiftPM's
    # headerSearchPath).
    header_search: tuple = ()
    # For a C module that is a framework: its module map and its static
    # library, relative to `path`. A binary xcframework slice publishes
    # both, and the module is imported like any other.
    module_map: str = ""
    library: str = ""
    # Extra arguments for the linker of a product that includes this
    # module (a system library its code calls).
    link_flags: tuple = ()
    # Files or folders inside `path` left out (SwiftPM's `exclude`).
    exclude: tuple = ()
    # Explicit sources (SwiftPM's `sources`), globs relative to `path`;
    # empty means every source file under it.
    sources: tuple = ()
    # Files outside `path` the target also compiles: the xcodeproj puts
    # Shared/Protocol's files in several targets, which no package
    # manifest can express.
    extra: tuple = ()
    # True for the module that holds a target's main.swift: it is
    # compiled as a program, and every other module as a library.
    entry: bool = False
    # Frameworks the linker needs for this module's code.
    frameworks: tuple = ()
    # Extra compiler flags, per language.
    cflags: tuple = ()
    swiftflags: tuple = ()
    # Resources the module's Bundle.module carries (folder names).
    resources: tuple = ()
    # The SwiftPM package the target belongs to, which names its
    # resource bundle ("<package>_<target>.bundle"), as SwiftPM does.
    package: str = ""
    # Set when the sources live in a package the repository does not
    # carry yet. The driver refuses to build a module that depends on
    # one it has not built.
    external: bool = False


# --- LurosKit -------------------------------------------------------
KIT = "Packages/LurosKit/Sources/"

# --- LurosFormats ---------------------------------------------------
FORMATS = "Packages/LurosFormats/Sources/"

# --- LurosToolchain -------------------------------------------------
TOOLCHAIN = "Packages/LurosToolchain/Sources/"

IRISIN = "Packages/IrisinKit/Sources/"

# --- LurosToolHost --------------------------------------------------
TOOLHOST = "Packages/LurosToolHost/Sources/"

# --- LurosDiagnostics -----------------------------------------------
DIAGNOSTICS = "Packages/LurosDiagnostics/Sources/"

# --- Runestone ------------------------------------------------------
RUNESTONE = "Packages/Runestone/Sources/"

# --- LurosAgent -----------------------------------------------------
AGENT = "Packages/LurosAgent/Sources/"

# --- vendored packages ----------------------------------------------
# The device slice of a binary xcframework: one folder holding a static
# framework for both arm64 and arm64e.
GIT2_SLICE = (
    "Vendor/packages/libgit2.xcframework/BinaryTarget/libgit2.xcframework/"
    "ios-arm64_arm64e/libgit2.framework"
)
GHOSTTY_SLICE = (
    "Vendor/packages/libghostty-spm/BinaryTarget/GhosttyKit.xcframework/ios-arm64"
)
ARCHIVE_SLICE = (
    "Vendor/packages/libarchive.xcframework/BinaryTarget/libarchive.xcframework/"
    "ios-arm64_arm64e/libarchive.framework"
)

_CXX_GRAMMARS = {
    "TreeSitterBash",
    "TreeSitterCPP",
    "TreeSitterPython",
    "TreeSitterRuby",
    "TreeSitterYAML",
}

_GRAMMARS = (
    "TreeSitterBash",
    "TreeSitterC",
    "TreeSitterCPP",
    "TreeSitterJSON",
    "TreeSitterMake",
    "TreeSitterMarkdown",
    "TreeSitterMarkdownInline",
    "TreeSitterObjC",
    "TreeSitterPython",
    "TreeSitterRuby",
    "TreeSitterSwift",
    "TreeSitterXML",
    "TreeSitterYAML",
)

MODULES = [
    # LurosKit: the system-only core, then the products built on it.
    Module("LurosCore", KIT + "LurosCore"),
    Module("LurosProtocol", KIT + "LurosProtocol", deps=("LurosCore",)),
    Module("LurosProject", KIT + "LurosProject", deps=("LurosCore", "LurosProtocol")),
    Module("LurosConsole", KIT + "LurosConsole", deps=("LurosCore", "LurosProtocol")),
    Module(
        "LurosReplay",
        KIT + "LurosReplay",
        deps=("LurosCore", "LurosProtocol"),
        resources=("Fixtures",),
        package="LurosKit",
    ),
    Module("LurosGitOptions", KIT + "LurosGitOptions", kind="c", cflags=("-I.",)),
    Module(
        "LurosGit",
        KIT + "LurosGit",
        deps=("LurosCore", "LurosGitOptions", "GitKit"),
        frameworks=("Foundation",),
    ),
    Module("LurosMachO", FORMATS + "LurosMachO"),
    Module("LurosDebian", FORMATS + "LurosDebian"),
    Module("LurosCodeSign", FORMATS + "LurosCodeSign", frameworks=("Foundation", "Security")),
    Module("LurosDebArchive", FORMATS + "LurosDebArchive", deps=("ArchiveKit",)),
    Module("CToolchainSystem", TOOLCHAIN + "CToolchainSystem", kind="c"),
    Module(
        "LurosToolchain",
        TOOLCHAIN + "LurosToolchain",
        deps=("CToolchainSystem", "LurosCodeSign"),
        frameworks=("Foundation",),
    ),
    Module(
        "LurosBuild",
        KIT + "LurosBuild",
        deps=(
            "LurosCore",
            "LurosProtocol",
            "LurosProject",
            "LurosMachO",
            "LurosCodeSign",
            "LurosDebian",
            "LurosDebArchive",
        ),
    ),
    Module(
        "LurosEnvironment",
        KIT + "LurosEnvironment",
        deps=(
            "LurosCore",
            "LurosProtocol",
            "LurosGit",
            "LurosProject",
            "ArchiveKit",
            "LurosMachO",
            "LurosDebian",
            "LurosDebArchive",
            "LurosToolchain",
        ),
    ),
    # LurosToolHost: the agent-tool protocol, system only.
    Module("LurosToolCore", TOOLHOST + "LurosToolCore"),
    Module("LurosToolHost", TOOLHOST + "LurosToolHost", deps=("LurosToolCore",)),
    Module("LurosToolExtension", TOOLHOST + "LurosToolExtension", deps=("LurosToolCore",)),
    # LurosDiagnostics: crash reports, the log reader, the loaded check.
    Module("LurosDiagnosticsCore", DIAGNOSTICS + "LurosDiagnosticsCore"),
    Module(
        "LurosDiagnostics",
        DIAGNOSTICS + "LurosDiagnostics",
        deps=("LurosDiagnosticsCore", "IcliKit"),
        frameworks=("UIKit", "IOKit"),
        link_flags=("-lxpc",),
    ),
    Module(
        "LurosLogReaderSPI",
        DIAGNOSTICS + "LurosLogReaderSPI",
        kind="c",
        frameworks=("Foundation",),
    ),
    Module("LurosLogReader", DIAGNOSTICS + "LurosLogReader", deps=("LurosDiagnosticsCore", "LurosLogReaderSPI")),
    Module("LurosCrashReport", DIAGNOSTICS + "LurosCrashReport"),
    Module("LurosCrashSymbols", DIAGNOSTICS + "LurosCrashSymbols", deps=("LurosCrashReport",)),
    Module("LurosCrashBlame", DIAGNOSTICS + "LurosCrashBlame", deps=("LurosCrashReport",)),
    Module("ConfirmLoaded", DIAGNOSTICS + "ConfirmLoaded", deps=("LurosDiagnosticsCore",)),
    Module(
        "LurosDiagnosticsWorker",
        DIAGNOSTICS + "LurosDiagnosticsWorker",
        deps=(
            "LurosDiagnostics",
            "LurosCore",
            "LurosProtocol",
            "LurosLogReaderWorker",
            "LurosCrashReport",
            "LurosCrashSymbols",
            "LurosCrashBlame",
            "ConfirmLoaded",
        ),
    ),
    Module(
        "LurosLogReaderWorker",
        DIAGNOSTICS + "LurosLogReaderWorker",
        deps=("LurosCore", "LurosProtocol", "LurosLogReader", "ConfirmLoaded"),
    ),
    # Runestone: the Tree-sitter runtime, the grammars, the text view.
    # lib.c includes every other runtime source; compiling them again
    # would define each symbol twice (Package.swift's `sources`).
    Module("TreeSitter", RUNESTONE + "TreeSitter", kind="c", sources=("src/lib.c",)),
] + [
    Module(
        name,
        RUNESTONE + name,
        kind="c",
        deps=("TreeSitter",),
        header_search=("src",),
        exclude=("src/schema.generated.cc",) if name == "TreeSitterYAML" else (),
    )
    for name in _GRAMMARS
] + [
    Module(
        "Runestone",
        RUNESTONE + "Runestone",
        deps=("TreeSitter",),
        frameworks=("UIKit",),
        resources=("PrivacyInfo.xcprivacy", "Theme.xcassets"),
        package="Runestone",
    ),
    Module(
        "RunestoneLanguageSupport",
        RUNESTONE + "RunestoneLanguageSupport",
        deps=("Runestone", "TreeSitter") + _GRAMMARS,
    ),
    Module("RunestoneThemeSupport", RUNESTONE + "RunestoneThemeSupport", deps=("Runestone",)),
    # The macros the project reads through C instead of Swift (the SDK's
    # XPC overlay would make libswiftXPC a required load, and iOS 15 has
    # no such library).
    Module(
        "CAppXPC",
        "Shared/XPCShim",
        kind="c",
        headers=".",
        module_map="module.modulemap",
    ),
    # The device's XPC: Luros's declarations for the C API, and a shadow
    # of the standard library's overlay named XPC so `import XPC` in the
    # project's sources means the same thing here (Vendor/compat/XPC).
    Module(
        "LurosXPC",
        "Vendor/include",
        kind="c",
        headers=".",
        module_map="module.modulemap",
    ),
    Module(
        "XPC",
        "Vendor/compat/XPC",
        deps=("LurosXPC",),
        frameworks=("Foundation",),
        link_flags=("-lxpc",),
    ),
    Module("CIrisinSpawn", IRISIN + "CIrisinSpawn", kind="c", headers="."),
    Module("CIrisinDB", IRISIN + "CIrisinDB", kind="c", headers="."),
    Module("IrisinProtocol", IRISIN + "IrisinProtocol", deps=("CIrisinSpawn",)),
    Module(
        "IrisinPreparation",
        IRISIN + "IrisinPreparation",
        deps=("IrisinProtocol", "ArchiveKit"),
    ),
    Module(
        "IrisinInstaller",
        IRISIN + "IrisinInstaller",
        deps=("CIrisinDB", "IrisinProtocol", "IrisinPreparation"),
    ),
    # The app itself.
    Module(
        "Luros",
        "Luros",
        entry=True,
        deps=(
            "LurosCore", "LurosProtocol", "LurosConsole", "LurosProject", "LurosBuild",
            "LurosDiagnostics", "LurosToolHost", "IrisinInstaller", "IcliKit",
            "Runestone", "RunestoneLanguageSupport",
            "GhosttyTerminal", "GhosttyTheme",
            "AlertController", "Dog", "ListViewKit", "Litext", "LitextAnimation",
            "MarkdownView", "SPIndicator", "ScrubberKit", "SnapKit", "Then",
            "CAppXPC", "XPC",
        ),
        extra=(
            "Shared/Protocol/AppProtocol.swift",
            "Shared/Protocol/AppXPC.swift",
            "Shared/Protocol/XPCEnvelope.swift",
            "Shared/RoothideRoot.swift",
            "Widgets/Shared/LurosLink.swift",
            "Widgets/Shared/ChatWidgetSnapshot.swift",
            "Widgets/Shared/ChatActivityAttributes.swift",
        ),
        frameworks=(
            "UIKit", "SwiftUI", "WidgetKit", "QuickLook", "QuickLookThumbnailing",
            "PhotosUI", "PDFKit", "Metal", "ImageIO", "AuthenticationServices",
            "LocalAuthentication", "UserNotifications",
        ),
        # Frameworks newer than the deployment target must be weak, or
        # dyld refuses to launch the app on a system without them: iOS
        # 17.3 has no Translation.framework, and ActivityKit is 16.1.
        link_flags=(
            "-Xlinker", "-weak_framework", "-Xlinker", "ActivityKit",
            "-Xlinker", "-weak_framework", "-Xlinker", "Translation",
            "-lswiftUIKit", "-lswiftWebKit", "-lswiftCoreMedia",
        ),
    ),

    # The workers: one executable each, a thin main over a worker module.
    Module("luros-build", "Workers/Build", deps=("LurosBuild", "LurosProtocol"), entry=True),
    Module(
        "luros-environment",
        "Workers/Environment",
        deps=("LurosEnvironment", "LurosProtocol"),
        entry=True,
    ),
    Module(
        "luros-diagnostics",
        "Workers/Diagnostics",
        deps=("LurosDiagnosticsWorker", "LurosProtocol"),
        entry=True,
    ),
    Module(
        "luros-log-reader",
        "Workers/LogReader",
        deps=("LurosLogReaderWorker", "LurosProtocol"),
        entry=True,
    ),
    # lurosd: the launchd job and its session host, one executable.
    Module(
        "Lurosd",
        "Lurosd",
        deps=("LurosCore", "LurosProtocol", "LurosToolHost", "XPC", "CAppXPC", "IrisinInstaller"),
        exclude=("Vendor",),
        extra=("Shared/Protocol/AppProtocol.swift", "Shared/Protocol/AppXPC.swift", "Shared/Protocol/XPCEnvelope.swift", "Shared/RoothideRoot.swift"),
        entry=True,
        frameworks=("UserNotifications",),
    ),
    # cmark-gfm, the C parser MarkdownView reads markdown with.
    Module("cmark_gfm", "Vendor/packages/swift-cmark/src", kind="c"),
    Module(
        "cmark_gfm_extensions",
        "Vendor/packages/swift-cmark/extensions",
        kind="c",
        deps=("cmark_gfm",),
        # The target keeps its public header in include and its private
        # ones beside the sources, which SwiftPM's headerSearchPath also
        # gives it.
        headers="include",
        header_search=(".", "../src/include"),
    ),
    Module(
        "MarkdownParser",
        "Vendor/packages/markdownview/Sources/MarkdownParser",
        deps=("cmark_gfm", "cmark_gfm_extensions"),
    ),
    Module(
        "MarkdownView",
        "Vendor/packages/markdownview/Sources/MarkdownView",
        deps=(
            "Litext", "LitextAnimation", "MarkdownParser", "SwiftMath", "LRUCache",
            "DequeModule", "OrderedCollections",
        ),
        frameworks=("UIKit",),
        resources=("Resources",),
        package="MarkdownView",
    ),

    # Ghostty's terminal: the C runtime, and the Swift layer Luros calls.
    Module(
        "libghostty",
        GHOSTTY_SLICE,
        kind="c",
        headers="Headers",
        module_map="Headers/libghostty/module.modulemap",
        library="libghostty.a",
    ),
    Module("GhosttyKit", "Vendor/packages/libghostty-spm/Sources/GhosttyKit", deps=("libghostty",)),
    Module(
        "GhosttyTerminal",
        "Vendor/packages/libghostty-spm/Sources/GhosttyTerminal",
        deps=("GhosttyKit", "DisplayLink"),
        frameworks=("UIKit", "Metal", "QuartzCore"),
        resources=("Resources/Ghostty", "Resources/terminfo", "Resources/Localization"),
        package="libghostty",
        link_flags=("-lc++",),
    ),
    Module(
        "GhosttyTheme",
        "Vendor/packages/libghostty-spm/Sources/GhosttyTheme",
        deps=("GhosttyTerminal",),
    ),

    # The app's UI libraries, vendored at the pins.
    Module("Then", "Vendor/packages/then/Sources/Then"),
    Module("SnapKit", "Vendor/packages/snapkit/Sources", frameworks=("UIKit",)),
    Module("Dog", "Vendor/packages/dog/Sources/Dog"),
    Module(
        "DisplayLink",
        "Vendor/packages/displaylink/Sources/DisplayLink",
        frameworks=("UIKit", "QuartzCore"),
    ),
    Module(
        "Litext",
        "Vendor/packages/litext/Sources/Litext",
        deps=("DisplayLink",),
        frameworks=("UIKit",),
        resources=("Resources",),
        package="Litext",
    ),
    Module(
        "LitextAnimation",
        "Vendor/packages/litext/Sources/LitextAnimation",
        deps=("Litext",),
        frameworks=("UIKit",),
    ),
    Module(
        "SwiftMath",
        "Vendor/packages/swiftmath/Sources/SwiftMath",
        frameworks=("UIKit",),
        resources=("mathFonts.bundle",),
        package="SwiftMath",
    ),
    Module("LRUCache", "Vendor/packages/lrucache/Sources"),
    Module("InternalCollectionsUtilities", "Vendor/packages/swift-collections/Sources/InternalCollectionsUtilities"),
    Module(
        "DequeModule",
        "Vendor/packages/swift-collections/Sources/DequeModule",
        deps=("InternalCollectionsUtilities",),
    ),
    Module(
        "OrderedCollections",
        "Vendor/packages/swift-collections/Sources/OrderedCollections",
        deps=("InternalCollectionsUtilities",),
    ),
    Module("SwiftSoup", "Vendor/packages/swiftsoup/Sources"),
    Module(
        "ScrubberKit",
        "Vendor/packages/scrubberkit/Sources/ScrubberKit",
        deps=("SwiftSoup",),
        frameworks=("UIKit",),
        resources=("Resources",),
        package="ScrubberKit",
    ),
    Module(
        "ListViewKit",
        "Vendor/packages/listviewkit/Sources",
        deps=("DisplayLink",),
        frameworks=("UIKit", "QuartzCore"),
    ),
    Module(
        "SPIndicator",
        "Vendor/packages/spindicator/Sources/SPIndicator",
        frameworks=("UIKit",),
    ),
    Module(
        "AlertController",
        "Vendor/packages/alertcontroller/Sources/AlertController",
        frameworks=("UIKit",),
        resources=("Resources",),
        package="AlertController",
    ),
    Module(
        "SwifterSwift",
        "Vendor/packages/swifterswift/Sources/SwifterSwift",
        frameworks=("UIKit",),
    ),

    # Packages the repository does not carry. Named so a dependency on
    # one is a clear "not vendored yet" rather than a missing module.
    Module(
        "libgit2",
        GIT2_SLICE,
        kind="c",
        headers="Headers",
        module_map="Modules/module.modulemap",
        library="libgit2",
        link_flags=("-lz", "-liconv"),
    ),
    Module("GitKit", "Vendor/packages/libgit2.xcframework/Sources/GitKit", deps=("libgit2",)),
    Module(
        "libarchive",
        ARCHIVE_SLICE,
        kind="c",
        headers="Headers",
        module_map="Modules/module.modulemap",
        library="libarchive",
        # The libraries libarchive calls that the SDK ships (its own
        # Package.swift names the same four).
        link_flags=("-lz", "-lbz2", "-liconv", "-lxml2"),
    ),
    Module(
        "ArchiveKit",
        "Vendor/packages/libarchive.xcframework/Sources/ArchiveKit",
        deps=("libarchive",),
    ),
    Module("IcliKit", "Vendor/packages/icli/Sources/IcliKit", deps=(
        "IcliPrivate", "IcliSystem", "IcliLaunch", "IcliProbe",
    ), frameworks=("Foundation", "UIKit")),
    Module("IcliSystem", "Vendor/packages/icli/Sources/IcliSystem", deps=("IcliSystemPrivate",)),
    Module(
        "IcliSystemPrivate",
        "Vendor/packages/icli/Sources/IcliSystemPrivate",
        kind="c",
        frameworks=("Foundation", "CoreFoundation"),
    ),
    Module("IcliLaunch", "Vendor/packages/icli/Sources/IcliLaunch", deps=(
        "IcliLaunchPrivate", "IcliSystem",
    )),
    Module(
        "IcliLaunchPrivate",
        "Vendor/packages/icli/Sources/IcliLaunchPrivate",
        kind="c",
        deps=("IcliSystemPrivate",),
        frameworks=("Foundation", "CoreFoundation"),
    ),
    Module(
        "IcliPrivate",
        "Vendor/packages/icli/Sources/IcliPrivate",
        kind="c",
        deps=("IcliSystemPrivate", "IcliLaunchPrivate", "ArchiveKit"),
        frameworks=("Foundation", "CoreFoundation", "UIKit"),
    ),
    Module(
        "IcliProbe",
        "Vendor/packages/icli/Sources/IcliProbe",
        kind="c",
        frameworks=("Foundation", "JavaScriptCore"),
    ),
    Module("KWWKAI", "Vendor/packages/kwwk", external=True),
    Module("KWWKAgent", "Vendor/packages/kwwk", external=True),
    Module("KWWKMCP", "Vendor/packages/kwwk", external=True),
    Module("NIOCore", "Vendor/packages/swift-nio", external=True),
]

BY_NAME = {module.name: module for module in MODULES}


# --- products -------------------------------------------------------


@dataclass(frozen=True)
class Product:
    """One executable or app the build links from planned modules."""

    name: str
    modules: tuple
    # Frameworks the linked image needs, on top of the modules' own.
    frameworks: tuple = ()
    # The entitlements ldid signs it with, relative to the project.
    entitlements: str = ""
    # For an app: its Info.plist, and the resources folder to copy in.
    info_plist: str = ""
    resources: str = ""


PRODUCTS = [
    # The launchd job and its session host: one executable, started from
    # <install root>/usr/libexec/lurosd.
    Product(
        "lurosd",
        ("Lurosd",),
        frameworks=("Foundation", "UserNotifications"),
        entitlements="Packaging/Lurosd.entitlements",
    ),
    Product(
        "Luros",
        ("Luros",),
        frameworks=("UIKit", "SwiftUI", "WidgetKit"),
        entitlements="Packaging/Luros.entitlements",
    ),
    Product(
        "luros-build",
        ("luros-build",),
        entitlements="Packaging/Workers/luros-build.entitlements",
    ),
    Product(
        "luros-environment",
        ("luros-environment",),
        entitlements="Packaging/Workers/luros-environment.entitlements",
    ),
    Product(
        "luros-diagnostics",
        ("luros-diagnostics",),
        entitlements="Packaging/Workers/luros-diagnostics.entitlements",
    ),
    Product(
        "luros-log-reader",
        ("luros-log-reader",),
        entitlements="Packaging/Workers/luros-log-reader.entitlements",
    ),
]

PRODUCTS_BY_NAME = {product.name: product for product in PRODUCTS}


def module(name):
    try:
        return BY_NAME[name]
    except KeyError:
        raise SystemExit(f"plan.py names no module {name!r}")


def build_order(names):
    """The named modules, dependencies first, each once."""
    ordered = []
    seen = set()
    visiting = []

    def visit(name):
        if name in seen:
            return
        if name in visiting:
            cycle = visiting[visiting.index(name):] + [name]
            raise SystemExit("dependency cycle: " + " -> ".join(cycle))
        target = module(name)
        visiting.append(name)
        for dependency in target.deps:
            visit(dependency)
        visiting.pop()
        seen.add(name)
        ordered.append(target)

    for name in names:
        visit(name)
    return ordered
