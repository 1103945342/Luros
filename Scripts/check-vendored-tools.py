#!/usr/bin/env python3
"""Fail when what Luros carries drifts from what says so.

`Vendor/` holds the one device tool the package no longer depends on: icli.
The installer is no longer a binary there — it is `Packages/IrisinKit`,
compiled into lurosd's installer mode — and the things that keep that honest
are checked here too: its README pins the upstream tag, its LICENSE travels
with it, and neither the package's maintainer scripts nor its staging bring
Irisin's daemon back.

Usage: check-vendored-tools.py <root>

Exit 0 clean, 65 when something does not agree.
"""

import hashlib
import os
import re
import sys

# path in the bundle -> the package the binary came from
TOOLS = {
    "bin/icli": "com.icli.icli",
}
# The vendored installer, compiled from source into lurosd.
INSTALLER = "Packages/IrisinKit"
PIN = "v5.1.8"


def read(path):
    with open(path, encoding="utf-8", errors="replace") as handle:
        return handle.read()


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    problems = []

    readme_path = os.path.join(root, "Vendor", "README.md")
    if not os.path.isfile(readme_path):
        print("error: Vendor/README.md is missing", file=sys.stderr)
        return 65
    readme = read(readme_path)

    for relative in TOOLS:
        path = os.path.join(root, "Vendor", relative)
        if not os.path.isfile(path):
            problems.append(f"Vendor/{relative} is missing")
            continue
        if not os.stat(path).st_mode & 0o111:
            problems.append(f"Vendor/{relative} is not executable")
        digest = hashlib.sha256(open(path, "rb").read()).hexdigest()
        row = re.search(
            r"^\|\s*`" + re.escape(relative) + r"`\s*\|[^|]*\|[^|]*\|\s*`([0-9a-f]{64})`\s*\|$",
            readme,
            re.M,
        )
        if not row:
            problems.append(f"Vendor/README.md has no digest row for {relative}")
        elif row.group(1) != digest:
            problems.append(
                f"Vendor/{relative} is {digest}, but README.md records {row.group(1)}: "
                "update the table when the binary changes",
            )

    # Irisin's daemon is not carried any more, in any form: a file under
    # Vendor/, a copy in the bundle, or a job the maintainer scripts write.
    for stale in ("Vendor/libexec/irisind", "Vendor/libexec/irisin-install"):
        if os.path.exists(os.path.join(root, stale)):
            problems.append(f"{stale} is back; the installer is source now ({INSTALLER})")

    control = read(os.path.join(root, "Packaging", "DEBIAN", "control"))
    depends = [line for line in control.splitlines() if line.startswith(("Depends:", "Pre-Depends:"))]
    for package in list(TOOLS.values()) + ["wiki.qaq.irisin"]:
        if any(package in line for line in depends):
            problems.append(f"control depends on {package}, which the bundle carries")

    packaging = read(os.path.join(root, "Scripts", "package-deb.sh"))
    for relative in TOOLS:
        if f"Vendor/{relative}" not in packaging:
            problems.append(f"package-deb.sh never stages Vendor/{relative}")
    for stale in ("Vendor/libexec/irisind", "Vendor/libexec/irisin-install"):
        if stale in packaging:
            problems.append(f"package-deb.sh still stages {stale}")

    postinst = read(os.path.join(root, "Packaging", "DEBIAN", "postinst"))
    if "wiki.qaq.irisin.service" in postinst or "com.fluoxetine.luros.irisind" in postinst:
        problems.append("postinst registers an irisind job again; nothing listens on a Mach service now")

    installer_readme = os.path.join(root, INSTALLER, "README.md")
    if not os.path.isfile(installer_readme):
        problems.append(f"{INSTALLER}/README.md is missing: the pinned installer has no provenance")
    elif PIN not in read(installer_readme):
        problems.append(f"{INSTALLER}/README.md does not pin {PIN}")
    if not os.path.isfile(os.path.join(root, INSTALLER, "LICENSE")):
        problems.append(f"{INSTALLER}/LICENSE is missing")

    for problem in problems:
        print("error: " + problem, file=sys.stderr)
    return 65 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
