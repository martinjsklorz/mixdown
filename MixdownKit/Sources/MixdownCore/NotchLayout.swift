import CoreGraphics
import Foundation

/// Where the Dynamic Island and what drops down under it go around the camera notch, in screen
/// coordinates, whose y grows upwards. On a screen without a notch, the notch is a zero-width
/// rectangle at the top center, as tall as the menu bar.
///
/// The island has a wing either side of the notch: the recording time on one, the input levels on
/// the other. The live text, if shown, runs under all three.
public struct NotchLayout: Equatable, Sendable {
    /// Whether the time's wing is left of the notch; the levels' go on the other side.
    public var timeOnLeft: Bool
    /// How far the time reaches out from the notch.
    public var timeWingWidth: CGFloat
    /// How far the levels reach out from the notch; zero without them.
    public var levelsWingWidth: CGFloat
    /// The height of the live text's line under the notch; zero without it.
    public var liveTextHeight: CGFloat
    /// Space left between the wings for the live text on a screen without a notch, which would
    /// otherwise be only as wide as the wings. Unused without live text.
    public var liveTextGapWidth: CGFloat

    public init(
        timeOnLeft: Bool,
        timeWingWidth: CGFloat,
        levelsWingWidth: CGFloat,
        liveTextHeight: CGFloat = 0,
        liveTextGapWidth: CGFloat = 0
    ) {
        self.timeOnLeft = timeOnLeft
        self.timeWingWidth = timeWingWidth
        self.levelsWingWidth = levelsWingWidth
        self.liveTextHeight = liveTextHeight
        self.liveTextGapWidth = liveTextGapWidth
    }

    /// How far the wings reach out from the notch on either side.
    public var wingWidths: (left: CGFloat, right: CGFloat) {
        timeOnLeft ? (timeWingWidth, levelsWingWidth) : (levelsWingWidth, timeWingWidth)
    }

    /// The space between the wings: `notch`, or without one, room for the live text to be wide
    /// enough to read.
    public func gap(for notch: CGRect) -> CGRect {
        guard notch.width == 0, liveTextHeight > 0 else { return notch }
        return notch.insetBy(dx: -liveTextGapWidth / 2, dy: 0)
    }

    /// The island's frame: the wings, each as wide as its content, either side of `notch`, and the
    /// live text under all three.
    public func islandFrame(around notch: CGRect) -> CGRect {
        let gap = gap(for: notch)
        let (left, right) = wingWidths
        let width = left + gap.width + right
        // Without a notch to grow out of: centered.
        let x = gap.width == 0 ? gap.midX - width / 2 : gap.minX - left
        return CGRect(x: x, y: gap.minY - liveTextHeight, width: width, height: gap.height + liveTextHeight)
    }

    /// The frame of a panel of `size` that drops down under `notch`, centered on it, `spacing`
    /// below it, or below the island while it's shown.
    public static func dropdownFrame(notch: CGRect, islandFrame: CGRect?, size: CGSize, spacing: CGFloat) -> CGRect {
        let top = (islandFrame?.minY ?? notch.minY) - spacing
        return CGRect(x: notch.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height)
    }
}
