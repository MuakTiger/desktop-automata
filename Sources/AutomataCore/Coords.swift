import CoreGraphics
import Foundation

/// Maps Cocoa screen points (global, bottom-left origin, points) to cells of
/// a grid stretched over one screen, exactly as the renderer draws it.
///
/// The grid is sized in points (`gridSize(for:cellPoints:)`) and stretched
/// over the screen's `pixelWidth x pixelHeight` drawable. A point resolves to
/// the backing pixel under it (`scale` = `backingScaleFactor`), and that
/// pixel's center to a cell, like `life_fragment` does. Row 0 is at the top.
public struct ScreenGrid: Equatable, Sendable {
    /// Screen frame in global Cocoa coordinates (points).
    public let frame: CGRect
    /// Backing pixels per point.
    public let scale: Double
    public let width: Int
    public let height: Int

    public init(frame: CGRect, scale: Double, width: Int, height: Int) {
        precondition(width > 0 && height > 0, "Grid must be at least 1x1")
        precondition(scale > 0, "Scale must be positive")
        self.frame = frame
        self.scale = scale
        self.width = width
        self.height = height
    }

    /// Grid sized for `frame` like the renderer sizes it: `gridSize(for: frame.size, cellPoints:)`.
    public init(frame: CGRect, scale: Double, cellPoints: Int) {
        let size = Self.gridSize(for: frame.size, cellPoints: cellPoints)
        self.init(frame: frame, scale: scale, width: size.width, height: size.height)
    }

    /// Grid dimensions for a view of `size` points: `ceil(points / cellPoints)`
    /// per axis (a partial cell at the edge still gets a column/row), at least 1x1.
    /// The grid is stretched over the drawable, so cells are at most `cellPoints`.
    public static func gridSize(for size: CGSize, cellPoints: Int) -> (width: Int, height: Int) {
        let cell = Double(max(cellPoints, 1))
        func cells(_ points: CGFloat) -> Int {
            let value = Double(points)
            guard value.isFinite, value > 0 else { return 1 }
            return max(Int((value / cell).rounded(.up)), 1)
        }
        return (cells(size.width), cells(size.height))
    }

    /// Drawable width in pixels.
    public var pixelWidth: Int { max(Int((Double(frame.width) * scale).rounded()), 1) }
    /// Drawable height in pixels.
    public var pixelHeight: Int { max(Int((Double(frame.height) * scale).rounded()), 1) }

    /// Continuous cell coordinates (x right, y down; the cell is `floor`) of
    /// the pixel under `point`, or nil if `point` is outside `frame`. Points on
    /// the frame's edges are clamped to the edge pixels.
    public func position(of point: CGPoint) -> SIMD2<Double>? {
        guard
            point.x >= frame.minX, point.x <= frame.maxX,
            point.y >= frame.minY, point.y <= frame.maxY
        else { return nil }
        let px = min(max(((Double(point.x) - Double(frame.minX)) * scale).rounded(.down), 0), Double(pixelWidth - 1))
        // Cocoa y grows upward; pixel rows and grid rows grow downward.
        let py = min(max(((Double(frame.maxY) - Double(point.y)) * scale).rounded(.down), 0), Double(pixelHeight - 1))
        return SIMD2(
            (px + 0.5) * Double(width) / Double(pixelWidth),
            (py + 0.5) * Double(height) / Double(pixelHeight)
        )
    }

    /// Cell under `point`, or nil if `point` is outside `frame`.
    public func cell(of point: CGPoint) -> (x: Int, y: Int)? {
        position(of: point).map { (min(Int($0.x), width - 1), min(Int($0.y), height - 1)) }
    }
}
