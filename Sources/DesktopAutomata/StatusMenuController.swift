import AppKit
import AutomataCore

/// Owns the menu-bar status item and its dropdown menu.
final class StatusMenuController: NSObject {
    var onToggleEnabled: ((Bool) -> Void)?
    var onTogglePaused: ((Bool) -> Void)?
    var onStep: (() -> Void)?
    var onRandomReset: (() -> Void)?
    var onClear: (() -> Void)?
    var onSelectRule: ((AutomatonRule) -> Void)?
    var onSelectSpeed: ((SimSpeed) -> Void)?
    var onSelectPalette: ((Palette) -> Void)?
    var onSelectStyle: ((RenderStyle) -> Void)?
    var onSelectCellSize: ((CellSize) -> Void)?
    var onToggleHUD: ((Bool) -> Void)?

    var isEnabled: Bool {
        didSet { enabledItem.state = isEnabled ? .on : .off }
    }

    var isPaused: Bool {
        didSet { updatePauseItems() }
    }

    var rule: AutomatonRule {
        didSet { updateRuleItems() }
    }

    var speed: SimSpeed {
        didSet { updateSpeedItems() }
    }

    var palette: Palette {
        didSet { updatePaletteItems() }
    }
    var style: RenderStyle {
        didSet { updateStyleItems() }
    }

    var cellSize: CellSize {
        didSet { updateCellSizeItems() }
    }

    var showsHUD: Bool {
        didSet { hudItem.state = showsHUD ? .on : .off }
    }

    private let statusItem: NSStatusItem
    private let enabledItem: NSMenuItem
    private let pauseItem: NSMenuItem
    private let stepItem: NSMenuItem
    /// Tag = index in `AutomatonRule.allCases`.
    private var ruleItems: [NSMenuItem] = []
    private var speedItems: [NSMenuItem] = []
    /// Tag = index in `Palette.allCases`.
    private var paletteItems: [NSMenuItem] = []
    /// Tag = index in `RenderStyle.allCases`.
    private var styleItems: [NSMenuItem] = []
    /// Tag = points.
    private var cellSizeItems: [NSMenuItem] = []
    private let hudItem: NSMenuItem

    init(isEnabled: Bool, isPaused: Bool, rule: AutomatonRule, speed: SimSpeed, palette: Palette, style: RenderStyle,
         cellSize: CellSize, showsHUD: Bool) {
        self.isEnabled = isEnabled
        self.isPaused = isPaused
        self.rule = rule
        self.speed = speed
        self.palette = palette
        self.style = style
        self.cellSize = cellSize
        self.showsHUD = showsHUD
        hudItem = NSMenuItem(title: "Show HUD", action: nil, keyEquivalent: "")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        enabledItem = NSMenuItem(title: "Enabled", action: nil, keyEquivalent: "")
        pauseItem = NSMenuItem(title: "Pause", action: nil, keyEquivalent: "")
        stepItem = NSMenuItem(title: "Step One Generation", action: nil, keyEquivalent: "")
        super.init()

        if let button = statusItem.button {
            let image = NSImage(
                systemSymbolName: "square.grid.3x3.fill",
                accessibilityDescription: "Desktop Automata"
            )
            image?.isTemplate = true
            button.image = image
            button.toolTip = "Desktop Automata"
        }

        enabledItem.action = #selector(toggleEnabled(_:))
        enabledItem.target = self
        enabledItem.state = isEnabled ? .on : .off

        pauseItem.action = #selector(togglePaused(_:))
        pauseItem.target = self
        stepItem.action = #selector(step(_:))
        stepItem.target = self
        let resetItem = NSMenuItem(title: "Random Reset", action: #selector(randomReset(_:)), keyEquivalent: "")
        resetItem.target = self
        let clearItem = NSMenuItem(title: "Clear", action: #selector(clear(_:)), keyEquivalent: "")
        clearItem.target = self

        let ruleMenu = NSMenu(title: "Rule")
        for (index, option) in AutomatonRule.allCases.enumerated() {
            let item = NSMenuItem(title: option.title, action: #selector(selectRule(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            ruleMenu.addItem(item)
            ruleItems.append(item)
        }
        let ruleItem = NSMenuItem(title: "Rule", action: nil, keyEquivalent: "")
        ruleItem.submenu = ruleMenu

        let speedMenu = NSMenu(title: "Speed")
        for option in SimSpeed.allCases {
            let item = NSMenuItem(title: option.title, action: #selector(selectSpeed(_:)), keyEquivalent: "")
            item.target = self
            item.tag = option.rawValue
            speedMenu.addItem(item)
            speedItems.append(item)
        }
        let speedItem = NSMenuItem(title: "Speed", action: nil, keyEquivalent: "")
        speedItem.submenu = speedMenu

        let paletteMenu = NSMenu(title: "Palette")
        for (index, option) in Palette.allCases.enumerated() {
            let item = NSMenuItem(title: option.title, action: #selector(selectPalette(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            paletteMenu.addItem(item)
            paletteItems.append(item)
        }
        let paletteItem = NSMenuItem(title: "Palette", action: nil, keyEquivalent: "")
        paletteItem.submenu = paletteMenu
        let styleMenu = NSMenu(title: "Style")
        for (index, option) in RenderStyle.allCases.enumerated() {
            let item = NSMenuItem(title: option.title, action: #selector(selectStyle(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            styleMenu.addItem(item)
            styleItems.append(item)
        }
        let styleItem = NSMenuItem(title: "Style", action: nil, keyEquivalent: "")
        styleItem.submenu = styleMenu

        let cellSizeMenu = NSMenu(title: "Cell Size")
        for option in CellSize.allCases {
            let item = NSMenuItem(title: option.title, action: #selector(selectCellSize(_:)), keyEquivalent: "")
            item.target = self
            item.tag = option.rawValue
            cellSizeMenu.addItem(item)
            cellSizeItems.append(item)
        }
        let cellSizeItem = NSMenuItem(title: "Cell Size", action: nil, keyEquivalent: "")
        cellSizeItem.submenu = cellSizeMenu

        hudItem.action = #selector(toggleHUD(_:))
        hudItem.target = self
        hudItem.state = showsHUD ? .on : .off

        let quitItem = NSMenuItem(
            title: "Quit Desktop Automata",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        let menu = NSMenu()
        // Manual enabling so Step can be disabled while the simulation runs.
        menu.autoenablesItems = false
        menu.addItem(enabledItem)
        menu.addItem(pauseItem)
        menu.addItem(stepItem)
        menu.addItem(resetItem)
        menu.addItem(clearItem)
        menu.addItem(.separator())
        menu.addItem(ruleItem)
        menu.addItem(paletteItem)
        menu.addItem(styleItem)
        menu.addItem(speedItem)
        menu.addItem(cellSizeItem)
        menu.addItem(hudItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)
        statusItem.menu = menu

        updatePauseItems()
        updateRuleItems()
        updateSpeedItems()
        updatePaletteItems()
        updateStyleItems()
        updateCellSizeItems()
    }

    private func updatePauseItems() {
        pauseItem.title = isPaused ? "Play" : "Pause"
        stepItem.isEnabled = isPaused
    }

    private func updateRuleItems() {
        let selected = AutomatonRule.allCases.firstIndex(of: rule)
        for item in ruleItems {
            item.state = item.tag == selected ? .on : .off
        }
    }

    private func updateSpeedItems() {
        for item in speedItems {
            item.state = item.tag == speed.rawValue ? .on : .off
        }
    }

    private func updatePaletteItems() {
        let selected = Palette.allCases.firstIndex(of: palette)
        for item in paletteItems {
            item.state = item.tag == selected ? .on : .off
        }
    }

    private func updateStyleItems() {
        let selected = RenderStyle.allCases.firstIndex(of: style)
        for item in styleItems {
            item.state = item.tag == selected ? .on : .off
        }
    }

    private func updateCellSizeItems() {
        for item in cellSizeItems {
            item.state = item.tag == cellSize.rawValue ? .on : .off
        }
    }

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        onToggleEnabled?(!isEnabled)
    }

    @objc private func togglePaused(_ sender: NSMenuItem) {
        onTogglePaused?(!isPaused)
    }

    @objc private func step(_ sender: NSMenuItem) {
        onStep?()
    }

    @objc private func randomReset(_ sender: NSMenuItem) {
        onRandomReset?()
    }

    @objc private func clear(_ sender: NSMenuItem) {
        onClear?()
    }

    @objc private func selectRule(_ sender: NSMenuItem) {
        guard AutomatonRule.allCases.indices.contains(sender.tag) else { return }
        onSelectRule?(AutomatonRule.allCases[sender.tag])
    }

    @objc private func selectSpeed(_ sender: NSMenuItem) {
        guard let option = SimSpeed(rawValue: sender.tag) else { return }
        onSelectSpeed?(option)
    }

    @objc private func selectPalette(_ sender: NSMenuItem) {
        guard Palette.allCases.indices.contains(sender.tag) else { return }
        onSelectPalette?(Palette.allCases[sender.tag])
    }

    @objc private func selectStyle(_ sender: NSMenuItem) {
        guard RenderStyle.allCases.indices.contains(sender.tag) else { return }
        onSelectStyle?(RenderStyle.allCases[sender.tag])
    }

    @objc private func selectCellSize(_ sender: NSMenuItem) {
        guard let option = CellSize(rawValue: sender.tag) else { return }
        onSelectCellSize?(option)
    }

    @objc private func toggleHUD(_ sender: NSMenuItem) {
        onToggleHUD?(!showsHUD)
    }
}
