import Testing
@testable import KeyDimmerCore

struct BelowFloorTests {
    @Test func embersAndShadesHaveABelowFloorIndexButOffAndSystemStepsDont() {
        #expect(Level.ember(index: 3, pwm: 7).belowFloorIndex == 3)
        #expect(Level.shade(index: 2, factor: 0.5).belowFloorIndex == 2)
        #expect(Level.off.belowFloorIndex == nil)
        #expect(Level.system(step: 4).belowFloorIndex == nil)
    }

    @Test func aKeyboardLadderCountsItsEmbersAsBelowTheFloor() {
        let ladder = Ladder(floorPWM: Ladder.assumedFloorPWM)
        #expect(ladder.belowFloorCount == Ladder.emberCount)
        #expect(ladder.belowFloorCount == ladder.emberCount)
        #expect(ladder.shadeCount == 0)
        // A very low floor leaves room for fewer embers.
        #expect(Ladder(floorPWM: 3).belowFloorCount == Ladder(floorPWM: 3).emberCount)
    }

    @Test func theDisplayLadderCountsItsShadesAsBelowTheFloor() {
        let ladder = Ladder.display()
        #expect(ladder.belowFloorCount == Ladder.shadeCount)
        #expect(ladder.belowFloorCount == ladder.shadeCount)
        #expect(ladder.emberCount == 0)
    }

    @Test func aKeyboardLadderLooksUpEmbersByIndexClampedToItsEmbers() {
        let ladder = Ladder(floorPWM: Ladder.assumedFloorPWM)
        let embers = ladder.levels.filter(\.isEmber)
        #expect(ladder.belowFloor(4) == embers[3])
        #expect(ladder.belowFloor(0) == embers.first)
        #expect(ladder.belowFloor(-5) == embers.first)
        #expect(ladder.belowFloor(99) == embers.last)
        #expect(ladder.ember(4) == embers[3])
        #expect(ladder.ember(99) == embers.last)
        #expect(ladder.shade(1) == nil)
    }

    @Test func theDisplayLadderLooksUpShadesByIndexClampedToItsShades() {
        let ladder = Ladder.display()
        let shades = ladder.levels.filter(\.isShade)
        #expect(ladder.belowFloor(3) == shades[2])
        #expect(ladder.belowFloor(0) == shades.first)
        #expect(ladder.belowFloor(99) == shades.last)
        #expect(ladder.shade(3) == shades[2])
        #expect(ladder.shade(-1) == shades.first)
        #expect(ladder.ember(1) == nil)
    }

    @Test func storedEmbersAndShadesStillDecodeOnTheirOwnLadders() {
        let keyboard = Ladder(floorPWM: Ladder.assumedFloorPWM)
        let display = Ladder.display()
        #expect(keyboard.level(named: "ember:5") == keyboard.ember(5))
        #expect(keyboard.level(named: "shade:2") == nil)
        #expect(display.level(named: "shade:2") == display.shade(2))
        #expect(display.level(named: "ember:5") == nil)
    }

    @Test func theFractionUpTheBelowFloorRangeIsIndexOverCount() {
        let keyboard = Ladder(floorPWM: Ladder.assumedFloorPWM)
        let display = Ladder.display()
        #expect(keyboard.belowFloorFraction(of: keyboard.ember(3)!) == 3.0 / Double(Ladder.emberCount))
        #expect(keyboard.belowFloorFraction(of: keyboard.ember(99)!) == 1)
        #expect(display.belowFloorFraction(of: display.shade(2)!) == 2.0 / Double(Ladder.shadeCount))
        #expect(display.belowFloorFraction(of: .system(step: 8)) == nil)
        #expect(keyboard.belowFloorFraction(of: .off) == nil)
    }

    @Test func theFractionMatchesThePerKindFormulaForEveryLevel() {
        for ladder in [Ladder(floorPWM: Ladder.assumedFloorPWM), Ladder(floorPWM: 3), Ladder.display()] {
            for level in ladder.levels {
                let expected: Double? = switch level {
                case let .ember(i, _): Double(i) / Double(max(ladder.emberCount, 1))
                case let .shade(i, _): Double(i) / Double(max(ladder.shadeCount, 1))
                case .off, .system: nil
                }
                #expect(ladder.belowFloorFraction(of: level) == expected)
            }
        }
    }
}
