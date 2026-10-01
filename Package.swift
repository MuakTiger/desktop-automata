// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DesktopAutomata",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DesktopAutomata", targets: ["DesktopAutomata"]),
    ],
    targets: [
        // Pure Swift model + CPU reference logic (no AppKit / Metal).
        .target(name: "AutomataCore"),
        // Metal simulation + rendering (MSL compiled at runtime).
        .target(name: "AutomataGPU", dependencies: ["AutomataCore"]),
        // Menu-bar app executable.
        .executableTarget(name: "DesktopAutomata", dependencies: ["AutomataCore", "AutomataGPU"]),
        .testTarget(name: "AutomataCoreTests", dependencies: ["AutomataCore"]),
        .testTarget(name: "AutomataGPUTests", dependencies: ["AutomataCore", "AutomataGPU"]),
    ],
    swiftLanguageModes: [.v5]
)
