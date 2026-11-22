import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct Script: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var body: String
    var updatedAt = Date()

    /// Spoken words only (`[notes]` excluded).
    var wordCount: Int { TextNormalizer.tokenize(body).count }
    /// Vietnamese talking-head pace ≈ 150–170 syllables per minute.
    var estimatedMinutes: Double { Double(wordCount) / 160 }
}

@MainActor
final class ScriptStore: ObservableObject {
    @Published var scripts: [Script] = [] {
        didSet { save() }
    }

    private let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("scripts.json")

    init() {
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([Script].self, from: data) {
            scripts = decoded
        } else {
            scripts = [Script.sample]
        }
    }

    func binding(for id: UUID) -> Binding<Script>? {
        guard scripts.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { self.scripts.first(where: { $0.id == id }) ?? Script(title: "", body: "") },
            set: { new in
                if let i = self.scripts.firstIndex(where: { $0.id == id }) {
                    var s = new
                    s.updatedAt = Date()
                    self.scripts[i] = s
                }
            })
    }

    @discardableResult
    func add() -> Script {
        let s = Script(title: "Kịch bản mới", body: "")
        scripts.insert(s, at: 0)
        return s
    }

    /// Set when a file arrives from AirDrop / "Open in…"; the list navigates to it.
    @Published var openRequest: UUID?

    static let importTypes: [UTType] = [.plainText, .utf8PlainText, .text, .rtf,
                                         UTType(filenameExtension: "md") ?? .plainText]

    @discardableResult
    func importText(_ raw: String, title: String? = nil) -> Script? {
        var lines = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") } // pasted from a chat code block
        // EyePrompter format: first non-empty line "# Title".
        var heading: String?
        if let i = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
           lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("#"),
           !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("##") { // "## " = section, not title
            heading = lines[i].trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespaces))
            lines.remove(at: i)
        }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let firstLine = text.split(separator: "\n").first.map(String.init) ?? ""
        let name = heading ?? title ?? String(firstLine.prefix(48))
        let script = Script(title: name.isEmpty ? "Kịch bản" : name, body: text)
        scripts.insert(script, at: 0)
        return script
    }

    /// Imports a .txt / .md / .rtf file (from Files, iCloud Drive or AirDrop).
    @discardableResult
    func importFile(_ url: URL) -> Script? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return nil }
        var text: String?
        if url.pathExtension.lowercased() == "rtf" {
            text = (try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                            documentAttributes: nil))?.string
        } else {
            text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16)
        }
        guard var body = text else { return nil }
        if url.pathExtension.lowercased() == "md" { body = Self.stripMarkdown(body) }
        return importText(body, title: url.deletingPathExtension().lastPathComponent)
    }

    func handleOpen(_ url: URL) {
        if let s = importFile(url) { openRequest = s.id }
    }

    private static func stripMarkdown(_ s: String) -> String {
        var out = s
        // "## " section headings are kept (outline); deeper levels become plain text.
        for (pattern, repl) in [("(?m)^#{3,6}\\s*", ""), ("\\*\\*|__", ""), ("(?m)^\\s*[-*+]\\s+", ""),
                                ("\\[([^\\]]*)\\]\\([^)]*\\)", "$1"), ("`", "")] {
            out = out.replacingOccurrences(of: pattern, with: repl, options: .regularExpression)
        }
        return out
    }

    private func save() {
        if let data = try? JSONEncoder().encode(scripts) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

extension Script {
    static let sample = Script(
        title: "Ví dụ: Giới thiệu kênh",
        body: """
        [Cảnh mở: cận mặt — ghi chú trong ngoặc vuông chỉ để nhắc, không cần đọc]

        ## Mở đầu
        Xin chào các bạn. Hôm nay mình sẽ chia sẻ cách quay một video nói chuyện trước camera sao cho thật tự nhiên.

        ## Ánh mắt
        Điều quan trọng nhất là ánh mắt. Khi bạn nhìn thẳng vào ống kính, người xem sẽ cảm thấy bạn đang nói chuyện trực tiếp với họ.

        ## Chữ chạy theo giọng
        Ứng dụng này sẽ lắng nghe giọng của bạn, và chữ sẽ tự chạy theo. Bạn đọc nhanh thì chữ chạy nhanh, bạn dừng lại thì chữ cũng dừng.

        Còn nếu bạn lỡ đọc sai hay bỏ qua một đoạn, đừng lo, ứng dụng sẽ tự tìm lại vị trí bạn đang đọc.

        ## Kết
        Cảm ơn các bạn đã xem, hẹn gặp lại ở video sau nhé.
        """)
}

/// Remembers where the reader stopped in each script, so reopening the app
/// continues there. Tied to the script's text: editing the text resets it.
enum ReadingPositionStore {
    struct Position { var index: Int; var total: Int }

    private static func key(_ id: UUID) -> String { "readingPos.\(id.uuidString)" }

    /// Stable across launches (Swift's hashValue is not).
    static func fingerprint(_ text: String) -> Int {
        var h: UInt64 = 5381
        for b in text.utf8 { h = (h &* 33) &+ UInt64(b) }
        return Int(truncatingIfNeeded: h)
    }

    static func load(_ script: Script) -> Position? {
        guard let a = UserDefaults.standard.array(forKey: key(script.id)) as? [Int], a.count == 3,
              a[2] == fingerprint(script.body), a[0] > 0, a[0] < a[1] else { return nil }
        return Position(index: a[0], total: a[1])
    }

    static func save(_ index: Int, total: Int, for script: Script) {
        if index <= 0 || index >= total {
            UserDefaults.standard.removeObject(forKey: key(script.id)) // at the start or finished
        } else {
            UserDefaults.standard.set([index, total, fingerprint(script.body)], forKey: key(script.id))
        }
    }
}
