---
name: eyeprompter-script
description: Write a talking-head script, or convert any existing script / outline / beat table / notes / doc, into the EyePrompter teleprompter format (the user's own iPhone app — "# Title", "## Section" headings for the outline, spoken lines only, [notes] for anything not said aloud, written exactly as it is read) and hand back a ready-to-import .md file plus a copy-paste block. Use this whenever the user wants a script to read on camera, a teleprompter / prompter / "chữ chạy" text, "kịch bản để đọc", "chuyển kịch bản sang EyePrompter", "format lại kịch bản để quay", a hook or intro to read, or has just written / approved a video script (e.g. a youtube-capcut-video beat table) and is about to film it — even if they don't name EyePrompter. Vietnamese or any language.
---

# EyePrompter script

EyePrompter is the user's iPhone teleprompter (`~/Desktop/VideoDemo/EyePrompter`). It listens to the
reader's voice and follows them word by word, shows `## sections` in a jump-to outline, and dims
`[notes]`. Everything below exists because of how that app reads a script — knowing *why* lets you
make good calls on scripts these rules don't foresee.

## Two jobs

1. **Convert** — the user gives a script in any shape (Word/Google Doc text, Markdown with bullets,
   a youtube-capcut-video beat table, a transcript, rough notes that are already the words to say).
   Keep their words. Your job is the format, not rewriting the content.
2. **Write** — the user gives a topic, outline, or bullet notes and wants a script to read.
   Write in their voice (casual, first person "mình"/"tôi" as they use it, talking *to* "các bạn"),
   then deliver it in the same format. Ask about length only if nothing hints at it; otherwise
   default to ~2–4 minutes (≈300–600 spoken words at ~150 words/min).

If it is unclear which one they want (notes that could be either the words or a brief), ask once.

## The format (and why)

Full spec with edge cases: `references/format.md`. The essentials:

- **First line `# Title`** — becomes the script's name in the app; not shown while reading.
- **`## Section` lines** for the parts of the video (Hook, Phần 1…, Kết, CTA). The app builds its
  jump-to outline from them and never waits for them to be read. Short: ≤ 8 syllables/words. Use them whenever
  the video has more than one part; skip them for a short single-part script.
- **Only spoken words in the body.** Anything not said aloud — B-roll, camera moves, actions,
  on-screen text, emotions, timings, beat ids — goes in `[square brackets]` **on its own line**.
  The app dims these and does not wait for them; inline brackets in the middle of a sentence break
  the reader's flow, so keep notes on their own lines between paragraphs.
- **Paragraphs of 1–3 sentences, one blank line between them.** Paragraphs are the outline entries
  and the unit of "đoạn trước / đoạn sau".
- **Short sentences (≲ 25 words), each ending in `.` `?` or `!`.** The app's "↺ Câu" button jumps to
  the start of the sentence, and the column on screen is only a few words wide — long sentences
  become a wall of text the eyes have to sweep.
- **Write it as it is spoken.** The speech recogniser hears words, not symbols, and matches what it
  hears against the script: `TP.HCM` → `Thành phố Hồ Chí Minh`, `vd` → `ví dụ`, `k` → `không`,
  `%` → `phần trăm`, `&` → `và`, `$5` → `5 đô`, `→` → words or nothing. Keep digits for numbers read
  the normal way (2026, 15, 3,5). Keep English names in their usual spelling (YouTube, iPhone, AI).
- **No other markup**: no `**bold**`, bullets, numbering, tables, links, emoji. Turn a list into
  spoken sentences ("Thứ nhất, … Thứ hai, …").
- **Converting: keep meaning, tone and language.** Fix obvious typos only. Don't add, cut or
  summarise ideas; if something is clearly a stage direction, move it into a `[note]`.

## Workflow

1. Get the source (pasted text, a file path, or a script you wrote earlier in the conversation).
   For a youtube-capcut-video beat table: the spoken line of each beat is the body; the beat id,
   mode (face / graphic / B-roll / screen) and visual go into a `[note]` before that line; its
   chapters/parts become `## sections`.
2. Produce the script in the format above.
3. Save it as `<slug>.md` — next to the source file if there is one, otherwise in
   `./eyeprompter-scripts/` (create it). Slug: lowercase ASCII, hyphens (strip Vietnamese accents).
4. Run the checker that ships with this skill (`scripts/check_script.py` in this skill's folder —
   `~/.claude/skills/eyeprompter-script/` on this Mac) and fix every ERROR, plus WARNs that are
   real problems:
   ```bash
   python3 <skill-folder>/scripts/check_script.py <file.md>
   ```
   It also prints the word count, estimated reading time and the outline the app will show.
5. Hand over:
   - the file path (clickable),
   - the whole script in ONE ```text block so it can be copied on the Mac and pasted on the iPhone,
   - one line on importing: copy → in EyePrompter tap **Dán** (Universal Clipboard), or AirDrop the
     `.md` file → open with EyePrompter,
   - the checker's duration + outline summary.

## Example

Source (Markdown notes the user already wrote as the words to say):

```
**Intro** – chào mn, hôm nay mình review iPhone 17 (giá ~25tr)
- pin: trâu hơn 20%
- camera: đẹp hơn, nhất là ban đêm
(chèn b-roll unbox)
Outro: like & sub nha
```

Output:

```text
# Review iPhone 17

## Mở đầu
Chào mọi người. Hôm nay mình review iPhone 17, giá khoảng 25 triệu đồng.

[B-roll: mở hộp]

## Pin và camera
Thứ nhất là pin. Pin trâu hơn khoảng 20 phần trăm.

Thứ hai là camera. Ảnh đẹp hơn, nhất là khi chụp ban đêm.

## Kết
Nếu thấy video hữu ích, các bạn nhớ like và đăng ký kênh nhé.
```

Note what changed and why: abbreviations and symbols spelled out (`mn`, `~`, `tr`, `%`, `&`), the
bullets became spoken sentences, the stage direction became its own `[note]` line, the parts became
`## sections`, and nothing about the content was invented.
