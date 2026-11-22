#include <metal_stdlib>
using namespace metal;

// Must match EyeShaderParams in GazeCorrector.swift (48 bytes).
struct EyeParams {
    float2 center;   // eye-opening centre, pixels
    float2 radii;    // eye-opening half extents, pixels
    float2 pupil;    // detected pupil, pixels
    float  irisR;    // iris radius, pixels
    float2 shift;    // how far the iris should move (pixels, y down)
    float  amount;   // 0..1 (fades out on blinks / lost tracking)
};

// Moves the iris disc of each eye by `shift`, confined to the eye opening so the
// eyelids and skin stay untouched. Output = input everywhere else (the caller
// blits the full frame first and only dispatches this kernel over the eye box).
kernel void gazeWarp(texture2d<float, access::sample> src [[texture(0)]],
                     texture2d<float, access::write>  dst [[texture(1)]],
                     constant EyeParams *eyes [[buffer(0)]],
                     constant uint &eyeCount  [[buffer(1)]],
                     constant uint2 &origin   [[buffer(2)]],
                     uint2 gid [[thread_position_in_grid]])
{
    uint2 p = gid + origin;
    if (p.x >= dst.get_width() || p.y >= dst.get_height()) return;

    constexpr sampler s(coord::pixel, filter::linear, address::clamp_to_edge);
    float2 pos = float2(p) + 0.5;
    float2 offset = float2(0.0);

    for (uint i = 0; i < eyeCount; i++) {
        EyeParams e = eyes[i];
        float re = length((pos - e.center) / max(e.radii, float2(1.0)));
        float wEye = 1.0 - smoothstep(0.62, 1.0, re);
        if (wEye <= 0.0) continue;
        float ri = length(pos - (e.pupil + e.shift)) / max(e.irisR, 1.0);
        float wIris = 1.0 - smoothstep(1.0, 1.9, ri);
        offset -= e.shift * (wIris * wEye * e.amount);
    }

    dst.write(src.sample(s, pos + offset), p);
}
