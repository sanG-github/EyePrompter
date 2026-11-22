import AVFoundation
import Photos
import SwiftUI
import UIKit

/// Front camera + microphone. Every video frame goes through the gaze corrector,
/// then to the on-screen preview and (while recording) to the file writer.
/// Microphone buffers go to the speech follower and the writer.
final class CameraPipeline: NSObject, ObservableObject {
    let session = AVCaptureSession()
    let displayLayer = AVSampleBufferDisplayLayer()
    let gaze = GazeCorrector()

    /// Called on the capture queue for every microphone buffer.
    var onAudio: ((CMSampleBuffer) -> Void)?

    @Published private(set) var hasCamera = false
    @Published private(set) var hasMicrophone = false
    @Published private(set) var isRecording = false
    @Published private(set) var recordingStartedAt: Date?
    @Published var message: String?
    /// Last clip recorded in this session (kept on disk for quick review).
    @Published private(set) var lastClipURL: URL?
    @Published private(set) var lastClipThumbnail: UIImage?
    /// Zoom range the active camera format supports (for the settings slider).
    @Published private(set) var zoomRange: ClosedRange<Double> = 1...1
    @Published private(set) var supports4K60 = false
    /// Whether the frames coming out of the camera are mirrored (preview adapts to it).
    @Published private(set) var outputMirrored = false

    struct Config: Equatable {
        enum Resolution: String, CaseIterable { case hd1080 = "1080p", uhd4K = "4K" }
        var resolution: Resolution = .hd1080
        var fps: Int = 30
        /// Exposure compensation, EV (−2…+2).
        var exposureBias: Float = 0
        var zoom: Double = 1
        /// Record the selfie (mirrored) image, i.e. exactly what the preview shows.
        var mirrored = true
    }
    private var config = Config()
    private var activeFPS = 30
    private var videoDevice: AVCaptureDevice?

    private let sessionQueue = DispatchQueue(label: "camera.session")
    private let captureQueue = DispatchQueue(label: "camera.capture", qos: .userInteractive)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var configured = false

    // Writer state — only touched on captureQueue.
    private var wantsRecording = false
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var sessionStarted = false

    // MARK: - Session

    func start(completion: (() -> Void)? = nil) {
        sessionQueue.async {
            self.configureIfNeeded()
            if !self.session.isRunning { self.session.startRunning() }
            DispatchQueue.main.async { completion?() }
        }
    }

    func stop() {
        sessionQueue.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    private func configureIfNeeded() {
        guard !configured else { return }
        configured = true
        session.beginConfiguration()
        if session.canSetSessionPreset(.hd1920x1080) { session.sessionPreset = .hd1920x1080 }

        var cam = false, mic = false
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
           let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
            cam = true
            videoDevice = device
            var s = gaze.settings
            s.fieldOfView = device.activeFormat.videoFieldOfView
            gaze.settings = s
        }
        if let device = AVCaptureDevice.default(for: .audio),
           let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
            mic = true
        }

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: captureQueue)
        if cam, session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        if let c = videoOutput.connection(with: .video) {
            if c.isVideoRotationAngleSupported(pendingRotation) { c.videoRotationAngle = pendingRotation } // upright buffers
            if c.isVideoMirroringSupported {
                c.automaticallyAdjustsVideoMirroring = false
                c.isVideoMirrored = false // record the true (un-mirrored) image; the preview mirrors itself
            }
        }

        audioOutput.setSampleBufferDelegate(self, queue: captureQueue)
        if mic, session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }
        session.commitConfiguration()

        DispatchQueue.main.async {
            self.hasCamera = cam
            self.hasMicrophone = mic
        }
        applyConfigOnSessionQueue()
    }

    // MARK: - Camera settings

    /// Resolution / frame rate / exposure / zoom. Format changes are ignored while recording.
    func apply(_ newConfig: Config) {
        sessionQueue.async {
            self.config = newConfig
            guard self.configured else { return }
            self.applyConfigOnSessionQueue()
        }
    }

    private func applyConfigOnSessionQueue() {
        guard let device = videoDevice else { return }
        let targetWidth: Int32 = config.resolution == .uhd4K ? 3840 : 1920
        let fps = Double(config.fps)
        func dims(_ f: AVCaptureDevice.Format) -> CMVideoDimensions { CMVideoFormatDescriptionGetDimensions(f.formatDescription) }
        func maxFPS(_ f: AVCaptureDevice.Format) -> Double { f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0 }
        let fourK60 = device.formats.contains { dims($0).width == 3840 && maxFPS($0) >= 60 }

        // Pick the format: exact width, enough frame rate, prefer full-range 420f.
        let candidates = device.formats.filter { dims($0).width == targetWidth && dims($0).height == targetWidth * 9 / 16 }
        let format = candidates.first { maxFPS($0) >= fps &&
            CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange }
            ?? candidates.first { maxFPS($0) >= fps }
            ?? candidates.first
        do {
            try device.lockForConfiguration()
            if !isRecordingSnapshot, let format, device.activeFormat != format {
                device.activeFormat = format
            }
            let usable = min(fps, maxFPS(device.activeFormat))
            let duration = CMTime(value: 1, timescale: CMTimeScale(usable.rounded()))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            activeFPS = Int(usable.rounded())
            let bias = max(device.minExposureTargetBias, min(device.maxExposureTargetBias, config.exposureBias))
            device.setExposureTargetBias(bias, completionHandler: nil)
            let maxZoom = min(3.0, Double(device.activeFormat.videoMaxZoomFactor))
            device.videoZoomFactor = CGFloat(max(1, min(maxZoom, config.zoom)))
            device.unlockForConfiguration()
            var mirrored = false
            if let c = videoOutput.connection(with: .video), c.isVideoMirroringSupported {
                c.automaticallyAdjustsVideoMirroring = false
                if !isRecordingSnapshot, c.isVideoMirrored != config.mirrored {
                    c.isVideoMirrored = config.mirrored
                    displayLayer.sampleBufferRenderer.flush()
                }
                mirrored = c.isVideoMirrored
            }
            var s = gaze.settings
            s.fieldOfView = device.activeFormat.videoFieldOfView
            s.mirrored = mirrored
            gaze.settings = s
            DispatchQueue.main.async { self.outputMirrored = mirrored }
            DispatchQueue.main.async {
                self.zoomRange = 1...max(1.01, maxZoom)
                self.supports4K60 = fourK60
            }
        } catch {
            post("Không chỉnh được camera: \(error.localizedDescription)")
        }
    }

    private let flagLock = NSLock()
    private var _recordingFlag = false
    private var isRecordingSnapshot: Bool {
        get { flagLock.lock(); defer { flagLock.unlock() }; return _recordingFlag }
        set { flagLock.lock(); _recordingFlag = newValue; flagLock.unlock() }
    }

    // MARK: - Orientation

    private var pendingRotation: CGFloat = 90

    /// Keeps the recorded/previewed frames upright for the current UI orientation.
    /// Ignored while recording (the file keeps the orientation it started with).
    func setInterfaceOrientation(_ o: UIInterfaceOrientation) {
        let angle: CGFloat
        switch o {
        // Front camera: measured on iPhone 15 Plus — the opposite of the back-camera mapping.
        case .landscapeRight: angle = 180
        case .landscapeLeft: angle = 0
        case .portraitUpsideDown: angle = 270
        default: angle = 90
        }
        pendingRotation = angle
        guard !isRecording else { return }
        applyRotation(angle)
    }

    private func applyRotation(_ angle: CGFloat) {
        sessionQueue.async {
            guard let c = self.videoOutput.connection(with: .video),
                  c.isVideoRotationAngleSupported(angle), c.videoRotationAngle != angle else { return }
            c.videoRotationAngle = angle
            self.displayLayer.sampleBufferRenderer.flush()
        }
    }

    // MARK: - Recording

    func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        isRecordingSnapshot = true
        recordingStartedAt = Date()
        captureQueue.async {
            self.writer = nil
            self.sessionStarted = false
            self.wantsRecording = true
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        isRecordingSnapshot = false
        recordingStartedAt = nil
        sessionQueue.async { self.applyConfigOnSessionQueue() } // format changes made during the take
        applyRotation(pendingRotation)
        captureQueue.async {
            self.wantsRecording = false
            guard let writer = self.writer, self.sessionStarted else {
                self.writer?.cancelWriting()
                self.writer = nil
                return
            }
            self.videoInput?.markAsFinished()
            self.audioInput?.markAsFinished()
            self.writer = nil
            writer.finishWriting {
                if writer.status == .completed {
                    self.rememberClip(writer.outputURL)
                    self.saveToPhotos(writer.outputURL)
                } else {
                    self.post("Lỗi ghi video: \(writer.error?.localizedDescription ?? "?")")
                }
            }
        }
    }

    private func makeWriter(width: Int, height: Int, at time: CMTime) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("EyePrompter-\(Int(Date().timeIntervalSince1970)).mov")
        guard let w = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return }

        let big = max(width, height) > 2000
        let fps = activeFPS
        let bitrate = (big ? 45_000_000 : 14_000_000) * (fps > 30 ? 3 : 2) / 2
        let vSettings: [String: Any] = [
            AVVideoCodecKey: big ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate,
                                              AVVideoExpectedSourceFrameRateKey: fps],
        ]
        let vi = AVAssetWriterInput(mediaType: .video, outputSettings: vSettings)
        vi.expectsMediaDataInRealTime = true
        let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vi, sourcePixelBufferAttributes: nil)
        if w.canAdd(vi) { w.add(vi) }

        var ai: AVAssetWriterInput?
        if hasMicrophoneSnapshot {
            let aSettings = audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov)
                ?? [AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 1, AVSampleRateKey: 44_100]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: aSettings)
            input.expectsMediaDataInRealTime = true
            if w.canAdd(input) { w.add(input); ai = input }
        }

        guard w.startWriting() else {
            post("Không thể bắt đầu ghi: \(w.error?.localizedDescription ?? "?")")
            return
        }
        w.startSession(atSourceTime: time)
        writer = w
        videoInput = vi
        audioInput = ai
        adaptor = ad
        sessionStarted = true
    }

    private var hasMicrophoneSnapshot: Bool { session.inputs.contains { ($0 as? AVCaptureDeviceInput)?.device.hasMediaType(.audio) == true } }

    private func saveToPhotos(_ url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                self.post("Chưa cho phép lưu vào Ảnh. File: \(url.lastPathComponent)")
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }) { ok, error in
                self.post(ok ? "Đã lưu video vào Ảnh" : "Lỗi lưu: \(error?.localizedDescription ?? "?")")
            }
        }
    }

    /// Keeps the newest clip (deleting the previous one) and makes a thumbnail for the library button.
    private func rememberClip(_ url: URL) {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 240)
        generator.generateCGImageAsynchronously(for: CMTime(seconds: 0.3, preferredTimescale: 600)) { image, _, _ in
            DispatchQueue.main.async {
                if let old = self.lastClipURL, old != url { try? FileManager.default.removeItem(at: old) }
                self.lastClipURL = url
                self.lastClipThumbnail = image.map { UIImage(cgImage: $0) }
            }
        }
    }

    private func post(_ text: String) {
        DispatchQueue.main.async { self.message = text }
    }

    // MARK: - Preview

    private func display(_ pb: CVPixelBuffer, time: CMTime) {
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &format)
        guard let format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: format,
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sample)
    }
}

extension CameraPipeline: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if output === audioOutput {
            onAudio?(sampleBuffer)
            if sessionStarted, let ai = audioInput, ai.isReadyForMoreMediaData {
                ai.append(sampleBuffer)
            }
            return
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let corrected = gaze.process(pixelBuffer)
        display(corrected, time: time)

        guard wantsRecording else { return }
        if writer == nil {
            makeWriter(width: CVPixelBufferGetWidth(corrected), height: CVPixelBufferGetHeight(corrected), at: time)
        }
        if sessionStarted, let vi = videoInput, vi.isReadyForMoreMediaData {
            adaptor?.append(corrected, withPresentationTime: time)
        }
    }
}

/// SwiftUI host for the processed-frame preview (mirrored like a selfie camera).

struct CameraPreview: UIViewRepresentable {
    let pipeline: CameraPipeline
    /// Frames already mirrored → show as-is; otherwise mirror the view so the
    /// preview always behaves like a selfie mirror.
    var framesMirrored = false

    final class PreviewView: UIView {
        var displayLayer: AVSampleBufferDisplayLayer?
        override func layoutSubviews() {
            super.layoutSubviews()
            displayLayer?.frame = bounds
        }
    }

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.backgroundColor = .black
        let layer = pipeline.displayLayer
        layer.videoGravity = .resizeAspect // show exactly the recorded frame
        v.layer.addSublayer(layer)
        v.displayLayer = layer
        v.transform = framesMirrored ? .identity : CGAffineTransform(scaleX: -1, y: 1)
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.transform = framesMirrored ? .identity : CGAffineTransform(scaleX: -1, y: 1)
    }
}
