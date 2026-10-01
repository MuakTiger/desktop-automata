import Foundation

/// A cosine palette: `color(t) = a + b * cos(2π (c * t + d))` per RGB
/// component (Inigo Quilez), clamped to [0, 1].
///
/// Every component of `c` is a multiple of 0.5, so every palette repeats with
/// period 2 in `t`. `LifeColoring.hueDrift(seconds:)` wraps at that period, so
/// the drift never shows a seam.
public struct CosinePalette: Equatable, Sendable {
    public static let period: Float = 2

    public var a: SIMD3<Float>
    public var b: SIMD3<Float>
    public var c: SIMD3<Float>
    public var d: SIMD3<Float>

    public init(a: SIMD3<Float>, b: SIMD3<Float>, c: SIMD3<Float>, d: SIMD3<Float>) {
        self.a = a
        self.b = b
        self.c = c
        self.d = d
    }

    /// Palette color at position `t`. Mirrors `palette()` in `ShaderSource.metal`.
    public func color(at t: Float) -> SIMD3<Float> {
        var result = SIMD3<Float>(repeating: 0)
        for k in 0..<3 {
            let phase = c[k] * t + d[k]
            let value = a[k] + b[k] * cos(2 * Float.pi * (phase - phase.rounded(.down)))
            result[k] = min(max(value, 0), 1)
        }
        return result
    }
}

extension Palette {
    public var cosine: CosinePalette {
        switch self {
        case .neon:
            // Hot pink, cyan, electric blue, yellow, violet.
            return CosinePalette(a: [0.5, 0.5, 0.75], b: [0.5, 0.5, 0.25], c: [1, 1.5, 1], d: [0, 0.5, 0.6])
        case .rainbow:
            // Full hue wheel; red, green and blue land 1/3 apart.
            return CosinePalette(a: [0.5, 0.5, 0.5], b: [0.5, 0.5, 0.5], c: [1, 1, 1], d: [0, 2.0 / 3, 1.0 / 3])
        case .fireAndIce:
            // Yellow -> orange -> purple -> blue -> cyan and back.
            return CosinePalette(a: [0.5, 0.5, 0.5], b: [0.5, 0.5, 0.5], c: [0.5, 1, 0.5], d: [0, 0, 0.5])
        case .pureRGB:
            // Overdriven and clamped: mostly pure red, green or blue with short dark blends.
            return CosinePalette(a: [-0.4, -0.4, -0.4], b: [1.4, 1.4, 1.4], c: [1, 1, 1], d: [0, 2.0 / 3, 1.0 / 3])
        case .acid:
            // Fast, uneven component frequencies: lime, orange, aqua, magenta.
            return CosinePalette(a: [0.5, 0.65, 0.4], b: [0.5, 0.35, 0.4], c: [1.5, 1, 2], d: [0.1, 0, 0.3])
        }
    }
}

/// How RGB Life cells are colored. CPU reference for the `life_colorize`
/// kernel in `ShaderSource.metal`, which receives these constants through
/// `ColorizeParams`.
///
/// Each live channel picks a palette color at
/// `drift + channel * channelSpread + agePosition(age)`, so a cell's color
/// walks along the palette as it ages. Newborn channels flash toward white for
/// their birth generation, and a channel that just died leaves a dim
/// afterimage for one generation. Channel colors add like light.
public enum LifeColoring {
    /// Palette offset between the red, green and blue channels.
    public static let channelSpread: Float = 1.0 / 3
    /// Palette distance from age 1 to age 256 (log2 scale, so young cells change fastest).
    public static let ageSpan: Float = 0.6
    /// How far a channel is pushed toward white on its birth generation.
    public static let birthFlash: Float = 0.55
    /// Brightness of the one-generation afterimage after a channel dies (Pixel style).
    public static let afterimage: Float = 0.3
    /// Seconds for the global hue drift to move one palette unit.
    public static let driftSecondsPerUnit: Double = 45

    /// Palette offset for a live channel of age `age` (1...255).
    public static func agePosition(_ age: UInt8) -> Float {
        ageSpan * log2(Float(max(age, 1))) / 8
    }

    /// Global palette offset after `seconds` of drift, wrapped to one palette period.
    public static func hueDrift(seconds: Double) -> Float {
        let units = seconds / driftSecondsPerUnit
        return Float(units.truncatingRemainder(dividingBy: Double(CosinePalette.period)))
    }

    /// Linear color of cell (`x`, `y`). Not clamped: overlapping channels can sum above 1.
    /// `afterimage` scales the color of channels that died in the latest generation (0 = off).
    public static func color(
        of grid: Grid, x: Int, y: Int, palette: CosinePalette, drift: Float, afterimage: Float
    ) -> SIMD3<Float> {
        var rgb = SIMD3<Float>(repeating: 0)
        for channel in 0..<RGBLife.channelCount {
            let base = drift + Float(channel) * channelSpread
            if RGBLife.isAlive(grid, x: x, y: y, channel: channel) {
                let age = grid.age(x: x, y: y, channel: channel)
                var color = palette.color(at: base + agePosition(age))
                if age == 1 { color += (1 - color) * birthFlash }
                rgb += color
            } else if RGBLife.diedLastGeneration(grid, x: x, y: y, channel: channel) {
                rgb += palette.color(at: base) * afterimage
            }
        }
        return rgb
    }
}
