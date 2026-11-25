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
        if text.startswith('"""', i):
            # A multi-line string literal: everything up to the closing
            # triple quote is text, commas and all.
            j = text.find('"""', i + 3)
            j = n if j < 0 else j + 3
            out.append(text[i:j])
            i = j
            continue
        if c == "#":
            m = re.match(r'(#*)"""', text[i:])
            if m:
                hashes = m.group(1)
                close = '"""' + hashes
                j = text.find(close, i + len(m.group(0)))
                j = n if j < 0 else j + len(close)
                out.append(text[i:j])
                i = j
                continue
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


def _matching_brace(text, start):
    """The index of the `}` that closes the `{` at `start`.

    Strings, raw strings, multi-line strings and comments are skipped,
    so a brace inside one does not count.
    """
    n = len(text)
    depth = 0
    i = start
    while i < n:
        c = text[i]
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            j = text.find("\n", i)
            i = n if j < 0 else j
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "*":
            j = text.find("*/", i + 2)
            i = n if j < 0 else j + 2
            continue
        if text.startswith('"""', i):
            j = text.find('"""', i + 3)
            i = n if j < 0 else j + 3
            continue
        if c == '"' or (c == "#" and re.match(r'#+"', text[i:])):
            m = re.match(r'#*"', text[i:])
            hashes = m.group(0).count("#")
            close = '"' + "#" * hashes
            j = text.find(close, i + len(m.group(0)))
            i = n if j < 0 else j + len(close)
            continue
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


def rewrite_count_where(text):
    """`.count { predicate }` becomes `.filter { predicate }.count`.

    `count(where:)` is SE-0220, available only from Swift 6; filtering
    and counting is the same walk with the same result.
    """
    out = []
    i = 0
    n = len(text)
    # A `{` after `.count` is also the body of a `for … in … where …`
    # clause, and that one must stay where it is.
    control = ("for ", "while ", "if ", "guard ", "switch ", "else", "do ", "repeat", "catch")
    while i < n:
        if text.startswith(".count", i):
            line_start = text.rfind("\n", 0, i) + 1
            # A `{` after `.count` is a closure only in a plain statement:
            # in a control head (`if x.count {`), an if-expression
            # (`let r = if a.count {`), or after `}` it is a block, and
            # rewriting one would change the program's shape.
            head = text[line_start:i].lstrip().lstrip("}").lstrip()
            if head.startswith(control) or "=" in head or " if " in head or " while " in head:
                out.append(text[i])
                i += 1
                continue
            if head.startswith(control):
                out.append(text[i])
                i += 1
                continue
            j = i + len(".count")
            while j < n and text[j] in " \t":
                j += 1
            if j < n and text[j] == "{":
                close = _matching_brace(text, j)
                if close > 0:
                    out.append(".filter(" + text[j + 1:close] + ").count")
                    i = close + 1
                    continue
        out.append(text[i])
        i += 1
    return "".join(out)


def rewrite_count_where_labelled(text):
    """`.count(where: p)` becomes `.filter(p).count`.

    The same SE-0220 call, written with its label instead of a trailing
    closure.
    """
    marker = ".count(where:"
    out = []
    i = 0
    n = len(text)
    while i < n:
        start = text.find(marker, i)
        if start < 0:
            out.append(text[i:])
            break
        out.append(text[i:start])
        open_paren = start + len(".count")
        close = _matching_paren(text, open_paren)
        if close < 0:
            out.append(text[start:start + len(marker)])
            i = start + len(marker)
            continue
        inner = text[open_paren + 1:close]
        if inner.startswith("where:"):
            inner = inner[len("where:"):].strip()
        out.append(".filter(" + inner + ").count")
        i = close + 1
    return "".join(out)


def _matching_paren(text, start):
    """The index of the `)` that closes the `(` at `start`."""
    n = len(text)
    depth = 0
    i = start
    while i < n:
        c = text[i]
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            j = text.find("\n", i)
            i = n if j < 0 else j
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "*":
            j = text.find("*/", i + 2)
            i = n if j < 0 else j + 2
            continue
        if text.startswith('"""', i):
            j = text.find('"""', i + 3)
            i = n if j < 0 else j + 3
            continue
        if c == '"':
            j = i + 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            i = j + 1
            continue
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


KEY_PATH_CALL = re.compile(
    r"\.(filter|map|compactMap|flatMap|allSatisfy)\((\\\.([A-Za-z_][A-Za-z0-9_.]*)|\\\.self)\)"
)


def rewrite_key_path_calls(text):
    """`xs.map(\.name)` becomes `xs.map { $0.name }`.

    Swift 5.10 cannot pass a key path where a closure is expected. The
    rewrite is line-scoped and skips a control-flow header, because a
    trailing closure inside a `for … in …` sequence is read as the loop
    body and the statement stops parsing.
    """
    lines = text.split("\n")
    control = ("for ", "if ", "while ", "guard ", "switch ", "case ", "catch")
    for index, line in enumerate(lines):
        if line.lstrip().startswith(control):
            continue
        if "\\." not in line:
            continue

        def replace(match):
            member = match.group(3)
            closure = "({ $0 })" if member is None else "({ $0." + member + " })"
            return "." + match.group(1) + closure

        lines[index] = KEY_PATH_CALL.sub(replace, line)
    return "\n".join(lines)


# Each entry rewrites one spelling Swift 5.10 does not know, added only
# when a compile reports it: a rewrite pattern works on the whole file,
# comments included, so it must never be one that can match prose.
REWRITES = [
    # A key path where a closure is expected: Swift 5.10 cannot infer
    # `\.self` as a function in `compactMap(\.self)` or
    # `flatMap(\.self)`, and the closure is the same call.
    (
        "key path as a closure",
        re.compile(r"\.(compactMap|flatMap)\(\\\.self\)"),
        r".\1 { $0 }",
    ),
    # SE-0423 lets a conformance be `@preconcurrency`; 5.10 reads the
    # attribute there as applying to a type. The conformance itself is
    # what the code means, on every compiler.
    (
        "preconcurrency conformance",
        re.compile(r":\s*@preconcurrency\s+"),
        ": ",
    ),
    # SE-0470's `SendableMetatype` is Swift 6.2. It is a promise the
    # compiler checks, not a type the code uses, so dropping it from a
    # constraint list changes nothing the program does.
    (
        "SendableMetatype constraint",
        re.compile(r"\s*&\s*SendableMetatype|SendableMetatype\s*&\s*"),
        " ",
    ),
    # SE-0413, typed throws (`throws(Failure)`), is Swift 6. An untyped
    # `throws` accepts every call the typed one did; only an
    # `exhaustive` catch clause would notice, and the project has none.
    (
        "typed throws",
        re.compile(r"(rethrows|throws)\(([A-Za-z_][A-Za-z0-9_.]*)\)"),
        r"\1",
    ),
]


def stage_text(text):
    text = remove_trailing_commas(text)
    # The trailing-closure form is not rewritten: `x.count {` cannot be
    # told apart from a block opener (an if-expression, or a condition
    # wrapped over several lines), and rewriting the wrong one changes
    # what the program does. The labelled form below has no such twin.
    text = rewrite_count_where_labelled(text)
    text = rewrite_key_path_calls(text)
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
