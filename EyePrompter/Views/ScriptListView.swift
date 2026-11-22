import SwiftUI

struct ScriptListView: View {
    @EnvironmentObject private var store: ScriptStore
    @State private var path: [UUID] = []
    @State private var showImporter = false
    @State private var showPrompt = false
    @AppStorage(Prefs.appLanguage) private var language = AppLanguage.system.rawValue

    var body: some View {
        NavigationStack(path: $path) {
            List {
                ForEach(store.scripts) { script in
                    NavigationLink(value: script.id) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(script.title.isEmpty ? tr("Không tên", "Untitled") : script.title)
                                .font(.headline)
                            Text(script.body.isEmpty ? tr("Chưa có nội dung", "Empty") : script.body)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            HStack(spacing: 6) {
                                Text(tr("\(script.wordCount) chữ · ~\(formatMinutes(script.estimatedMinutes))", "\(script.wordCount) words · ~\(formatMinutes(script.estimatedMinutes))"))
                                    .foregroundStyle(.tertiary)
                                if let pos = ReadingPositionStore.load(script) {
                                    Text(tr("· đang đọc dở \(pos.index * 100 / max(pos.total, 1))%", "· \(pos.index * 100 / max(pos.total, 1))% read"))
                                        .foregroundStyle(Color.prompterYellow)
                                }
                            }
                            .font(.caption)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .onDelete { store.scripts.remove(atOffsets: $0) }
            }
            .navigationTitle(tr("Kịch bản", "Scripts"))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // Universal Clipboard: copy on the Mac (⌘C), tap this on the iPhone.
                    PasteButton(payloadType: String.self) { strings in
                        Task { @MainActor in
                            if let s = store.importText(strings.joined(separator: "\n")) { path = [s.id] }
                        }
                    }
                    .labelStyle(.titleAndIcon)
                    .buttonBorderShape(.capsule)
                    .tint(Color.prompterYellow)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker(tr("Ngôn ngữ", "Language"), selection: $language) {
                            ForEach(AppLanguage.allCases) { Text($0.menuName).tag($0.rawValue) }
                        }
                    } label: {
                        Image(systemName: "globe")
                    }
                    .accessibilityLabel(tr("Ngôn ngữ", "Language"))
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button(tr("Kịch bản trống", "Blank script"), systemImage: "square.and.pencil") {
                            path = [store.add().id]
                        }
                        Button(tr("Mở file (iCloud Drive, Tệp)…", "Open file (iCloud Drive, Files)…"), systemImage: "folder") {
                            showImporter = true
                        }
                        Divider()
                        Button(tr("Prompt chuyển kịch bản (AI)…", "Script conversion prompt (AI)…"), systemImage: "wand.and.stars") {
                            showPrompt = true
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showPrompt) { ConversionPromptView() }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: ScriptStore.importTypes,
                          allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { return }
                let added = urls.compactMap { store.importFile($0) }
                if let last = added.last { path = [last.id] }
            }
            .onChange(of: store.openRequest) {
                if let id = store.openRequest {
                    path = [id]
                    store.openRequest = nil
                }
            }
            .overlay {
                if store.scripts.isEmpty {
                    ContentUnavailableView(tr("Chưa có kịch bản", "No scripts yet"),
                                           systemImage: "text.document",
                                           description: Text(tr("Copy kịch bản trên Mac rồi bấm Dán, hoặc AirDrop file .txt sang iPhone.", "Copy a script on your Mac and tap Paste, or AirDrop a .txt file to your iPhone.")))
                }
            }
            .onAppear {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-openFirst"), path.isEmpty, let first = store.scripts.first {
                    path.append(first.id)
                }
                #endif
            }
            .navigationDestination(for: UUID.self) { id in
                if let binding = store.binding(for: id) {
                    ScriptEditorView(script: binding)
                }
            }
        }
    }
}

func formatMinutes(_ m: Double) -> String {
    let secs = Int((m * 60).rounded())
    return secs < 60 ? tr("\(secs) giây", "\(secs) s") : tr("\(secs / 60) phút \(secs % 60) giây", "\(secs / 60) min \(secs % 60) s")
}

struct ScriptEditorView: View {
    @Binding var script: Script
    @State private var showPrompter = false
    @State private var resume = false
    @State private var saved: ReadingPositionStore.Position?
    @FocusState private var editing: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextField(tr("Tiêu đề", "Title"), text: $script.title)
                .font(.title2.bold())
                .padding(.horizontal)
                .padding(.top, 8)
            TextEditor(text: $script.body)
                .font(.body)
                .focused($editing)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
                .overlay(alignment: .topLeading) {
                    if script.body.isEmpty {
                        Text(tr("Dán hoặc gõ kịch bản ở đây…", "Paste or type your script here…"))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 17)
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                    }
                }
            HStack {
                Text(tr("\(script.wordCount) chữ · ~\(formatMinutes(script.estimatedMinutes))", "\(script.wordCount) words · ~\(formatMinutes(script.estimatedMinutes))"))
                    .font(.footnote)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(.secondary)
                Spacer()
                if let saved {
                    Button {
                        open(resume: false)
                    } label: {
                        Label(tr("Từ đầu", "Restart"), systemImage: "backward.end.fill")
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.bordered)
                    Button {
                        open(resume: true)
                    } label: {
                        Label(tr("Đọc tiếp \(saved.index * 100 / max(saved.total, 1))%", "Resume \(saved.index * 100 / max(saved.total, 1))%"), systemImage: "play.fill")
                            .font(.headline)
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 6)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(.black)
                } else {
                    Button {
                        open(resume: false)
                    } label: {
                        Label(tr("Bắt đầu", "Start"), systemImage: "video.fill")
                            .font(.headline)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(.black)
                    .disabled(script.wordCount == 0)
                }
            }
            .padding()
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(tr("Xong", "Done")) { editing = false }
            }
        }
        .onAppear {
            saved = ReadingPositionStore.load(script)
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-prompter") { showPrompter = true }
            #endif
        }
        .onChange(of: script.body) { saved = ReadingPositionStore.load(script) }
        .fullScreenCover(isPresented: $showPrompter, onDismiss: { saved = ReadingPositionStore.load(script) }) {
            PrompterView(script: script, resume: resume)
        }
    }

    private func open(resume: Bool) {
        editing = false
        self.resume = resume
        showPrompter = true
    }
}
