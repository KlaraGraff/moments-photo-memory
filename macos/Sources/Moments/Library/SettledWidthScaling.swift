import SwiftUI

/// Keeps its content laid out at the last settled width and scales it to the
/// live width while the width is changing, the way Photos zooms its grid
/// while the sidebar moves. The photo grid then does one layout when the
/// width settles instead of one per animation frame (about half a second
/// each with a few hundred photos on the CI Mac).
struct SettledWidthScaling<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var live: CGSize = .zero
    @State private var settledWidth: CGFloat = 0
    @State private var settle: Task<Void, Never>?

    /// How long the width must stay put before the content is laid out again.
    private static var settleDelay: Duration { .milliseconds(120) }

    var body: some View {
        let scale = settledWidth > 0 && live.width > 0 ? live.width / settledWidth : 1
        Color.clear
            .overlay(alignment: .topLeading) {
                content
                    // Taller or shorter by the inverse scale, so once scaled
                    // it still fills the space from top to bottom.
                    .frame(width: settledWidth > 0 ? settledWidth : nil,
                           height: live.height > 0 ? live.height / scale : nil)
                    .scaleEffect(scale, anchor: .topLeading)
            }
            .clipped()
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { size in
                live = size
                guard settledWidth > 0 else {
                    settledWidth = size.width
                    return
                }
                guard size.width != settledWidth else {
                    settle?.cancel()
                    return
                }
                settle?.cancel()
                settle = Task { @MainActor in
                    try? await Task.sleep(for: Self.settleDelay)
                    guard !Task.isCancelled else { return }
                    settledWidth = live.width
                }
            }
    }
}
