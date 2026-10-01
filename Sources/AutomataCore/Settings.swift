import Foundation

/// Cellular automaton rule the simulation runs.
public enum AutomatonRule: String, CaseIterable, Sendable {
    case rgbLife
    case briansBrain
    case cyclic
    case rockPaperScissors

    public var title: String {
        switch self {
        case .rgbLife: return "RGB Life"
        case .briansBrain: return "Brian's Brain"
        case .cyclic: return "Cyclic CA"
        case .rockPaperScissors: return "Rock Paper Scissors"
        }
    }
}

/// Cosine color palette used to tint cells.
public enum Palette: String, CaseIterable, Sendable {
    case neon
    case rainbow
    case fireAndIce
    case pureRGB
    case acid

    public var title: String {
        switch self {
        case .neon: return "Neon"
        case .rainbow: return "Rainbow"
        case .fireAndIce: return "Fire & Ice"
        case .pureRGB: return "Pure RGB"
        case .acid: return "Acid"
        }
    }
}

/// How cells are drawn on screen.
public enum RenderStyle: String, CaseIterable, Sendable {
    case pixel
    case glow

    public var title: String {
        switch self {
        case .pixel: return "Pixel"
        case .glow: return "Glow"
        }
    }
}

/// Simulation speed in generations per second (raw value).
public enum SimSpeed: Int, CaseIterable, Sendable {
    case gps1 = 1
    case gps2 = 2
    case gps5 = 5
    case gps10 = 10
    case gps20 = 20
    case gps30 = 30
    case gps60 = 60

    public var generationsPerSecond: Int { rawValue }
    public var title: String { "\(rawValue) gen/s" }
}

/// Cell edge length in points (raw value).
public enum CellSize: Int, CaseIterable, Sendable {
    case pt3 = 3
    case pt4 = 4
    case pt6 = 6
    case pt8 = 8
    case pt12 = 12

    public var points: Int { rawValue }
    public var title: String { "\(rawValue) pt" }
}

/// App settings. Held in memory only; every launch starts from `Settings.defaults`.
public struct Settings: Equatable, Sendable {
    public var isEnabled: Bool
    public var rule: AutomatonRule
    public var palette: Palette
    public var style: RenderStyle
    public var speed: SimSpeed
    public var cellSize: CellSize
    public var hudEnabled: Bool

    public init(
        isEnabled: Bool = true,
        rule: AutomatonRule = .rgbLife,
        palette: Palette = .neon,
        style: RenderStyle = .pixel,
        speed: SimSpeed = .gps10,
        cellSize: CellSize = .pt6,
        hudEnabled: Bool = true
    ) {
        self.isEnabled = isEnabled
        self.rule = rule
        self.palette = palette
        self.style = style
        self.speed = speed
        self.cellSize = cellSize
        self.hudEnabled = hudEnabled
    }

    public static let defaults = Settings()
}
