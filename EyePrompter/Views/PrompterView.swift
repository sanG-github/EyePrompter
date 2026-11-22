import AVKit
import SwiftUI

struct PrompterView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm: PrompterViewModel

    @AppStorage(Prefs.fontSize) private var fontSize: Double = 30
    @AppStorage(Prefs.visibleLines) private var visibleLines: Double = 4
    @AppStorage(Prefs.columnWidth) private var columnWidth: Double = 0.86
    @AppStorage(Prefs.localeID) private var localeID = "vi-VN"
    @AppStorage(Prefs.eyeContact) private var eyeContact = true
    @AppStorage(Prefs.eyeStrength) private var eyeStrength: Double = 1.0
    @AppStorage(Prefs.autoWPM) private var autoWPM: Double = 150
    @AppStorage(Prefs.centerText) private var centerText = true
    @AppStorage(Prefs.narrowColumn) private var narrowColumn = true
    @AppStorage(Prefs.camResolution) private var camResolution = "1080p"
    @AppStorage(Prefs.camFPS) private var camFPS = 30
    @AppStorage(Prefs.camExposure) private var camExposure: Double = 0
    @AppStorage(Prefs.camZoom) private var camZoom: Double = 1
    @AppStorage(Prefs.camMirror) private var camMirror = true
    @AppStorage(Prefs.autoRewind) private var autoRewind = true

    @State private var showSettings = false
    @State private var comparing = false
    @State private var showRewind = false
    @State private var showOutline = false
    @State private var calibrating = false
    @State private var calibrationVersion = 0

    init(script: Script, resume: Bool = false) {
        _vm = StateObject(wrappedValue: PrompterViewModel(script: script, resume: resume))
    }

    private var lineHeight: CGFloat { fontSize * 1.42 }
    /// Narrow mode keeps each line to a few words right under the lens, so the
    /// eyes barely sweep left-right while reading.
    private var portraitColumnFraction: CGFloat { narrowColumn ? min(columnWidth, 0.52) : columnWidth }
    private let portraitAnchor: CGFloat = 8
    @StateObject private var orientationObserver = OrientationObserver()
    private var orientation: UIInterfaceOrientation { orientationObserver.orientation }

    private var isLandscape: Bool { orientation.isLandscape }
    /// In landscapeRight the top of the phone (the camera) is on the left of the screen.
    private var lensOnLeft: Bool { orientation == .landscapeRight }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                CameraLayer(camera: vm.camera)
                if isLandscape { landscapeLayout(geo) } else { portraitLayout(geo) }
                if calibrating {
                    let g = layoutGeometry(geo, orientation)
                    GazeCalibrationOverlay(gaze: vm.camera.gaze,
                                           orientation: orientation,
                                           lens: g.lens,
                                           line: g.line,
                                           isLandscape: isLandscape) {
                        calibrating = false
                        calibrationVersion += 1
                    }
                    .transition(.opacity)
                }
            }
            .ignoresSafeArea()
            .onAppear {
                updateOrientation(geo)
                applyCamera()
                vm.autoRewind = autoRewind
                vm.appear()
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-calibrate") { calibrating = true }
                if ProcessInfo.processInfo.arguments.contains("-settings") { showSettings = true }
                if ProcessInfo.processInfo.arguments.contains("-auto") { vm.mode = .auto }
                if ProcessInfo.processInfo.arguments.contains("-outline") { showOutline = true }
                #endif
            }
            .onDisappear { vm.disappear() }
            .onChange(of: geo.size) { orientationObserver.refresh(); applySettings(geo: geo) }
            .onChange(of: orientationObserver.orientation) { updateOrientation(geo) }
            .onChange(of: gazeKey) { applySettings(geo: geo) }
            .onChange(of: cameraKey) { applyCamera() }
            .onChange(of: autoRewind) { vm.autoRewind = autoRewind }
            .onChange(of: calibrating) { if calibrating { vm.paused = true } }
            .onChange(of: autoWPM) { vm.autoWPM = autoWPM }
            .onChange(of: vm.rewindCount) {
                withAnimation(.spring(duration: 0.25)) { showRewind = true }
                let n = vm.rewindCount
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                    if vm.rewindCount == n { withAnimation(.easeOut) { showRewind = false } }
                }
            }
            .onChange(of: localeID) {
                vm.localeID = localeID
                vm.restartSpeech()
            }
        }
        .statusBarHidden()
        .sheet(isPresented: $showOutline) {
            OutlineSheet(vm: vm)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showSettings) {
            PrompterSettingsView(camera: vm.camera, orientation: orientation, onCalibrate: {
                showSettings = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    withAnimation { calibrating = true }
                }
            }, onCalibrationChanged: { calibrationVersion += 1 })
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    /// Everything that changes the eye-contact geometry (one onChange instead of many:
    /// keeps the body cheap to type-check).
    private var gazeKey: [Double] {
        [fontSize, columnWidth, narrowColumn ? 1 : 0, eyeContact ? 1 : 0, eyeStrength,
         comparing ? 1 : 0, calibrating ? 1 : 0, Double(calibrationVersion)]
    }

    private var cameraKey: [Double] {
        [camResolution == "4K" ? 1 : 0, Double(camFPS), camExposure, camZoom, camMirror ? 1 : 0]
    }

    private func applyCamera() {
        vm.camera.apply(CameraPipeline.Config(
            resolution: CameraPipeline.Config.Resolution(rawValue: camResolution) ?? .hd1080,
            fps: camFPS,
            exposureBias: Float(camExposure),
            zoom: camZoom,
            mirrored: camMirror))
    }

    // MARK: Layouts

    /// Portrait: a band of text right under the camera at the top of the screen.
    private func portraitLayout(_ geo: GeometryProxy) -> some View {
        let bandHeight = lineHeight * visibleLines + portraitAnchor + 8
        return VStack(spacing: 0) {
            prompterText(anchorY: portraitAnchor)
                .frame(width: geo.size.width * portraitColumnFraction, height: bandHeight)
                .mask(LinearGradient(stops: [.init(color: .black, location: 0),
                                             .init(color: .black, location: 0.72),
                                             .init(color: .black.opacity(0), location: 1)],
                                     startPoint: .top, endPoint: .bottom))
                .padding(.top, geo.safeAreaInsets.top)
                .frame(maxWidth: .infinity)
                .background(LinearGradient(colors: [.black.opacity(0.92), .black.opacity(0.7)],
                                           startPoint: .top, endPoint: .bottom))
                .overlay(alignment: .bottom) { progressBar }

            HStack(spacing: 8) {
                closeButton
                Spacer(minLength: 0)
                statusRow
                Spacer(minLength: 0)
                outlineButton
                rewindButton
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            Spacer()
            VStack(spacing: 14) {
                CameraMessage(camera: vm.camera)
                if vm.mode == .auto { speedSlider.padding(.horizontal, 24) }
                // Spacers instead of fixed gaps: the bar fits any width.
                HStack(spacing: 0) {
                    LibraryButton(camera: vm.camera)
                    Spacer(minLength: 4)
                    modeMenu
                    Spacer(minLength: 4)
                    pauseButton
                    Spacer(minLength: 4)
                    RecordButton(camera: vm.camera) { vm.toggleRecording() }
                    Spacer(minLength: 4)
                    eyeButton
                    Spacer(minLength: 4)
                    settingsButton
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, 16)
                if vm.mode != .voice { HStack(spacing: 18) { stepButtons } }
            }
            .padding(.bottom, max(geo.safeAreaInsets.bottom, 12))
        }
    }

    /// Landscape: the camera is on a short edge, so the text column hugs that edge
    /// and the line being read stays at mid-height, level with the lens.
    private func landscapeLayout(_ geo: GeometryProxy) -> some View {
        let fullH = geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom
        let lensInset = lensOnLeft ? geo.safeAreaInsets.leading : geo.safeAreaInsets.trailing
        let farInset = lensOnLeft ? geo.safeAreaInsets.trailing : geo.safeAreaInsets.leading
        let colW = landscapeColumnWidth(geo)
        let band = prompterText(anchorY: fullH / 2 - lineHeight / 2)
            .frame(width: colW, height: fullH)
            .mask(LinearGradient(stops: [.init(color: .black.opacity(0), location: 0),
                                         .init(color: .black, location: 0.18),
                                         .init(color: .black, location: 0.8),
                                         .init(color: .black.opacity(0), location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .padding(lensOnLeft ? .leading : .trailing, lensInset + 8)
            .padding(lensOnLeft ? .trailing : .leading, 12)
            .background(LinearGradient(colors: [.black.opacity(0.9), .black.opacity(0.6)],
                                       startPoint: lensOnLeft ? .leading : .trailing,
                                       endPoint: lensOnLeft ? .trailing : .leading))
            .overlay(alignment: .bottom) { progressBar }
        // Controls column: width follows what the text column leaves free.
        let fullW = geo.size.width + geo.safeAreaInsets.leading + geo.safeAreaInsets.trailing
        let controlsW = max(190, min(250, fullW - colW - lensInset - farInset - 40))
        let controls = VStack(spacing: 12) {
            statusRow
            Spacer(minLength: 0)
            CameraMessage(camera: vm.camera)
            if vm.mode == .auto { speedSlider }
            spreadRow { closeButton; modeMenu; pauseButton }
            spreadRow {
                LibraryButton(camera: vm.camera)
                RecordButton(camera: vm.camera) { vm.toggleRecording() }
                eyeButton
            }
            spreadRow {
                settingsButton
                outlineButton
                circleButton("arrow.uturn.backward") { vm.rewindSentence() }
                if vm.mode != .voice { stepButtons }
            }
            Spacer(minLength: 0)
        }
        .frame(width: controlsW)
        .padding(.vertical, 16)
        .padding(lensOnLeft ? .trailing : .leading, farInset + 8)

        return HStack(spacing: 0) {
            if lensOnLeft { band; Spacer(minLength: 0); controls } else { controls; Spacer(minLength: 0); band }
        }
    }

    private func landscapeColumnWidth(_ geo: GeometryProxy) -> CGFloat {
        let fullW = geo.size.width + geo.safeAreaInsets.leading + geo.safeAreaInsets.trailing
        return min(fullW - 260, fullW * (narrowColumn ? 0.3 : 0.62 * columnWidth))
    }

    private func prompterText(anchorY: CGFloat) -> some View {
        PrompterTextView(text: vm.script.body,
                         tokens: vm.tokens,
                         cursor: vm.cursor,
                         fontSize: fontSize,
                         centered: centerText,
                         anchorY: anchorY,
                         onPickToken: { vm.jump(to: $0) },
                         onPace: { wpm in if vm.wordsPerMinute != wpm { vm.wordsPerMinute = wpm } })
    }

    // MARK: Orientation + eye-contact geometry

    private func updateOrientation(_ geo: GeometryProxy) {
        orientationObserver.refresh()
        let o = orientationObserver.orientation
        vm.camera.setInterfaceOrientation(o)
        applySettings(geo: geo, orientation: o)
    }

    /// Front-camera lens position and the rectangle of the line being read, in
    /// full-screen points (the coordinate space of the safe-area-ignoring ZStack).
    private func layoutGeometry(_ geo: GeometryProxy, _ o: UIInterfaceOrientation) -> (lens: CGPoint, line: CGRect) {
        let ins = geo.safeAreaInsets
        let fullW = geo.size.width + ins.leading + ins.trailing
        let fullH = geo.size.height + ins.top + ins.bottom
        if o.isLandscape {
            let onLeft = o == .landscapeRight
            let lensInset = onLeft ? ins.leading : ins.trailing
            let lensDepth: CGFloat = lensInset > 40 ? 24 : 12 // Dynamic Island / notch
            let colW = landscapeColumnWidth(geo)
            let x = onLeft ? lensInset + 8 : fullW - lensInset - 8 - colW
            return (CGPoint(x: onLeft ? lensDepth : fullW - lensDepth, y: fullH / 2),
                    CGRect(x: x, y: fullH / 2 - lineHeight / 2, width: colW, height: lineHeight))
        } else {
            let colW = geo.size.width * portraitColumnFraction
            return (CGPoint(x: fullW / 2, y: ins.top > 40 ? 24 : 12),
                    CGRect(x: (fullW - colW) / 2, y: ins.top + portraitAnchor, width: colW, height: lineHeight))
        }
    }

    /// Pushes layout-derived numbers to the gaze corrector: where (in mm on the
    /// physical screen) the line being read is relative to the front camera lens,
    /// plus the user's measured calibration for this orientation, if any.
    private func applySettings(geo: GeometryProxy, orientation o: UIInterfaceOrientation? = nil) {
        let o = o ?? orientation
        vm.localeID = localeID
        vm.autoWPM = autoWPM
        let scale = UIScreen.main.scale
        let ppi: CGFloat = scale >= 3 ? 460 : 326
        let mmPerPoint = 25.4 / (ppi / scale)
        let (lens, line) = layoutGeometry(geo, o)
        // Where the eyes rest while reading: near the start of the line in landscape
        // (the column hugs the lens), the line centre in portrait.
        let reading = o.isLandscape
            ? CGPoint(x: lens.x < line.midX ? line.minX + line.width * 0.45 : line.maxX - line.width * 0.45, y: line.midY)
            : CGPoint(x: line.midX, y: line.minY + lineHeight * 0.9)

        var s = vm.camera.gaze.settings
        s.enabled = eyeContact
        s.strength = Float(eyeStrength)
        s.bypass = comparing || calibrating
        s.textOffsetMM = SIMD2(Float((reading.x - lens.x) * mmPerPoint), Float((reading.y - lens.y) * mmPerPoint))
        s.calibration = GazeCalibrationStore.load(o)
        vm.camera.gaze.settings = s
    }

    // MARK: Pieces

    private var progressBar: some View {
        GeometryReader { g in
            Rectangle()
                .fill(Color.prompterYellow)
                .frame(width: g.size.width * vm.progress, height: 2)
                .animation(.easeOut(duration: 0.3), value: vm.progress)
        }
        .frame(height: 2)
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            RecordingBadge(camera: vm.camera)
            if showRewind {
                Label("Đọc lại", systemImage: "arrow.uturn.backward")
                    .font(.caption.bold())
                    .foregroundStyle(.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.prompterYellow, in: Capsule())
                    .transition(.scale.combined(with: .opacity))
            }
            if vm.mode == .voice {
                Label(vm.paused ? "Tạm dừng"
                      : vm.heard.isEmpty ? vm.speechStatus
                      : vm.wordsPerMinute > 0 ? "≈\(vm.wordsPerMinute) từ/phút · \(vm.heard)" : vm.heard,
                      systemImage: vm.paused ? "pause.fill" : "waveform")
                    .lineLimit(1)
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            if let msg = vm.permissionProblem {
                Text(msg).font(.caption).padding(6).background(.red.opacity(0.8), in: Capsule())
            }
        }
        .padding(.horizontal)
    }

    private var speedSlider: some View {
        HStack {
            Image(systemName: "tortoise")
            Slider(value: $autoWPM, in: 60...260, step: 5)
            Image(systemName: "hare")
            Text("\(Int(autoWPM))/ph").font(.caption.monospacedDigit()).frame(width: 52)
        }
    }

    /// Jump to a section / paragraph.
    private var outlineButton: some View {
        circleButton("list.bullet.indent") { showOutline = true }
            .accessibilityLabel("Mục lục")
    }

    /// "Read this sentence again" — tap once for the current sentence, again for the previous.
    private var rewindButton: some View {
        Button { vm.rewindSentence() } label: {
            Label("Câu", systemImage: "arrow.uturn.backward")
                .font(.footnote.bold())
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    /// A centred row of controls that never overflows the column.
    private func spreadRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) { content() }
            .frame(maxWidth: .infinity)
            .minimumScaleFactor(0.8)
    }

    private var closeButton: some View { circleButton("xmark") { dismiss() } }
    private var pauseButton: some View { circleButton(vm.paused ? "play.fill" : "pause.fill") { vm.paused.toggle() } }
    private var settingsButton: some View { circleButton("slider.horizontal.3") { showSettings = true } }

    @ViewBuilder private var stepButtons: some View {
        circleButton("chevron.up") { vm.step(-5) }
        circleButton("chevron.down") { vm.step(5) }
    }

    private var modeMenu: some View {
        Menu {
            Picker("Chế độ", selection: $vm.mode) {
                ForEach(PrompterViewModel.ScrollMode.allCases) { m in
                    Label(m.title, systemImage: m.icon).tag(m)
                }
            }
            Divider()
            Button("Về đầu kịch bản", systemImage: "arrow.uturn.backward") { vm.restartFromTop() }
        } label: {
            circleLabel(vm.mode.icon)
        }
    }

    private var eyeButton: some View {
        circleLabel(eyeContact ? "eye.fill" : "eye.slash")
            .foregroundStyle(eyeContact ? Color.prompterYellow : .white)
            .onTapGesture { eyeContact.toggle() }
            .onLongPressGesture(minimumDuration: 0.25, maximumDistance: 40, pressing: { comparing = $0 }, perform: {})
            .overlay(alignment: .top) {
                if comparing {
                    Text("Gốc").font(.caption2.bold()).padding(4)
                        .background(.black.opacity(0.7), in: Capsule()).offset(y: -26)
                }
            }
    }

    private func circleButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { circleLabel(icon) }.buttonStyle(.plain)
    }

    private func circleLabel(_ icon: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 17, weight: .semibold))
            .frame(width: 44, height: 44)
            .background(.ultraThinMaterial, in: Circle())
    }
}

// MARK: - Camera-observing pieces

private struct CameraLayer: View {
    @ObservedObject var camera: CameraPipeline
    var body: some View {
        ZStack {
            Color.black
            if camera.hasCamera {
                CameraPreview(pipeline: camera, framesMirrored: camera.outputMirrored)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "video.slash").font(.largeTitle)
                    Text("Không có camera trước (Simulator?)").font(.footnote)
                }
                .foregroundStyle(.secondary)
            }
        }
    }
}

private struct RecordButton: View {
    @ObservedObject var camera: CameraPipeline
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().stroke(.white, lineWidth: 4).frame(width: 72, height: 72)
                RoundedRectangle(cornerRadius: camera.isRecording ? 6 : 30)
                    .fill(.red)
                    .frame(width: camera.isRecording ? 28 : 58, height: camera.isRecording ? 28 : 58)
                    .animation(.spring(duration: 0.25), value: camera.isRecording)
            }
        }
        .buttonStyle(.plain)
        .disabled(!camera.hasCamera)
        .opacity(camera.hasCamera ? 1 : 0.4)
    }
}

private struct RecordingBadge: View {
    @ObservedObject var camera: CameraPipeline
    var body: some View {
        if let start = camera.recordingStartedAt {
            TimelineView(.periodic(from: start, by: 1)) { ctx in
                let s = Int(ctx.date.timeIntervalSince(start))
                Label(String(format: "%02d:%02d", s / 60, s % 60), systemImage: "record.circle")
                    .font(.caption.monospacedDigit().bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.red, in: Capsule())
            }
        }
    }
}

private struct CameraMessage: View {
    @ObservedObject var camera: CameraPipeline
    var body: some View {
        if let msg = camera.message {
            Text(msg)
                .font(.footnote)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .task(id: msg) {
                    try? await Task.sleep(for: .seconds(3))
                    camera.message = nil
                }
        }
    }
}

// MARK: - Settings

struct PrompterSettingsView: View {
    @ObservedObject var camera: CameraPipeline
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Prefs.camResolution) private var camResolution = "1080p"
    @AppStorage(Prefs.camFPS) private var camFPS = 30
    @AppStorage(Prefs.camExposure) private var camExposure: Double = 0
    @AppStorage(Prefs.camZoom) private var camZoom: Double = 1
    @AppStorage(Prefs.camMirror) private var camMirror = true
    @AppStorage(Prefs.autoRewind) private var autoRewind = true
    var orientation: UIInterfaceOrientation = .portrait
    var onCalibrate: () -> Void = {}
    var onCalibrationChanged: () -> Void = {}
    @State private var hasCalibration = false
    @AppStorage(Prefs.fontSize) private var fontSize: Double = 30
    @AppStorage(Prefs.visibleLines) private var visibleLines: Double = 4
    @AppStorage(Prefs.columnWidth) private var columnWidth: Double = 0.86
    @AppStorage(Prefs.localeID) private var localeID = "vi-VN"
    @AppStorage(Prefs.eyeContact) private var eyeContact = true
    @AppStorage(Prefs.eyeStrength) private var eyeStrength: Double = 1.0
    @AppStorage(Prefs.centerText) private var centerText = true
    @AppStorage(Prefs.narrowColumn) private var narrowColumn = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Độ phân giải", selection: $camResolution) {
                        Text("1080p").tag("1080p")
                        Text("4K").tag("4K")
                    }
                    .pickerStyle(.segmented)
                    Picker("Khung hình/giây", selection: $camFPS) {
                        Text("30 fps").tag(30)
                        Text("60 fps").tag(60)
                    }
                    .pickerStyle(.segmented)
                    .disabled(camResolution == "4K" && !camera.supports4K60)
                    LabeledSlider(title: "Độ sáng", value: $camExposure, range: -2...2, step: 0.1, format: "%+.1f EV")
                    if camera.zoomRange.upperBound > 1.05 {
                        LabeledSlider(title: "Zoom", value: $camZoom, range: camera.zoomRange, step: 0.05, format: "%.2fx")
                    }
                    Toggle(isOn: $camMirror) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Video giống lúc quay (lật gương)")
                            Text(camMirror ? "Video ra y như màn hình xem trước" : "Video ra đúng chiều thật (chữ trên áo đọc xuôi)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Button("Đặt lại độ sáng & zoom") { camExposure = 0; camZoom = 1 }
                } header: { Text("Camera") } footer: {
                    Text(camera.isRecording
                         ? "Đang quay: độ phân giải và fps sẽ áp dụng cho lần quay sau. Độ sáng và zoom đổi ngay."
                         : "4K cho hình nét hơn nhưng file nặng hơn và máy nóng hơn. Khung xem trước hiển thị đúng khung hình sẽ được quay.")
                }
                .onChange(of: camResolution) { if camResolution == "4K" && !camera.supports4K60 { camFPS = 30 } }
                Section("Chữ") {
                    LabeledSlider(title: "Cỡ chữ", value: $fontSize, range: 20...56, format: "%.0f pt")
                    LabeledSlider(title: "Số dòng hiển thị", value: $visibleLines, range: 2...10, step: 1, format: "%.0f")
                    Toggle(isOn: $narrowColumn) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Ít liếc mắt")
                            Text("Cột hẹp vài chữ ngay dưới camera — mắt gần như không lướt ngang")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    LabeledSlider(title: "Độ rộng cột", value: $columnWidth, range: 0.3...1, format: "%.0f%%", scale: 100)
                        .disabled(narrowColumn)
                    Toggle("Căn giữa", isOn: $centerText)
                }
                Section {
                    Picker("Ngôn ngữ đọc", selection: $localeID) {
                        Text("Tiếng Việt").tag("vi-VN")
                        Text("English (US)").tag("en-US")
                        Text("English (UK)").tag("en-GB")
                    }
                    Toggle("Tự lùi khi đọc lại", isOn: $autoRewind)
                } header: { Text("Giọng nói") } footer: {
                    Text("Chữ trôi theo tốc độ đọc của bạn. Muốn đọc lại chỗ nào: vuốt chữ cho dòng đó nằm ở mũi tên vàng rồi thả tay, hoặc chạm vào chữ.")
                }
                Section {
                    Toggle("Chỉnh ánh mắt nhìn camera", isOn: $eyeContact)
                    LabeledSlider(title: "Mức chỉnh", value: $eyeStrength, range: 0...2, format: "%.0f%%", scale: 100)
                        .disabled(!eyeContact)
                    Button {
                        onCalibrate()
                    } label: {
                        Label(hasCalibration ? "Hiệu chỉnh lại ánh mắt…" : "Hiệu chỉnh ánh mắt…", systemImage: "scope")
                    }
                    if hasCalibration {
                        Button("Xoá hiệu chỉnh (\(GazeCalibrationStore.name(orientation)))", role: .destructive) {
                            GazeCalibrationStore.clear(orientation)
                            hasCalibration = false
                            onCalibrationChanged()
                        }
                    }
                } header: { Text("Eye contact") } footer: {
                    Text(hasCalibration
                         ? "Đang dùng số đo thật của mắt bạn (\(GazeCalibrationStore.name(orientation))). Nhấn giữ nút con mắt để so với hình gốc."
                         : "Đang dùng số ước tính. Hiệu chỉnh 4 giây để app đo độ lệch thật của mắt bạn — làm riêng cho quay dọc và quay ngang.")
                }
            }
            .onAppear { hasCalibration = GazeCalibrationStore.load(orientation) != nil }
            .navigationTitle("Cài đặt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Xong") { dismiss() } }
            }
        }
    }
}

private struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    let format: String
    var scale: Double = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value * scale)).foregroundStyle(.secondary).monospacedDigit()
            }
            if let step {
                Slider(value: $value, in: range, step: step)
            } else {
                Slider(value: $value, in: range)
            }
        }
    }
}

// MARK: - Library

/// Thumbnail of the last clip: tap to review it right away; with no clip yet, opens Photos.
private struct LibraryButton: View {
    @ObservedObject var camera: CameraPipeline
    @Environment(\.openURL) private var openURL
    @State private var showClip = false

    var body: some View {
        Button {
            if camera.lastClipURL != nil { showClip = true } else { openURL(RecentClipView.photosURL) }
        } label: {
            Group {
                if let thumb = camera.lastClipThumbnail {
                    Image(uiImage: thumb).resizable().scaledToFill()
                } else {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.ultraThinMaterial)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.8), lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Video vừa quay")
        .sheet(isPresented: $showClip) {
            if let url = camera.lastClipURL { RecentClipView(url: url) }
        }
    }
}

struct RecentClipView: View {
    static let photosURL = URL(string: "photos-redirect://")!
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var player: AVPlayer?

    var body: some View {
        NavigationStack {
            VideoPlayer(player: player)
                .ignoresSafeArea(edges: .bottom)
                .background(.black)
                .onAppear {
                    let p = AVPlayer(url: url)
                    player = p
                    p.play()
                }
                .onDisappear { player?.pause() }
                .navigationTitle("Video vừa quay")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Đóng") { dismiss() } }
                    ToolbarItemGroup(placement: .primaryAction) {
                        ShareLink(item: url)
                        Button("Mở Ảnh", systemImage: "photo.on.rectangle") { openURL(Self.photosURL) }
                    }
                }
        }
    }
}


// MARK: - Outline

/// Sections (## headings) and paragraphs; tap one to continue reading from there.
struct OutlineSheet: View {
    @ObservedObject var vm: PrompterViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    Section {
                        HStack(spacing: 12) {
                            Button {
                                vm.stepParagraph(-1)
                                dismiss()
                            } label: {
                                Label("Đoạn trước", systemImage: "chevron.up").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            Button {
                                vm.stepParagraph(1)
                                dismiss()
                            } label: {
                                Label("Đoạn sau", systemImage: "chevron.down").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                        .listRowBackground(Color.clear)
                    }
                    Section {
                        ForEach(vm.outline) { item in
                            row(item).id(item.id)
                        }
                    } footer: {
                        Text("Thêm dòng \"## Tên phần\" vào kịch bản để chia phần (Hook, Phần 1, Kết…).")
                    }
                }
                .onAppear {
                    if let i = vm.currentOutlineIndex { proxy.scrollTo(i, anchor: .center) }
                }
            }
            .navigationTitle("Mục lục")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Xong") { dismiss() } }
            }
        }
    }

    @ViewBuilder private func row(_ item: OutlineItem) -> some View {
        let isCurrent = item.id == vm.currentOutlineIndex
        Button {
            vm.jump(to: item.tokenIndex)
            dismiss()
        } label: {
            switch item.kind {
            case .heading:
                Text(item.title.uppercased())
                    .font(.footnote.weight(.heavy))
                    .foregroundStyle(Color.prompterYellow)
                    .padding(.top, 6)
            case .paragraph:
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: isCurrent ? "play.fill" : "circle.fill")
                        .font(.system(size: isCurrent ? 11 : 5))
                        .foregroundStyle(isCurrent ? Color.prompterYellow : .secondary)
                        .frame(width: 14)
                    Text(item.title + "…")
                        .lineLimit(2)
                        .foregroundStyle(item.tokenIndex + 1 < vm.cursor && !isCurrent ? .secondary : .primary)
                }
            }
        }
        .buttonStyle(.plain)
        .listRowBackground(isCurrent ? Color.prompterYellow.opacity(0.12) : nil)
    }
}
