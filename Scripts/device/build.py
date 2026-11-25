#!/usr/bin/env python3
"""Build this project on the device, without Xcode or SwiftPM.

    python3 Scripts/device/build.py --list
    python3 Scripts/device/build.py --modules LurosCore LurosProtocol
    python3 Scripts/device/build.py --all
    python3 Scripts/device/build.py --clean

Every module is compiled whole (one swiftc invocation for its module
and one object), into Builds/Device/. A module whose staged sources
and flags have not changed since its last successful compile is
skipped, so a fix in one module does not rebuild the rest.

The sources are staged first (Scripts/device/stage.py), because the
repository is written for Swift 6 and this toolchain's compiler is
5.10. See that file for what is rewritten and why.

Run it through luros_project_build (luros/build.sh does); a bare
shell_run sets none of the variables a build needs.
"""

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)

import plan  # noqa: E402
import stage  # noqa: E402

BUILD = os.path.join(ROOT, "Builds", "Device")
STAGED = os.path.join(BUILD, "staged")
MODULES_DIR = os.path.join(BUILD, "modules")
OBJECTS = os.path.join(BUILD, "objects")
HEADERS = os.path.join(BUILD, "include")
STATE = os.path.join(BUILD, "state.json")

DEPLOYMENT_TARGET = os.environ.get("IPHONEOS_DEPLOYMENT_TARGET", "16.0")


class BuildError(Exception):
    pass


def log(message):
    print(message, flush=True)


def sdk_path():
    sdk = os.environ.get("SDKROOT")
    if not sdk:
        raise SystemExit("SDKROOT is not set: run this through luros_project_build")
    return sdk


def architecture():
    """The slice to compile: arm64, the one the shipped binaries use.

    LUROS_ARCHITECTURE names the *package's* Architecture, which is
    iphoneos-arm64e on roothide; the binaries inside it are arm64 — that
    is what the installed package holds, and what the only build of
    GhosttyKit offers. An arm64e output cannot link an arm64 library, and
    an arm64 binary runs on the same devices, so the build makes arm64
    and says so.
    """
    return os.environ.get("LUROS_BINARY_ARCH", "arm64")


def configuration():
    return os.environ.get("LUROS_CONFIGURATION", "debug")


def toolchain_bin():
    """The toolchain's own bin, so swiftc and clang are the same pair.

    shell_run puts the toolchain first on PATH; a build script gets the
    same. Keep the name, not a resolved path: roothide's prefixes move.
    """
    return os.environ.get("LUROS_TOOLCHAIN_BIN", "")


def relative(path):
    """A path the compiler can open: its cwd is the project root.

    On roothide the toolchain's drivers are vroot-linked — their `/` is
    the jbroot — so an absolute path built from the project's real path
    is looked for under /rootfs and never found. Every path handed to
    swiftc or clang is relative to the project root instead; the SDK is
    the exception, which both drivers read by name.
    """
    return os.path.relpath(path, ROOT)


def tool(name):
    path = shutil.which(name)
    if not path:
        raise BuildError(f"{name} is not on PATH; the toolchain is not prepared")
    return path


def run(command, cwd=ROOT, capture=False):
    started = time.monotonic()
    result = subprocess.run(
        command,
        cwd=cwd,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.STDOUT if capture else None,
        text=True,
    )
    elapsed = time.monotonic() - started
    output = result.stdout or ""
    if result.returncode != 0 and capture:
        sys.stdout.write(output)
    return result.returncode, output, elapsed


# --- sources ---------------------------------------------------------


def module_sources(target):
    """Every source file of a module, as paths relative to the project."""
    root = os.path.join(ROOT, target.path)
    if not os.path.isdir(root):
        raise BuildError(f"{target.name}: no source folder at {target.path}")
    import glob as globbing

    suffixes = (".swift",) if target.kind == "swift" else (".c", ".cc", ".cpp", ".m", ".mm")
    if target.sources:
        found = []
        for pattern in target.sources:
            for path in sorted(globbing.glob(os.path.join(root, pattern))):
                found.append(os.path.relpath(os.path.normpath(path), ROOT))
        if not found:
            raise BuildError(f"{target.name}: no file matches {target.sources}")
        return found
    excluded = {os.path.normpath(os.path.join(root, entry)) for entry in target.exclude}
    found = []
    for directory, folders, files in os.walk(root):
        folders[:] = sorted(
            folder for folder in folders
            if os.path.normpath(os.path.join(directory, folder)) not in excluded
            and folder != target.headers
        )
        for name in sorted(files):
            path = os.path.normpath(os.path.join(directory, name))
            if not name.endswith(suffixes) or path in excluded:
                continue
            found.append(os.path.relpath(path, ROOT))
    for relative in target.extra:
        found.append(relative)
    if not found and target.kind == "swift":
        raise BuildError(f"{target.name}: {target.path} holds no swift sources")
    # A C target may publish only headers and a module map: it is
    # imported, and nothing of it is compiled.
    return found


def staged_root(target):
    return os.path.join(STAGED, target.name)


def stage_module(target, sources):
    """Copy the module's source folder to staging, rewritten.

    The whole folder is copied, not only the files that are compiled:
    a C file may `#include` a sibling that is not a unit of its own
    (Tree-sitter's lib.c includes every other runtime source). The
    compiled files are returned, in the order `sources` gave them.
    """
    destination = staged_root(target)
    if os.path.isdir(destination):
        shutil.rmtree(destination)
    root = os.path.join(ROOT, target.path)
    excluded = {
        os.path.normpath(os.path.join(root, entry)) for entry in target.exclude
    }
    for directory, folders, files in os.walk(root):
        folders[:] = sorted(
            folder for folder in folders
            if os.path.normpath(os.path.join(directory, folder)) not in excluded
        )
        for name in sorted(files):
            source = os.path.normpath(os.path.join(directory, name))
            if source in excluded:
                continue
            relative_path = os.path.relpath(source, root)
            target_path = os.path.join(destination, relative_path)
            os.makedirs(os.path.dirname(target_path), exist_ok=True)
            if name.endswith(".swift"):
                with open(source, encoding="utf-8") as handle:
                    text = handle.read()
                rewritten = stage.stage_text(text)
                with open(target_path, "w", encoding="utf-8") as handle:
                    handle.write(rewritten)
            else:
                shutil.copyfile(source, target_path)
    staged = []
    for relative in sources:
        source = os.path.normpath(os.path.join(ROOT, relative))
        if os.path.commonpath([source, root]) != root:
            # A file from outside the target's folder (Shared/Protocol):
            # staged under its own name, so two targets never share it.
            staged_path = os.path.join(destination, os.path.basename(source))
            with open(source, encoding="utf-8") as handle:
                text = handle.read()
            with open(staged_path, "w", encoding="utf-8") as handle:
                handle.write(stage.stage_text(text) if target.kind == "swift" else text)
        else:
            staged_path = os.path.join(destination, os.path.relpath(source, root))
            if not os.path.exists(staged_path):
                raise BuildError(f"{target.name}: {relative} was not staged")
        staged.append(staged_path)
    accessor = write_accessor(target)
    if accessor:
        staged.append(accessor)
    return staged


ACCESSOR = """// Generated by Scripts/device/build.py, as SwiftPM generates it: the
// module's own resource bundle, found beside the running binary.
import Foundation

extension Foundation.Bundle {
    static let module: Bundle = {
        let name = "@BUNDLE@"
        let roots = [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL,
            Bundle(for: BundleFinder.self).resourceURL,
        ]
        for root in roots {
            if let root, let bundle = Bundle(url: root.appendingPathComponent(name)) {
                return bundle
            }
        }
        return Bundle.main
    }()
}

private final class BundleFinder {}
"""


def write_accessor(target):
    """SwiftPM's `Bundle.module` accessor, for a target with resources."""
    if not target.resources:
        return None
    name = f"{target.package}_{target.name}.bundle"
    path = os.path.join(staged_root(target), "resource_bundle_accessor.swift")
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(ACCESSOR.replace("@BUNDLE@", name))
    return path


def digest_of(target, staged, flags):
    hasher = hashlib.sha256()
    hasher.update(target.name.encode())
    hasher.update(target.kind.encode())
    for path in staged:
        hasher.update(os.path.basename(path).encode())
        with open(path, "rb") as handle:
            hasher.update(hashlib.sha256(handle.read()).digest())
    for flag in flags:
        hasher.update(flag.encode())
    return hasher.hexdigest()


# --- module maps -----------------------------------------------------


def write_module_map(target):
    """A module map for a C target, as SwiftPM writes one.

    `import CToolchainSystem` finds the header the target publishes
    under its publicHeadersPath; an umbrella folder covers the target
    that publishes more than one.
    """
    headers = os.path.join(ROOT, target.path, target.headers)
    if not os.path.isdir(headers):
        raise BuildError(f"{target.name}: no public headers at {target.path}/{target.headers}")
    # A binary framework publishes its map beside its modules, and a
    # source target may carry its own (TreeSitter does); keep it.
    if target.module_map:
        own = os.path.join(ROOT, target.path, target.module_map)
        if not os.path.exists(own):
            raise BuildError(f"{target.name}: no module map at {target.path}/{target.module_map}")
        if not target.library:
            return own
        # Only a `framework module` makes the linker auto-link a
        # framework; a plain module map is used exactly as it is.
        with open(own, encoding="utf-8") as handle:
            if "framework module" not in handle.read():
                return own
        # A binary framework's own map is a `framework module`, and the
        # linker then auto-links `-framework <name>`, which no device
        # has. Its headers are plain files here, and the library is
        # handed to the linker by path, so the map is written again
        # without the framework.
        local = os.path.join(HEADERS, target.name)
        os.makedirs(local, exist_ok=True)
        for name in os.listdir(headers):
            link = os.path.join(local, name)
            if not os.path.exists(link):
                os.symlink(os.path.join(headers, name), link)
        module_map = os.path.join(local, "module.modulemap")
        with open(module_map, "w", encoding="utf-8") as handle:
            handle.write(
                "module " + target.name + " {\n"
                '    umbrella "."\n'
                "    export *\n"
                "}\n"
            )
        return module_map
    own = os.path.join(headers, "module.modulemap")
    if os.path.exists(own):
        return own
    module_map = os.path.join(HEADERS, target.name, "module.modulemap")
    os.makedirs(os.path.dirname(module_map), exist_ok=True)
    # Relative, because the module map is read by the vrooted clang: an
    # absolute path under the jbroot would be looked for under /rootfs.
    umbrella = os.path.relpath(headers, os.path.dirname(module_map))
    with open(module_map, "w", encoding="utf-8") as handle:
        handle.write(
            f'module {target.name} {{\n'
            f'    umbrella "{umbrella}"\n'
            f"    export *\n"
            f"}}\n"
        )
    return module_map


# --- compiling -------------------------------------------------------


def base_swift_flags(arch):
    flags = [
        "-target", f"{arch}-apple-ios{DEPLOYMENT_TARGET}",
        "-sdk", sdk_path(),
        "-swift-version", "5",
        "-enable-upcoming-feature", "ConciseMagicFile",
        # SE-0409, spelled by this project as `public import`: Swift 6
        # language mode, experimental in 5.10, same meaning.
        "-enable-experimental-feature", "AccessLevelOnImport",
        # SE-0411: a default argument may name an isolated value.
        "-enable-upcoming-feature", "IsolatedDefaultValues",
        "-file-prefix-map", ROOT + "=.",
        "-file-prefix-map", BUILD + "=DerivedData",
        "-module-cache-path", relative(os.path.join(BUILD, "module-cache")),
        "-I", relative(MODULES_DIR),
        # Luros's local declarations for what the SDK leaves out (the
        # XPC C API); see Vendor/include/xpc/xpc.h.
        "-Xcc", "-I" + os.path.join("Vendor", "include"),
        "-Xcc", "-fblocks",
        "-Xcc", "-I.",
    ]
    if configuration() == "debug":
        flags += ["-Onone", "-g"]
    else:
        flags += ["-O"]
    return flags


def c_interop_flags(target):
    """The module maps and header paths of every C module behind `target`.

    A Swift module's public interface can name a type from a C module
    it imports, and a client of it must then find that module map too
    (`missing required module` otherwise), so the walk is transitive.
    """
    flags = []
    seen = set()

    def walk(name):
        module = plan.BY_NAME.get(name)
        if module is None or name in seen:
            return
        seen.add(name)
        if module.kind == "c":
            flags.extend(
                [
                    "-Xcc", "-fmodule-map-file=" + relative(write_module_map(module)),
                    "-Xcc", "-I" + os.path.join(module.path, module.headers),
                ]
            )
        for dependency in module.deps:
            walk(dependency)

    for dependency in target.deps:
        walk(dependency)
    return flags


def c_modules_behind(names):
    """Every C module reachable from `names`, each once, in order."""
    found = []
    seen = set()

    def walk(name):
        module = plan.BY_NAME.get(name)
        if module is None or name in seen:
            return
        seen.add(name)
        if module.kind == "c":
            found.append(module)
        for dependency in module.deps:
            walk(dependency)

    for name in names:
        walk(name)
    return found


def with_dependencies(target, key, state):
    """Fold the modules this one imports into its cache key.

    A module's own sources can be untouched while what it imports changed
    shape — turning a `let` into a `var` renames the symbol its callers
    reference — so a stale object would fail at link time. The digests of
    the modules it depends on are part of the key for that reason.
    """
    for dependency in target.deps:
        remembered = state.get(dependency, {}).get("digest")
        if remembered:
            key = hashlib.sha256((key + remembered).encode()).hexdigest()
    return key


def compile_swift(target, staged, state):
    arch = architecture()
    flags = base_swift_flags(arch) + c_interop_flags(target) + list(target.swiftflags)
    if not target.entry:
        flags.append("-parse-as-library")
    key = with_dependencies(target, digest_of(target, staged, flags), state)
    remember = state.get(target.name, {})
    module_path = os.path.join(MODULES_DIR, f"{target.name}.swiftmodule")
    object_path = os.path.join(OBJECTS, f"{target.name}.o")
    if (
        remember.get("digest") == key
        and os.path.exists(module_path)
        and (remember.get("objects") or [] and all(os.path.exists(path) for path in remember["objects"]))
    ):
        return "cached", 0.0

    os.makedirs(MODULES_DIR, exist_ok=True)
    os.makedirs(OBJECTS, exist_ok=True)
    command = [tool("swiftc")] + flags + [
        "-module-name", target.name,
        "-emit-module", "-emit-module-path", relative(module_path),
        "-c", "-o", relative(object_path),
        "-wmo",
    ] + [relative(path) for path in staged]
    code, output, elapsed = run(command)
    if code != 0:
        raise BuildError(f"{target.name} failed to compile")
    state[target.name] = {"digest": key, "objects": [object_path], "module": module_path}
    return "compiled", elapsed


def compile_c(target, staged, state):
    arch = architecture()
    include_flags = [
        f"-I{os.path.join(target.path, target.headers)}",
        "-I" + os.path.join("Vendor", "include"),
        "-I.",
    ]
    include_flags += [f"-I{os.path.join(target.path, search)}" for search in target.header_search]
    for module in c_modules_behind(target.deps):
        include_flags.append(f"-I{os.path.join(module.path, module.headers)}")
        if module.module_map:
            # A binary framework is also reached the way its own
            # headers are written: `#include <libarchive/archive.h>`
            # needs the folder that holds the .framework.
            include_flags.append(f"-F{os.path.dirname(module.path)}")
    flags = [
        "-target", f"{arch}-apple-ios{DEPLOYMENT_TARGET}",
        "-isysroot", sdk_path(),
        "-fmodules",
        "-fobjc-arc",
        "-ffile-prefix-map=" + ROOT + "=.",
        "-O0" if configuration() == "debug" else "-O2",
    ] + include_flags + list(target.cflags)
    key = with_dependencies(target, digest_of(target, staged, flags), state)
    # The module map is rewritten every run: its umbrella path is
    # relative, and the build folder may have moved.
    module_map = write_module_map(target)
    remember = state.get(target.name, {})
    cached_objects = remember.get("objects") or []
    if remember.get("digest") == key and all(
        os.path.exists(path) for path in cached_objects
    ) and (cached_objects or not staged):
        return "cached", 0.0

    os.makedirs(OBJECTS, exist_ok=True)
    objects = []
    elapsed = 0.0
    for path in staged:
        stem = os.path.splitext(os.path.basename(path))[0]
        piece = os.path.join(OBJECTS, f"{target.name}-{stem}.o")
        suffix = os.path.splitext(path)[1]
        if suffix in (".cc", ".cpp"):
            language = ["-x", "c++", "-std=c++17"]
            compiler = tool("clang")
        else:
            language = []
            compiler = tool("clang")
        command = [compiler] + flags + language + ["-c", relative(path), "-o", relative(piece)]
        code, _, seconds = run(command)
        elapsed += seconds
        if code != 0:
            raise BuildError(f"{target.name}: {os.path.basename(path)} failed to compile")
        objects.append(piece)
    state[target.name] = {"digest": key, "objects": objects, "module": module_map}
    return "compiled", elapsed


def build(names):
    targets = plan.build_order(names)
    missing = [t.name for t in targets if t.external]
    if missing:
        raise SystemExit(
            "not vendored yet: " + ", ".join(missing)
        )
    state = {}
    if os.path.exists(STATE):
        with open(STATE, encoding="utf-8") as handle:
            state = json.load(handle)
    failures = 0
    for target in targets:
        sources = module_sources(target)
        staged = stage_module(target, sources)
        try:
            outcome, seconds = (
                compile_swift(target, staged, state)
                if target.kind == "swift"
                else compile_c(target, staged, state)
            )
        except BuildError as error:
            failures += 1
            log(f"  {target.name}: {error}")
            break
        log(f"  {target.name}: {outcome} ({seconds:.1f}s, {len(sources)} files)")
    with open(STATE, "w", encoding="utf-8") as handle:
        json.dump(state, handle, indent=2, sort_keys=True)
    return failures


def write_xpc_stub():
    """The libxpc .tbd the linker needs, from the local declarations."""
    library = os.path.join(BUILD, "lib")
    os.makedirs(library, exist_ok=True)
    stub = os.path.join(library, "libxpc.tbd")
    code, output, _ = run([sys.executable, os.path.join(HERE, "xpc.py"), stub])
    if code != 0:
        raise SystemExit("could not write the libxpc stub: " + output)
    return library


def link_product(product):
    """Compile the product's modules, then link and sign the executable."""
    if build(product.modules):
        raise SystemExit(f"{product.name}: a module did not compile")
    with open(STATE, encoding="utf-8") as handle:
        state = json.load(handle)
    objects = []
    frameworks = set(product.frameworks)
    libraries = []
    extra = []
    for name in product.modules:
        for target in plan.build_order((name,)):
            objects.extend(state[target.name]["objects"])
            frameworks.update(target.frameworks)
            extra.extend(target.link_flags)
            if target.library:
                libraries.append(os.path.join(ROOT, target.path, target.library))
    output = os.path.join(BUILD, "products", product.name)
    os.makedirs(os.path.dirname(output), exist_ok=True)
    if os.path.exists(output):
        os.remove(output)
    # A system overlay's stub is handed over by path: the SDK's own .tbd
    # of that name sits earlier on the search path and lists no symbols.
    extra_arguments = []
    for flag in extra:
        stub = os.path.join(BUILD, "lib", "lib" + flag[2:] + ".tbd") if flag.startswith("-l") else ""
        extra_arguments.append(relative(stub) if stub and os.path.exists(stub) else flag)

    command = [tool("swiftc")] + base_swift_flags(architecture()) + [
        "-L", relative(write_xpc_stub()),
        "-o", relative(output),
    ] + [relative(path) for path in objects] + [
        relative(path) for path in libraries
    ] + extra_arguments + [
        argument for framework in sorted(frameworks) for argument in ("-framework", framework)
    ] + [
        # libclang_rt's availability check calls a libSystem internal the
        # 17.4 SDK's stubs do not name; dyld resolves it at launch, so
        # the link lets it stay undefined instead of refusing.
        "-Xlinker", "-U", "-Xlinker", "__availability_version_check",
        "-Xlinker", "-U", "-Xlinker", "_reboot3",
        # Two UIKit symbols the SDK's stub omits although the system has
        # them: `UICellAccessory`'s type metadata and
        # `UICollectionViewDiffableDataSource`'s
        # `init(collectionView:cellProvider:)`, both there since iOS 14.
        # Optimised code references them (unoptimised code never did, which
        # is why this only surfaced with -O), and dyld binds both at launch.
        "-Xlinker", "-U", "-Xlinker", "_$s5UIKit15UICellAccessoryVMn",
        "-Xlinker", "-U", "-Xlinker",
        "_$s5UIKit34UICollectionViewDiffableDataSourceC010collectionC012cellProviderACyxq_GSo0bC0C_So0bC4CellCSgAH_10Foundation9IndexPathVq_tctcfc",
    ]
    code, _, elapsed = run(command)
    if code != 0:
        if os.environ.get("LUROS_LINK_DEBUG"):
            log("  command: " + " ".join(command))
        raise SystemExit(f"{product.name}: link failed")
    if product.entitlements:
        entitlements = os.path.join(ROOT, product.entitlements)
        code, _, _ = run([tool("ldid"), f"-S{relative(entitlements)}", relative(output)])
    else:
        code, _, _ = run([tool("ldid"), "-S", relative(output)])
    if code != 0:
        raise SystemExit(f"{product.name}: ldid refused to sign it")
    size = os.path.getsize(output)
    log(f"  {product.name}: linked and signed ({size / 1_000_000:.1f} MB, {elapsed:.1f}s)")
    return output


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--list", action="store_true", help="name every module the plan has")
    parser.add_argument("--modules", nargs="+", default=None, help="build these modules and their dependencies")
    parser.add_argument("--all", action="store_true", help="build every module the plan can build")
    parser.add_argument("--product", default=None, help="link one product of plan.PRODUCTS")
    parser.add_argument("--clean", action="store_true", help="remove Builds/Device before building")
    arguments = parser.parse_args(argv)

    if arguments.list:
        for target in plan.MODULES:
            note = " (external)" if target.external else ""
            log(f"{target.name}{note}: {target.path}{'' if target.deps else ''}")
        return 0

    if arguments.clean and os.path.isdir(BUILD):
        shutil.rmtree(BUILD)

    if arguments.product:
        product = plan.PRODUCTS_BY_NAME.get(arguments.product)
        if product is None:
            parser.error(f"plan.py names no product {arguments.product!r}")
        link_product(product)
        return 0

    if arguments.all:
        names = [target.name for target in plan.MODULES if not target.external]
    elif arguments.modules:
        names = arguments.modules
    else:
        parser.error("give --modules, --all, --product or --list")
    return 1 if build(names) else 0


if __name__ == "__main__":
    sys.exit(main())