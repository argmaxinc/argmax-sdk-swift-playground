import SwiftUI

// ProgressView().progressViewStyle(.linear) with no value is indeterminate on macOS (animates side-to-side)
// but renders as a static filled bar on iOS. This custom view replicates that animation on both platforms.
struct IndeterminateProgressBar: View {
    // 0 = capsule at left edge, 0.65 = capsule at right edge (capsule is 35% of track width).
    // Starting at 0 (not -1) keeps the indicator inside the track on every animation frame,
    // avoiding the overflow past the left edge that happened when reversing back to -1.
    @State private var offset: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.2))

                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: geo.size.width * 0.35)
                    .offset(x: offset * geo.size.width)
            }
        }
        .frame(height: 4)
        .clipped()
        .onAppear {
            withAnimation(
                .easeInOut(duration: 1.2)
                .repeatForever(autoreverses: true)
            ) {
                offset = 0.65
            }
        }
    }
}
