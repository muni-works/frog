import SwiftUI

/// A scroll view as tall as its content, up to `maxHeight`, so a floating card hugs short
/// content instead of stretching to the window.
struct HuggingScroll<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: Content
    @State private var height: CGFloat = 0

    var body: some View {
        ScrollView {
            content
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { height = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(max(height, 1), maxHeight))
    }
}
