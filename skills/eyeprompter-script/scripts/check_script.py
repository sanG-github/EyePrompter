#!/usr/bin/env python3
"""Check a script against the EyePrompter format and summarise it.

Usage: python3 check_script.py <script.md> [--wpm 150]

Prints ERROR lines (must fix: the app will misbehave), WARN lines (likely
problems for reading aloud), then word count, reading time and the outline the
app will show. Exit code 1 if there is any ERROR.
"""
import re
import sys
import unicodedata

HEADING = re.compile(r"^\s*#{1,6}\s+\S")
NOTE_LINE = re.compile(r"^\s*\[[^\]\n]*\]\s*$")
NOTE_ANY = re.compile(r"\[[^\]\n]*\]")
SENT_END = re.compile(r"[.!?…]+[\"'”’)\]]*$")
EMOJI = re.compile("[\U0001F300-\U0001FAFF☀-➿⬀-⯿️]")

# Written forms the speech recogniser will never produce (it writes what is said).
SPOKEN = [
    (r"%", "% → 'phần trăm'"),
    (r"\s&\s", "& → 'và'"),
    (r"\$", "$ → 'đô'"),
    (r"(?<!\w)~\s*\d|≈", "~/≈ → 'khoảng'"),
    (r"→|=>|->", "→ / => → words ('thì', 'nên') or rephrase"),
    (r"\bTP\.?\s?HCM\b|\bHCM\b", "TP.HCM → 'Thành phố Hồ Chí Minh'"),
    (r"\b(vd|VD)\b", "vd → 'ví dụ'"),
    (r"\b(mn|mng)\b", "mn → 'mọi người'"),
    (r"\b(ko|kh|k)\b(?!\s*\d)", "k/ko → 'không'"),
    (r"\b(đc|dc)\b", "đc → 'được'"),
    (r"\d+\s?(tr|k)\b", "25tr / 50k → '25 triệu' / '50 nghìn'"),
    (r"\bvs\b", "vs → 'so với'"),
    (r"\betc\b", "etc → 'vân vân' or end the sentence"),
]
MARKDOWN = [
    (r"\*\*|__", "bold markers"),
    (r"^\s*[-*+•]\s+", "bullet"),
    (r"^\s*\d+[.)]\s+", "numbered list"),
    (r"`", "backticks"),
    (r"\[[^\]]*\]\([^)]*\)", "markdown link"),
    (r"^\s*\|.*\|\s*$", "table row"),
    (r"^\s*>", "blockquote"),
]


def words(text: str) -> list[str]:
    return [w for w in text.split() if re.search(r"\w", w)]


def main() -> int:
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return 2
    wpm = 150
    if "--wpm" in args:
        wpm = int(args[args.index("--wpm") + 1])
    path = args[0]
    text = open(path, encoding="utf-8").read().replace("\r\n", "\n")
    text = unicodedata.normalize("NFC", text)
    lines = text.split("\n")

    errors, warns = [], []

    def err(n, msg): errors.append(f"ERROR line {n}: {msg}")
    def warn(n, msg): warns.append(f"WARN  line {n}: {msg}")

    # Title
    first = next(((i, l) for i, l in enumerate(lines, 1) if l.strip()), None)
    title = None
    if not first:
        print("ERROR: file is empty")
        return 1
    if re.match(r"^\s*#\s+\S", first[1]) and not first[1].lstrip().startswith("##"):
        title = first[1].strip().lstrip("#").strip()
    else:
        err(first[0], "first line must be the title: '# Tên video'")

    spoken_words = 0
    outline = []
    para_sentences = 0
    para_start = None
    in_fence = False

    def close_paragraph(n):
        nonlocal para_sentences, para_start
        if para_start is not None and para_sentences > 3:
            warn(para_start, f"paragraph has {para_sentences} sentences (keep 1–3)")
        para_sentences, para_start = 0, None

    for n, raw in enumerate(lines, 1):
        line = raw.rstrip()
        if line.strip().startswith("```"):
            in_fence = not in_fence
            warn(n, "code fence inside the file (the app drops it on paste, but the .md should be clean)")
            continue
        if not line.strip():
            close_paragraph(n)
            continue
        if first and n == first[0] and title is not None:
            continue
        if HEADING.match(line):
            close_paragraph(n)
            level = len(line.strip()) - len(line.strip().lstrip("#"))
            name = line.strip().lstrip("#").strip()
            if level == 1:
                err(n, "second '# ' title — use '## ' for sections")
            elif level > 2:
                warn(n, f"'{'#' * level}' heading: use '## ' for sections")
            if len(words(name)) > 8:
                warn(n, f"section name has {len(words(name))} words/syllables (≤ 8 reads better in the outline)")
            outline.append(("section", name, n))
            continue
        if NOTE_LINE.match(line):
            continue

        # Spoken line
        if NOTE_ANY.search(line):
            warn(n, "[note] inside a spoken line — put notes on their own line")
        spoken = NOTE_ANY.sub(" ", line)
        for pattern, label in MARKDOWN:
            if re.search(pattern, line):
                err(n, f"markdown {label} — the app shows it literally")
        if EMOJI.search(spoken):
            err(n, "emoji — not spoken, remove it")
        for pattern, hint in SPOKEN:
            if re.search(pattern, spoken):
                warn(n, f"write as spoken: {hint}")
        sentences = [s for s in re.split(r"(?<=[.!?…])\s+", spoken.strip()) if s.strip()]
        for s in sentences:
            if len(words(s)) > 25:
                warn(n, f"sentence of {len(words(s))} words (≲ 25): '{s[:50]}…'")
        if para_start is None:
            para_start = n
            outline.append(("paragraph", " ".join(spoken.split()[:8]), n))
        para_sentences += len(sentences)
        if not SENT_END.search(spoken.strip()):
            # Only the last line of a paragraph must end a sentence.
            nxt = lines[n] if n < len(lines) else ""
            if not nxt.strip() or HEADING.match(nxt) or NOTE_LINE.match(nxt):
                warn(n, "paragraph does not end with . ? or ! (sentence jumps rely on it)")
        spoken_words += len(words(spoken))
    close_paragraph(len(lines))

    for e in errors:
        print(e)
    for w in warns:
        print(w)
    minutes = spoken_words / wpm if wpm else 0
    print()
    print(f"Title: {title or '(missing)'}")
    print(f"Spoken words: {spoken_words}  ·  ~{int(minutes)}:{int(round((minutes % 1) * 60)):02d} at {wpm} wpm")
    sections = [o for o in outline if o[0] == "section"]
    paragraphs = [o for o in outline if o[0] == "paragraph"]
    print(f"Outline: {len(sections)} sections, {len(paragraphs)} paragraphs")
    for kind, name, _ in outline:
        print(f"  § {name}" if kind == "section" else f"      · {name}…")
    print()
    print("RESULT:", "FAIL" if errors else ("OK with warnings" if warns else "OK"))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
