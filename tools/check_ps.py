#!/usr/bin/env python3
"""Static checks for the Harness PowerShell sources.

There is no PowerShell available in most CI/sandbox environments, so this
script stands in for the parts of `pwsh -Command {...}` / PSScriptAnalyzer
that can be reproduced with a real PowerShell grammar:

  1. Parse every .ps1 with tree-sitter-powershell and fail on ERROR/MISSING
     nodes (this catches the syntax errors that would otherwise only show up
     on a Windows box).
  2. Enforce ASCII-only sources. Windows PowerShell 5.1 reads a .ps1 without a
     BOM as Windows-1252, so any non-ASCII byte is a latent corruption bug.
  3. Enforce LF line endings and no tabs (house style, prevents diff noise).
  4. Cross-check the profile JSON files against the real param() block of
     HARNESS.ps1 so a profile can never reference a knob that does not exist.
  5. Sanity-check balance of brace/paren inside PowerShell here-strings is left
     to the grammar (item 1 already covers it) - but we do assert that no
     C# here-string contains a line starting with the closing delimiter.

Usage:  python3 tools/check_ps.py [--root .]
Exit code 0 = clean, 1 = problems found.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

try:
    import tree_sitter
    import tree_sitter_powershell
except ImportError:  # pragma: no cover
    print("ERROR: needs tree-sitter + tree-sitter-powershell (pip install tree-sitter tree-sitter-powershell)")
    sys.exit(2)

# The tree-sitter-powershell grammar only accepts the PowerShell numeric unit
# suffixes (KB/MB/GB/TB/PB) when they follow a bare number literal. Real
# PowerShell accepts them after any expression, e.g. "$used -gt 2GB" or
# "$x * 1MB", which is how they are used here. Normalising them to an explicit
# number keeps the parse meaningful; the only thing hidden by this is a typo
# inside the suffix itself (there are only five legal suffixes).
UNIT_RE = re.compile(r"\b(\d+(?:\.\d+)?)\s?(KB|MB|GB|TB|PB)\b", re.IGNORECASE)
UNIT_MULTIPLIER = {
    "KB": 1024,
    "MB": 1024 ** 2,
    "GB": 1024 ** 3,
    "TB": 1024 ** 4,
    "PB": 1024 ** 5,
}


def normalize_units(text: str) -> str:
    """Replace 512MB-style literals with their numeric value for parsing only."""
    def repl(match: "re.Match[str]") -> str:
        value = float(match.group(1)) * UNIT_MULTIPLIER[match.group(2).upper()]
        return str(int(value))
    return UNIT_RE.sub(repl, text)

LANG = tree_sitter.Language(tree_sitter_powershell.language())
PARSER = tree_sitter.Parser(LANG)

# Params that exist for the CLI only and are not valid profile keys.
CLI_ONLY_PARAMS = {
    "ProfilePath",
    "Restore",
    "SelfTest",
    "Yes",
    "NoElevate",
    "NoPause",
    "DryRun",
    "Watch",
    "WatchIntervalSec",
    "StatePath",
    "LogPath",
    "Launch",
}


class Problem:
    def __init__(self, path: Path, line: int, col: int, kind: str, msg: str):
        self.path, self.line, self.col, self.kind, self.msg = path, line, col, kind, msg

    def __str__(self) -> str:
        return f"{self.path}:{self.line}:{self.col}: {self.kind}: {self.msg}"


def walk(node):
    """Yield node and all descendants."""
    yield node
    stack = [node]
    while stack:
        cur = stack.pop()
        stack.extend(cur.children)
        yield cur


def check_syntax(path: Path, source: bytes) -> list[Problem]:
    problems: list[Problem] = []
    text = source.decode("ascii", "replace")
    normalized = normalize_units(text).encode("ascii", "replace")
    tree = PARSER.parse(normalized)
    for node in walk(tree.root_node):
        if node.type == "ERROR":
            problems.append(
                Problem(path, node.start_point[0] + 1, node.start_point[1] + 1,
                        "syntax", f"unparsable token: {normalized[node.start_byte:node.end_byte][:80]!r}")
            )
        elif node.is_missing:
            problems.append(
                Problem(path, node.start_point[0] + 1, node.start_point[1] + 1,
                        "syntax", f"missing {node.type}")
            )
    return problems


def check_text_hygiene(path: Path, source: bytes) -> list[Problem]:
    problems: list[Problem] = []
    # ASCII only
    for i, line in enumerate(source.split(b"\n"), start=1):
        bad = [b for b in line if b > 0x7F]
        if bad:
            problems.append(
                Problem(path, i, 1, "encoding",
                        f"non-ASCII byte 0x{bad[0]:02x} - PS 5.1 reads BOM-less .ps1 as Windows-1252")
            )
        if b"\t" in line:
            problems.append(Problem(path, i, 1, "style", "tab character; use spaces"))
        if b"\r" in line:
            problems.append(Problem(path, i, 1, "style", "CRLF; use LF endings"))
    return problems


def check_here_string_delimiters(path: Path, lines: list[str]) -> list[Problem]:
    """A C# here-string must not contain a line that starts with '@ (block end)."""
    problems: list[Problem] = []
    open_re = re.compile(r"@'\s*$|@\"\s*$")
    in_block = False
    block_start = 0
    for i, line in enumerate(lines, start=1):
        if not in_block and open_re.search(line):
            in_block = True
            block_start = i
            continue
        if in_block:
            if line.startswith("'@") or line.startswith('"@'):
                in_block = False
            elif re.match(r"^\s*(public|private|internal|static|using|namespace|\})", line) and "@'" in line:
                problems.append(Problem(path, i, 1, "herestring",
                                        "suspicious @' inside a here-string block"))
    if in_block:
        problems.append(Problem(path, block_start, 1, "herestring", "unterminated here-string block"))
    return problems


IDENT_RE = re.compile(r"\$(\w+)")


def read_param_names(text: str) -> set[str]:
    """Extract parameter names from the first param() block.

    Bracket depth is tracked by hand rather than with a regex, because
    parameters carry attributes and array types ("[string[]] $Name") - a naive
    pattern silently skips every array-typed parameter, which would make the
    profile cross-check reject legitimate keys.
    """
    start = text.find("param(")
    if start < 0:
        return set()
    depth = 0
    end = len(text)
    for i, ch in enumerate(text[start:], start=start):
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                end = i
                break
    block = text[start + len("param("):end]

    names: list[str] = []
    depth = 0
    i = 0
    while i < len(block):
        ch = block[i]
        if ch == "[":
            depth += 1
        elif ch == "]":
            depth -= 1
        elif ch == "$" and depth == 0:
            match = IDENT_RE.match(block[i:])
            if match:
                names.append(match.group(1))
                i += len(match.group(0)) - 1
        i += 1
    return set(names)


def check_profiles(root: Path, param_names: set[str]) -> list[Problem]:
    problems: list[Problem] = []
    profiles_dir = root / "profiles"
    if not profiles_dir.is_dir():
        return problems
    for path in sorted(profiles_dir.glob("*.json")):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            problems.append(Problem(path, exc.lineno, exc.colno, "json", exc.msg))
            continue
        if not isinstance(data, dict):
            problems.append(Problem(path, 1, 1, "json", "profile root must be an object"))
            continue
        for key in data:
            if key not in param_names:
                problems.append(Problem(path, 1, 1, "profile",
                                        f"unknown key '{key}' - no such parameter in HARNESS.ps1"))
            elif key in CLI_ONLY_PARAMS and key not in ("Launch",):
                problems.append(Problem(path, 1, 1, "profile",
                                        f"'{key}' is CLI-only and cannot be set from a profile"))
    return problems


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=".")
    args = ap.parse_args()
    root = Path(args.root).resolve()

    sources = sorted(root.rglob("*.ps1")) + sorted(root.rglob("*.psm1"))
    sources = [p for p in sources if ".git" not in p.parts and "build" not in p.parts]
    if not sources:
        print("no PowerShell sources found")
        return 1

    problems: list[Problem] = []
    for path in sources:
        raw = path.read_bytes()
        problems += check_syntax(path, raw)
        problems += check_text_hygiene(path, raw)
        problems += check_here_string_delimiters(path, raw.decode("ascii", "replace").split("\n"))

    harness = root / "HARNESS.ps1"
    if harness.exists():
        names = read_param_names(harness.read_text(encoding="ascii", errors="replace"))
        if not names:
            problems.append(Problem(harness, 1, 1, "params", "could not read param() block"))
        else:
            problems += check_profiles(root, names)
            print(f"param() block: {len(names)} parameters -> {', '.join(sorted(names))}")

    for p in problems:
        print(p)
    print(f"\nchecked {len(sources)} file(s); {len(problems)} problem(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
