#!/usr/bin/env python3
"""Line-coverage report for `./run-tests.sh --coverage`.

Shell coverage has no off-the-shelf tool that works here (see bash_env.sh), so
this file owns both halves of it: the hits come from the DEBUG traps, and the
denominator -- which lines are statements at all -- comes from classify() below.
Python and JavaScript numbers come from coverage.py and c8 and are only merged
into the table.

    report.py <repo-root> <cov-dir> [--missing]
"""
import json
import os
import re
import sys

# Every shell file that ships. run-tests.sh and test/ are the harness, not the
# product. ada.sh is zsh; the classifier handles the subset of syntax it uses.
SHELL_FILES = [
    "ada-install.sh",
    "ada-menubar.sh",
    "ada-paseo-watch.sh",
    "ada.sh",
    "lib/ada-claude-hook.sh",
    "lib/ada-history.sh",
    "lib/ada-mute.sh",
    "lib/ada-notify.sh",
    "lib/ada-pause.sh",
    "lib/ada-show-alert.sh",
    "lib/ada-stage.sh",
    "lib/ada-status.sh",
    "release.sh",
]

HEREDOC = re.compile(r"<<(-?)\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\2")
FUNC_HEADER = re.compile(
    r"^(function\s+[A-Za-z_][\w:.-]*(\s*\(\s*\))?|[A-Za-z_][\w:.-]*\s*\(\s*\)|\(\s*\))\s*[{(]?\s*$"
)
# Words that only shape control flow. The DEBUG trap never fires for a line made
# of nothing else, so counting one as a statement would make it a permanent miss.
STRUCTURAL = {"then", "else", "fi", "do", "done", "esac", "{", "}", "(", ")", ";;", ";&", ";;&", "in"}
REDIRECT = re.compile(r"^(\d*[<>]|&>)")


def statements(lines):
    """Split a shell file into logical statements: (start, end, code).

    A statement ends at a newline that is outside every quote, $(...), (...),
    ${...} and heredoc body, and not continued by a trailing backslash, &&, ||
    or |. That is what lets a `python3 -c '...'` block, an array literal, or a
    heredoc count as ONE statement instead of dozens of phantom misses. `code`
    is the first line with its comment removed, which is what classify() reads.
    """
    out = []
    stack = []          # sq dq ansi bt subst arith paren brace
    heredocs = []       # terminators still to read, in order
    start = None
    first_code = ""
    lineno = 0
    for lineno, raw in enumerate(lines, 1):
        line = raw.rstrip("\n")
        if heredocs:
            term, strip = heredocs[0]
            if (line.lstrip("\t") if strip else line) == term:
                heredocs.pop(0)
                if not heredocs and not stack:
                    out.append((start, lineno, first_code))
                    start = None
            continue
        code_end = len(line)
        cont = False
        j = 0
        n = len(line)
        while j < n:
            c = line[j]
            nxt = line[j + 1] if j + 1 < n else ""
            top = stack[-1] if stack else None
            if top == "sq":
                if c == "'":
                    stack.pop()
                j += 1
                continue
            if top == "ansi":
                if c == "\\":
                    j += 2
                    continue
                if c == "'":
                    stack.pop()
                j += 1
                continue
            if c == "\\":
                if j == n - 1:
                    cont = True
                j += 2
                continue
            if top == "bt":
                if c == "`":
                    stack.pop()
                j += 1
                continue
            if top == "dq":
                if c == '"':
                    stack.pop()
                elif c == "$" and nxt == "(":
                    stack.append("arith" if line[j + 2:j + 3] == "(" else "subst")
                    j += 3 if stack[-1] == "arith" else 2
                    continue
                elif c == "$" and nxt == "{":
                    stack.append("brace")
                    j += 2
                    continue
                elif c == "`":
                    stack.append("bt")
                j += 1
                continue
            # top is None, subst, arith, paren or brace: real shell syntax.
            if c == "#" and top != "brace" and (j == 0 or line[j - 1] in " \t;&|()"):
                code_end = j
                break
            if c == "'":
                stack.append("sq")
            elif c == "$" and nxt == "'":
                stack.append("ansi")
                j += 2
                continue
            elif c == '"':
                stack.append("dq")
            elif c == "`":
                stack.append("bt")
            elif c == "$" and nxt == "(":
                stack.append("arith" if line[j + 2:j + 3] == "(" else "subst")
                j += 3 if stack[-1] == "arith" else 2
                continue
            elif c == "$" and nxt == "{":
                stack.append("brace")
                j += 2
                continue
            elif c == "(":
                stack.append("paren")
            elif c == ")":
                if top in ("subst", "paren"):
                    stack.pop()
                elif top == "arith" and nxt == ")":
                    stack.pop()
                    j += 2
                    continue
                # otherwise an unmatched ")" closes a case pattern
            elif c == "}" and top == "brace":
                stack.pop()
            elif c == "<" and top not in ("arith",) and line[j:j + 3] != "<<<":
                m = HEREDOC.match(line, j)
                if m:
                    heredocs.append((m.group(3), m.group(1) == "-"))
                    j = m.end()
                    continue
            j += 1
        code = line[:code_end].rstrip()
        if start is None:
            if not code.strip() and not stack:
                continue
            start = lineno
            first_code = code.strip()
        if heredocs:
            continue
        if stack or cont or re.search(r"(&&|\|\||(?<!\|)\|)\s*$", code):
            continue
        out.append((start, lineno, first_code))
        start = None
    if start is not None:
        out.append((start, lineno, first_code))
    return out


def pattern_rest(code):
    """For a case-pattern line, the text after the pattern's closing paren."""
    depth = 0
    quote = None
    for i, c in enumerate(code):
        if quote:
            if c == quote:
                quote = None
        elif c in "'\"":
            quote = c
        elif c == "(":
            depth += 1
        elif c == ")":
            if depth == 0:
                return code[i + 1:]
            depth -= 1
    return ""


def is_structural(code):
    # Strip leading control words; whatever remains decides. A bare redirect
    # (`done < file`, `} >/dev/null 2>&1`) runs nothing the trap can see.
    rest = code
    while True:
        rest = rest.lstrip(" \t;")
        word = re.match(r"(;;&|;;|;&|[{}()]|[A-Za-z]+)", rest)
        if word and word.group(1) in STRUCTURAL and (
            len(rest) == len(word.group(1))
            or not rest[len(word.group(1))].isalnum()
        ):
            rest = rest[len(word.group(1)):]
            continue
        break
    rest = rest.strip()
    return rest == "" or bool(REDIRECT.match(rest))


def classify(lines):
    """Map each statement to executable or not, tracking case-pattern position."""
    result = []
    case_depth = 0
    expect_pattern = False
    for start, end, code in statements(lines):
        executable = True
        ends_arm = bool(re.search(r"(;;&|;;|;&)\s*$", code))
        if FUNC_HEADER.match(code):
            executable = False
        elif case_depth and re.match(r"esac\b", code):
            case_depth -= 1
            expect_pattern = False
            executable = not is_structural(code)
        elif case_depth and expect_pattern:
            rest = pattern_rest(code)
            executable = not is_structural(rest)
            expect_pattern = ends_arm
        else:
            executable = not is_structural(code)
            if case_depth and ends_arm:
                expect_pattern = True
        if re.match(r"case\b.*\bin$", code):
            case_depth += 1
            expect_pattern = True
        result.append((start, end, executable))
    return result


def shell_hits(root, cov_dir):
    """file -> set of line numbers that ran, keyed by the repo file's realpath.

    Two fixtures run a verbatim COPY of a repo script rather than the script
    itself: the Cellar-layout installer test (a real keg holds files, not
    symlinks) and the Paseo watcher's staging dir. A hit on a same-named file
    inside the bats temp dir (bats-run-*) is credited to the repo file. Every
    shipped script has a distinct basename, so the mapping is unambiguous.
    """
    by_name = {os.path.basename(rel): os.path.realpath(os.path.join(root, rel)) for rel in SHELL_FILES}
    hits = {}
    shell_dir = os.path.join(cov_dir, "shell")
    for name in os.listdir(shell_dir) if os.path.isdir(shell_dir) else []:
        with open(os.path.join(shell_dir, name), errors="replace") as fh:
            for rec in fh:
                path, _, line = rec.rstrip("\n").rpartition(":")
                if not line.isdigit():
                    continue
                real = os.path.realpath(path)
                if "/bats-run-" in path and os.path.basename(path) in by_name:
                    real = by_name[os.path.basename(path)]
                hits.setdefault(real, set()).add(int(line))
    return hits


def embedded_python(root, cov_dir):
    """rel shell file -> {file line: ran?} for the Python it embeds.

    bin/python3 saved every `python3 -c '...'` / `python3 - <<'PY'` program the
    suite ran as .cov/embedded/<hash>.py, and coverage.py measured those files.
    Each multi-line program is found verbatim in the shell script it came from
    (single-quoted strings and quoted heredocs are passed through unchanged),
    which turns its line k into file line start + k - 1. A program that never
    ran has no file here; its enclosing shell statement shows up as a miss.
    """
    path = os.path.join(cov_dir, "python.json")
    if not os.path.exists(path):
        return {}
    texts = {rel: open(os.path.join(root, rel)).read() for rel in SHELL_FILES}
    out = {}
    for name, f in json.load(open(path))["files"].items():
        if f"{os.sep}embedded{os.sep}" not in name or not os.path.exists(name):
            continue
        code = open(name).read()
        if code.count("\n") < 2:
            continue
        for rel, text in texts.items():
            idx = text.find(code)
            if idx < 0:
                continue
            base = text.count("\n", 0, idx) + 1
            lines = out.setdefault(rel, {})
            for n in f["executed_lines"]:
                lines[base + n - 1] = True
            for n in f["missing_lines"]:
                lines.setdefault(base + n - 1, False)
            break
    return out


def shell_rows(root, cov_dir):
    hits = shell_hits(root, cov_dir)
    embedded = embedded_python(root, cov_dir)
    rows = []
    for rel in SHELL_FILES:
        path = os.path.join(root, rel)
        with open(path) as fh:
            lines = fh.readlines()
        got = hits.get(os.path.realpath(path), set())
        covered, missing = 0, []
        stmts = [s for s in classify(lines) if s[2]]
        for start, end, _ in stmts:
            if any(start <= h <= end for h in got):
                covered += 1
            else:
                missing.append(start)
        # The embedded Python's own statements count alongside the shell ones.
        py = embedded.get(rel, {})
        covered += sum(1 for ran in py.values() if ran)
        missing += [n for n, ran in py.items() if not ran]
        rows.append((rel, covered, len(stmts) + len(py), sorted(missing)))
    return rows


def python_rows(root, cov_dir):
    path = os.path.join(cov_dir, "python.json")
    if not os.path.exists(path):
        return []
    data = json.load(open(path))
    rows = []
    for name, f in sorted(data["files"].items()):
        rel = os.path.relpath(os.path.join(root, name) if not os.path.isabs(name) else name, root)
        if not rel.startswith("lib/"):
            continue  # .cov/embedded programs are credited to their shell file
        s = f["summary"]
        rows.append((rel, s["covered_lines"], s["num_statements"], f["missing_lines"]))
    return rows


def js_rows(root, cov_dir):
    path = os.path.join(cov_dir, "js", "coverage-final.json")
    if not os.path.exists(path):
        return []
    rows = []
    for name, f in sorted(json.load(open(path)).items()):
        # c8 turns V8 byte ranges into one istanbul "statement" per source line,
        # blank lines and comments included, all marked covered unless they sit
        # in a range that never ran. Left in, they inflate the percentage, so
        # only lines with code on them count, same as the shell and python rows.
        code = code_lines(name)
        lines = {}
        for sid, loc in f["statementMap"].items():
            ln = loc["start"]["line"]
            if ln in code:
                lines[ln] = lines.get(ln, False) or f["s"][sid] > 0
        missing = sorted(ln for ln, ok in lines.items() if not ok)
        rows.append((os.path.relpath(name, root), len(lines) - len(missing), len(lines), missing))
    return rows


def swift_rows(root, cov_dir):
    """llvm-cov's lcov export: DA:<line>,<count> per executable line."""
    path = os.path.join(cov_dir, "swift.lcov")
    if not os.path.exists(path):
        return []
    files = {}
    current = None
    for rec in open(path):
        rec = rec.strip()
        if rec.startswith("SF:"):
            current = os.path.relpath(rec[3:], root)
            if not current.startswith("Sources/"):
                current = None
            else:
                files.setdefault(current, {})
        elif rec.startswith("DA:") and current:
            line, count = rec[3:].split(",")[:2]
            files[current][int(line)] = files[current].get(int(line), 0) + int(count)
    rows = []
    for rel, lines in sorted(files.items()):
        missing = sorted(n for n, c in lines.items() if c == 0)
        rows.append((rel, len(lines) - len(missing), len(lines), missing))
    return rows


def page_rows(root, cov_dir):
    """alert.html's inline script, from Playwright's V8 coverage entries.

    Each entry holds the script's source text and V8 block ranges as character
    offsets. The count at an offset is that of the innermost range containing
    it; a code line counts as run when the count at its first non-blank
    character is non-zero in any test. The source is located inside alert.html
    so the rows carry the page's own line numbers.
    """
    page_dir = os.path.join(cov_dir, "page")
    html_path = os.path.join(root, "alert.html")
    if not os.path.isdir(page_dir) or not os.listdir(page_dir):
        return []
    html = open(html_path).read()
    covered, code = set(), set()
    for name in sorted(os.listdir(page_dir)):
        for entry in json.load(open(os.path.join(page_dir, name))):
            source = entry.get("source", "")
            base = html.find(source) if source else -1
            if base < 0:
                continue
            base_line = html.count("\n", 0, base)
            ranges = [(r["startOffset"], r["endOffset"], r["count"])
                      for f in entry["functions"] for r in f["ranges"]]
            offset = 0
            in_block = False
            for i, line in enumerate(source.split("\n")):
                s = line.strip()
                start = offset + (len(line) - len(line.lstrip()))
                offset += len(line) + 1
                if in_block:
                    in_block = "*/" not in s
                    continue
                if s.startswith("/*"):
                    in_block = "*/" not in s
                    continue
                if not s or s.startswith("//"):
                    continue
                n = base_line + i + 1
                code.add(n)
                inner = [r for r in ranges if r[0] <= start < r[1]]
                if inner and min(inner, key=lambda r: r[1] - r[0])[2] > 0:
                    covered.add(n)
    if not code:
        return []
    return [("alert.html (script)", len(covered & code), len(code), sorted(code - covered))]


def code_lines(path):
    """Line numbers of a JS file that hold code, not just a comment or nothing."""
    out = set()
    in_block = False
    with open(path) as fh:
        for n, line in enumerate(fh, 1):
            s = line.strip()
            if in_block:
                if "*/" not in s:
                    continue
                in_block = False
                s = s.split("*/", 1)[1].strip()
            if s.startswith("/*"):
                if "*/" not in s:
                    in_block = True
                    continue
                s = s.split("*/", 1)[1].strip()
            if s and not s.startswith("//"):
                out.add(n)
    return out


def main():
    root, cov_dir = sys.argv[1], sys.argv[2]
    show_missing = "--missing" in sys.argv
    groups = [
        ("shell", shell_rows(root, cov_dir)),
        ("python", python_rows(root, cov_dir)),
        ("javascript", js_rows(root, cov_dir)),
        ("page", page_rows(root, cov_dir)),
        ("swift", swift_rows(root, cov_dir)),
    ]
    width = max(len(r[0]) for _, rows in groups for r in rows) + 2
    tot_c = tot_n = 0
    print(f"{'file':<{width}}{'lines':>8}{'hit':>7}{'cover':>9}")
    for label, rows in groups:
        if not rows:
            print(f"-- {label}: no data")
            continue
        gc = sum(r[1] for r in rows)
        gn = sum(r[2] for r in rows)
        tot_c += gc
        tot_n += gn
        for rel, c, n, missing in rows:
            pct = 100.0 * c / n if n else 100.0
            print(f"{rel:<{width}}{n:>8}{c:>7}{pct:>8.1f}%")
            if show_missing and missing:
                print(f"{'':<4}missing: {compress(missing)}")
        print(f"{'  ' + label + ' total':<{width}}{gn:>8}{gc:>7}{100.0 * gc / gn:>8.1f}%")
    if tot_n:
        print(f"{'TOTAL':<{width}}{tot_n:>8}{tot_c:>7}{100.0 * tot_c / tot_n:>8.1f}%")


def compress(nums):
    out = []
    for n in sorted(nums):
        if out and n == out[-1][1] + 1:
            out[-1][1] = n
        else:
            out.append([n, n])
    return ", ".join(str(a) if a == b else f"{a}-{b}" for a, b in out)


if __name__ == "__main__":
    main()
