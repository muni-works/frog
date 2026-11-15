import SwiftUI

/// How much room a split pane has, so its pieces agree on what to show instead of each
/// squeezing on its own: wide shows everything, medium drops the extras, narrow keeps only
/// what you act on (what it's doing, the field, the model). A pane alone is always wide.
enum PaneWidth: Comparable {
    case narrow, medium, wide

    init(_ width: CGFloat) {
        self = width < 560 ? .narrow : width < 900 ? .medium : .wide
    }
}

extension EnvironmentValues {
    @Entry var paneWidth: PaneWidth = .wide
}
