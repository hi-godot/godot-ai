"""Lint: GDScript does not support Python-style implicit adjacent-string concat.

Hit three times in recent PRs (#236, twice in #243): the pattern looks fine to
anyone with Python muscle memory, but lands as a parse error in GDScript:

    assert_false(cond,
        "first half - "
        "second half")          # parse error in GDScript

The CI `--import` log scan in `script/ci-check-gdscript` does catch this — but
only after a push round-trip, and only if the failed file actually loads. This
test runs at `pytest` time and walks every `.gd` file under `plugin/` and
`test_project/tests/`, so the regression is caught locally before the commit.

The detector is a small purpose-built tokenizer (no third-party dependency):
it tracks paren/bracket depth and flags any two string literals that appear
back-to-back inside `()` / `[]` / `{}` with only whitespace and comments
between them. It deliberately does not flag adjacent strings outside parens
(e.g. consecutive `match` cases) because GDScript newlines end statements
there, so adjacency is not a parse hazard.

See issue #246.
"""

from __future__ import annotations

from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCAN_ROOTS = (
    REPO_ROOT / "plugin" / "addons" / "godot_ai",
    REPO_ROOT / "test_project" / "tests",
)


def _find_adjacent_string_pairs(text: str) -> list[tuple[tuple[int, int], tuple[int, int]]]:
    """Return ((prev_line, prev_col), (cur_line, cur_col)) for each offending pair.

    A pair is only reported when both string literals occur with paren/bracket
    depth > 0 — outside parens, GDScript ends the statement at the newline and
    adjacent strings are independent expressions, not a concat hazard.
    """
    n = len(text)
    i = 0
    prev_string_loc: tuple[int, int] | None = None
    paren_depth = 0
    hits: list[tuple[tuple[int, int], tuple[int, int]]] = []

    def loc(pos: int) -> tuple[int, int]:
        line = text.count("\n", 0, pos) + 1
        col = pos - (text.rfind("\n", 0, pos) + 1) + 1
        return line, col

    while i < n:
        c = text[i]
        if c in " \t\r\n":
            i += 1
            continue
        if c == "#":
            while i < n and text[i] != "\n":
                i += 1
            continue
        if c in "([{":
            paren_depth += 1
            prev_string_loc = None
            i += 1
            continue
        if c in ")]}":
            # Clamp at 0 so the lint stays useful on partially-edited / malformed
            # files instead of underflowing into a negative depth that would
            # silently disable the in-parens check for the rest of the file.
            paren_depth = max(0, paren_depth - 1)
            prev_string_loc = None
            i += 1
            continue
        # GDScript string prefixes: r"..." (raw), &"..." (StringName),
        # ^"..." (NodePath). The prefix char must be immediately followed by
        # an opening quote — otherwise it is just an identifier starting with
        # that letter (e.g. `return`, `range`).
        prefix_len = 0
        if c in ("r", "&", "^") and i + 1 < n and text[i + 1] in ('"', "'"):
            prefix_len = 1
        q_start = i + prefix_len
        if q_start < n and text[q_start] in ('"', "'"):
            q = text[q_start]
            if text[q_start : q_start + 3] == q * 3:
                # Triple-quoted strings do not honor backslash-escaping for the
                # closing quote in GDScript, so a plain `find` is sufficient.
                end = text.find(q * 3, q_start + 3)
                end = (end + 3) if end != -1 else n
            else:
                j = q_start + 1
                while j < n:
                    ch = text[j]
                    if ch == "\\":
                        j += 2
                        continue
                    if ch == q:
                        j += 1
                        break
                    if ch == "\n":
                        # Unterminated single-line string; stop tokenizing this
                        # span without crashing the lint pass.
                        break
                    j += 1
                end = j
            tok_loc = loc(i)
            if prev_string_loc is not None and paren_depth > 0:
                hits.append((prev_string_loc, tok_loc))
            prev_string_loc = tok_loc
            i = end
            continue
        prev_string_loc = None
        i += 1

    return hits


def test_no_python_style_adjacent_string_concat_in_gdscript() -> None:
    """No `.gd` file may contain two string literals adjacent inside parens.

    Acceptance criterion from issue #246: a structural scan that runs at lint
    time (i.e. in `pytest`) and points at the offending file:line pair, so the
    contributor sees the bug before pushing — not after CI's `--import` round-
    trip flags it.
    """
    offenders: list[str] = []
    for root in SCAN_ROOTS:
        assert root.exists(), f"Lint root does not exist: {root}"
        for path in sorted(root.rglob("*.gd")):
            text = path.read_text(encoding="utf-8")
            for prev, cur in _find_adjacent_string_pairs(text):
                rel = path.relative_to(REPO_ROOT)
                offenders.append(
                    f"{rel}:{cur[0]}:{cur[1]}  (string at line {prev[0]} is "
                    f"adjacent to string at line {cur[0]} inside a parenthesised "
                    f"expression — GDScript parse error)"
                )

    assert not offenders, (
        "GDScript does not support Python-style implicit adjacent-string "
        "concat. Use explicit `+` or merge the literals onto one line.\n"
        "Offenders:\n  " + "\n  ".join(offenders)
    )


# --- detector self-tests: pin the tokenizer's behavior so a future refactor
# cannot quietly weaken the lint into a no-op (which is how a "lint added but
# not actually firing" regression slips through). ---


def test_detector_flags_canonical_multiline_bug_pattern() -> None:
    """The exact shape from PR #236 must be detected."""
    src = (
        "assert_false(cond,\n"
        '    "first half - "\n'
        '    "second half")\n'
    )
    hits = _find_adjacent_string_pairs(src)
    assert len(hits) == 1, f"expected 1 hit, got {hits}"
    (prev_line, _), (cur_line, _) = hits[0]
    assert prev_line == 2 and cur_line == 3


def test_detector_flags_same_line_adjacent_strings() -> None:
    """A single-line `foo("a" "b")` is also a parse error and must be flagged."""
    assert _find_adjacent_string_pairs('foo("a" "b")') != []


def test_detector_ignores_explicit_plus_concat() -> None:
    """Explicit `+` between strings is the supported form and must not flag."""
    src = 'foo("a" +\n    "b")\n'
    assert _find_adjacent_string_pairs(src) == []


def test_detector_ignores_comma_separated_args() -> None:
    """Two string args separated by `,` are independent — not a concat hazard."""
    src = 'foo("a",\n    "b")\n'
    assert _find_adjacent_string_pairs(src) == []


def test_detector_ignores_match_block_adjacent_cases() -> None:
    """Adjacent `match` cases share no expression context and must not flag.

    `_path_template.gd::_os_key` is the in-tree shape this guards: consecutive
    `"darwin": / "windows":` cases sit at paren_depth=0, so the tokenizer must
    not treat them as a parenthesised concat pair.
    """
    src = (
        "match OS.get_name():\n"
        '    "macOS":\n'
        '        return "darwin"\n'
        '    "Windows":\n'
        '        return "windows"\n'
    )
    assert _find_adjacent_string_pairs(src) == []


def test_detector_handles_triple_quoted_strings_with_embedded_quotes() -> None:
    """Triple-quoted strings can contain `"`; the tokenizer must not desync."""
    src = 'var s := """hello "world" again"""\n'
    assert _find_adjacent_string_pairs(src) == []


def test_detector_does_not_treat_return_as_a_string_prefix() -> None:
    """`return "x"` starts with `r`; `r` is a string-prefix only before a quote."""
    src = 'func f() -> String:\n    return "x"\n'
    assert _find_adjacent_string_pairs(src) == []


def test_detector_flags_prefixed_adjacent_strings() -> None:
    """`r"a" "b"` inside a call is still a hazard."""
    assert _find_adjacent_string_pairs('foo(r"a"\n    "b")') != []
