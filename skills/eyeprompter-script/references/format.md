# EyePrompter script format — full spec

How the app (`~/Desktop/VideoDemo/EyePrompter`) parses a script, so you can reason about edge cases.

## Parsing rules (what the app actually does)

| Element | Syntax | App behaviour |
|---|---|---|
| Title | first non-empty line starting with exactly one `#` + space | Used as the script name; removed from the body. A first line starting `##` is a section, not a title. |
| Section | line `## …` (regex `^\s*#{1,6}\s+.*$`) | Shown as a small yellow heading; not tracked by speech; listed in the outline ("Mục lục"). |
| Note | `[ … ]` on one line (no `]` or newline inside) | Shown small, italic, dimmed blue; skipped by speech tracking. |
| Paragraph | text block separated by a blank line | One outline entry; target of "Đoạn trước / Đoạn sau". |
| Sentence | ends with `.` `!` `?` `…` | "↺ Câu" jumps to the start of the current sentence. |
| Word | any run of non-spaces | Matched against speech after lower-casing, removing accents and punctuation (`đ`→`d`). |
| Code fences | lines starting with ``` | Dropped on paste (so pasting a chat code block works). |

Markdown files (`.md`) imported by AirDrop/Files additionally get `**`, `__`, leading bullets,
`[text](link)` → `text` and backticks stripped, and `###`+ headings turned into plain text. Don't
rely on that — deliver a clean script.

## Why "write it as spoken" matters

The tracker compares what the recogniser *hears* with the script words. Vietnamese dictation writes
what was said: "phần trăm", "Thành phố Hồ Chí Minh", "ví dụ". A script that says `%`, `TP.HCM`,
`vd` has words that never match, so the prompter stalls there or jumps. Numbers: dictation usually
outputs digits for ordinary numbers, so keep `2026`, `15`, `3,5`; spell out unusual readings
(`1/2` → `một nửa`, `x2` → `gấp đôi`, `24/7` → `hai bốn trên bảy` or rephrase).

Common replacements (Vietnamese):

| Written | Spoken form |
|---|---|
| `mn`, `mng` | mọi người |
| `vd`, `VD` | ví dụ |
| `k`, `ko`, `kh` | không |
| `đc`, `dc` | được |
| `tr` (money) | triệu |
| `k` (money, 50k) | nghìn (50 nghìn) |
| `TP.HCM`, `HCM` | Thành phố Hồ Chí Minh |
| `HN` | Hà Nội |
| `%` | phần trăm |
| `&`, `+` (and) | và |
| `$5`, `5$` | 5 đô |
| `~`, `≈` | khoảng |
| `→`, `=>` | thì / nên / dẫn đến (or rephrase) |
| `/` (or) | hoặc |
| `vs` | so với |
| `etc`, `...` at list end | vân vân, or end the sentence |

English abbreviations that are read letter by letter (AI, CEO, USB) stay as they are.

## Section naming

Short and scannable in a list: `## Hook`, `## Mở đầu`, `## Phần 1: Ánh mắt`, `## Mẹo 2`, `## Kết`,
`## Kêu gọi đăng ký`. ≤ 8 syllables/words, no trailing punctuation.

## Notes

- One note per line, between paragraphs: `[B-roll: phố cổ Hà Nội]`, `[cười]`, `[cầm sản phẩm lên]`,
  `[chuyển cảnh]`, `[màn hình: mở app]`, `[beat 3 · face+graphic]`.
- Keep them short; the reader glances at them while talking.
- A note inside a sentence is legal for the app but breaks the reading line — move it out.

## Length

~150 words per minute is a comfortable Vietnamese talking-head pace (130 slow, 180 fast).
The checker reports spoken words (notes and headings excluded) and minutes at 150 wpm.
