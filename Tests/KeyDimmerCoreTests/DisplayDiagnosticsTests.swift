import Testing
@testable import KeyDimmerCore

struct DisplayCommandTests {
    @Test func infoIsTheDefault() throws {
        #expect(try DisplayCommand.parse([]) == .info)
        #expect(try DisplayCommand.parse(["info"]) == .info)
    }

    @Test func shadeHoldsForTenSecondsUnlessToldOtherwise() throws {
        #expect(try DisplayCommand.parse(["shade", "0.5"]) == .shade(factor: 0.5, seconds: 10))
        #expect(try DisplayCommand.parse(["shade", "0.25", "30"]) == .shade(factor: 0.25, seconds: 30))
        #expect(try DisplayCommand.parse(["shade", "1"]) == .shade(factor: 1, seconds: 10))
    }

    @Test(arguments: [
        ["shade"],
        ["shade", "half"],
        ["shade", "0"],
        ["shade", "-0.5"],
        ["shade", "1.5"],
        ["shade", "nan"],
        ["shade", "0.5", "soon"],
        ["shade", "0.5", "0"],
        ["shade", "0.5", "-3"],
        ["shade", "0.5", "inf"],
        ["shade", "0.5", "10", "extra"],
        ["info", "extra"],
        ["dim"],
    ])
    func rejectsMalformedArguments(_ arguments: [String]) {
        #expect(throws: DisplayCommand.UsageError.self) { try DisplayCommand.parse(arguments) }
    }
}

struct GammaWatchTests {
    static let identity = GammaTable(
        red: (0...255).map { Float($0) / 255 }, green: (0...255).map { Float($0) / 255 }, blue: (0...255).map { Float($0) / 255 }
    )
    static let shaded = identity.scaled(by: 0.4)

    @Test func reportsWhenSomeoneElseResetsTheShade() {
        var watch = GammaWatch(expecting: Self.shaded)
        #expect(watch.observe(Self.shaded) == nil)
        let change = watch.observe(Self.identity)
        #expect(change?.peakBefore == 0.4)
        #expect(change?.peakAfter == 1.0)
    }

    @Test func ignoresRoundingInTheTableReadBack() {
        var watch = GammaWatch(expecting: Self.shaded)
        let quantized = GammaTable(
            red: Self.shaded.red.map { $0 + 0.0002 }, green: Self.shaded.green.map { $0 - 0.0002 }, blue: Self.shaded.blue
        )
        #expect(watch.observe(quantized) == nil)
    }

    @Test func reportsALastingChangeOnceAndAcceptsTheReassertedShade() {
        var watch = GammaWatch(expecting: Self.shaded)
        #expect(watch.observe(Self.identity) != nil)
        #expect(watch.observe(Self.identity) == nil, "the same outside table is not a second change")
        watch.expect(Self.shaded) // kdctl puts the shade back
        #expect(watch.observe(Self.shaded) == nil)
        #expect(watch.observe(Self.identity)?.peakBefore == 0.4, "a second reset is reported again")
    }

    @Test func noticesAChangeThatLeavesThePeakAlone() {
        // Night Shift warms the picture by pulling blue down; red still peaks at the shade.
        var watch = GammaWatch(expecting: Self.shaded)
        let warmer = GammaTable(red: Self.shaded.red, green: Self.shaded.green, blue: Self.shaded.blue.map { $0 * 0.7 })
        let change = watch.observe(warmer)
        #expect(change != nil)
        #expect(change?.peakAfter == change?.peakBefore)
    }
}
