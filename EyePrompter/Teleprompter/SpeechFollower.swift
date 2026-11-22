import AVFoundation
import Speech

/// Streams microphone audio into Apple's speech recogniser and reports the live
/// (partial) transcript. Recognition tasks are recycled automatically: Apple caps
/// a single task at ~1 minute and ends it after long pauses.
final class SpeechFollower {
    /// Called on the main queue with the full hypothesis of the current task.
    var onHypothesis: ((String) -> Void)?
    var onStatus: ((String) -> Void)?

    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let lock = NSLock()
    private var running = false
    private var contextual: [String] = []
    private var rotateTimer: Timer?
    private var generation = 0
    private var consecutiveErrors = 0

    // Fallback input when the capture session has no microphone (e.g. Simulator).
    private var engine: AVAudioEngine?

    static func requestAuthorization(_ done: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async { done(status == .authorized) }
        }
    }

    var isRunning: Bool { running }

    func start(localeID: String, contextualStrings: [String]) {
        stop()
        guard let r = SFSpeechRecognizer(locale: Locale(identifier: localeID)) else {
            onStatus?(tr("Không hỗ trợ ngôn ngữ \(localeID)", "Language not supported: \(localeID)"))
            return
        }
        recognizer = r
        contextual = contextualStrings
        running = true
        consecutiveErrors = 0
        onStatus?(r.supportsOnDeviceRecognition ? tr("Nghe trên máy", "Listening on device") : tr("Nghe (cần mạng)", "Listening (needs internet)"))
        beginTask()
    }

    func stop() {
        running = false
        rotateTimer?.invalidate()
        rotateTimer = nil
        generation += 1
        lock.lock()
        let old = request
        request = nil
        lock.unlock()
        old?.endAudio()
        task?.cancel()
        task = nil
        stopEngine()
    }

    /// Feed audio from AVCaptureAudioDataOutput (any thread).
    func append(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        request?.appendAudioSampleBuffer(sampleBuffer)
        lock.unlock()
    }

    /// Use AVAudioEngine as the audio source instead of the capture session.
    func useEngineInput() {
        guard engine == nil else { return }
        let e = AVAudioEngine()
        let input = e.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { onStatus?(tr("Không có micro", "No microphone")); return }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.lock.lock()
            self.request?.append(buffer)
            self.lock.unlock()
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
            e.prepare()
            try e.start()
            engine = e
        } catch {
            onStatus?(tr("Lỗi micro: \(error.localizedDescription)", "Microphone error: \(error.localizedDescription)"))
        }
    }

    private func stopEngine() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    private func beginTask() {
        guard running, let r = recognizer else { return }
        generation += 1
        let gen = generation

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.taskHint = .dictation
        req.addsPunctuation = false
        if r.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        req.contextualStrings = Array(contextual.prefix(100))

        lock.lock()
        let old = request
        request = req
        lock.unlock()
        old?.endAudio()
        task?.cancel()

        task = r.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.running, gen == self.generation else { return }
                if let result {
                    self.consecutiveErrors = 0
                    self.onHypothesis?(result.bestTranscription.formattedString)
                    if result.isFinal { self.restart(after: 0.05) }
                } else if error != nil {
                    self.consecutiveErrors += 1
                    // "No speech detected" after silence is normal; back off on real failures.
                    self.restart(after: min(3.0, 0.2 * Double(self.consecutiveErrors)))
                }
            }
        }

        rotateTimer?.invalidate()
        rotateTimer = Timer.scheduledTimer(withTimeInterval: 50, repeats: false) { [weak self] _ in
            self?.beginTask()
        }
    }

    private func restart(after delay: TimeInterval) {
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.running, gen == self.generation else { return }
            self.beginTask()
        }
    }

    /// Words worth biasing the recogniser towards: names, numbers, long/rare words.
    static func contextualStrings(from tokens: [ScriptToken]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for t in tokens {
            let clean = t.text.trimmingCharacters(in: .punctuationCharacters)
            guard let first = clean.first else { continue }
            let interesting = first.isUppercase || clean.contains(where: \.isNumber) || clean.count >= 7
            if interesting, seen.insert(clean.lowercased()).inserted { out.append(clean) }
            if out.count >= 100 { break }
        }
        return out
    }
}
