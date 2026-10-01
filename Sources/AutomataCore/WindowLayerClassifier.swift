/// Decides whether the topmost window under the cursor means the bare desktop
/// is visible there.
///
/// Desktop: any layer below 0 (the desktop picture at `kCGDesktopWindowLevel`
/// ≈ -2147483623, Finder's icons at `kCGDesktopIconWindowLevel` ≈ -2147483603
/// and nearby desktop-level helpers), or our own desktop window.
/// Not desktop: normal windows (0), floating panels, the Dock (20), the menu
/// bar and status items (24-25), and every other layer >= 0. An unknown window
/// (no number or no layer) is not desktop, so interaction fails closed.
public enum WindowLayerClassifier {
    public static func isDesktop(layer: Int?, windowNumber: Int, ownWindowNumber: Int?) -> Bool {
        if windowNumber > 0, windowNumber == ownWindowNumber { return true }
        guard windowNumber > 0, let layer else { return false }
        return layer < 0
    }
}
