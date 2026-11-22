import Foundation

/// Sections (`## headings`) and paragraphs of a script, for jumping around.
struct OutlineItem: Identifiable, Hashable {
    enum Kind: Hashable { case heading, paragraph }
    let id: Int
    let kind: Kind
    let title: String
    /// First spoken word of this part.
    let tokenIndex: Int
}

enum ScriptOutline {
    static func build(text: String, tokens: [ScriptToken]) -> [OutlineItem] {
        let ns = text as NSString
        let headings = TextNormalizer.headingRanges(text)
        let notes = TextNormalizer.noteRanges(text)
        var items: [OutlineItem] = []

        func firstToken(from location: Int) -> Int? {
            tokens.firstIndex { $0.range.location >= location }
        }

        // Blocks separated by blank lines; a heading line is its own block.
        let blockRegex = try! NSRegularExpression(pattern: "[^\\n](?:.|\\n(?![ \\t]*\\n))*")
        for match in blockRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var cursor = match.range.location
            let end = NSMaxRange(match.range)
            // Headings inside the block (usually its first line).
            for h in headings where h.location >= match.range.location && h.location < end {
                let title = ns.substring(with: h).trimmingCharacters(in: CharacterSet(charactersIn: "# \t"))
                if let t = firstToken(from: NSMaxRange(h)) {
                    items.append(OutlineItem(id: items.count, kind: .heading, title: title, tokenIndex: t))
                }
                cursor = max(cursor, NSMaxRange(h))
            }
            // The spoken paragraph (skip blocks that are only notes / headings).
            guard let t = firstToken(from: cursor), tokens[t].range.location < end else { continue }
            if notes.contains(where: { NSLocationInRange(tokens[t].range.location, $0) }) { continue }
            let preview = tokens[t..<min(tokens.count, t + 9)]
                .filter { $0.range.location < end }
                .map(\.text).joined(separator: " ")
            // A paragraph right after a heading starts at the same word: keep both, the
            // heading is the section, the paragraph line shows its first words.
            items.append(OutlineItem(id: items.count, kind: .paragraph, title: preview, tokenIndex: t))
        }
        return items
    }

    /// Index of the item the reader is in.
    static func current(_ items: [OutlineItem], cursor: Int) -> Int? {
        items.lastIndex { $0.kind == .paragraph && $0.tokenIndex <= cursor }
    }
}
