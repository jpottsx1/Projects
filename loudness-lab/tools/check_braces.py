#!/usr/bin/env python3
"""Do the braces balance? For Swift, which this machine cannot compile.

A structural mistake -- a search-and-replace that landed inside a type
body, a closure left open -- is the cheapest class of error to make here
and the most expensive to find, because finding it means a round trip to a
Mac with a toolchain. This catches that one class and claims nothing more:
balanced braces are not a compiling program.

It knows about `//` and `/* */`, about "..." and \"\"\"...\"\"\", and about
string interpolation, which nests code inside a string inside code. A
checker that ignored interpolation reported every file in this project as
unbalanced, which is the same as reporting none of them.

    python3 tools/check_braces.py macapp/Sources/**/*.swift
    find macapp -name '*.swift' | xargs python3 tools/check_braces.py
"""
import sys
from pathlib import Path

OPEN, CLOSE = "{([", {"}": "{", ")": "(", "]": "["}

def scan(text):
    i, n = 0, len(text)
    depth = {"{": 0, "(": 0, "[": 0}
    stack = [("code", None)]           # (mode, paren depth interpolation began at)
    while i < n:
        c, mode = text[i], stack[-1][0]
        if mode == "code":
            if text.startswith("//", i):
                j = text.find("\n", i); i = n if j < 0 else j; continue
            if text.startswith("/*", i):
                j = text.find("*/", i + 2); i = n if j < 0 else j + 2; continue
            if text.startswith('"""', i):
                stack.append(("multiline", None)); i += 3; continue
            if c == '"':
                stack.append(("string", None)); i += 1; continue
            if c in OPEN:
                depth[c] += 1
            elif c in CLOSE:
                if c == ")" and stack[-1][1] is not None \
                        and depth["("] == stack[-1][1] + 1:
                    depth["("] -= 1          # closes the interpolation
                    stack.pop()
                    i += 1
                    continue
                depth[CLOSE[c]] -= 1
                if depth[CLOSE[c]] < 0:
                    return depth, f"unmatched {c} at offset {i}"
            i += 1
        else:
            if c == "\\" and i + 1 < n:
                if text[i + 1] == "(":
                    stack.append(("code", depth["("]))
                    depth["("] += 1
                    i += 2
                    continue
                i += 2
                continue
            if mode == "string" and c == '"':
                stack.pop(); i += 1; continue
            if mode == "multiline" and text.startswith('"""', i):
                stack.pop(); i += 3; continue
            i += 1
    if len(stack) != 1:
        return depth, f"ended inside {stack[-1][0]}"
    return depth, None

def main(paths) -> int:
    failed = 0
    for f in paths:
        depth, problem = scan(Path(f).read_text())
        bad = {k: v for k, v in depth.items() if v != 0}
        if bad or problem:
            failed += 1
            print(f"{f}: {problem or bad}")
    if failed:
        print(f"{failed} file(s) do not balance")
        return 1
    print(f"{len(paths)} file(s) balance")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
