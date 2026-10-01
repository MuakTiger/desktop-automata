import Metal

/// MSL compiled at runtime (Command Line Tools have no offline `metal` compiler).
///
/// `lowbias32` / `cell_hash` and the `life_seed` / `life_step` kernels mirror
/// `CellHash` and `RGBLife` in AutomataCore exactly, and `life_stamp` mirrors
/// `RGBLife.stamp(_:into:)`; GPU parity tests compare them bit-for-bit. `palette` / `life_colorize` mirror `CosinePalette` and
/// `LifeColoring` (compared within float tolerance).
enum ShaderSource {
    static let metal = """
    #include <metal_stdlib>
    using namespace metal;

    // ---- Hash (mirror of AutomataCore.CellHash) ----

    inline uint lowbias32(uint x) {
        x ^= x >> 16;
        x *= 0x7feb352du;
        x ^= x >> 15;
        x *= 0x846ca68bu;
        x ^= x >> 16;
        return x;
    }

    inline uint cell_hash(uint x, uint y, uint generation, uint seed) {
        uint h = lowbias32(seed);
        h = lowbias32(h ^ x);
        h = lowbias32(h ^ y);
        h = lowbias32(h ^ generation);
        return h;
    }

    // ---- State texture (rgba8Uint) ----
    // r = state (RGB Life: bits 0-2 live mask, bit 0 red, 1 green, 2 blue;
    //     bits 3-5 = that channel died in the latest generation)
    // g/b/a = RGB Life age of the red/green/blue channel
    //     (0 = dead, 1 = born this generation, max 255); other rules use g only
    // Brian's Brain: r = 0 off / 1 firing / 2 refractory, g = age in state
    //     (off: generations since going off, 0 = never fired)
    // Cyclic: r = state 0..N-1, g = age in state (1 = just advanced)
    // RPS: r = species 0 R / 1 G / 2 B, g = age since conversion

    constant uint kRuleLife = 0u;
    constant uint kRuleBrain = 1u;
    constant uint kRuleCyclic = 2u;
    constant uint kRuleRPS = 3u;

    struct SeedParams {
        uint seed;
        uint threshold;  // Life: per channel; Brian's Brain: firing
        uint rule;
        uint states;     // Cyclic: N; RPS: 3
    };

    kernel void life_seed(texture2d<uint, access::write> dst [[texture(0)]],
                          constant SeedParams &params [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        uint h = cell_hash(gid.x, gid.y, 0u, params.seed);
        uint4 cell = uint4(0u);
        if (params.rule == kRuleLife) {
            for (uint c = 0; c < 3; c++) {
                if (((h >> (8u * c)) & 0xFFu) < params.threshold) {
                    cell.r |= 1u << c;
                    cell[c + 1] = 1u;
                }
            }
        } else if (params.rule == kRuleBrain) {
            if ((h & 0xFFu) < params.threshold) { cell = uint4(1u, 1u, 0u, 0u); }
        } else {
            cell = uint4(h % params.states, 1u, 0u, 0u);
        }
        dst.write(cell, gid);
    }

    kernel void life_clear(texture2d<uint, access::write> dst [[texture(0)]],
                           uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
        dst.write(uint4(0u), gid);
    }

    struct StepParams {
        uint rule;
        uint states;       // Cyclic N
        uint threshold;    // Cyclic successor neighbors needed
        uint rpsBase;      // RPS threshold = rpsBase + hash % rpsRange
        uint rpsRange;
        uint rpsSeed;
        uint generation;   // generation being stepped from (RPS noise)
    };

    // Moore neighbors of gid whose state byte equals `value`, on a torus.
    inline uint count_equal(texture2d<uint, access::read> src, uint2 gid, uint w, uint h, uint value) {
        uint n = 0u;
        for (int dy = -1; dy <= 1; dy++) {
            for (int dx = -1; dx <= 1; dx++) {
                if (dx == 0 && dy == 0) { continue; }
                uint nx = uint(int(gid.x) + dx + int(w)) % w;
                uint ny = uint(int(gid.y) + dy + int(h)) % h;
                if (src.read(uint2(nx, ny)).r == value) { n++; }
            }
        }
        return n;
    }

    inline uint older(uint age) { return min(age + 1u, 255u); }

    // Brian's Brain (mirror of BriansBrain.step).
    inline uint4 brain_step(texture2d<uint, access::read> src, uint2 gid, uint w, uint h, uint4 cell) {
        if (cell.r == 1u) { return uint4(2u, 1u, 0u, 0u); }
        if (cell.r == 2u) { return uint4(0u, 1u, 0u, 0u); }
        if (count_equal(src, gid, w, h, 1u) == 2u) { return uint4(1u, 1u, 0u, 0u); }
        return uint4(0u, cell.g == 0u ? 0u : older(cell.g), 0u, 0u);
    }

    // Cyclic CA (mirror of CyclicCA.step).
    inline uint4 cyclic_step(texture2d<uint, access::read> src, uint2 gid, uint w, uint h, uint4 cell,
                             constant StepParams &p) {
        uint successor = (cell.r + 1u) % p.states;
        if (count_equal(src, gid, w, h, successor) >= p.threshold) { return uint4(successor, 1u, 0u, 0u); }
        return uint4(cell.r, older(cell.g), 0u, 0u);
    }

    // Rock-Paper-Scissors (mirror of RockPaperScissors.step).
    inline uint4 rps_step(texture2d<uint, access::read> src, uint2 gid, uint w, uint h, uint4 cell,
                          constant StepParams &p) {
        uint predator = (cell.r + 2u) % 3u;
        uint threshold = p.rpsBase + cell_hash(gid.x, gid.y, p.generation, p.rpsSeed) % p.rpsRange;
        if (count_equal(src, gid, w, h, predator) > threshold) { return uint4(predator, 1u, 0u, 0u); }
        return uint4(cell.r, older(cell.g), 0u, 0u);
    }

    // Rule selected by p.rule. RGB Life: B3/S23 per channel on a torus.
    // Ages: born 1, survived +1 (max 255), dead 0.
    // Death flags: set when a live channel dies, cleared otherwise.
    kernel void life_step(texture2d<uint, access::read> src [[texture(0)]],
                          texture2d<uint, access::write> dst [[texture(1)]],
                          constant StepParams &p [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
        uint w = src.get_width();
        uint h = src.get_height();
        if (gid.x >= w || gid.y >= h) { return; }
        if (p.rule != kRuleLife) {
            uint4 cell = src.read(gid);
            uint4 next;
            if (p.rule == kRuleBrain) { next = brain_step(src, gid, w, h, cell); }
            else if (p.rule == kRuleCyclic) { next = cyclic_step(src, gid, w, h, cell, p); }
            else { next = rps_step(src, gid, w, h, cell, p); }
            dst.write(next, gid);
            return;
        }
        uint3 counts = uint3(0u);
        for (int dy = -1; dy <= 1; dy++) {
            for (int dx = -1; dx <= 1; dx++) {
                if (dx == 0 && dy == 0) { continue; }
                uint nx = uint(int(gid.x) + dx + int(w)) % w;
                uint ny = uint(int(gid.y) + dy + int(h)) % h;
                uint m = src.read(uint2(nx, ny)).r;
                counts += uint3(m & 1u, (m >> 1) & 1u, (m >> 2) & 1u);
            }
        }
        uint4 cell = src.read(gid);
        uint4 next = uint4(0u);
        for (uint c = 0; c < 3; c++) {
            bool alive = ((cell.r >> c) & 1u) == 1u;
            uint n = counts[c];
            bool lives = n == 3u || (alive && n == 2u);
            if (lives) {
                next.r |= 1u << c;
                next[c + 1] = alive ? min(cell[c + 1] + 1u, 255u) : 1u;
            } else if (alive) {
                next.r |= 1u << (3u + c);
            }
        }
        dst.write(next, gid);
    }

    // ---- Stamps: brush trail / click burst (mirror of RGBLife.stamp) ----

    struct Stamp {
        int x;
        int y;
        int radius;
        uint kind;   // 0 trail, 1 burst
        uint value;  // hue step 0..5: R, RG, G, GB, B, BR
        uint seed;
    };

    struct StampParams {
        uint count;
        uint trailDensity;
        uint burstDensity;
        int ringWidth;
        uint rule;
        uint states;  // Cyclic N
    };

    constant uint kHueMasks[6] = {1u, 3u, 2u, 6u, 4u, 5u};

    inline int isqrt(int v) {
        int k = 0;
        while ((k + 1) * (k + 1) <= v) { k++; }
        return k;
    }

    // State a non-Life stamp paints into gid, or -1 (mirror of
    // BriansBrain/CyclicCA/RockPaperScissors.paint).
    inline int rule_paint(Stamp s, uint2 gid, constant StampParams &p) {
        int dx = int(gid.x) - s.x;
        int dy = int(gid.y) - s.y;
        int d2 = dx * dx + dy * dy;
        int r = s.radius;
        if (d2 > r * r + r) { return -1; }
        uint h = cell_hash(gid.x, gid.y, 0u, s.seed);
        bool trailHit = (h & 0xFFu) < p.trailDensity;
        uint step = s.value % 6u;
        if (p.rule == kRuleBrain) {
            if (s.kind == 0u) { return trailHit ? 1 : -1; }
            int inner = r - p.ringWidth;
            if (d2 > inner * inner + inner) { return 1; }
            return (h & 0xFFu) < p.burstDensity ? 1 : -1;
        }
        if (p.rule == kRuleCyclic) {
            uint base = step * p.states / 6u;
            if (s.kind == 0u) { return trailHit ? int(base) : -1; }
            uint ring = uint(isqrt(d2)) % p.states;
            return int((base + p.states - ring) % p.states);
        }
        uint species = step / 2u;
        if (s.kind == 0u) { return trailHit ? int(species) : -1; }
        return int(species);
    }

    inline uint stamp_paint(Stamp s, uint2 gid, constant StampParams &p) {
        int dx = int(gid.x) - s.x;
        int dy = int(gid.y) - s.y;
        int d2 = dx * dx + dy * dy;
        int r = s.radius;
        if (d2 > r * r + r) { return 0u; }
        uint h = cell_hash(gid.x, gid.y, 0u, s.seed);
        uint hueMask = kHueMasks[s.value % 6u];
        if (s.kind == 0u) { return (h & 0xFFu) < p.trailDensity ? hueMask : 0u; }
        int inner = r - p.ringWidth;
        if (d2 > inner * inner + inner) { return hueMask; }
        uint paint = 0u;
        for (uint c = 0; c < 3; c++) {
            if (((h >> (8u * c)) & 0xFFu) < p.burstDensity) { paint |= 1u << c; }
        }
        return paint;
    }

    // Painted channels become alive at age 1 (newborn) and lose their death flag.
    kernel void life_stamp(texture2d<uint, access::read> src [[texture(0)]],
                           texture2d<uint, access::write> dst [[texture(1)]],
                           constant StampParams &p [[buffer(0)]],
                           constant Stamp *stamps [[buffer(1)]],
                           uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= src.get_width() || gid.y >= src.get_height()) { return; }
        if (p.rule != kRuleLife) {
            // Set the painted state at age 1; later stamps win.
            int value = -1;
            for (uint i = 0; i < p.count; i++) {
                int v = rule_paint(stamps[i], gid, p);
                if (v >= 0) { value = v; }
            }
            dst.write(value >= 0 ? uint4(uint(value), 1u, 0u, 0u) : src.read(gid), gid);
            return;
        }
        uint paint = 0u;
        for (uint i = 0; i < p.count; i++) { paint |= stamp_paint(stamps[i], gid, p); }
        uint4 cell = src.read(gid);
        for (uint c = 0; c < 3; c++) {
            if (((paint >> c) & 1u) == 1u) {
                cell.r = (cell.r | (1u << c)) & ~(1u << (3u + c));
                cell[c + 1] = 1u;
            }
        }
        dst.write(cell, gid);
    }

    // ---- Colorize: state -> rgba16Float color/trail texture ----
    // Mirror of AutomataCore.CosinePalette / LifeColoring.

    struct ColorizeParams {
        float4 a;  // cosine palette coefficients (xyz used)
        float4 b;
        float4 c;
        float4 d;
        float drift;
        float channelSpread;
        float ageSpan;
        float birthFlash;
        float afterimage;
        // Non-Life rules (mirror of AutomataCore.RuleColoring).
        uint rule;
        uint states;
        float spatialSpread;
        float fireFlash;
        float refractoryBrightness;
        float trailLength;
        float frontFlash;
        float ageDim;
        float speciesSpread;
        float period;
        float speciesTint;
    };

    inline float3 palette(float t, constant ColorizeParams &p) {
        float3 phase = p.c.xyz * t + p.d.xyz;
        return saturate(p.a.xyz + p.b.xyz * cos(2.0f * M_PI_F * fract(phase)));
    }

    // Cyclic / RPS: dim with age, flash on the generation the cell changed.
    inline float3 front(float3 col, uint age, constant ColorizeParams &p) {
        float3 c = col * (1.0f - p.ageDim * log2(float(max(age, 1u))) / 8.0f);
        if (age == 1u) { c += (1.0f - c) * p.frontFlash; }
        return c;
    }

    inline float3 rule_color(uint4 cell, uint2 gid, float2 size, constant ColorizeParams &p) {
        if (p.rule == kRuleBrain) {
            float t = p.drift + p.spatialSpread * 0.5f * (float(gid.x) / size.x + float(gid.y) / size.y);
            if (cell.r == 1u) {
                float3 c = palette(t, p);
                return c + (1.0f - c) * p.fireFlash;
            }
            if (cell.r == 2u) { return palette(t + 1.0f / 3.0f, p) * p.refractoryBrightness; }
            float age = float(cell.g);
            if (cell.g < 1u || age > p.trailLength) { return float3(0.0f); }
            return palette(t + 2.0f / 3.0f, p) * (p.afterimage * (p.trailLength + 1.0f - age) / p.trailLength);
        }
        if (p.rule == kRuleCyclic) {
            return front(palette(p.drift + p.period * float(cell.r) / float(p.states), p), cell.g, p);
        }
        float3 primary = float3(0.0f);
        primary[cell.r % 3u] = 1.0f;
        float3 tinted = primary * p.speciesTint + palette(p.drift + float(cell.r) * p.speciesSpread, p) * (1.0f - p.speciesTint);
        return front(tinted, cell.g, p);
    }

    kernel void life_colorize(texture2d<uint, access::read> state [[texture(0)]],
                              texture2d<float, access::write> color [[texture(1)]],
                              constant ColorizeParams &p [[buffer(0)]],
                              uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= state.get_width() || gid.y >= state.get_height()) { return; }
        uint4 cell = state.read(gid);
        if (p.rule != kRuleLife) {
            float2 size = float2(float(state.get_width()), float(state.get_height()));
            color.write(float4(rule_color(cell, gid, size, p), 1.0f), gid);
            return;
        }
        float3 rgb = float3(0.0f);
        for (uint c = 0; c < 3; c++) {
            float base = p.drift + float(c) * p.channelSpread;
            if (((cell.r >> c) & 1u) == 1u) {
                uint age = cell[c + 1];
                float3 col = palette(base + p.ageSpan * log2(float(max(age, 1u))) / 8.0f, p);
                if (age == 1u) { col += (1.0f - col) * p.birthFlash; }
                rgb += col;
            } else if (((cell.r >> (3u + c)) & 1u) == 1u) {
                rgb += palette(base, p) * p.afterimage;
            }
        }
        color.write(float4(rgb, 1.0f), gid);
    }

    // ---- Population (mirror of AutomataCore.Automaton.population) ----

    kernel void life_population(texture2d<uint, access::read> state [[texture(0)]],
                                constant uint &rule [[buffer(0)]],
                                device atomic_uint *count [[buffer(1)]],
                                uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= state.get_width() || gid.y >= state.get_height()) { return; }
        uint4 cell = state.read(gid);
        bool counted;
        if (rule == kRuleLife) { counted = (cell.r & 7u) != 0u; }
        else if (rule == kRuleBrain) { counted = cell.r == 1u; }
        else { counted = cell.g == 1u; }
        if (counted) { atomic_fetch_add_explicit(count, 1u, memory_order_relaxed); }
    }

    // ---- Render: nearest-neighbor color texture, optional gridlines ----

    struct FullscreenOut {
        float4 position [[position]];
    };

    // One oversized triangle covering the viewport.
    vertex FullscreenOut fullscreen_vertex(uint vid [[vertex_id]]) {
        float2 p = float2(float((vid << 1) & 2u), float(vid & 2u));
        FullscreenOut out;
        out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        return out;
    }

    struct RenderParams {
        float2 cellsPerPixel;
        uint2 gridSize;
        float gridLineWidth;  // pixels; 0 = no gridlines
    };

    constant float3 kGridLineColor = float3(0.13f, 0.13f, 0.16f);
    constant float kGridLineMix = 0.7f;

    fragment float4 life_fragment(FullscreenOut in [[stage_in]],
                                  texture2d<float, access::read> color [[texture(0)]],
                                  constant RenderParams &params [[buffer(0)]]) {
        float2 cellPos = in.position.xy * params.cellsPerPixel;
        uint2 cell = min(uint2(cellPos), params.gridSize - 1u);
        float3 rgb = saturate(color.read(cell).rgb);
        if (params.gridLineWidth > 0.0f) {
            // Pixels from this pixel's center to its cell's top/left edge.
            float2 inCell = fract(cellPos) / params.cellsPerPixel;
            if (any(inCell < params.gridLineWidth)) {
                rgb = mix(rgb, kGridLineColor, kGridLineMix);
            }
        }
        return float4(rgb, 1.0f);
    }

    // ---- Glow style (mirror of AutomataCore.GlowTrail + BloomPass) ----

    struct TrailParams {
        float decay;   // 0 on the first frame after (re)allocation
        float cutoff;
    };

    // next = max(prev * decay, cur), small values snapped to 0.
    kernel void glow_trail(texture2d<float, access::read> current [[texture(0)]],
                           texture2d<float, access::read> previous [[texture(1)]],
                           texture2d<float, access::write> next [[texture(2)]],
                           constant TrailParams &p [[buffer(0)]],
                           uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= next.get_width() || gid.y >= next.get_height()) { return; }
        float3 value = max(previous.read(gid).rgb * p.decay, current.read(gid).rgb);
        value = select(value, float3(0.0f), value < p.cutoff);
        next.write(float4(value, 1.0f), gid);
    }

    // Bilinear resample of the grid-sized trail into the half-resolution bloom source.
    kernel void glow_downsample(texture2d<float, access::sample> trail [[texture(0)]],
                                texture2d<float, access::write> half_res [[texture(1)]],
                                uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= half_res.get_width() || gid.y >= half_res.get_height()) { return; }
        constexpr sampler linear(filter::linear, address::clamp_to_edge, coord::normalized);
        float2 uv = (float2(gid) + 0.5f) / float2(half_res.get_width(), half_res.get_height());
        half_res.write(float4(trail.sample(linear, uv).rgb, 1.0f), gid);
    }

    struct GlowParams {
        float2 cellsPerPixel;
        uint2 gridSize;
        float2 invDrawableSize;
        float bloomStrength;
    };

    // Trail cells (nearest, no gridlines) plus the blurred halo.
    fragment float4 glow_fragment(FullscreenOut in [[stage_in]],
                                  texture2d<float, access::read> trail [[texture(0)]],
                                  texture2d<float, access::sample> bloom [[texture(1)]],
                                  constant GlowParams &params [[buffer(0)]]) {
        constexpr sampler linear(filter::linear, address::clamp_to_edge, coord::normalized);
        uint2 cell = min(uint2(in.position.xy * params.cellsPerPixel), params.gridSize - 1u);
        float3 core = trail.read(cell).rgb;
        float3 halo = bloom.sample(linear, in.position.xy * params.invDrawableSize).rgb;
        return float4(saturate(core + halo * params.bloomStrength), 1.0f);
    }
    """

    /// Compiles `metal` for `device`.
    static func makeLibrary(device: MTLDevice) throws -> MTLLibrary {
        try device.makeLibrary(source: metal, options: nil)
    }
}
