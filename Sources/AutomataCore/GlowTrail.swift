/// CPU reference for the Glow style's persistent trail (mirrored by the
/// `glow_trail` MSL kernel). Every rendered frame, per cell and channel:
/// `trail = max(prev * decay, cur)`, so live cells show at full color and
/// dead cells fade out smoothly over a few dozen frames.
public enum GlowTrail {
    /// Per-frame decay of the trail. Tweak here: 0.90 = short tails, 0.95 = long.
    /// At 60 fps and 10 gen/s a dead cell keeps ~60% per generation.
    public static let decay: Float = 0.92

    /// Values below this snap to 0. Without it half floats stall at the
    /// smallest subnormal (x * decay rounds back to x) and never reach 0.
    public static let cutoff: Float = 1.0 / 512.0

    /// One frame of the trail for one channel.
    public static func update(previous: Float, current: Float, decay: Float = decay) -> Float {
        let value = max(previous * decay, current)
        return value < cutoff ? 0 : value
    }

    /// One frame of the trail for an RGB color.
    public static func update(previous: SIMD3<Float>, current: SIMD3<Float>, decay: Float = decay) -> SIMD3<Float> {
        SIMD3(
            update(previous: previous.x, current: current.x, decay: decay),
            update(previous: previous.y, current: current.y, decay: decay),
            update(previous: previous.z, current: current.z, decay: decay)
        )
    }
}
