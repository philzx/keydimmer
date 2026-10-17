import Foundation
import Testing
@testable import KeyDimmerCore

struct DisplayLightTests {
    // MARK: - Ladder

    private func shadeFactors(_ ladder: Ladder) -> [Float] {
        ladder.levels.compactMap { if case let .shade(_, factor) = $0 { return factor } else { return nil } }
    }

    @Test func theDisplayLadderIsEightShadesThenSixteenSystemStepsWithNoOff() {
        let ladder = Ladder.display()

        #expect(ladder.count == 24)
        #expect(!ladder.levels.contains(.off))
        #expect(!ladder.levels.contains { $0.isEmber })
        #expect(ladder.levels.prefix(8).allSatisfy { $0.isShade })
        #expect(ladder.shade(1) == ladder.levels[0])
        #expect(ladder.shade(8) == ladder.levels[7])
        #expect(Array(ladder.levels.suffix(16)) == (1...16).map { Level.system(step: $0) })
    }

    @Test func shadesAreSpacedGeometricallyFromAReadableDarkestShadeUpToJustBelowTheFloor() {
        let factors = shadeFactors(Ladder.display())

        #expect(factors.count == 8)
        // The darkest shade keeps roughly 10-15% of the picture, so it stays readable.
        #expect(factors[0] >= 0.10 && factors[0] <= 0.15)
        // Every step is the same change in darkness, including the step up to the unshaded floor:
        // no gap between the brightest shade and the dimmest system step.
        let ratios = zip(factors.dropFirst() + [1], factors).map { $0 / $1 }
        for ratio in ratios { #expect(abs(ratio - ratios[0]) < 0.0001) }
        #expect(factors[7] < 1)
    }

    @Test func theDisplayFloorIsTheDimmestSystemStep() {
        let ladder = Ladder.display()

        #expect(ladder.nearestLevel(forBrightness: 0) == .system(step: 1))
        #expect(ladder.nearestLevel(forBrightness: 0.01) == .system(step: 1))
        #expect(ladder.nearestLevel(forBrightness: 0.5) == .system(step: 8))
    }
}
