import SwiftUI
import simd

/// Per-orientation gaze calibration: the pupil movement (in eye widths, image
/// coordinates) between "reading the prompter line" and "looking at the lens".
enum GazeCalibrationStore {
    private static func key(_ o: UIInterfaceOrientation) -> String {
        switch o {
        // v2: stores the camera-look iris position too (gaze lock).
        case .landscapeLeft: return "gazeCal2.landscapeLeft"
        case .landscapeRight: return "gazeCal2.landscapeRight"
        default: return "gazeCal2.portrait"
        }
    }

    static func name(_ o: UIInterfaceOrientation) -> String {
        switch o {
        case .landscapeLeft: return tr("ngang, camera bên phải", "landscape, camera on the right")
        case .landscapeRight: return tr("ngang, camera bên trái", "landscape, camera on the left")
        default: return tr("dọc", "portrait")
        }
    }

    static func load(_ o: UIInterfaceOrientation) -> GazeCalibration? {
        guard let a = UserDefaults.standard.array(forKey: key(o)) as? [Float], a.count == 4 else { return nil }
        return GazeCalibration(camera: SIMD2(a[0], a[1]), offset: SIMD2(a[2], a[3]))
    }

    static func save(_ c: GazeCalibration, _ o: UIInterfaceOrientation) {
        UserDefaults.standard.set([c.camera.x, c.camera.y, c.offset.x, c.offset.y], forKey: key(o))
    }

    static func clear(_ o: UIInterfaceOrientation) {
        UserDefaults.standard.removeObject(forKey: key(o))
    }
}

/// Two-step measurement: look at the lens (2 s), then at the prompter line (2 s).
struct GazeCalibrationOverlay: View {
    let gaze: GazeCorrector
    let orientation: UIInterfaceOrientation
    /// Full-screen points.
    let lens: CGPoint
    let line: CGRect
    let isLandscape: Bool
    let onClose: () -> Void

    private enum Phase: Equatable {
        case camera, text
        case done(message: String, saved: Bool)
        case failed(String)
    }

    @State private var phase: Phase = .camera
    @State private var countdown: Int? = 3
    @State private var progress: Double = 0
    @State private var pulse = false
    @State private var runID = 0

    var body: some View {
        ZStack {
            Color.black.opacity(phase == .text ? 0.15 : 0.45)
                .ignoresSafeArea()
                .allowsHitTesting(true)

            // Target markers
            if phase == .camera {
                // The lens sits inside the Dynamic Island, so point at it from just outside.
                let towardsLens: Angle = isLandscape ? (lens.x < line.midX ? .degrees(-90) : .degrees(90)) : .zero
                Image(systemName: "arrowtriangle.up.fill").font(.system(size: 20))
                .foregroundStyle(Color.prompterYellow)
                .offset(y: pulse ? -6 : 2)
                .rotationEffect(towardsLens)
                .position(isLandscape
                          ? CGPoint(x: lens.x + (lens.x < line.midX ? 46 : -46), y: lens.y)
                          : CGPoint(x: lens.x, y: lens.y + 36))
            }
            if phase == .text {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.prompterYellow, lineWidth: 3)
                    .frame(width: line.width + 16, height: line.height + 10)
                    .scaleEffect(pulse ? 1.03 : 1)
                    .position(x: line.midX, y: line.midY)
            }

            card
                .frame(maxWidth: 340)
                .position(cardPosition)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
        }
        .task(id: runID) { await run() }
    }

    private var cardPosition: CGPoint {
        let screen = UIScreen.main.bounds.size
        let w = isLandscape ? max(screen.width, screen.height) : min(screen.width, screen.height)
        let h = isLandscape ? min(screen.width, screen.height) : max(screen.width, screen.height)
        if isLandscape {
            // Opposite side from the lens.
            return CGPoint(x: lens.x < w / 2 ? w - 200 : 200, y: h / 2)
        }
        return CGPoint(x: w / 2, y: h * 0.62)
    }

    @ViewBuilder private var card: some View {
        VStack(spacing: 14) {
            switch phase {
            case .camera:
                step("1/2", tr("Nhìn thẳng vào camera", "Look straight into the camera"), tr("Mũi tên vàng chỉ chỗ ống kính. Giữ đầu yên, mắt mở tự nhiên.", "The yellow arrow marks the lens. Keep your head still and your eyes relaxed."))
            case .text:
                step("2/2", tr("Nhìn vào dòng chữ trong khung vàng", "Look at the text in the yellow frame"), tr("Như lúc bạn đang đọc. Giữ đầu ở đúng vị trí cũ.", "As if you were reading. Keep your head where it was."))
            case .done(let message, _):
                Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundStyle(Color.prompterYellow)
                Text(message).multilineTextAlignment(.center).font(.subheadline)
                buttons
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.orange)
                Text(message).multilineTextAlignment(.center).font(.subheadline)
                buttons
            }
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
    }

    private func step(_ index: String, _ title: String, _ detail: String) -> some View {
        VStack(spacing: 10) {
            Text(index).font(.caption.bold()).foregroundStyle(.secondary)
            Text(title).font(.headline).multilineTextAlignment(.center)
            Text(detail).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let countdown {
                Text("\(countdown)").font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
            } else {
                ProgressView(value: progress).tint(Color.prompterYellow)
                Text(tr("Đang đo…", "Measuring…")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: 12) {
            Button(tr("Làm lại", "Try again")) {
                phase = .camera
                runID += 1
            }
            .buttonStyle(.bordered)
            Button(tr("Xong", "Done")) { onClose() }
                .buttonStyle(.borderedProminent)
                .foregroundStyle(.black)
        }
    }

    // MARK: - Measurement

    private func run() async {
        phase = .camera
        guard let atCamera = await measure(countFrom: 3) else { return }
        phase = .text
        guard let atText = await measure(countFrom: 2) else { return }
        evaluate(camera: atCamera, text: atText)
    }

    private func measure(countFrom n: Int) async -> GazeCorrector.SampleResult? {
        progress = 0
        for i in stride(from: n, through: 1, by: -1) {
            countdown = i
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { return nil }
        }
        countdown = nil
        gaze.beginSampling()
        let steps = 40
        for i in 1...steps {
            try? await Task.sleep(for: .milliseconds(50))
            if Task.isCancelled { _ = gaze.endSampling(); return nil }
            progress = Double(i) / Double(steps)
        }
        return gaze.endSampling()
    }

    private func evaluate(camera: GazeCorrector.SampleResult, text: GazeCorrector.SampleResult) {
        guard camera.count >= 10, text.count >= 10 else {
            phase = .failed(tr("Không thấy rõ mắt (\(min(camera.count, text.count)) khung hình). Đưa mặt vào giữa khung, đủ sáng, rồi làm lại.", "Couldn’t see your eyes clearly (\(min(camera.count, text.count)) frames). Center your face in good light and try again."))
            return
        }
        guard max(camera.spread, text.spread) < 0.08 else {
            phase = .failed(tr("Mắt hoặc đầu di chuyển nhiều quá trong lúc đo. Giữ yên rồi làm lại nhé.", "Your eyes or head moved too much while measuring. Hold still and try again."))
            return
        }
        // How the pupil must move to go from "reading" to "looking at the lens".
        let offset = camera.mean - text.mean
        let magnitude = simd_length(offset)
        let percent = String(format: "%.1f", magnitude * 100)
        guard magnitude < 0.25 else {
            phase = .failed(tr("Kết quả bất thường (\(percent)% bề rộng mắt). Làm lại và giữ đầu yên giữa hai bước.", "Unusual result (\(percent)% of eye width). Try again and keep your head still between the two steps."))
            return
        }
        // Saved even when the offset is tiny: the camera-look position is what the
        // gaze lock pulls the iris back to while reading.
        GazeCalibrationStore.save(GazeCalibration(camera: camera.mean, offset: offset), orientation)
        let direction: String
        if abs(offset.y) >= abs(offset.x) {
            direction = offset.y < 0 ? tr("chủ yếu nhìn xuống", "mostly downward") : tr("chủ yếu nhìn lên", "mostly upward")
        } else {
            // Samples are stored un-mirrored: +x in the image is the user's left.
            direction = offset.x > 0 ? tr("chủ yếu liếc sang phải", "mostly to the right") : tr("chủ yếu liếc sang trái", "mostly to the left")
        }
        phase = .done(message: tr("Đã lưu cho chế độ \(GazeCalibrationStore.name(orientation)). Khi đọc, mắt bạn lệch \(percent)% bề rộng mắt, \(direction). Từ giờ app khoá tròng mắt về đúng vị trí lúc bạn nhìn camera.", "Saved for \(GazeCalibrationStore.name(orientation)). While reading, your eyes are off by \(percent)% of eye width, \(direction). From now on the app locks your irises to where they were when you looked at the camera."),
                      saved: true)
    }
}
