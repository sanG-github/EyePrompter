import CoreVideo
import QuartzCore
import Metal
import Vision
import simd

/// Layout must match `EyeParams` in GazeWarp.metal.
struct EyeShaderParams {
    var center: SIMD2<Float>
    var radii: SIMD2<Float>
    var pupil: SIMD2<Float>
    var irisR: Float
    var _pad0: Float = 0
    var shift: SIMD2<Float>
    var amount: Float
    var _pad1: Float = 0
}

/// Result of the calibration flow, in eye widths (image coordinates, relative to
/// the centre of the eye opening).
struct GazeCalibration: Equatable {
    /// Where the iris sits when the user looks straight into the lens.
    var camera: SIMD2<Float>
    /// Iris movement from "reading the prompter line" to "looking at the lens".
    var offset: SIMD2<Float>
}

/// Eye-contact correction.
///
/// Every frame: Vision (async) gives the eye openings; the iris itself is found
/// synchronously on the current frame from its pixels (darkest blob inside the
/// opening), so there is no lag. With a calibration the iris is *locked* to the
/// position it has when the user looks into the lens — which also cancels the
/// small left-right glances of reading a line. Without one, a static shift is
/// computed from the screen geometry. A Metal kernel moves the iris disc.
final class GazeCorrector {
    struct Settings {
        var enabled = true
        /// 0…2. With a calibration: 1 ≈ 85 % lock, ≥1.2 full lock.
        var strength: Float = 1.0
        /// Show the original frame (hold-to-compare).
        var bypass = false
        /// Where the line being read is relative to the camera lens on the physical
        /// screen, in mm, in UI coordinates (x → right, y → down as the user sees it).
        var textOffsetMM = SIMD2<Float>(0, 14)
        /// Horizontal field of view of the active camera format, degrees (landscape sensor).
        var fieldOfView: Float = 70
        /// Calibration is always stored in un-mirrored image coordinates.
        var calibration: GazeCalibration?
        /// Frames arrive mirrored (selfie recording): flip x of stored/measured data.
        var mirrored = false
    }

    struct SampleResult {
        /// Mean iris position relative to the eye centre, in eye widths.
        var mean: SIMD2<Float>
        var count: Int
        /// Standard deviation (eye widths) — how steady the gaze was.
        var spread: Float
    }

    private struct Eye {
        var center: SIMD2<Float>
        var halfSize: SIMD2<Float>
        var pupil: SIMD2<Float>
        var width: Float { 2 * halfSize.x }
        var openness: Float { halfSize.y / max(halfSize.x, 1) }
    }

    private let lock = NSLock()
    private var _settings = Settings()
    var settings: Settings {
        get { lock.lock(); defer { lock.unlock() }; return _settings }
        set { lock.lock(); _settings = newValue; lock.unlock() }
    }

    private var eyes: [Eye] = []
    private var sampling = false
    private var samples: [SIMD2<Float>] = []
    private var eyesTime: CFTimeInterval = 0
    private var visionBusy = false
    private let visionQueue = DispatchQueue(label: "gaze.vision", qos: .userInitiated)

    /// Smoothed per-eye iris centres (video queue only).
    private var irisSmoothed: [SIMD2<Float>] = []

    /// Last applied shift in pixels, for the debug overlay.
    private(set) var lastShiftPx: Float = 0
    private(set) var faceFound = false

    private let device = MTLCreateSystemDefaultDevice()
    private lazy var commandQueue = device?.makeCommandQueue()
    private lazy var pipeline: MTLComputePipelineState? = {
        guard let device, let lib = device.makeDefaultLibrary(), let fn = lib.makeFunction(name: "gazeWarp") else { return nil }
        return try? device.makeComputePipelineState(function: fn)
    }()
    private lazy var textureCache: CVMetalTextureCache? = {
        guard let device else { return nil }
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        return cache
    }()
    private var pool: CVPixelBufferPool?
    private var poolSize = (0, 0)

    // MARK: - Frame processing (video queue)

    func process(_ pb: CVPixelBuffer) -> CVPixelBuffer {
        let s = settings
        lock.lock()
        let isSampling = sampling
        let current = eyes
        let age = CACurrentMediaTime() - eyesTime
        lock.unlock()
        if s.enabled || isSampling { scheduleVision(pb) }
        guard s.enabled || isSampling else { faceFound = false; return pb }
        guard current.count == 2, age < 0.35 else { faceFound = false; irisSmoothed = []; return pb }
        faceFound = true

        let width = CVPixelBufferGetWidth(pb), height = CVPixelBufferGetHeight(pb)

        // Iris centres measured on THIS frame.
        let measured = measureIrises(pb, current)
        let iris: [SIMD2<Float>] = zip(current, measured).map { eye, m in m ?? eye.pupil }
        if irisSmoothed.count == 2 {
            irisSmoothed = zip(irisSmoothed, iris).map { simd_mix($0, $1, SIMD2(repeating: 0.6)) }
        } else {
            irisSmoothed = iris
        }
        let rel = zip(current, irisSmoothed).map { eye, i in (i - eye.center) / max(eye.width, 1) }
        let avgRel = (rel[0] + rel[1]) / 2
        let open = current.map(\.openness).min() ?? 0

        if isSampling, measured.allSatisfy({ $0 != nil }), open > 0.15 {
            let raw = zip(current, measured).map { eye, m in (m! - eye.center) / max(eye.width, 1) }
            var sample = (raw[0] + raw[1]) / 2
            if s.mirrored { sample.x = -sample.x } // store un-mirrored
            lock.lock(); samples.append(sample); lock.unlock()
        }
        guard s.enabled, !s.bypass else { return pb }

        let shifts: [SIMD2<Float>]
        if var cal = s.calibration {
            if s.mirrored { cal.camera.x = -cal.camera.x; cal.offset.x = -cal.offset.x }
            // Gaze lock: both eyes move together, so use the averaged position (less noise).
            let amount = simd_clamp(0.85 * s.strength, 0, 1)
            var common = (cal.camera - avgRel) * amount
            let maxShift: Float = 0.12 // eye widths; larger moves would ghost the old iris
            if simd_length(common) > maxShift { common = simd_normalize(common) * maxShift }
            shifts = current.map { common * $0.width }
        } else {
            // Geometry: interpupillary distance ≈ 63 mm, eyeball radius ≈ 12 mm.
            let ipdPx = simd_distance(current[0].center, current[1].center)
            guard ipdPx > 20 else { return pb }
            let pxPerMM = ipdPx / 63
            let fovRad = max(30, min(120, s.fieldOfView)) * .pi / 180
            let focalPx = Float(max(width, height)) / 2 / tan(fovRad / 2)
            let faceDistMM = focalPx * 63 / ipdPx
            // Image is upright and un-mirrored: text to the user's right turns the iris
            // towards image-left, so the correction is +x; text below needs the iris up (-y).
            let k = 12 * pxPerMM * s.strength
            let g = SIMD2<Float>((s.mirrored ? -k : k) * sin(atan(s.textOffsetMM.x / faceDistMM)),
                                 -k * sin(atan(s.textOffsetMM.y / faceDistMM)))
            shifts = [g, g]
        }
        let shiftLen = shifts.map(simd_length).max() ?? 0
        lastShiftPx = shiftLen
        guard shiftLen > 0.2 else { return pb }

        var params: [EyeShaderParams] = (0..<2).map { i in
            let eye = current[i]
            // Fade out during blinks / squints.
            let amount = simd_clamp((eye.openness - 0.12) / 0.1, 0, 1)
            return EyeShaderParams(center: eye.center,
                                   radii: eye.halfSize * SIMD2(1.05, 1.25),
                                   pupil: irisSmoothed[i],
                                   irisR: 0.21 * eye.width,
                                   shift: shifts[i],
                                   amount: amount)
        }

        guard let out = makeOutputBuffer(width: width, height: height),
              let pipeline, let commandQueue,
              let srcTex = texture(pb), let dstTex = texture(out),
              let cmd = commandQueue.makeCommandBuffer() else { return pb }

        // Region to warp: bounding box of both eyes with margin.
        var minP = SIMD2<Float>(repeating: .greatestFiniteMagnitude), maxP = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)
        for p in params {
            let r = p.radii * 1.1 + SIMD2(repeating: shiftLen * 2 + 4)
            minP = simd_min(minP, p.center - r)
            maxP = simd_max(maxP, p.center + r)
        }
        let x0 = max(0, Int(minP.x)), y0 = max(0, Int(minP.y))
        let x1 = min(width, Int(maxP.x) + 1), y1 = min(height, Int(maxP.y) + 1)

        if let blit = cmd.makeBlitCommandEncoder() {
            blit.copy(from: CVMetalTextureGetTexture(srcTex)!, to: CVMetalTextureGetTexture(dstTex)!)
            blit.endEncoding()
        }
        if x1 > x0, y1 > y0, let enc = cmd.makeComputeCommandEncoder() {
            enc.setComputePipelineState(pipeline)
            enc.setTexture(CVMetalTextureGetTexture(srcTex), index: 0)
            enc.setTexture(CVMetalTextureGetTexture(dstTex), index: 1)
            enc.setBytes(&params, length: MemoryLayout<EyeShaderParams>.stride * params.count, index: 0)
            var count = UInt32(params.count)
            enc.setBytes(&count, length: 4, index: 1)
            var origin = SIMD2<UInt32>(UInt32(x0), UInt32(y0))
            enc.setBytes(&origin, length: MemoryLayout<SIMD2<UInt32>>.size, index: 2)
            let tg = MTLSize(width: 16, height: 16, depth: 1)
            let grid = MTLSize(width: (x1 - x0 + 15) / 16, height: (y1 - y0 + 15) / 16, depth: 1)
            enc.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)
            enc.endEncoding()
        }
        cmd.commit()
        cmd.waitUntilCompleted()
        CVBufferPropagateAttachments(pb, out)
        return out
    }

    // MARK: - Iris from pixels

    private func measureIrises(_ pb: CVPixelBuffer, _ eyes: [Eye]) -> [SIMD2<Float>?] {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) else {
            return eyes.map { _ in nil }
        }
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        return eyes.map { eye in
            IrisLocator.locate(base: UnsafePointer(base), bytesPerRow: bpr, width: w, height: h,
                               center: eye.center, halfSize: eye.halfSize)
        }
    }

    // MARK: - Vision (own queue, latest-frame-wins)

    private func scheduleVision(_ pb: CVPixelBuffer) {
        lock.lock()
        if visionBusy { lock.unlock(); return }
        visionBusy = true
        lock.unlock()

        visionQueue.async { [weak self] in
            guard let self else { return }
            let found = Self.detectEyes(in: pb)
            self.lock.lock()
            if found.count == 2 {
                if self.eyes.count == 2 {
                    // Light smoothing against landmark jitter.
                    let a: Float = 0.6
                    self.eyes = zip(self.eyes, found).map { old, new in
                        Eye(center: simd_mix(old.center, new.center, SIMD2(repeating: a)),
                            halfSize: simd_mix(old.halfSize, new.halfSize, SIMD2(repeating: a)),
                            pupil: simd_mix(old.pupil, new.pupil, SIMD2(repeating: a)))
                    }
                } else {
                    self.eyes = found
                }
                self.eyesTime = CACurrentMediaTime()
            }
            self.visionBusy = false
            self.lock.unlock()
        }
    }

    // MARK: - Calibration sampling

    func beginSampling() {
        lock.lock(); samples = []; sampling = true; lock.unlock()
    }

    func endSampling() -> SampleResult {
        lock.lock()
        sampling = false
        let all = samples
        samples = []
        lock.unlock()
        guard !all.isEmpty else { return SampleResult(mean: .zero, count: 0, spread: 1) }
        // Trimmed mean: drop the 20% of samples furthest from the median (saccades, bad landmarks).
        let sortedX = all.map(\.x).sorted(), sortedY = all.map(\.y).sorted()
        let median = SIMD2(sortedX[sortedX.count / 2], sortedY[sortedY.count / 2])
        let kept = all.sorted { simd_distance($0, median) < simd_distance($1, median) }
            .prefix(max(1, Int(Double(all.count) * 0.8)))
        let mean = kept.reduce(SIMD2<Float>.zero, +) / Float(kept.count)
        let variance = kept.reduce(Float(0)) { $0 + simd_distance_squared($1, mean) } / Float(kept.count)
        return SampleResult(mean: mean, count: all.count, spread: variance.squareRoot())
    }

    private static func detectEyes(in pb: CVPixelBuffer) -> [Eye] {
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up)
        try? handler.perform([request])
        guard let face = request.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }),
              let lm = face.landmarks else { return [] }
        let size = CGSize(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb))
        let h = Float(size.height)

        func pts(_ r: VNFaceLandmarkRegion2D?) -> [SIMD2<Float>] {
            (r?.pointsInImage(imageSize: size) ?? []).map { SIMD2(Float($0.x), h - Float($0.y)) }
        }

        var out: [Eye] = []
        for (eyeRegion, pupilRegion) in [(lm.leftEye, lm.leftPupil), (lm.rightEye, lm.rightPupil)] {
            let contour = pts(eyeRegion)
            guard contour.count >= 4 else { return [] }
            let lo = contour.reduce(SIMD2<Float>(repeating: .greatestFiniteMagnitude)) { simd_min($0, $1) }
            let hi = contour.reduce(SIMD2<Float>(repeating: -.greatestFiniteMagnitude)) { simd_max($0, $1) }
            let center = (lo + hi) / 2
            let pupil = pts(pupilRegion).first ?? center
            out.append(Eye(center: center, halfSize: (hi - lo) / 2, pupil: pupil))
        }
        return out
    }

    // MARK: - Metal helpers

    private func texture(_ pb: CVPixelBuffer) -> CVMetalTexture? {
        guard let textureCache else { return nil }
        var tex: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, pb, nil, .bgra8Unorm,
                                                  CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb), 0, &tex)
        return tex
    }

    private func makeOutputBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        if pool == nil || poolSize != (width, height) {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
            var newPool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 6] as CFDictionary,
                                    attrs as CFDictionary, &newPool)
            pool = newPool
            poolSize = (width, height)
        }
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        return out
    }
}
