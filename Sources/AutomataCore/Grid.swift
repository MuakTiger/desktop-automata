/// CPU mirror of the GPU state texture (`rgba8Uint`).
///
/// Four bytes per cell, row-major, row 0 at the top, so `cells` has the same
/// layout as a tightly packed texture readback.
/// - Byte 0 (r): the rule's state. For RGB Life, bits 0...2 are the live mask
///   (bit 0 = red, bit 1 = green, bit 2 = blue) and bits 3...5 flag a channel
///   that died in the latest generation (alive before, dead now).
/// - Bytes 1...3 (g, b, a): RGB Life per-channel age of the red, green and blue
///   cell in generations (0 = dead, 1 = born this generation, saturates at 255).
///   Other rules keep a single age in byte 1 (g) only.
public struct Grid: Equatable, Sendable {
    public static let bytesPerCell = 4

    public let width: Int
    public let height: Int
    public var cells: [UInt8]
    /// Generations stepped since the grid was seeded or cleared.
    public var generation: UInt32

    /// An empty (all-zero) grid.
    public init(width: Int, height: Int) {
        precondition(width > 0 && height > 0, "Grid must be at least 1x1")
        self.width = width
        self.height = height
        self.cells = [UInt8](repeating: 0, count: width * height * Self.bytesPerCell)
        self.generation = 0
    }

    /// Byte offset of cell (`x`, `y`) in `cells`.
    @inlinable
    public func index(x: Int, y: Int) -> Int {
        (y * width + x) * Self.bytesPerCell
    }

    /// Byte 0 of cell (`x`, `y`).
    public func state(x: Int, y: Int) -> UInt8 {
        cells[index(x: x, y: y)]
    }

    /// Byte `1 + channel` of cell (`x`, `y`).
    public func age(x: Int, y: Int, channel: Int) -> UInt8 {
        precondition((0..<3).contains(channel))
        return cells[index(x: x, y: y) + 1 + channel]
    }
}
