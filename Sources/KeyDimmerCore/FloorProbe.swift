import Foundation

/// Finds the PWM macOS outputs for its smallest non-zero brightness on this Mac.
///
/// Floors differ between models (54 / 960 on a 15" M4 MacBook Air), so ember targets are derived
/// from the measured value rather than hard-coded.
public enum FloorProbe {
    public static let settleTime: TimeInterval = 0.35
    /// Real floors are tens of counts; anything lower means the probe read a fade in progress.
    public static let minimumPlausibleFloor = 8

    /// Snaps to the floor, waits for the PWM to settle, then reports it. The caller decides what to
    /// show next; the backlight is left at the floor.
    public static func measure(
        hardware: BacklightHardware, clock: EngineClock, floorGoal: Float = HoldEngine.Tuning().floorGoal,
        completion: @escaping (Int?) -> Void
    ) {
        // A goal equal to the fade in flight is ignored, so step through a different (also
        // floor-clamped) goal first.
        hardware.setBrightness(floorGoal * 2, fadeSpeed: 0, commit: false)
        hardware.setBrightness(floorGoal, fadeSpeed: 0, commit: false)
        _ = clock.after(settleTime) {
            let first = hardware.readPWM()
            _ = clock.after(0.05) {
                guard let pwm = hardware.readPWM(), pwm == first, pwm >= minimumPlausibleFloor else {
                    return completion(nil)
                }
                completion(pwm)
            }
        }
    }

    public static func cacheKey(model: String) -> String { "floorPWM.\(model)" }

    public static var hardwareModel: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }
}
