import CoreGraphics

/// App-level spacing scale for the main window and transcript chrome.
///
/// `agents.md` mandates shared spacing tokens over ad-hoc paddings. Adopt these
/// instead of literal padding values so spacing stays consistent and a single
/// edit can retune the rhythm. The scale is 4-based; genuine one-off values that
/// don't fit the scale may stay as literals until they can be normalized.
enum LayoutTokens {
    /// 4 — tight inner gaps (icon ↔ label, chip vertical padding).
    static let xs: CGFloat = 4
    /// 8 — default gap between adjacent controls; pane content inset.
    static let sm: CGFloat = 8
    /// 12 — card interior inset; section horizontal padding.
    static let md: CGFloat = 12
    /// 16 — separation between distinct groups.
    static let lg: CGFloat = 16
    /// 24 — major section separation.
    static let xl: CGFloat = 24
}
