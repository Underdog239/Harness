#!/usr/bin/env python3
"""Resolution check for PowerShell sources: undefined functions, undefined
variables, and top-level statements that run before their dependencies exist.

This exists because the development environment for this repo has no Windows
and therefore no Windows PowerShell: the script cannot be executed before it is
handed to a user. A grammar-backed reference check catches the failures that
execution would otherwise find first - a typo'd function name, a variable that
was never assigned, a stray $-identifier - without running anything.

Deliberately conservative: it reports findings for review rather than failing a
build on its own, and it understands common automatic variables.

Usage:  python3 tools/lint_ps_refs.py [file ...]
Exit code 0 = no findings, 1 = findings (review them).
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

try:
    import tree_sitter
    import tree_sitter_powershell
except ImportError:  # pragma: no cover
    print("ERROR: needs tree-sitter + tree-sitter-powershell")
    sys.exit(2)

LANG = tree_sitter.Language(tree_sitter_powershell.language())
PARSER = tree_sitter.Parser(LANG)

# Automatic / well-known variables that never need an assignment.
AUTOMATIC = {
    "_", "PSItem", "args", "input", "null", "true", "false", "this", "HOME", "PWD",
    "PID", "PPID", "Host", "Error", "foreach", "switch", "matches", "LASTEXITCODE",
    "PSVersionTable", "PSCommandPath", "PSScriptRoot", "PSBoundParameters", "PSCmdlet",
    "MyInvocation", "ExecutionContext", "VerbosePreference", "DebugPreference",
    "ErrorActionPreference", "WarningPreference", "InformationPreference",
    "ProgressPreference", "ConfirmPreference", "WhatIfPreference", "ErrorView",
    "MaximumHistoryCount", "NestedPromptLevel", "OutputEncoding", "Profile",
    "PSEdition", "PSHOME", "PSHome", "PSStyle", "ShellId", "StackTrace", "IsWindows",
    "IsLinux", "IsMacOS", "IsCoreCLR", "EnabledExperimentalFeatures", "PWD",
}
AUTOMATIC_RE = re.compile(r"^(env|global|script|local|private|using|variable|function|alias|drive):", re.IGNORECASE)

# Built-in cmdlets/keywords/aliases the sources are allowed to call.
BUILTIN_COMMANDS = {
    # core language constructs that look like commands
    "param", "if", "else", "elseif", "foreach", "for", "while", "do", "switch",
    "function", "filter", "return", "throw", "try", "catch", "finally", "trap",
    "begin", "process", "end", "class", "enum", "using", "exit", "break", "continue",
    # approved verbs used in this repo that are not cmdlets
    "not", "select", "where", "sort", "group", "measure", "compare", "join",
    # cmdlets actually used
    "Add-Content", "Add-Member", "Add-Type", "Clear-Host", "ConvertFrom-Json",
    "ConvertTo-Json", "ForEach-Object", "Format-Hex", "Format-List", "Format-Table",
    "Get-ChildItem", "Get-CimInstance", "Get-Command", "Get-Content", "Get-Date",
    "Get-Item", "Get-ItemProperty", "Get-Member", "Get-Process", "Get-Variable",
    "Group-Object", "Invoke-Command", "Join-Path", "Measure-Object", "New-Item",
    "New-Object", "Out-File", "Out-Null", "Out-String", "Read-Host", "Remove-Item",
    "Rename-Item", "Resolve-Path", "Select-Object", "Set-Content", "Set-ItemProperty",
    "Sort-Object", "Split-Path", "Start-Process", "Start-Sleep", "Stop-Process",
    "Test-Path", "Wait-Process", "Where-Object", "Write-Debug", "Write-Error",
    "Write-Host", "Write-Information", "Write-Output", "Write-Verbose", "Write-Warning",
    "Get-ComputerInfo", "Get-Process", "Test-Connection", "Get-Random",
    "Set-StrictMode", "Get-Location", "Get-Help", "Get-Verb", "Get-Alias",
    # external programs deliberately invoked
    "cmd.exe", "cmd", "powershell.exe", "pwsh", "python.exe", "py", "notepad",
    "timeout", "robocopy", "subst", "uname",
}
BUILTIN_COMMANDS = {c.lower() for c in BUILTIN_COMMANDS}


def walk(node):
    stack = [node]
    while stack:
        cur = stack.pop()
        yield cur
        stack.extend(cur.children)


def text_of(source: bytes, node) -> str:
    return source[node.start_byte:node.end_byte].decode("ascii", "replace")


def collect_definitions(source: bytes, tree):
    functions: dict[str, tuple[int, int]] = {}
    variables: set[str] = set()
    assigned_at_top_level: list[tuple[str, int]] = []

    for node in walk(tree.root_node):
        if node.type in ("function_statement", "function_definition"):
            name = None
            for child in node.children:
                if child.type in ("function_name", "simple_name", "identifier"):
                    name = text_of(source, child)
                    break
            if name is None:
                match = re.match(r"\s*function\s+([\w:-]+)", text_of(source, node))
                if match:
                    name = match.group(1)
            if name:
                functions[name] = (node.start_point[0] + 1, node.end_point[0] + 1)

        # assignment_expression covers "$x = value" and "[type]$x = value"
        if node.type == "assignment_expression":
            lhs = node.child_by_field_name("left") or (node.children[0] if node.children else None)
            if lhs is not None:
                for inner in walk(lhs):
                    if inner.type == "variable":
                        name = text_of(source, inner).lstrip("$")
                        name = name.split(":")[-1]
                        variables.add(name)
                        if node.start_point[0] < 200:
                            assigned_at_top_level.append((name, node.start_point[0] + 1))

        # foreach ($x in ...) / for ($i = 0; ...) bring new variables into scope
        if node.type in ("foreach_statement", "for_statement"):
            head = text_of(source, node)
            for match in re.finditer(r"foreach\s*\(\s*\$(\w+)", head):
                variables.add(match.group(1))
            for match in re.finditer(r"\$(\w+)\s*=", head):
                variables.add(match.group(1))

        # function/script parameters: param_block -> parameter_list -> script_parameter
        if node.type == "script_parameter":
            for v in walk(node):
                if v.type == "variable":
                    variables.add(text_of(source, v).lstrip("$").split(":")[-1])

        # foreach ($x in ...) binds $x structurally
        if node.type == "foreach_statement":
            for child in node.children:
                if child.type == "variable":
                    variables.add(text_of(source, child).lstrip("$").split(":")[-1])

        # catch blocks shadow $_
        if node.type == "catch_clause":
            variables.add("_")

    return functions, variables, assigned_at_top_level


def script_parameter_names(source: bytes, tree) -> set[str]:
    """Parameters declared at file scope: visible inside every function."""
    names: set[str] = set()
    root = tree.root_node
    for node in walk(root):
        if node.type != "script_parameter":
            continue
        # only the outermost param_block (the script's own) counts
        ancestor = node.parent
        in_function = False
        while ancestor is not None:
            if ancestor.type == "function_statement":
                in_function = True
                break
            if ancestor is root:
                break
            ancestor = ancestor.parent
        if in_function:
            continue
        for v in walk(node):
            if v.type == "variable":
                names.add(text_of(source, v).lstrip("$"))
    return names


def check_use_before_assignment(source: bytes, tree, script_params: set[str]) -> dict[str, tuple[int, int, int]]:
    """Per function: variables whose first occurrence line precedes their first
    assignment line inside that same function.

    Only variables assigned *inside* the function are considered, which keeps
    script-scope state (that is what $script: is for) out of the report.
    """
    problems: dict[str, tuple[int, int, int]] = {}

    for node in walk(tree.root_node):
        if node.type != "function_statement":
            continue
        name = None
        for child in node.children:
            if child.type == "function_name":
                name = text_of(source, child)
                break
        if not name:
            continue

        first_use: dict[str, int] = {}
        first_assign: dict[str, int] = {}

        for inner in walk(node):
            if inner.type == "variable":
                raw = text_of(source, inner).lstrip("$")
                # explicit scope prefixes (script:/env:/global:) are different
                # variables from a same-named local, so they are out of scope here
                if ":" in raw:
                    continue
                var = raw
                if var in script_params:
                    continue
                line = inner.start_point[0] + 1
                if var not in first_use or line < first_use[var]:
                    first_use[var] = line

            # any assignment whose left-hand side contains the variable.
            # This grammar does not give the left side a field name, so fall
            # back to the first child (left_assignment_expression).
            if inner.type == "assignment_expression":
                lhs = inner.child_by_field_name("left")
                if lhs is None and inner.children:
                    lhs = inner.children[0]
                if lhs is not None:
                    for v in walk(lhs):
                        if v.type == "variable":
                            var = text_of(source, v).lstrip("$").split(":")[-1]
                            line = inner.start_point[0] + 1
                            if var not in first_assign or line < first_assign[var]:
                                first_assign[var] = line

            if inner.type == "script_parameter":
                for v in walk(inner):
                    if v.type == "variable":
                        var = text_of(source, v).lstrip("$").split(":")[-1]
                        line = v.start_point[0] + 1
                        if var not in first_assign or line < first_assign[var]:
                            first_assign[var] = line

            if inner.type == "foreach_statement":
                for child in inner.children:
                    if child.type == "variable":
                        var = text_of(source, child).lstrip("$").split(":")[-1]
                        line = inner.start_point[0] + 1
                        if var not in first_assign or line < first_assign[var]:
                            first_assign[var] = line

        for var, use_line in first_use.items():
            assign_line = first_assign.get(var)
            if assign_line is not None and use_line < assign_line:
                problems.setdefault(var, (node.start_point[0] + 1, use_line, assign_line))

    return problems


def main() -> int:
    files = [Path(a) for a in sys.argv[1:]] or [Path("HARNESS.ps1")]
    findings = 0

    for path in files:
        if not path.exists():
            print(f"{path}: missing")
            findings += 1
            continue
        source = path.read_bytes()
        tree = PARSER.parse(source)
        functions, variables, top_level = collect_definitions(source, tree)

        # ---- undefined functions ------------------------------------------
        known = set(functions)
        reported_commands: dict[str, int] = {}
        for node in walk(tree.root_node):
            if node.type != "command":
                continue
            name = None
            for child in node.children:
                if child.type in ("command_name", "generic_token", "command_name_expr"):
                    name = text_of(source, child).strip()
                    break
            if not name:
                continue
            if name.startswith(("-", "$", "(", "{")):
                continue
            # numeric literals with a PowerShell unit suffix ("64MB") parse as a
            # command name in this grammar; they are values, not commands
            if re.match(r"^[\d.,]+\s*(KB|MB|GB|TB|PB)?$", name, re.IGNORECASE):
                continue
            if name in known or name.lower() in BUILTIN_COMMANDS:
                continue
            # method calls and types are not commands
            if "." in name or "::" in name:
                continue
            reported_commands.setdefault(name, node.start_point[0] + 1)

        if reported_commands:
            findings += len(reported_commands)
            print(f"\n{path}: commands that do not resolve to a function in this file or a known cmdlet:")
            for name, line in sorted(reported_commands.items(), key=lambda kv: kv[1]):
                print(f"  line {line:>5}  {name}")

        # ---- use before assignment -----------------------------------------
        early = check_use_before_assignment(source, tree, script_parameter_names(source, tree))
        if early:
            findings += len(early)
            print(f"\n{path}: variables read before their first assignment inside the same function:")
            for var, (func_line, use_line, assign_line) in sorted(early.items(), key=lambda kv: kv[1][1]):
                print(f"  ${var:<24} used at line {use_line}, first assigned at {assign_line} (function at line {func_line})")

        # ---- undefined variables ------------------------------------------
        reported_vars: dict[str, int] = {}
        for node in walk(tree.root_node):
            if node.type != "variable":
                continue
            raw = text_of(source, node).lstrip("$")
            if not raw:
                continue
            if AUTOMATIC_RE.match(raw):
                continue
            bare = raw.split(":")[-1]
            if bare in AUTOMATIC or bare in variables:
                continue
            # numeric-ish or weird tokens are not variables
            if not re.match(r"^[A-Za-z_]\w*$", bare):
                continue
            reported_vars.setdefault(bare, node.start_point[0] + 1)

        if reported_vars:
            findings += len(reported_vars)
            print(f"\n{path}: variables referenced but never assigned anywhere:")
            for name, line in sorted(reported_vars.items(), key=lambda kv: kv[1])[:40]:
                print(f"  line {line:>5}  ${name}")

        print(f"\n{path}: {len(functions)} functions defined, "
              f"{len(reported_commands)} unresolved command(s), "
              f"{len(reported_vars)} unresolved variable(s)")

    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
