#!/usr/bin/env python3
"""Build the help document from the guide and the app's own help entries.

The per-control help lives in Swift, beside the thing it documents, because
that is where it stays true -- `check_help.py` fails the build if a setting
has no entry. But Swift source is not a help file, and a reader who has not
opened the app yet needs the part the entries cannot give them: what the
thing is for and what order to do it in.

So the document is two halves. The guide is written by hand. The settings
reference is generated from `Help.swift`, which means it cannot drift: add
a control, write its help, and it appears here.

Two outputs, because they are read in different places:

    <name>.md     the canonical text, rendered inside the app's window
    <name>.html   standalone and styled, opens in any browser

Both are written into the app's own resources so they ship with it, and
both are committed, so a fresh checkout builds without running anything.

Both are committed. `check_help_build.py` regenerates and diffs, so a help
entry changed without rebuilding is an error rather than a stale file.

Nothing here is specific to this app -- the Swift path, the guide and the
output stem are all arguments, so another app with a `HelpEntry` of the
same shape can use it unchanged:

    python3 tools/build_help.py --swift path/to/Help.swift \\
        --guide docs/help/guide.md --out docs/help/its-name
"""

from __future__ import annotations

import argparse
import html
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def _swift_string(text: str) -> str:
    """One Swift string literal's contents, as text.

    Handles the two forms in use: a plain "..." and a multi-line \"\"\"...\"\"\"
    whose lines end in a backslash to say "this is one paragraph".
    """
    lines = []
    for line in text.split("\n"):
        lines.append(line.strip())
    joined, out = "", []
    for line in lines:
        if line.endswith("\\"):
            joined += line[:-1].rstrip() + " "
        else:
            out.append((joined + line).strip())
            joined = ""
    if joined:
        out.append(joined.strip())
    # A blank line is a paragraph break; anything else is a continuation
    # the author chose not to mark, which in practice does not happen.
    paragraphs, current = [], []
    for line in out:
        if line:
            current.append(line)
        elif current:
            paragraphs.append(" ".join(current))
            current = []
    if current:
        paragraphs.append(" ".join(current))
    return "\n\n".join(paragraphs)


def parse_entries(source: str) -> dict[str, dict]:
    """{name: {title, summary, detail}} for every HelpEntry declared."""
    found = {}
    pattern = re.compile(
        r'static let (\w+) = HelpEntry\(\s*'
        r'title:\s*"((?:[^"\\]|\\.)*)",\s*'
        r'summary:\s*"((?:[^"\\]|\\.)*)",\s*'
        r'detail:\s*"""\n(.*?)\n\s*"""\)',
        re.S)
    for match in pattern.finditer(source):
        found[match.group(1)] = {
            "title": match.group(2).replace('\\"', '"'),
            "summary": match.group(3).replace('\\"', '"'),
            "detail": _swift_string(match.group(4)),
        }
    return found


def parse_sections(source: str) -> list[tuple[str, list[str]]]:
    """The order and grouping the app itself shows, so the document reads
    the way the window does."""
    block = re.search(r"static let sections:[^=]*=\s*\[(.*?)\n    \]", source, re.S)
    if not block:
        return []
    out = []
    for match in re.finditer(r'HelpSection\("([^"]+)",\s*\[([^\]]*)\]\)',
                             block.group(1), re.S):
        names = [n.strip() for n in match.group(2).split(",") if n.strip()]
        out.append((match.group(1), names))
    return out


def build_markdown(guide: str, entries: dict, sections: list) -> str:
    out = [guide.rstrip(), "", "# Every setting", "",
           "Generated from the app's own help, so this cannot drift from "
           "what the window shows.", ""]
    for name, keys in sections:
        out += [f"## {name}", ""]
        for key in keys:
            entry = entries.get(key)
            if entry is None:
                continue
            out += [f"### {entry['title']}", "", f"*{entry['summary']}*", ""]
            out += [entry["detail"], ""]
    return "\n".join(out).rstrip() + "\n"


# --- a small Markdown subset, so the HTML needs nothing installed ---------

def _inline(text: str) -> str:
    text = html.escape(text)
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"(?<![*\w])\*([^*]+)\*(?!\w)", r"<em>\1</em>", text)
    return text


def markdown_to_html(text: str) -> str:
    out, lines, i = [], text.split("\n"), 0
    while i < len(lines):
        line = lines[i]
        if not line.strip():
            i += 1
            continue
        heading = re.match(r"(#{1,4})\s+(.*)", line)
        if heading:
            level = len(heading.group(1))
            out.append(f"<h{level}>{_inline(heading.group(2))}</h{level}>")
            i += 1
            continue
        if line.lstrip().startswith("|") and i + 1 < len(lines) \
                and set(lines[i + 1].replace("|", "").strip()) <= set("-: "):
            head = [c.strip() for c in line.strip().strip("|").split("|")]
            rows, i = [], i + 2
            while i < len(lines) and lines[i].lstrip().startswith("|"):
                rows.append([c.strip() for c in
                             lines[i].strip().strip("|").split("|")])
                i += 1
            out.append("<table><thead><tr>"
                       + "".join(f"<th>{_inline(c)}</th>" for c in head)
                       + "</tr></thead><tbody>"
                       + "".join("<tr>" + "".join(f"<td>{_inline(c)}</td>"
                                                  for c in r) + "</tr>"
                                 for r in rows)
                       + "</tbody></table>")
            continue
        bullet = re.match(r"[-*]\s+(.*)", line.strip())
        number = re.match(r"\d+\.\s+(.*)", line.strip())
        if bullet or number:
            tag = "ul" if bullet else "ol"
            items, i = [], i
            while i < len(lines):
                m = re.match(r"[-*]\s+(.*)" if bullet else r"\d+\.\s+(.*)",
                             lines[i].strip())
                if not m:
                    if lines[i].startswith("   ") and lines[i].strip() and items:
                        items[-1] += " " + lines[i].strip()
                        i += 1
                        continue
                    break
                items.append(m.group(1))
                i += 1
            out.append(f"<{tag}>"
                       + "".join(f"<li>{_inline(v)}</li>" for v in items)
                       + f"</{tag}>")
            continue
        if line.startswith("    "):
            block, i = [], i
            while i < len(lines) and (lines[i].startswith("    ")
                                      or not lines[i].strip()):
                block.append(lines[i][4:] if lines[i].startswith("    ") else "")
                i += 1
            out.append("<pre>" + html.escape("\n".join(block).strip()) + "</pre>")
            continue
        start = i
        para = []
        while i < len(lines) and lines[i].strip() \
                and not re.match(r"(#{1,4}\s|[-*]\s|\d+\.\s|\|)", lines[i].strip()) \
                and not lines[i].startswith("    "):
            para.append(lines[i].strip())
            i += 1
        if i == start:
            # Nothing matched and nothing was consumed, which means the
            # branches above and this one's stopping rule disagree about
            # what this line is. Take it as a paragraph and move on: the
            # alternative is a loop that never ends, which is what happened
            # when the two regexes were changed out of step.
            para.append(lines[i].strip())
            i += 1
        out.append(f"<p>{_inline(' '.join(para))}</p>")
    return "\n".join(out)


PAGE = """<!DOCTYPE html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<style>
:root {{
  color-scheme: light dark;
  --ink: #1b1b1f; --dim: #5d5d68; --bg: #fbfbfd; --card: #fff;
  --rule: #e3e3ea; --accent: #2b5fd9; --code: #f2f2f6;
}}
@media (prefers-color-scheme: dark) {{
  :root {{
    --ink: #e9e9ee; --dim: #a0a0ad; --bg: #16161a; --card: #1e1e24;
    --rule: #2f2f38; --accent: #7fa5ff; --code: #26262e;
  }}
}}
* {{ box-sizing: border-box; }}
body {{
  margin: 0; background: var(--bg); color: var(--ink);
  font: 16px/1.62 ui-sans-serif, -apple-system, "SF Pro Text", system-ui, sans-serif;
}}
main {{ max-width: 46rem; margin: 0 auto; padding: 3rem 16px 6rem; }}
h1 {{ font-size: 1.9rem; line-height: 1.2; margin: 2.6rem 0 .6rem; letter-spacing: -.02em; }}
h1:first-child {{ margin-top: 0; }}
h2 {{ font-size: 1.28rem; margin: 2.2rem 0 .5rem; letter-spacing: -.01em; }}
h3 {{ font-size: 1.02rem; margin: 1.6rem 0 .3rem; color: var(--accent); }}
p, li {{ color: var(--ink); }}
p {{ margin: .7rem 0; }}
em {{ color: var(--dim); font-style: normal; }}
h3 + p em {{ display: block; margin-bottom: .5rem; }}
ul, ol {{ padding-left: 1.3rem; }}
li {{ margin: .35rem 0; }}
code {{
  background: var(--code); padding: .1em .35em; border-radius: 4px;
  font: .88em ui-monospace, "SF Mono", Menlo, monospace;
}}
pre {{
  background: var(--code); padding: .9rem 1rem; border-radius: 8px;
  overflow-x: auto; font: .85rem/1.5 ui-monospace, "SF Mono", Menlo, monospace;
}}
table {{
  border-collapse: collapse; width: 100%; margin: 1rem 0;
  font-size: .93rem; background: var(--card); border-radius: 8px;
  overflow: hidden;
}}
th, td {{ text-align: left; padding: .5rem .7rem; border-bottom: 1px solid var(--rule); }}
th {{ font-weight: 600; color: var(--dim); font-size: .8rem;
     text-transform: uppercase; letter-spacing: .04em; }}
tr:last-child td {{ border-bottom: 0; }}
</style>
</head><body><main>
{body}
</main></body></html>
"""


def renderer_blocks(text: str) -> tuple[dict, bool]:
    """What `HelpDocument.swift` will make of this document.

    The renderer is Swift and cannot be run here, so its grammar is
    mirrored and run over the real file. It answers the question that
    actually matters -- will the app drop a block on the floor -- which
    diffing the markdown against itself cannot.
    """
    lines = text.split("\n")
    kinds, i = [], 0

    def marker(line):
        stripped = line.strip()
        if stripped.startswith("- ") or stripped.startswith("* "):
            return (False, stripped[2:])
        found = re.match(r"(\d+)\. (.*)", stripped)
        return (True, found.group(2)) if found else None

    def is_rule(line):
        kept = line.replace("|", "").strip()
        return bool(kept) and all(c in "-: " for c in kept)

    while i < len(lines):
        line = lines[i]
        if not line.strip():
            i += 1
            continue
        if line.startswith("#"):
            kinds.append("heading")
            i += 1
            continue
        if line.strip().startswith("|") and i + 1 < len(lines) and is_rule(lines[i + 1]):
            kinds.append("table")
            i += 2
            while i < len(lines) and lines[i].strip().startswith("|"):
                i += 1
            continue
        if marker(line):
            first = marker(line)
            kinds.append("list")
            while i < len(lines):
                nxt = marker(lines[i])
                if nxt and nxt[0] == first[0]:
                    i += 1
                elif lines[i].startswith("   ") and lines[i].strip():
                    i += 1
                else:
                    break
            continue
        if line.startswith("    "):
            kinds.append("preformatted")
            while i < len(lines) and (lines[i].startswith("    ")
                                      or not lines[i].strip()):
                i += 1
            continue
        kinds.append("paragraph")
        start = i
        while i < len(lines):
            stripped = lines[i].strip()
            if (not stripped or lines[i].startswith("#")
                    or lines[i].startswith("    ")
                    or stripped.startswith("|") or marker(lines[i])):
                break
            i += 1
        if i == start:
            i += 1          # always advance; see markdown_to_html
    counts = {}
    for kind in kinds:
        counts[kind] = counts.get(kind, 0) + 1
    return counts, i >= len(lines)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--swift", type=Path,
                        default=ROOT / "macapp/Sources/LoudnessLabUI/Views/Help.swift")
    parser.add_argument("--guide", type=Path, default=ROOT / "docs/help/guide.md")
    # Into the app's resources rather than into docs/, because the point
    # is that it SHIPS: the window renders the markdown and the menu opens
    # the page. Committed as well as generated, so a checkout builds
    # without running anything, and `--check` keeps the two honest.
    parser.add_argument("--out", type=Path,
                        default=ROOT / "macapp/Sources/LoudnessLabUI"
                                       "/Resources/Help/loudness-lab",
                        help="output stem; .md and .html are written")
    parser.add_argument("--title", default=None)
    parser.add_argument("--check", action="store_true",
                        help="write nothing; fail if the files are out of date")
    args = parser.parse_args(argv)

    for path in (args.swift, args.guide):
        if not path.is_file():
            print(f"missing: {path}")
            return 2
    source = args.swift.read_text()
    entries = parse_entries(source)
    sections = parse_sections(source)
    if not entries or not sections:
        print(f"no help entries or no sections found in {args.swift}")
        return 2
    listed = {name for _, names in sections for name in names}
    missing = sorted(listed - set(entries))
    if missing:
        print("sections name entries that do not exist: " + ", ".join(missing))
        return 2

    guide = args.guide.read_text()
    markdown = build_markdown(guide, entries, sections)
    title = args.title or guide.lstrip().split("\n")[0].lstrip("# ").strip()
    page = PAGE.format(title=html.escape(title), body=markdown_to_html(markdown))

    wanted = {args.out.with_suffix(".md"): markdown,
              args.out.with_suffix(".html"): page}
    counts, consumed = renderer_blocks(markdown)
    problems = []
    if not consumed:
        problems.append("the renderer's grammar does not consume the whole "
                        "document -- the app would drop the tail")
    # Against the HTML, which was produced by a different converter. Two
    # implementations agreeing is the only evidence either is right.
    for kind, tag in (("heading", r"<h[1-4][ >]"), ("paragraph", "<p[ >]"),
                      ("table", "<table[ >]")):
        in_html = len(re.findall(tag, page))
        if counts.get(kind, 0) != in_html:
            problems.append(f"{kind}: the renderer sees {counts.get(kind, 0)}, "
                            f"the html has {in_html}")
    lists = len(re.findall(r"<ul[ >]", page)) + len(re.findall(r"<ol[ >]", page))
    if counts.get("list", 0) != lists:
        problems.append(f"list: the renderer sees {counts.get('list', 0)}, "
                        f"the html has {lists}")
    if problems:
        print("the document and the renderer disagree:")
        for problem in problems:
            print(f"  {problem}")
        return 1

    if args.check:
        stale = [p for p, text in wanted.items()
                 if not p.is_file() or p.read_text() != text]
        if stale:
            print("the help document is out of date:")
            for path in stale:
                print(f"  {path.relative_to(ROOT)}")
            print("run: python3 tools/build_help.py")
            return 1
        print(f"help document current: {len(entries)} entries in "
              f"{len(sections)} sections, "
              f"{sum(counts.values())} blocks the app can render")
        return 0

    args.out.parent.mkdir(parents=True, exist_ok=True)
    for path, text in wanted.items():
        path.write_text(text)
    print(f"wrote {args.out.with_suffix('.md').relative_to(ROOT)} and "
          f"{args.out.with_suffix('.html').name}: {len(entries)} entries in "
          f"{len(sections)} sections")
    return 0


if __name__ == "__main__":
    sys.exit(main())
