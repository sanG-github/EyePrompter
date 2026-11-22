import SwiftUI
import UIKit

/// The scrolling script.
///
/// UITextView adjusts its own contentOffset whenever its text storage changes
/// (colour updates) or it thinks something should be "visible", which showed up
/// as the text flashing to another passage for a frame. `LockedTextView` ignores
/// every offset change that does not come from our own code; user scrolling is
/// replaced by our own pan gesture.
///
/// Speech gives a word index (`cursor`) in irregular bursts; `ReadingPacer`
/// turns it into continuous motion at the reader's pace. Drag the text to pick a
/// reading position by hand (the line at the yellow ▶ becomes the next words),
/// or tap a word.
struct PrompterTextView: UIViewRepresentable {
    let text: String
    let tokens: [ScriptToken]
    let cursor: Int
    let fontSize: CGFloat
    let centered: Bool
    let anchorY: CGFloat
    /// The reader picked a position (tap on a word, or drag + release).
    var onPickToken: (Int) -> Void
    /// Estimated reading pace, words per minute (called ~1×/s).
    var onPace: (Int) -> Void = { _ in }

    static let readColor = UIColor(white: 1, alpha: 0.28)
    static let upcomingColor = UIColor(white: 1, alpha: 0.6)
    static let currentLineColor = UIColor.white
    static let currentWordColor = UIColor(red: 1.0, green: 0.84, blue: 0.04, alpha: 1)
    static let noteColor = UIColor(red: 0.55, green: 0.75, blue: 1.0, alpha: 0.55)
    static let headingColor = UIColor(red: 1.0, green: 0.84, blue: 0.04, alpha: 0.75)

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> Container {
        let container = Container()
        container.coordinator = context.coordinator
        context.coordinator.attach(container)
        return container
    }

    static func dismantleUIView(_ uiView: Container, coordinator: Coordinator) {
        coordinator.detach()
    }

    func updateUIView(_ container: Container, context: Context) {
        let c = context.coordinator
        c.parent = self
        c.relayoutIfNeeded()
        c.setTarget(cursor)
    }

    /// Clipping host; relays size changes to the coordinator.
    final class Container: UIView {
        weak var coordinator: Coordinator?
        override init(frame: CGRect) {
            super.init(frame: frame)
            clipsToBounds = true
            backgroundColor = .clear
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layoutSubviews() {
            super.layoutSubviews()
            coordinator?.relayoutIfNeeded()
        }
    }

    final class Coordinator: NSObject {
        var parent: PrompterTextView
        private weak var container: Container?
        private let textView = LockedTextView(usingTextLayoutManager: false) // TextKit 1: precise line rects
        private let marker = UILabel()
        private var styleKey = ""
        private var noteRanges: [NSRange] = []
        private var headingRanges: [NSRange] = []

        private struct Line { var top: CGFloat; var advance: CGFloat; var first: Int; var last: Int; var chars: NSRange }
        private var lines: [Line] = []
        private var tokenLine: [Int] = []

        private var pacer = ReadingPacer()
        private var initialized = false
        private var offset: CGFloat = 0          // shown offset (points the text is moved up)
        private var highlighted = -1
        private var colouredRange = NSRange(location: 0, length: 0)
        private var link: CADisplayLink?
        private var lastTick: CFTimeInterval = 0
        private var lastPaceReport: CFTimeInterval = 0

        // Manual dragging
        private var dragging = false
        private var dragStartOffset: CGFloat = 0
        private var flingVelocity: CGFloat = 0

        init(_ parent: PrompterTextView) { self.parent = parent }

        func attach(_ c: Container) {
            container = c
            textView.isEditable = false
            textView.isSelectable = false
            // Must stay a scrolling text view so it keeps drawing the region we scroll to;
            // touches go to our own gestures on the container instead.
            textView.isScrollEnabled = true
            textView.isUserInteractionEnabled = false
            textView.showsVerticalScrollIndicator = false
            textView.backgroundColor = .clear
            textView.textContainer.lineFragmentPadding = 0
            textView.layoutManager.allowsNonContiguousLayout = false
            textView.contentInsetAdjustmentBehavior = .never
            c.addSubview(textView)

            marker.text = "▶"
            marker.textColor = PrompterTextView.currentWordColor
            marker.font = .systemFont(ofSize: 18, weight: .heavy)
            marker.alpha = 0
            c.addSubview(marker)

            c.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(panned(_:))))
            c.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))

            let l = CADisplayLink(target: WeakProxy(self), selector: #selector(WeakProxy.tick(_:)))
            l.add(to: .main, forMode: .common)
            link = l
        }

        func detach() {
            link?.invalidate()
            link = nil
        }

        // MARK: Layout

        func relayoutIfNeeded() {
            guard let c = container, c.bounds.width > 0 else { return }
            let p = parent
            let key = "\(p.text.hashValue)|\(p.fontSize)|\(p.centered)|\(Int(c.bounds.width))|\(p.anchorY)"
            guard key != styleKey else { return }
            styleKey = key

            let para = NSMutableParagraphStyle()
            para.lineSpacing = p.fontSize * 0.22
            para.paragraphSpacing = p.fontSize * 0.5
            para.alignment = p.centered ? .center : .natural
            let attributed = NSMutableAttributedString(string: p.text, attributes: [
                .font: UIFont.systemFont(ofSize: p.fontSize, weight: .semibold),
                .foregroundColor: PrompterTextView.upcomingColor,
                .paragraphStyle: para,
            ])
            noteRanges = TextNormalizer.noteRanges(p.text)
            let noteFont = UIFont.italicSystemFont(ofSize: max(14, p.fontSize * 0.55))
            for r in noteRanges {
                attributed.addAttribute(.font, value: noteFont, range: r)
                attributed.addAttribute(.foregroundColor, value: PrompterTextView.noteColor, range: r)
            }
            // ## Section headings: small bold caps-style titles.
            headingRanges = TextNormalizer.headingRanges(p.text)
            let headingFont = UIFont.systemFont(ofSize: max(14, p.fontSize * 0.55), weight: .heavy)
            for r in headingRanges {
                attributed.addAttribute(.font, value: headingFont, range: r)
                attributed.addAttribute(.foregroundColor, value: PrompterTextView.headingColor, range: r)
                // Hide the leading "#" marks.
                let str = (p.text as NSString).substring(with: r)
                let hashes = str.prefix { $0 == "#" || $0 == " " || $0 == "\t" }.utf16.count
                if hashes > 0 {
                    attributed.addAttribute(.foregroundColor, value: UIColor.clear,
                                            range: NSRange(location: r.location, length: hashes))
                    attributed.addAttribute(.font, value: UIFont.systemFont(ofSize: 1), range: NSRange(location: r.location, length: hashes))
                }
            }
            textView.frame = c.bounds
            textView.textContainerInset = UIEdgeInsets(top: p.anchorY, left: 0, bottom: c.bounds.height, right: 0)
            textView.attributedText = attributed
            textView.layoutIfNeeded()
            buildLineMap()
            applyOffset()
        }

        private func buildLineMap() {
            lines = []
            tokenLine = []
            highlighted = -1
            colouredRange = NSRange(location: 0, length: 0)
            initialized = false
            let lm = textView.layoutManager
            lm.ensureLayout(for: textView.textContainer)
            for (i, token) in parent.tokens.enumerated() {
                let glyph = lm.glyphRange(forCharacterRange: token.range, actualCharacterRange: nil).location
                var lineGlyphs = NSRange()
                let rect = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &lineGlyphs)
                if let last = lines.last, abs(last.top - rect.minY) < 0.5 {
                    lines[lines.count - 1].last = i
                } else {
                    let chars = lm.characterRange(forGlyphRange: lineGlyphs, actualGlyphRange: nil)
                    lines.append(Line(top: rect.minY, advance: rect.height, first: i, last: i, chars: chars))
                }
                tokenLine.append(lines.count - 1)
            }
            for k in 0..<max(0, lines.count - 1) { lines[k].advance = lines[k + 1].top - lines[k].top }
        }

        // MARK: Motion

        func setTarget(_ newTarget: Int) {
            guard !lines.isEmpty else { return }
            if !initialized {
                pacer.reset(to: newTarget)
                initialized = true
                if let y = scrollTarget() { offset = y; applyOffset() }
                updateHighlight()
                return
            }
            guard newTarget != pacer.target else { return }
            pacer.update(target: newTarget, now: CACurrentMediaTime())
        }

        fileprivate func tick(_ l: CADisplayLink) {
            guard initialized, !lines.isEmpty else { return }
            let now = l.timestamp
            let dt = lastTick == 0 ? 1.0 / 60 : min(0.05, now - lastTick)
            lastTick = now

            if dragging { return }
            if abs(flingVelocity) > 5 {
                // Momentum after a manual fling, then pick the line.
                offset = clampOffset(offset + flingVelocity * CGFloat(dt))
                flingVelocity *= CGFloat(exp(-dt / 0.18))
                applyOffset()
                if abs(flingVelocity) <= 5 { flingVelocity = 0; pickLineAtMarker() }
                return
            }

            pacer.step(dt: dt, now: now)
            updateHighlight()
            if now - lastPaceReport > 1 {
                lastPaceReport = now
                parent.onPace(pacer.wordsPerMinute)
            }
            guard let y = scrollTarget() else { return }
            offset += (y - offset) * CGFloat(1 - exp(-dt / 0.08))
            applyOffset()
        }

        private func applyOffset() {
            let scale = container?.window?.screen.scale ?? 3
            textView.setOffset((offset * scale).rounded() / scale)
        }

        private func clampOffset(_ y: CGFloat) -> CGFloat {
            guard let last = lines.last else { return 0 }
            return min(max(-parent.fontSize, y), last.top + last.advance)
        }

        /// Offset for the fractional position: the reading point moves through each
        /// line (line start sits a bit below the anchor, line end a bit above).
        private func scrollTarget() -> CGFloat? {
            guard !lines.isEmpty, !tokenLine.isEmpty else { return nil }
            let pos = pacer.position
            let n = tokenLine.count
            if pos >= Double(n) {
                let last = lines[lines.count - 1]
                return last.top + last.advance * 0.7
            }
            let k = max(0, min(n - 1, Int(pos)))
            let frac = pos - Double(k)
            let line = lines[tokenLine[k]]
            let p = (Double(k - line.first) + frac) / Double(line.last - line.first + 1)
            return line.top + CGFloat(p - 0.3) * line.advance
        }

        // MARK: Colours (only the lines that change)

        private func updateHighlight() {
            let h = max(0, min(pacer.target + 1, Int(pacer.position)))
            guard h != highlighted else { return }
            let tokens = parent.tokens
            let storage = textView.textStorage
            let length = storage.length
            func lineRange(_ i: Int) -> NSRange {
                guard i >= 0, i < tokenLine.count else { return NSRange(location: length, length: 0) }
                return lines[tokenLine[i]].chars
            }
            let union = NSUnionRange(NSUnionRange(lineRange(highlighted), lineRange(h)), colouredRange)
            let lo = highlighted < 0 ? 0 : union.location
            let hi = highlighted < 0 ? length : NSMaxRange(union)
            highlighted = h
            guard hi > lo else { return }

            let wordStart = h < tokens.count ? tokens[h].range.location : length
            let lineEnd = h < tokenLine.count ? NSMaxRange(lines[tokenLine[h]].chars) : length
            storage.beginEditing()
            func paint(_ from: Int, _ to: Int, _ color: UIColor) {
                let a = max(lo, from), b = min(hi, to)
                if b > a { storage.addAttribute(.foregroundColor, value: color, range: NSRange(location: a, length: b - a)) }
            }
            paint(lo, wordStart, PrompterTextView.readColor)
            paint(wordStart, lineEnd, PrompterTextView.currentLineColor)
            paint(lineEnd, hi, PrompterTextView.upcomingColor)
            if h < tokens.count { paint(tokens[h].range.location, NSMaxRange(tokens[h].range), PrompterTextView.currentWordColor) }
            let span = NSRange(location: lo, length: hi - lo)
            for r in noteRanges where NSIntersectionRange(r, span).length > 0 {
                paint(r.location, NSMaxRange(r), PrompterTextView.noteColor)
            }
            for r in headingRanges where NSIntersectionRange(r, span).length > 0 {
                let str = (parent.text as NSString).substring(with: r)
                let hashes = str.prefix { $0 == "#" || $0 == " " || $0 == "\t" }.utf16.count
                paint(r.location, r.location + hashes, .clear)
                paint(r.location + hashes, NSMaxRange(r), PrompterTextView.headingColor)
            }
            storage.endEditing()
            colouredRange = lineRange(h)
        }

        // MARK: Manual positioning

        @objc private func panned(_ g: UIPanGestureRecognizer) {
            guard let c = container else { return }
            switch g.state {
            case .began:
                dragging = true
                flingVelocity = 0
                dragStartOffset = offset
                positionMarker()
                UIView.animate(withDuration: 0.15) { self.marker.alpha = 1 }
            case .changed:
                offset = clampOffset(dragStartOffset - g.translation(in: c).y)
                applyOffset()
            case .ended, .cancelled, .failed:
                dragging = false
                flingVelocity = -g.velocity(in: c).y * 0.9
                if abs(flingVelocity) <= 5 { flingVelocity = 0; pickLineAtMarker() }
            default:
                break
            }
        }

        private func positionMarker() {
            marker.sizeToFit()
            marker.center = CGPoint(x: marker.bounds.width / 2 + 2, y: parent.anchorY + parent.fontSize * 0.6)
        }

        /// The line sitting on the reading anchor becomes the reading position.
        private func pickLineAtMarker() {
            UIView.animate(withDuration: 0.25) { self.marker.alpha = 0 }
            guard !lines.isEmpty else { return }
            let y = offset + parent.fontSize * 0.6
            let line = lines.last(where: { $0.top <= y }) ?? lines[0]
            jumpHere(line.first)
        }

        private func jumpHere(_ index: Int) {
            pacer.reset(to: index)
            highlighted = -1
            colouredRange = NSRange(location: 0, length: textView.textStorage.length)
            updateHighlight()
            parent.onPickToken(index)
        }

        @objc private func tapped(_ g: UITapGestureRecognizer) {
            var p = g.location(in: textView) // content coordinates (includes the offset)
            p.x -= textView.textContainerInset.left
            p.y -= textView.textContainerInset.top
            let idx = textView.layoutManager.characterIndex(for: p, in: textView.textContainer,
                                                            fractionOfDistanceBetweenInsertionPoints: nil)
            guard let i = parent.tokens.firstIndex(where: { NSMaxRange($0.range) > idx }) else { return }
            flingVelocity = 0
            jumpHere(i)
        }
    }

    /// A UITextView whose scroll position only our code may change.
    final class LockedTextView: UITextView {
        private var ours = false
        func setOffset(_ y: CGFloat) {
            guard contentOffset.y != y else { return }
            ours = true
            super.contentOffset = CGPoint(x: 0, y: y)
            ours = false
        }
        override var contentOffset: CGPoint {
            get { super.contentOffset }
            set { if ours { super.contentOffset = newValue } }
        }
        override func setContentOffset(_ contentOffset: CGPoint, animated: Bool) {
            if ours { super.setContentOffset(contentOffset, animated: false) }
        }
        override func scrollRectToVisible(_ rect: CGRect, animated: Bool) {}
        override func scrollRangeToVisible(_ range: NSRange) {}
    }

    /// CADisplayLink retains its target; this breaks the cycle.
    private final class WeakProxy: NSObject {
        weak var owner: Coordinator?
        init(_ owner: Coordinator) { self.owner = owner }
        @objc func tick(_ l: CADisplayLink) {
            if let owner { owner.tick(l) } else { l.invalidate() }
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
