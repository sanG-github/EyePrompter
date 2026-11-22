import SwiftUI

struct ScriptListView: View {
    @EnvironmentObject private var store: ScriptStore
    @State private var path: [UUID] = []
    @State private var showImporter = false
    @State private var showPrompt = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                ForEach(store.scripts) { script in
                    NavigationLink(value: script.id) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(script.title.isEmpty ? "Không tên" : script.title)
                                .font(.headline)
                            Text(script.body.isEmpty ? "Chưa có nội dung" : script.body)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            HStack(spacing: 6) {
                                Text("\(script.wordCount) chữ · ~\(formatMinutes(script.estimatedMinutes))")
                                    .foregroundStyle(.tertiary)
                                if let pos = ReadingPositionStore.load(script) {
                                    Text("· đang đọc dở \(pos.index * 100 / max(pos.total, 1))%")
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
            .navigationTitle("Kịch bản")
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
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Kịch bản trống", systemImage: "square.and.pencil") {
                            path = [store.add().id]
                        }
                        Button("Mở file (iCloud Drive, Tệp)…", systemImage: "folder") {
                            showImporter = true
                        }
                        Divider()
                        Button("Prompt chuyển kịch bản (AI)…", systemImage: "wand.and.stars") {
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
                    ContentUnavailableView("Chưa có kịch bản",
                                           systemImage: "text.document",
                                           description: Text("Copy kịch bản trên Mac rồi bấm Dán, hoặc AirDrop file .txt sang iPhone."))
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
    return secs < 60 ? "\(secs) giây" : "\(secs / 60) phút \(secs % 60) giây"
}

struct ScriptEditorView: View {
    @Binding var script: Script
    @State private var showPrompter = false
    @State private var resume = false
    @State private var saved: ReadingPositionStore.Position?
    @FocusState private var editing: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextField("Tiêu đề", text: $script.title)
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
                        Text("Dán hoặc gõ kịch bản ở đây…")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 17)
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                    }
                }
            HStack {
                Text("\(script.wordCount) chữ · ~\(formatMinutes(script.estimatedMinutes))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                if let saved {
                    Button {
                        open(resume: false)
                    } label: {
                        Label("Từ đầu", systemImage: "backward.end.fill")
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.bordered)
                    Button {
                        open(resume: true)
                    } label: {
                        Label("Đọc tiếp \(saved.index * 100 / max(saved.total, 1))%", systemImage: "play.fill")
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
                        Label("Bắt đầu", systemImage: "video.fill")
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
                Button("Xong") { editing = false }
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
