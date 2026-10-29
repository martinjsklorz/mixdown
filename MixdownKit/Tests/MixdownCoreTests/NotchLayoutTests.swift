import CoreGraphics
import Foundation
import MixdownCore
import Testing

struct NotchLayoutTests {
    /// A 200 pt notch at the top of a 1512 × 982 screen.
    private let notch = CGRect(x: 656, y: 950, width: 200, height: 32)
    /// No notch: zero width at the top center, as tall as the menu bar.
    private let noNotch = CGRect(x: 756, y: 958, width: 0, height: 24)

    @Test func wingsGoEitherSideOfTheNotch() {
        let layout = NotchLayout(timeOnLeft: true, timeWingWidth: 60, levelsWingWidth: 40)
        #expect(layout.islandFrame(around: notch) == CGRect(x: 596, y: 950, width: 300, height: 32))

        let flipped = NotchLayout(timeOnLeft: false, timeWingWidth: 60, levelsWingWidth: 40)
        #expect(flipped.wingWidths == (40, 60))
        #expect(flipped.islandFrame(around: notch) == CGRect(x: 616, y: 950, width: 300, height: 32))
    }

    @Test func liveTextRunsUnderTheWingsAndTheNotch() {
        let layout = NotchLayout(timeOnLeft: true, timeWingWidth: 60, levelsWingWidth: 40, liveTextHeight: 20)
        #expect(layout.islandFrame(around: notch) == CGRect(x: 596, y: 930, width: 300, height: 52))
    }

    @Test func withoutANotchTheIslandIsCentered() {
        let layout = NotchLayout(timeOnLeft: true, timeWingWidth: 60, levelsWingWidth: 40)
        #expect(layout.gap(for: noNotch) == noNotch)
        #expect(layout.islandFrame(around: noNotch) == CGRect(x: 706, y: 958, width: 100, height: 24))
    }

    @Test func withoutANotchLiveTextGetsAGapToBeReadable() {
        let layout = NotchLayout(
            timeOnLeft: true,
            timeWingWidth: 60,
            levelsWingWidth: 40,
            liveTextHeight: 20,
            liveTextGapWidth: 300
        )
        #expect(layout.gap(for: noNotch) == CGRect(x: 606, y: 958, width: 300, height: 24))
        #expect(layout.islandFrame(around: noNotch) == CGRect(x: 546, y: 938, width: 400, height: 44))
        // A real notch is wide enough already.
        #expect(layout.gap(for: notch) == notch)
    }

    @Test func dropdownsHangCenteredUnderTheNotchOrTheIsland() {
        let size = CGSize(width: 320, height: 100)
        #expect(
            NotchLayout.dropdownFrame(notch: notch, islandFrame: nil, size: size, spacing: 8)
                == CGRect(x: 596, y: 842, width: 320, height: 100)
        )
        let island = CGRect(x: 596, y: 930, width: 300, height: 52)
        #expect(
            NotchLayout.dropdownFrame(notch: notch, islandFrame: island, size: size, spacing: 8)
                == CGRect(x: 596, y: 822, width: 320, height: 100)
        )
    }
}
