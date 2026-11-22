import QuartzCore
import AVFoundation
import SwiftUI

@MainActor
final class PrompterViewModel: ObservableObject {
    enum ScrollMode: String, CaseIterable, Identifiable {
        case voice, auto, manual
        var id: String { rawValue }
        var title: String {
            switch self {
            case .voice: return tr("Theo giọng", "Voice")
            case .auto: return tr("Tự cuộn", "Auto scroll")
            case .manual: return tr("Thủ công", "Manual")
            }
        }
        var icon: String {
            switch self {
            case .voice: return "waveform"
            case .auto: return "arrow.down.circle"
            case .manual: return "hand.tap"
            }
        }
    }

    let script: Script
    let tracker: ScriptTracker
    let camera = CameraPipeline()
    private let speech = SpeechFollower()

    /// Where the reader actually is (from speech).
    @Published private(set) var cursor = 0 {
        didSet { ReadingPositionStore.save(cursor, total: tracker.tokens.count, for: script) }
    }
    /// Bumped whenever the reader is detected going back to re-read.
    @Published private(set) var rewindCount = 0
    @Published var mode: ScrollMode = .voice { didSet { modeChanged() } }
    @Published var paused = false
    @Published private(set) var heard = ""
    /// Reading pace estimated by the prompter, words per minute (0 = not measured yet).
    @Published var wordsPerMinute = 0
    var autoRewind: Bool {
        get { tracker.allowRewind }
        set { tracker.allowRewind = newValue }
    }
    @Published private(set) var speechStatus = ""
    @Published private(set) var permissionProblem: String?

    var localeID = AppLanguage.current.defaultSpeechLocale
    var autoWPM: Double = 150
    private var autoTimer: Timer?
    private var autoAccumulator = 0.0

    /// `resume`: continue from the start of the sentence where the reader stopped last time.
    init(script: Script, resume: Bool = false) {
        self.script = script
        tracker = ScriptTracker(text: script.body)
        speech.onHypothesis = { [weak self] h in self?.handle(hypothesis: h) }
        speech.onStatus = { [weak self] s in self?.speechStatus = s }
        let speech = self.speech
        camera.onAudio = { buffer in speech.append(buffer) }
        if resume, let pos = ReadingPositionStore.load(script) {
            jump(to: tracker.sentenceStart(before: pos.index + 1))
        }
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-cursor"), i + 1 < args.count, let n = Int(args[i + 1]) { jump(to: n) }
        #endif
    }

    var tokens: [ScriptToken] { tracker.tokens }
    /// Sections and paragraphs for the outline sheet.
    lazy var outline: [OutlineItem] = ScriptOutline.build(text: script.body, tokens: tracker.tokens)
    var currentOutlineIndex: Int? { ScriptOutline.current(outline, cursor: cursor) }

    /// Next / previous paragraph start.
    func stepParagraph(_ direction: Int) {
        let starts = outline.filter { $0.kind == .paragraph }.map(\.tokenIndex)
        guard !starts.isEmpty else { return }
        if direction > 0 {
            if let next = starts.first(where: { $0 > cursor }) { jump(to: next) }
        } else {
            // Within the first words of a paragraph, go to the previous one.
            let currentStart = starts.last(where: { $0 <= cursor }) ?? 0
            let target = cursor - currentStart <= 2 ? (starts.last(where: { $0 < currentStart }) ?? 0) : currentStart
            jump(to: target)
        }
    }
    var progress: Double { tracker.progress }

    // MARK: Lifecycle

    func appear() {
        UIApplication.shared.isIdleTimerDisabled = true
        Task {
            let cam = await AVCaptureDevice.requestAccess(for: .video)
            let mic = await AVCaptureDevice.requestAccess(for: .audio)
            if !cam || !mic {
                permissionProblem = tr("Cần quyền Camera và Micro — mở Cài đặt › EyePrompter.", "Camera and microphone access needed: open Settings › EyePrompter.")
            }
            camera.start { [weak self] in
                guard let self else { return }
                if !self.camera.hasMicrophone { self.speech.useEngineInput() }
                self.modeChanged()
            }
        }
    }

    func disappear() {
        UIApplication.shared.isIdleTimerDisabled = false
        camera.stopRecording()
        camera.stop()
        speech.stop()
        autoTimer?.invalidate()
    }

    // MARK: Following

    private func handle(hypothesis: String) {
        heard = TextNormalizer.words(hypothesis).isEmpty ? "" :
            hypothesis.split(separator: " ").suffix(6).joined(separator: " ")
        guard mode == .voice, !paused else { return }
        if tracker.ingest(hypothesis: hypothesis) {
            cursor = tracker.cursor
            if tracker.lastMoveWasRewind { rewindCount += 1 }
        }
    }

    private func modeChanged() {
        autoTimer?.invalidate()
        autoTimer = nil
        switch mode {
        case .voice:
            startSpeech()
        case .auto:
            speech.stop()
            autoAccumulator = 0
            autoTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.autoTick() }
            }
        case .manual:
            speech.stop()
        }
    }

    private func startSpeech() {
        SpeechFollower.requestAuthorization { [weak self] ok in
            guard let self else { return }
            guard ok else {
                self.speechStatus = tr("Chưa cho phép nhận dạng giọng nói", "Speech recognition not allowed")
                return
            }
            self.speech.start(localeID: self.localeID,
                              contextualStrings: SpeechFollower.contextualStrings(from: self.tracker.tokens))
            if !self.camera.hasMicrophone { self.speech.useEngineInput() }
        }
    }

    func restartSpeech() {
        if mode == .voice { startSpeech() }
    }

    private func autoTick() {
        guard !paused, !tracker.isFinished else { return }
        autoAccumulator += autoWPM / 60 * 0.05
        if autoAccumulator >= 1 {
            let n = Int(autoAccumulator)
            autoAccumulator -= Double(n)
            jump(to: tracker.cursor + n)
        }
    }

    func jump(to index: Int) {
        tracker.jump(to: index)
        cursor = tracker.cursor
    }

    /// Back to the start of the current sentence; pressed again right there, the previous one.
    func rewindSentence() {
        var start = tracker.sentenceStart(before: cursor)
        if cursor - start <= 1, start > 0 { start = tracker.sentenceStart(before: start - 1) }
        jump(to: start)
        rewindCount += 1
    }

    func step(_ delta: Int) { jump(to: cursor + delta) }

    func restartFromTop() {
        jump(to: 0)
        restartSpeech()
    }

    // MARK: Recording

    func toggleRecording() {
        if camera.isRecording {
            camera.stopRecording()
        } else {
            camera.startRecording()
            paused = false
        }
    }
}
