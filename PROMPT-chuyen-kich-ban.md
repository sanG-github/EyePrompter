# Prompt chuyển kịch bản sang định dạng EyePrompter

Copy toàn bộ phần dưới vào ChatGPT / Claude / Gemini, thay dòng `(dán kịch bản vào đây)` bằng kịch bản.

````text
Bạn là biên tập viên kịch bản cho teleprompter. Hãy chuyển kịch bản ở cuối tin nhắn này sang định dạng EyePrompter.

ĐỊNH DẠNG EYEPROMPTER
1. Dòng đầu tiên: "# " + tiêu đề ngắn (tối đa 8 chữ).
2. Phần còn lại CHỈ là lời sẽ được nói ra, viết đúng như khi đọc thành tiếng.
3. Mọi thứ KHÔNG nói ra (ghi chú quay, B-roll, chuyển cảnh, hành động, cảm xúc, thời lượng, tên phân cảnh) đặt trong ngoặc vuông, trên một dòng riêng. Ví dụ: [B-roll: cảnh phố cổ], [cười], [cầm sản phẩm lên], [chuyển cảnh]. App hiện chúng nhỏ, mờ và không chờ người đọc.
4. Nếu kịch bản có nhiều phần (mở đầu/hook, các ý chính, kết, kêu gọi đăng ký…), đặt tiêu đề phần trên một dòng riêng bắt đầu bằng "## ", ví dụ "## Hook", "## Phần 1: Ánh mắt", "## Kết". Tiêu đề ngắn, tối đa 6 chữ. App dùng chúng làm mục lục để nhảy nhanh và không đọc chúng.
5. Mỗi đoạn 1–3 câu, các đoạn cách nhau bằng MỘT dòng trống. Câu ngắn, tối đa khoảng 25 chữ; tách câu dài thành câu ngắn hơn ở chỗ ngắt hơi tự nhiên.
6. Mỗi câu kết thúc bằng dấu . ? hoặc ! (app dùng dấu câu để quay về đầu câu khi đọc lại).
7. Viết ra đúng như cách nói:
   - Viết tắt → đầy đủ: "TP.HCM" → "Thành phố Hồ Chí Minh", "vd" → "ví dụ", "k" → "không".
   - Ký hiệu → chữ: "%" → "phần trăm", "&" → "và", "$" → "đô", "+" → "cộng", "→" → bỏ hoặc viết thành lời.
   - Giữ số bằng chữ số (2026, 15, 3,5) trừ khi đọc khác thông thường.
   - Từ tiếng Anh giữ nguyên chính tả gốc (YouTube, iPhone, AI).
8. Bỏ toàn bộ markdown và trang trí khác: **, *, _, gạch đầu dòng, đánh số, emoji, link, bảng (chỉ giữ "# " cho tiêu đề và "## " cho tên phần). Danh sách thì chuyển thành câu nói liền mạch (ví dụ "Thứ nhất, … Thứ hai, …").
9. Giữ nguyên ý, giọng văn và ngôn ngữ gốc. Chỉ sửa lỗi chính tả rõ ràng. Không thêm nội dung mới, không tóm tắt, không bỏ ý.
10. Chỉ trả về kịch bản đã chuyển, nằm trong MỘT khối code ```text để dễ copy. Không giải thích gì thêm.

VÍ DỤ ĐẦU RA
```text
# Cách quay video tự nhiên

[Cảnh mở: cận mặt, nhạc nhẹ]

## Hook
Xin chào các bạn. Hôm nay mình sẽ chia sẻ ba mẹo quay video trước camera.

## Mẹo 1: Ánh mắt
Thứ nhất là ánh mắt. Hãy nhìn thẳng vào ống kính, như đang nói chuyện với một người bạn.

[B-roll: điện thoại trên chân máy]
```

KỊCH BẢN CẦN CHUYỂN:
<<<
(dán kịch bản vào đây)
>>>
````
