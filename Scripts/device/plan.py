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
    # Files or folders inside `path` left out (SwiftPM's `exclude`).
    exclude: tuple = ()
    # Explicit sources (SwiftPM's `sources`), globs relative to `path`;
    # empty means every source file under it.
    sources: tuple = ()
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

# --- LurosToolHost --------------------------------------------------
TOOLHOST = "Packages/LurosToolHost/Sources/"

# --- LurosDiagnostics -----------------------------------------------
DIAGNOSTICS = "Packages/LurosDiagnostics/Sources/"

# --- Runestone ------------------------------------------------------
RUNESTONE = "Packages/Runestone/Sources/"

# --- LurosAgent -----------------------------------------------------
AGENT = "Packages/LurosAgent/Sources/"

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
        frameworks=("UIKit",),
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
        deps=("LurosDiagnostics", "LurosCore", "LurosProtocol"),
    ),
    Module(
        "LurosLogReaderWorker",
        DIAGNOSTICS + "LurosLogReaderWorker",
        deps=("LurosCore", "LurosProtocol"),
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
    Module("CIrisinExternalXPC", "Lurosd/Vendor/IrisinExternalClient/CIrisinExternalXPC", kind="c", headers="."),
    Module("IrisinExternalClient", "Lurosd/Vendor/IrisinExternalClient", deps=("CIrisinExternalXPC",)),
    # lurosd: the launchd job and its session host, one executable.
    Module(
        "Lurosd",
        "Lurosd",
        deps=("LurosCore", "LurosProtocol", "LurosToolHost", "IrisinExternalClient"),
        exclude=("Vendor",),
        frameworks=("XPC", "UserNotifications"),
    ),
    # Packages the repository does not carry. Named so a dependency on
    # one is a clear "not vendored yet" rather than a missing module.
    Module("GitKit", "Vendor/packages/libgit2", external=True),
    Module("ArchiveKit", "Vendor/packages/libarchive", external=True),
    Module("IcliKit", "Vendor/packages/icli", external=True),
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
        frameworks=("Foundation", "XPC", "UserNotifications"),
        entitlements="Packaging/Lurosd.entitlements",
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
