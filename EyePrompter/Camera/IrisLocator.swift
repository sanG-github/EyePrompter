import simd

/// Finds the iris centre inside an eye opening from the pixels of the current
/// frame: the iris (and pupil) is the darkest blob between the eyelids, the sclera
/// around it is bright. We take the darkest ~30 % of pixels inside a slightly
/// shrunken ellipse (to stay clear of the eye corners and the lash line) and
/// return their darkness-weighted centroid.
enum IrisLocator {
    static func locate(base: UnsafePointer<UInt8>, bytesPerRow bpr: Int, width w: Int, height h: Int,
                       center: SIMD2<Float>, halfSize: SIMD2<Float>, darkFraction: Int = 30) -> SIMD2<Float>? {
        let hw = halfSize.x * 0.85
        let hh = max(halfSize.y * 0.75, 2)
        let x0 = max(0, Int(center.x - hw)), x1 = min(w - 1, Int(center.x + hw))
        let y0 = max(0, Int(center.y - hh)), y1 = min(h - 1, Int(center.y + hh))
        guard x1 - x0 >= 8, y1 - y0 >= 3 else { return nil }

        @inline(__always) func luma(_ x: Int, _ y: Int) -> Int {
            let p = base + y * bpr + x * 4 // BGRA
            return (Int(p[0]) + 2 * Int(p[1]) + Int(p[2])) >> 2
        }
        @inline(__always) func inside(_ x: Int, _ y: Int) -> Bool {
            let dx = (Float(x) + 0.5 - center.x) / hw
            let dy = (Float(y) + 0.5 - center.y) / hh
            return dx * dx + dy * dy <= 1
        }

        var hist = [Int](repeating: 0, count: 256)
        var n = 0
        for y in y0...y1 {
            for x in x0...x1 where inside(x, y) {
                hist[luma(x, y)] += 1
                n += 1
            }
        }
        guard n >= 24 else { return nil }

        let target = n * darkFraction / 100
        var acc = 0, threshold = 0
        for i in 0..<256 {
            acc += hist[i]
            if acc >= target { threshold = i; break }
        }
        // Low contrast (very dark scene / closed eye): no reliable iris.
        var brightAcc = 0, bright = 255
        for i in stride(from: 255, through: 0, by: -1) {
            brightAcc += hist[i]
            if brightAcc >= n / 5 { bright = i; break }
        }
        guard bright - threshold >= 18 else { return nil }

        var sx: Float = 0, sy: Float = 0, sw: Float = 0
        for y in y0...y1 {
            for x in x0...x1 where inside(x, y) {
                let l = luma(x, y)
                guard l <= threshold else { continue }
                let wgt = Float(threshold - l + 1)
                sx += wgt * (Float(x) + 0.5)
                sy += wgt * (Float(y) + 0.5)
                sw += wgt
            }
        }
        guard sw > 0 else { return nil }
        return SIMD2(sx / sw, sy / sw)
    }
}
