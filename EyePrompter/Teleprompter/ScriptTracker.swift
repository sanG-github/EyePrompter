import Foundation

/// One spoken unit of the script (a whitespace-separated word / Vietnamese syllable).
struct ScriptToken {
    let text: String
    /// Lowercased, diacritic-folded, punctuation-free form used for matching.
    let norm: String
    /// Range in the original script string (UTF-16, for UIKit).
    let range: NSRange
}

enum TextNormalizer {
    static func normalize(_ s: String) -> String {
        var t = s.lowercased()
        t = t.replacingOccurrences(of: "đ", with: "d")
        t = t.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
        return String(String.UnicodeScalarView(t.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }

    /// `[ghi chú]` — stage directions / B-roll notes: shown dimmed, never spoken.
    static func noteRanges(_ text: String) -> [NSRange] {
        let regex = try! NSRegularExpression(pattern: "\\[[^\\]\\n]*\\]")
        return regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).map(\.range)
    }

    /// `## Phần 1` — section headings: shown as small titles, never spoken.
    static func headingRanges(_ text: String) -> [NSRange] {
        let regex = try! NSRegularExpression(pattern: "(?m)^[ \\t]*#{1,6}[ \\t]+[^\\n]*$")
        return regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).map(\.range)
    }

    static func tokenize(_ text: String) -> [ScriptToken] {
        let ns = text as NSString
        let regex = try! NSRegularExpression(pattern: "\\S+")
        let notes = noteRanges(text) + headingRanges(text)
        var out: [ScriptToken] = []
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if notes.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) { continue }
            let word = ns.substring(with: m.range)
            let n = normalize(word)
            if n.isEmpty { continue }
            out.append(ScriptToken(text: word, norm: n, range: m.range))
        }
        return out
    }

    static func words(_ hypothesis: String) -> [String] {
        hypothesis.split(whereSeparator: { $0.isWhitespace }).map { normalize(String($0)) }.filter { !$0.isEmpty }
    }
}

/// Follows the reader through the script by aligning the tail of the live speech
/// transcript against a window of script words around the current position.
///
/// The alignment is a small Smith–Waterman local alignment, so skipped words,
/// ad-libs, mis-recognised syllables and fast reading all still land on the
/// right spot. Large jumps (skipping a paragraph, re-reading) need more
/// consecutive evidence than small forward steps.
final class ScriptTracker {
    let tokens: [ScriptToken]
    /// Index of the next token the reader has not spoken yet.
    private(set) var cursor: Int = 0

    /// How many recent recognised words are aligned.
    var tailLength = 10
    /// How far behind / ahead of the cursor we look.
    /// Far enough back to catch "let me read that sentence / paragraph again".
    var lookBehind = 60
    /// Auto-rewind when the reader goes back to re-read (can be turned off).
    var allowRewind = true
    var lookAhead = 90

    init(text: String) {
        tokens = TextNormalizer.tokenize(text)
    }

    var progress: Double { tokens.isEmpty ? 0 : Double(cursor) / Double(tokens.count) }
    var isFinished: Bool { cursor >= tokens.count }

    /// Recognised words at the start of the current hypothesis that belong to
    /// before a manual jump; they must not drag the cursor back to where it was.
    private var ignoredWords = 0
    private var lastWordCount = 0

    /// Set when the last ingest moved the cursor backwards (re-reading).
    private(set) var lastMoveWasRewind = false

    /// A big or backward move seen once, waiting for the next hypothesis to agree.
    private var pending: Int?

    func jump(to index: Int) {
        cursor = min(max(0, index), tokens.count)
        ignoredWords = lastWordCount
        pending = nil
    }

    /// Start of the sentence containing `index` (token after the last . ! ? … or paragraph).
    func sentenceStart(before index: Int) -> Int {
        var i = min(max(0, index), tokens.count) - 1
        while i >= 0 {
            if let last = tokens[i].text.last, ".!?…".contains(last) { return i + 1 }
            i -= 1
        }
        return 0
    }

    /// Feed the full current hypothesis of the recogniser. Returns true when the cursor moved.
    @discardableResult
    func ingest(hypothesis: String) -> Bool {
        var rec = TextNormalizer.words(hypothesis)
        // A new recognition task starts from an empty hypothesis.
        if rec.count < lastWordCount || rec.count < ignoredWords { ignoredWords = 0 }
        lastWordCount = rec.count
        rec = Array(rec.dropFirst(ignoredWords))
        guard !rec.isEmpty, !tokens.isEmpty else { return false }
        let tail = Array(rec.suffix(tailLength))
        let lo = max(0, cursor - lookBehind)
        let hi = min(tokens.count, cursor + lookAhead)
        guard hi > lo else { return false }
        let window = tokens[lo..<hi].map(\.norm)
        let n = tail.count, m = window.count

        var sim = Array(repeating: Array(repeating: 0.0, count: m), count: n)
        for i in 0..<n { for j in 0..<m { sim[i][j] = Self.similarity(tail[i], window[j]) } }

        // Local alignment + run length of consecutive matches (R).
        var H = Array(repeating: Array(repeating: 0.0, count: m + 1), count: n + 1)
        var R = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        let gap = 0.8
        for i in 1...n {
            for j in 1...m {
                let s = sim[i - 1][j - 1]
                let diag = H[i - 1][j - 1] + (s > 0 ? s : -1.0)
                H[i][j] = max(0, diag, H[i - 1][j] - gap, H[i][j - 1] - gap)
                R[i][j] = s > 0 ? R[i - 1][j - 1] + 1 : 0
            }
        }

        // The alignment must end on one of the newest recognised words, on a matching cell.
        var bestCursor = -1
        var bestScore = -Double.infinity
        var bestRaw = 0.0
        // Phrases that repeat in the script ("các bạn hãy", "mình sẽ") are ambiguous:
        // never jump far (either way) to a place whose last 3 words also occur elsewhere nearby.
        func phraseKey(_ j: Int) -> String? {
            guard j >= 3 else { return nil }
            return window[(j - 3)..<j].joined(separator: " ")
        }
        var phraseCount: [String: Int] = [:]
        if m >= 3 { for j in 3...m { if let key = phraseKey(j) { phraseCount[key, default: 0] += 1 } } }
        func isAmbiguous(_ j: Int) -> Bool {
            guard let key = phraseKey(j) else { return true }
            return (phraseCount[key] ?? 0) > 1
        }

        // How many of the newest recognised words (up to 4, fillers skipped) match the
        // script in order, ending at (i, j). Robust "is this really where we are" check.
        func support(_ i: Int, _ j: Int) -> Int {
            var count = 1, ti = i - 2, sj = j - 2
            while ti >= max(0, i - 4), sj >= max(0, j - 5) {
                if sim[ti][sj] > 0 { count += 1; ti -= 1; sj -= 1 }
                else if ti > 0, sj > 0, sim[ti - 1][sj] > 0 { ti -= 1 }   // filler / ad-lib in speech
                else { sj -= 1 }                                            // skipped script word
            }
            return count
        }

        for i in max(1, n - 2)...n {
            for j in 1...m where sim[i - 1][j - 1] > 0 {
                let raw = H[i][j]
                guard raw > 0 else { continue }
                // window[j-1] == tokens[lo + j - 1] was just spoken. No speculative lead when the
                // newest word is unmatched: it is usually a mis-heard or still-changing word.
                let candidate = min(tokens.count, lo + j)
                let jump = candidate - cursor
                guard Self.isConvincing(raw: raw, jump: jump) else { continue }
                // Moving more than one word needs the newest words to match the script
                // *in sequence*; a lone filler ("bạn", "là") matching far ahead does not count.
                if (jump > 2 || jump < 0), R[i][j] < 2, support(i, j) < 2 { continue }
                if abs(jump) > 4, isAmbiguous(j) { continue }
                if jump < 0 {
                    guard allowRewind else { continue }
                    // Going back further than the current/previous sentence needs a long, exact phrase.
                    if jump < -25, raw < 8 || R[i][j] < 4 { continue }
                }
                // Prefer nearby positions; going back is penalised less per word than
                // skipping ahead, since re-reading a sentence is a normal thing to do.
                var score = raw - (jump > 0 ? 0.04 : 0.025) * Double(abs(jump))
                if i == n { score += 0.3 } else if i == n - 2 { score -= 0.3 }
                if score > bestScore {
                    bestScore = score
                    bestCursor = candidate
                    bestRaw = raw
                }
            }
        }
        guard bestCursor >= 0, bestCursor != cursor else { pending = nil; return false }
        // Recogniser partials get revised all the time. A backward move, or a long jump
        // ahead without overwhelming evidence, must be seen in two consecutive
        // hypotheses before the prompter follows it — this removes the flicker.
        let jumpSize = bestCursor - cursor
        if jumpSize < 0 || (jumpSize > 6 && bestRaw < 9) {
            if let p = pending, abs(p - bestCursor) <= 3 {
                pending = nil
            } else {
                pending = bestCursor
                return false
            }
        } else {
            pending = nil
        }
        lastMoveWasRewind = bestCursor < cursor
        cursor = bestCursor
        return true
    }

    private static func isConvincing(raw: Double, jump: Int) -> Bool {
        switch jump {
        case 0: return false
        case 1: return raw >= 2.0          // the very next word: one clear word is enough
        case 2...4: return raw >= 3.0      // a little further: two words in sequence
        case 5...20: return raw >= 4.0     // ~2 words in sequence
        case 21...: return raw >= 6.0      // skipped ahead: need a solid phrase
        case -2 ... -1: return false       // tiny corrections: not worth a visible step back
        default: return raw >= 5.5         // going back (re-reading): ~3 words in sequence
        }
    }

    static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return a.count <= 2 ? 1.0 : 2.0 }
        let la = a.count, lb = b.count
        guard min(la, lb) >= 4 else { return 0 }
        if a.hasPrefix(b) || b.hasPrefix(a) { return 1.2 }
        let limit = max(la, lb) >= 7 ? 2 : 1
        return levenshtein(a, b, limit: limit) <= limit ? 1.2 : 0
    }

    static func levenshtein(_ a: String, _ b: String, limit: Int) -> Int {
        let x = Array(a), y = Array(b)
        if abs(x.count - y.count) > limit { return limit + 1 }
        var prev = Array(0...y.count)
        var cur = prev
        for i in 1...x.count {
            cur[0] = i
            var rowMin = cur[0]
            for j in 1...y.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
                rowMin = min(rowMin, cur[j])
            }
            if rowMin > limit { return limit + 1 }
            swap(&prev, &cur)
        }
        return prev[y.count]
    }
}
