import Foundation
import KeyDimmerCore

// Diagnostics for the built-in display and its shades.
//
//   kdctl display [info]                 brightness, measured nits and the gamma peak
//   kdctl display shade <factor> [sec]   hold a shade, report outside gamma changes, then restore

func runDisplay(_ arguments: [String]) -> Never {
    let command: DisplayCommand
    do {
        command = try DisplayCommand.parse(arguments)
    } catch {
        fail("\(error)")
    }
    let display: BuiltInDisplay
    do {
        display = try BuiltInDisplay()
    } catch {
        fail("kdctl: \(error)")
    }
    switch command {
    case .info:
        displayInfo(display)
        exit(0)
    case let .shade(factor, seconds):
        holdShade(display, factor: factor, seconds: seconds)
    }
}

private func format(peak: Float?) -> String {
    peak.map { String(format: "%.4f", $0) } ?? "unavailable"
}

private func displayInfo(_ display: BuiltInDisplay) {
    let gamma = display.readGamma()
    print("display id       \(display.displayID)")
    print("brightness       \(display.brightness())")
    print("auto brightness  \(display.hasAutoBrightness ? String(display.isAutoBrightnessEnabled) : "unavailable")")
    print("measured nits    \(display.measuredNits().map { String(format: "%.3f", $0) } ?? "unavailable")")
    print("gamma peak       \(format(peak: gamma?.peak))\(gamma.map { " (\($0.green.count) entries)" } ?? "")")
}

private func holdShade(_ display: BuiltInDisplay, factor: Float, seconds: TimeInterval) -> Never {
    let clock = DispatchClock()
    let start = clock.now
    func stamp() -> String { String(format: "t=%7.2f ", clock.now - start) }

    // Restore on Ctrl-C and on a plain kill as well as at the end.
    var signalSources: [DispatchSourceSignal] = []
    for (signalNumber, status) in [(SIGINT, Int32(130)), (SIGTERM, Int32(143))] {
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
        source.setEventHandler {
            display.restoreGamma()
            print("\(stamp())interrupted, gamma restored (peak \(format(peak: display.readGamma()?.peak)))")
            exit(status)
        }
        source.resume()
        signalSources.append(source)
    }

    print("\(stamp())nits \(display.measuredNits().map { String(format: "%.3f", $0) } ?? "unavailable"), gamma peak \(format(peak: display.readGamma()?.peak)) before the shade")
    display.setGamma(factor: factor)
    guard let applied = display.readGamma() else {
        display.restoreGamma()
        fail("kdctl: could not read the display's gamma table")
    }
    print("\(stamp())shade \(factor) applied, gamma peak \(format(peak: applied.peak)); holding \(seconds) s")

    var watch = GammaWatch(expecting: applied)
    var outsideChanges = 0
    func sample() {
        if let current = display.readGamma(), let change = watch.observe(current) {
            outsideChanges += 1
            print("\(stamp())gamma changed by someone else: peak \(format(peak: change.peakBefore)) → \(format(peak: change.peakAfter))")
            // Put the shade back, as the app would, and expect whatever actually took.
            display.setGamma(factor: factor)
            if let reasserted = display.readGamma() {
                watch.expect(reasserted)
                print("\(stamp())shade re-applied, gamma peak \(format(peak: reasserted.peak))")
            }
        }
        if clock.now - start >= seconds {
            display.restoreGamma()
            print("—")
            print("\(outsideChanges) outside gamma change\(outsideChanges == 1 ? "" : "s") in \(seconds) s")
            print("gamma restored, peak \(format(peak: display.readGamma()?.peak))")
            withExtendedLifetime(signalSources) { exit(0) }
        }
        _ = clock.after(0.05, sample)
    }
    sample()
    dispatchMain()
}
