# EyePrompter

Ứng dụng teleprompter cho iPhone: chữ chạy theo giọng đọc, kèm chỉnh ánh mắt nhìn thẳng vào camera.

## Tính năng

- **Chữ chạy theo giọng nói**: nhận dạng giọng nói tiếng Việt (SFSpeechRecognizer) và so khớp với kịch bản từng chữ. App tự ước tính tốc độ đọc (chữ/phút) để cuộn mượt, vẫn theo kịp khi đọc nhanh.
- **Đọc lại**: khi bạn đọc lại một câu, chữ tự lùi về đúng chỗ. Có nút "↺ Câu", kéo chữ để chọn dòng muốn đọc, và mục lục để nhảy theo đoạn hoặc theo tiêu đề.
- **Đọc tiếp**: mở lại app thì tiếp tục từ chỗ đang đọc dở.
- **Chỉnh ánh mắt**: Vision tìm vùng mắt, một shader Metal dời tròng mắt để trông như đang nhìn vào camera. Hiệu chỉnh mất 4 giây: nhìn camera 2 giây, rồi nhìn chữ 2 giây.
- **Quay video**: camera trước, 1080p hoặc 4K, 30 hoặc 60 fps, chỉnh phơi sáng và zoom, tuỳ chọn lật gương. Video được lưu vào Ảnh. Hỗ trợ cả màn hình dọc lẫn ngang.
- **Nhập kịch bản**: dán từ Mac qua Universal Clipboard, AirDrop file `.txt`, `.md` hoặc `.rtf`, hoặc mở bằng "Mở trong".

## Định dạng kịch bản

```text
# Tên video

## Mở đầu
Chào mọi người. Câu ngắn, viết đúng như khi đọc.

[B-roll: ghi chú không đọc, nằm trên một dòng riêng]

## Phần 1
Đoạn văn từ 1 đến 3 câu, cách nhau bằng một dòng trống.
```

- `PROMPT-chuyen-kich-ban.md`: prompt để dán vào AI bất kỳ, giúp chuyển kịch bản sang định dạng này.
- `skills/eyeprompter-script/`: skill dùng cho Claude Code, Antigravity hoặc Gemini CLI để viết hoặc chuyển kịch bản, kèm script kiểm tra `scripts/check_script.py`. Muốn cài, chép thư mục này vào `~/.claude/skills/`.

## Build

Cần Xcode 16 trở lên, iOS 17 trở lên.

1. Mở `EyePrompter.xcodeproj`.
2. Ở *Signing & Capabilities*, chọn Team của bạn và đổi Bundle Identifier.
3. Chạy trên iPhone thật. Simulator không có camera trước nên không thử được phần quay và chỉnh mắt.
