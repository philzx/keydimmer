import Foundation
import KeyDimmerCore

// Diagnostics for the keyboard backlight and the hold engine.
//
//   kdctl info              current state of the backlight
//   kdctl floor             measure this Mac's floor PWM
//   kdctl hold <pwm> [sec]  hold a sub-minimum PWM and report how steady it stayed
//   kdctl set <0...1>       set a macOS brightness (committed)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let arguments = Array(CommandLine.arguments.dropFirst())
let hardware: CoreBrightnessBacklight
do {
    hardware = try CoreBrightnessBacklight()
} catch {
    fail("kdctl: \(error)")
}
let clock = DispatchClock()

func info() {
    print("model            \(FloorProbe.hardwareModel)")
    print("keyboard id      \(hardware.keyboardID)")
    print("pwm              \(hardware.readPWM().map(String.init) ?? "unavailable") / \(hardware.totalPeriod)")
    print("brightness       \(hardware.brightness())")
    print("auto brightness  \(hardware.isAutoBrightnessEnabled)")
    print("idle dim time    \(hardware.idleDimTime()) s")
    print("lid closed       \(hardware.isLidClosed())")
}

func hold(pwm: Int, seconds: TimeInterval) {
    let originalBrightness = hardware.brightness()
    let originalAuto = hardware.isAutoBrightnessEnabled
    hardware.setAutoBrightness(false)
    hardware.setIdleDimmingSuspended(true)

    func restore() {
        hardware.setBrightness(originalBrightness, fadeSpeed: 350, commit: false)
        hardware.setIdleDimmingSuspended(false)
        hardware.setAutoBrightness(originalAuto)
    }
    signal(SIGINT, SIG_IGN)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    interrupt.setEventHandler { restore(); exit(130) }
    interrupt.resume()

    FloorProbe.measure(hardware: hardware, clock: clock) { floor in
        guard let floor else { restore(); fail("kdctl: could not measure the floor") }
        print("floor \(floor) / \(hardware.totalPeriod)")
        let engine = HoldEngine(hardware: hardware, clock: clock, floorPWM: floor)
        engine.onFailure = { message in restore(); fail("kdctl: \(message)") }
        let start = clock.now
        engine.onTrace = { print(String(format: "t=%7.2f ", clock.now - start) + $0) }
        engine.hold(pwm: pwm)
        print("holding \(engine.target ?? pwm)")

        var samples = 0
        var hits = 0
        var histogram: [Int: Int] = [:]
        var last: Int?
        var holdingSince: TimeInterval?
        func sample() {
            let now = clock.now
            let value = hardware.readPWM() ?? -1
            if engine.phase == .holding {
                if holdingSince == nil {
                    holdingSince = now
                    print(String(format: "synced after %.2f s", now - start))
                }
                samples += 1
                histogram[value, default: 0] += 1
                if value == engine.target { hits += 1 }
                if value != last {
                    print(String(format: "t=%7.2f pwm=%d", now - start, value))
                    last = value
                }
            }
            if now - start >= seconds {
                let stats = engine.stats
                engine.stop()
                restore()
                print("—")
                print(String(format: "on target %.2f%% of %d samples (20 Hz)", Double(hits) / Double(max(samples, 1)) * 100, samples))
                print("histogram \(histogram.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: " "))")
                print("reversals \(stats.reversals), resyncs \(stats.resyncs), hold duration estimate \(String(format: "%.1f", engine.tuning.holdDuration)) s")
                exit(0)
            }
            _ = clock.after(0.05, sample)
        }
        sample()
    }
    dispatchMain()
}

switch arguments.first {
case "info", nil:
    info()
case "floor":
    let original = hardware.brightness()
    FloorProbe.measure(hardware: hardware, clock: clock) { floor in
        print(floor.map { "floor \($0) / \(hardware.totalPeriod)" } ?? "floor unavailable")
        hardware.setBrightness(original, fadeSpeed: 0, commit: false)
        exit(floor == nil ? 1 : 0)
    }
    dispatchMain()
case "hold":
    guard arguments.count >= 2, let pwm = Int(arguments[1]) else { fail("usage: kdctl hold <pwm> [seconds]") }
    hold(pwm: pwm, seconds: arguments.count >= 3 ? TimeInterval(arguments[2]) ?? 60 : 60)
case "set":
    guard arguments.count >= 2, let value = Float(arguments[1]) else { fail("usage: kdctl set <0...1>") }
    hardware.setBrightness(value, fadeSpeed: 350, commit: true)
default:
    fail("usage: kdctl info | floor | hold <pwm> [seconds] | set <0...1>")
}
