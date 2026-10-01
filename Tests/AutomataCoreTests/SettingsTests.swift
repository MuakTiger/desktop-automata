import Testing
@testable import AutomataCore

@Suite("Settings")
struct SettingsTests {
    @Test("Defaults: on, RGB Life, Neon, Pixel, 10 gen/s, 6pt, HUD on")
    func defaults() {
        let settings = Settings()
        #expect(settings.isEnabled)
        #expect(settings.rule == .rgbLife)
        #expect(settings.palette == .neon)
        #expect(settings.style == .pixel)
        #expect(settings.speed == .gps10)
        #expect(settings.speed.generationsPerSecond == 10)
        #expect(settings.cellSize == .pt6)
        #expect(settings.cellSize.points == 6)
        #expect(settings.hudEnabled)
        #expect(Settings.defaults == settings)
    }

    @Test("Settings are value types")
    func valueSemantics() {
        var changed = Settings.defaults
        changed.rule = .cyclic
        changed.isEnabled = false
        #expect(changed != Settings.defaults)
        #expect(Settings.defaults.rule == .rgbLife)
        #expect(Settings.defaults.isEnabled)
    }
}

@Suite("Setting enums")
struct SettingEnumTests {
    @Test func rules() {
        #expect(AutomatonRule.allCases == [.rgbLife, .briansBrain, .cyclic, .rockPaperScissors])
        #expect(AutomatonRule.allCases.map(\.title) == ["RGB Life", "Brian's Brain", "Cyclic CA", "Rock Paper Scissors"])
    }

    @Test func palettes() {
        #expect(Palette.allCases == [.neon, .rainbow, .fireAndIce, .pureRGB, .acid])
        #expect(Palette.allCases.map(\.title) == ["Neon", "Rainbow", "Fire & Ice", "Pure RGB", "Acid"])
    }

    @Test func styles() {
        #expect(RenderStyle.allCases == [.pixel, .glow])
        #expect(RenderStyle.allCases.map(\.title) == ["Pixel", "Glow"])
    }

    @Test func speeds() {
        #expect(SimSpeed.allCases.map(\.generationsPerSecond) == [1, 2, 5, 10, 20, 30, 60])
        #expect(SimSpeed.gps10.title == "10 gen/s")
    }

    @Test func cellSizes() {
        #expect(CellSize.allCases.map(\.points) == [3, 4, 6, 8, 12])
        #expect(CellSize.pt6.title == "6 pt")
    }
}
