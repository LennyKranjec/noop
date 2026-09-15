import SwiftUI
import StrandDesign

// MissionMarqueeView.swift — today's mission, as one running line.
//
// SwiftUI twin of the Android `MissionMarquee`. The mission used to be a card of its own under the
// hero. It is one sentence, and a sentence does not need a heading, a surface and a section slot —
// that card cost more of the screen than anything else on Today per word it carried. It now runs above
// the three scores as a single line.
//
// IT SCROLLS BECAUSE IT HAS TO. A mission is two or three sentences and the strip is one line high, so
// the choice is between an ellipsis and movement. An ellipsis hides the half that says what to do.
//
// SPEED IS PER POINT OF TRAVEL, not a fixed duration: a fixed one makes a short mission crawl and a
// long one bolt past unreadably. This holds the reading speed constant and lets the duration follow the
// length.
//
// A LINE THAT FITS DOES NOT MOVE. Motion with nothing to reveal is decoration, and the app's own motion
// gate (Reduce Motion, battery saver, quiet hours) stills it regardless, in which case it truncates
// rather than scrolls. Truncated-and-still beats moving-when-asked-not-to.
//
// MEASURED UNCONSTRAINED, which is the bug the Android lane shipped first. Reading the width back off
// the laid-out line gives the VIEWPORT's width, because the line is laid out to fill it — so "is it
// wider than the strip" was never true and the marquee simply sat there truncated, looking exactly like
// one that had been asked not to move. `fixedSize` inside a scrolling clip is what measures the real
// thing here.

/// Reading speed, in points of travel per second. Slow enough to read a sentence at arm's length.
private let scrollPointsPerSecond: Double = 42

private let minDuration: Double = 6
private let maxDuration: Double = 40

struct MissionMarqueeView: View {
    let text: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var motion = NoopMotionState.shared

    @State private var textWidth: CGFloat = 0
    @State private var viewportWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    private var still: Bool { motion.poseStill(reduceMotion) }
    private var overflows: Bool { textWidth > viewportWidth && viewportWidth > 0 }

    private var font: Font { StrandFont.footnote.weight(.medium) }

    var body: some View {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            ZStack(alignment: .leading) {
                // The hidden twin is what measures the line at its TRUE width — `fixedSize` opts it out
                // of the parent's width so it reports what it actually needs rather than what it was
                // given. It never draws.
                Text(trimmed)
                    .font(font)
                    .lineLimit(1)
                    .fixedSize()
                    .background(
                        GeometryReader { geo in
                            Color.clear.onAppear { textWidth = geo.size.width }
                                .onChangeCompat(of: geo.size.width) { textWidth = $0 }
                        }
                    )
                    .hidden()

                if overflows && !still {
                    Text(trimmed)
                        .font(font)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineLimit(1)
                        .fixedSize()
                        .offset(x: offset)
                } else {
                    Text(trimmed)
                        .font(font)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
            .background(
                GeometryReader { geo in
                    Color.clear.onAppear { viewportWidth = geo.size.width }
                        .onChangeCompat(of: geo.size.width) { viewportWidth = $0 }
                }
            )
            .padding(.horizontal, 16)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(trimmed))
            .onAppear { restart() }
            .onChangeCompat(of: trimmed) { _ in restart() }
            .onChangeCompat(of: overflows) { _ in restart() }
            .onChangeCompat(of: still) { _ in restart() }
        }
    }

    /// Start (or stop) the loop for the current measurements.
    ///
    /// Enters from the right edge and leaves past the left, so the loop has no visible seam. LINEAR and
    /// repeating without autoreverse: an eased loop slows at both ends, which on a line of text reads as
    /// the app stuttering rather than as a considered motion, and an autoreversed one would run the
    /// sentence backwards.
    private func restart() {
        guard overflows, !still else {
            offset = 0
            return
        }
        let travel = textWidth + viewportWidth
        let duration = min(max(Double(travel) / scrollPointsPerSecond, minDuration), maxDuration)
        offset = viewportWidth
        withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) {
            offset = -textWidth
        }
    }
}
