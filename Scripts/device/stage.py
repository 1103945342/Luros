"""Swift 5.10 source staging for the device build.

The repository is written for Swift 6 (Xcode 26). This device has the
Command Line Tools 15.3 toolchain, whose compiler is Swift 5.10, so a
handful of spellings it accepts do not parse here. Rather than rewrite
the repository for an older compiler — which would make the Mac build
carry the difference — the device build copies each target's sources
into its own staging folder and applies the same rewrites to the copy.
The repository stays as it is; its own build is unaffected.

Every rewrite is syntax-only: the staged file has the same meaning.

    python3 Scripts/device/stage.py <source dir> <destination dir>
"""

import os
import re
import sys

# SE-0439, "Trailing commas", is Swift 6.1. A comma directly before a
# closing parenthesis is a trailing comma in an argument or parameter
# list, and 5.10 reports it as "unexpected ',' separator". Inside an
# array, dictionary or tuple literal it is already legal, so the
# scanner only drops one whose innermost open bracket is "(".
_IDENTIFIER_BEFORE_KEYWORD = re.compile(r"[A-Za-z0-9_]")

def remove_trailing_commas(text):
    out = []
    i = 0
    n = len(text)
    stack = []
    while i < n:
        c = text[i]
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            j = text.find("\n", i)
            j = n if j < 0 else j
            out.append(text[i:j])
            i = j
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "*":
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append(text[i:j])
            i = j
            continue
        if c == "#":
            m = re.match(r'#+"', text[i:])
            if m:
                hashes = m.group(0).count("#")
                close = '"' + "#" * hashes
                j = text.find(close, i + len(m.group(0)))
                j = n if j < 0 else j + len(close)
                out.append(text[i:j])
                i = j
                continue
        if c == '"':
            j = i + 1
            depth = 0
            while j < n:
                if text[j] == "\\":
                    if j + 1 < n and text[j + 1] == "(":
                        depth += 1
                        j += 2
                        continue
                    j += 2
                    continue
                if depth:
                    if text[j] == "(":
                        depth += 1
                    elif text[j] == ")":
                        depth -= 1
                    j += 1
                    continue
                if text[j] == '"':
                    j += 1
                    break
                if text[j] == "\n":
                    break
                j += 1
            out.append(text[i:j])
            i = j
            continue
        if c in "([{":
            stack.append(c)
            out.append(c)
            i += 1
            continue
        if c in ")]}":
            if stack:
                stack.pop()
            out.append(c)
            i += 1
            continue
        if c == "," and stack and stack[-1] == "(":
            j = i + 1
            while j < n:
                if text[j] in " \t\r\n":
                    j += 1
                    continue
                if text[j] == "/" and j + 1 < n and text[j + 1] == "/":
                    k = text.find("\n", j)
                    j = n if k < 0 else k
                    continue
                if text[j] == "/" and j + 1 < n and text[j + 1] == "*":
                    k = text.find("*/", j + 2)
                    j = n if k < 0 else k + 2
                    continue
                break
            if j < n and text[j] == ")":
                i += 1
                continue
        out.append(c)
        i += 1
    return "".join(out)


# Each entry rewrites one spelling Swift 5.10 does not know, added only
# when a compile reports it: a rewrite pattern works on the whole file,
# comments included, so it must never be one that can match prose.
REWRITES = [
]


def stage_text(text):
    text = remove_trailing_commas(text)
    for _, pattern, replacement in REWRITES:
        text = pattern.sub(replacement, text)
    return text


def stage_tree(source, destination):
    """Copy every Swift file under source to destination, rewritten."""
    changed = 0
    total = 0
    for root, _, files in os.walk(source):
        for name in files:
            if not name.endswith(".swift"):
                continue
            path = os.path.join(root, name)
            with open(path, encoding="utf-8") as handle:
                original = handle.read()
            staged = stage_text(original)
            relative = os.path.relpath(path, source)
            target = os.path.join(destination, relative)
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with open(target, "w", encoding="utf-8") as handle:
                handle.write(staged)
            total += 1
            if staged != original:
                changed += 1
    return total, changed


def main(argv):
    if len(argv) != 3:
        sys.stderr.write(__doc__)
        return 2
    total, changed = stage_tree(argv[1], argv[2])
    print(f"staged {total} Swift files, rewrote {changed}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
