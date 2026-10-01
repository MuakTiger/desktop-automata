/// Deterministic integer hashing.
///
/// `ShaderSource.metal` (AutomataGPU) contains an identical MSL copy of these
/// functions so CPU reference grids and GPU textures match bit-for-bit. Any
/// change here must be mirrored there.
public enum CellHash {
    /// Chris Wellons' `lowbias32` 32-bit integer finalizer.
    @inlinable
    public static func lowbias32(_ value: UInt32) -> UInt32 {
        var x = value
        x ^= x >> 16
        x &*= 0x7feb_352d
        x ^= x >> 15
        x &*= 0x846c_a68b
        x ^= x >> 16
        return x
    }

    /// Hash of cell (`x`, `y`) at `generation` for `seed`.
    @inlinable
    public static func hash(x: UInt32, y: UInt32, generation: UInt32, seed: UInt32) -> UInt32 {
        var h = lowbias32(seed)
        h = lowbias32(h ^ x)
        h = lowbias32(h ^ y)
        h = lowbias32(h ^ generation)
        return h
    }
}
