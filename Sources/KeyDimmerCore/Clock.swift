import Foundation

public protocol Cancellable: AnyObject {
    func cancel()
}

/// Time source and one-shot scheduler. The engine only ever runs on the clock's queue.
public protocol EngineClock: AnyObject {
    var now: TimeInterval { get }
    @discardableResult
    func after(_ delay: TimeInterval, _ work: @escaping () -> Void) -> Cancellable
}

/// Main-queue clock backed by strict one-shot dispatch timers (approach polling needs ~ms accuracy).
public final class DispatchClock: EngineClock {
    private let queue: DispatchQueue

    public init(queue: DispatchQueue = .main) {
        self.queue = queue
    }

    public var now: TimeInterval { TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }

    public func after(_ delay: TimeInterval, _ work: @escaping () -> Void) -> Cancellable {
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now() + max(delay, 0), leeway: .milliseconds(1))
        let token = TimerToken(timer)
        // The handler keeps the token alive until the timer fires or is cancelled, so callers may
        // discard it; cancel() clears the handler and breaks the cycle.
        timer.setEventHandler {
            guard !token.isCancelled else { return }
            token.cancel()
            work()
        }
        timer.resume()
        return token
    }

    private final class TimerToken: Cancellable {
        private let timer: DispatchSourceTimer
        private(set) var isCancelled = false

        init(_ timer: DispatchSourceTimer) { self.timer = timer }

        func cancel() {
            guard !isCancelled else { return }
            isCancelled = true
            timer.setEventHandler(handler: nil)
            timer.cancel()
        }
    }
}
