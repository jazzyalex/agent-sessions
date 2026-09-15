import SwiftUI
import AppKit

/// The window's surface ramp.
///
/// Light mode used to read as two apps stitched together: the session list sits on
/// `windowBackgroundColor` while the Session info inspector painted
/// `controlBackgroundColor` — pure white — beside it. Dark mode hid the mismatch
/// because every dark surface collapses toward the same near-black.
///
/// One rule fixes it: **the transcript is the only thing that gets a lifted
/// surface.** Everything that frames it — toolbars, session list, inspector,
/// identity strip — is chrome and shares one level.
///
/// The ramp is applied, not inverted, across themes. In light, paper is *lighter*
/// than the chrome; in dark, `textBackgroundColor` is *darker* than
/// `windowBackgroundColor`, so paper recedes instead of floating. A raised light
/// surface in a dark UI reads as a modal.
enum Surface {
    /// Level 0 — toolbars, session list, inspector, status and identity strips.
    static let chrome = Color(nsColor: .windowBackgroundColor)

    /// Level 1 — the transcript body. The only lifted surface in the window.
    static let paper = Color(nsColor: .textBackgroundColor)

    /// Hairline between two Level 0 regions.
    static let hairline = Color(nsColor: .separatorColor)
}
