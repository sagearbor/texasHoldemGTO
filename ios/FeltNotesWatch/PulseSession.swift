import Foundation
import HealthKit
import WatchConnectivity

/// Heart rate from a workout session, sent to the iPhone over WatchConnectivity
/// (protocol: docs/PULSE.md, ios/PulseShared/PulseProtocol.swift).
///
/// * HKWorkoutSession (.other, indoor) + HKLiveWorkoutBuilder: the only way a
///   third-party watch app gets ~1 Hz heart rate.
/// * On stop the workout is discarded, never saved, so nothing lands in the
///   player's Health app or Activity rings.
/// * Samples are batched and sent every ~2 s while the iPhone is reachable;
///   `state` goes out on every change. `ctl` start/stop from the phone is obeyed.
@MainActor
final class PulseSession: NSObject, ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var starting = false
    @Published private(set) var bpm: Int?
    @Published private(set) var phoneReachable = false
    @Published private(set) var error: String?

    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var pending: [PulseProtocol.Sample] = []
    private var lastSampleMs: Int64 = 0
    private var sendTimer: Timer?

    /// Keep at most this many unsent samples (about 4 minutes at 1 Hz) while
    /// the phone is away; older ones are dropped.
    private let maxPending = 240

    override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    // MARK: Start / stop

    func toggle() {
        if running || starting { stop() } else { start() }
    }

    func start() {
        guard !running, !starting else {
            sendState()
            return
        }
        guard HKHealthStore.isHealthDataAvailable() else {
            fail("unavailable")
            return
        }
        starting = true
        error = nil
        let hr = HKQuantityType(.heartRate)
        store.requestAuthorization(toShare: [HKObjectType.workoutType()], read: [hr]) { [weak self] ok, err in
            Task { @MainActor in
                guard let self else { return }
                // Read authorization is private in HealthKit; a refused share
                // (workout) permission is what we can see.
                if !ok || err != nil || self.store.authorizationStatus(for: HKObjectType.workoutType()) != .sharingAuthorized {
                    self.starting = false
                    self.fail("no_permission")
                    return
                }
                self.beginWorkout()
            }
        }
    }

    func stop() {
        starting = false
        if let session {
            session.end() // discarding happens in the .ended delegate callback
        } else {
            setRunning(false)
        }
    }

    private func beginWorkout() {
        let config = HKWorkoutConfiguration()
        config.activityType = .other
        config.locationType = .indoor
        do {
            let session = try HKWorkoutSession(healthStore: store, configuration: config)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: config)
            session.delegate = self
            builder.delegate = self
            self.session = session
            self.builder = builder
            let now = Date()
            session.startActivity(with: now)
            builder.beginCollection(withStart: now) { [weak self] ok, _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.starting = false
                    if ok {
                        self.setRunning(true)
                    } else {
                        self.session?.end()
                        self.fail("workout_failed")
                    }
                }
            }
        } catch {
            starting = false
            fail("workout_failed")
        }
    }

    private func fail(_ code: String) {
        error = code
        running = false
        stopTimer()
        sendState()
    }

    private func setRunning(_ value: Bool) {
        let changed = running != value
        running = value
        if value {
            error = nil
            startTimer()
        } else {
            flush()
            stopTimer()
            bpm = nil
        }
        if changed { sendState() }
    }

    // MARK: Sending

    private func startTimer() {
        guard sendTimer == nil else { return }
        sendTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.flush() }
        }
    }

    private func stopTimer() {
        sendTimer?.invalidate()
        sendTimer = nil
    }

    private func flush() {
        guard !pending.isEmpty, WCSession.isSupported() else { return }
        let wc = WCSession.default
        guard wc.activationState == .activated, wc.isReachable else { return }
        let batch = pending
        pending.removeAll()
        wc.sendMessage(PulseProtocol.wcMessage(.hr(batch)), replyHandler: nil) { [weak self] _ in
            // Put the batch back in front; the next tick retries.
            Task { @MainActor in
                guard let self else { return }
                self.pending = Array((batch + self.pending).suffix(self.maxPending))
            }
        }
    }

    private func sendState() {
        guard WCSession.isSupported() else { return }
        let wc = WCSession.default
        guard wc.activationState == .activated else { return }
        let msg = PulseProtocol.wcMessage(.state(running: running, err: error))
        if wc.isReachable {
            wc.sendMessage(msg, replyHandler: nil) { _ in
                try? wc.updateApplicationContext(msg)
            }
        } else {
            // Latest state wins; the phone reads it when it next activates.
            try? wc.updateApplicationContext(msg)
        }
    }

    private func addSample(bpm value: Double, at date: Date) {
        let t = Int64((date.timeIntervalSince1970 * 1000).rounded())
        guard t > lastSampleMs else { return }
        lastSampleMs = t
        let b = Int(value.rounded())
        bpm = b
        pending.append(PulseProtocol.Sample(tMs: t, bpm: b))
        if pending.count > maxPending { pending.removeFirst(pending.count - maxPending) }
    }

    fileprivate func handle(_ dict: [String: Any]) {
        guard case .ctl(let cmd)? = PulseProtocol.decode(dictionary: dict) else { return }
        switch cmd {
        case .start: start()
        case .stop: stop()
        }
        sendState()
    }

    fileprivate func reachabilityChanged(_ reachable: Bool) {
        phoneReachable = reachable
        if reachable {
            sendState()
            flush()
        }
    }

    fileprivate func workoutEnded() {
        builder?.endCollection(withEnd: Date()) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                self.builder?.discardWorkout()
                self.builder = nil
                self.session = nil
            }
        }
        setRunning(false)
    }

    fileprivate func workoutFailed() {
        builder?.discardWorkout()
        builder = nil
        session = nil
        fail("workout_failed")
    }
}

// MARK: - HealthKit delegates

extension PulseSession: HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        guard toState == .ended else { return }
        Task { @MainActor in self.workoutEnded() }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in self.workoutFailed() }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        let hr = HKQuantityType(.heartRate)
        guard collectedTypes.contains(hr),
              let stats = workoutBuilder.statistics(for: hr),
              let quantity = stats.mostRecentQuantity()
        else { return }
        let value = quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
        let date = stats.mostRecentQuantityDateInterval()?.end ?? Date()
        Task { @MainActor in self.addSample(bpm: value, at: date) }
    }
}

// MARK: - WatchConnectivity

extension PulseSession: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        let reachable = session.isReachable
        Task { @MainActor in self.reachabilityChanged(reachable) }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in self.reachabilityChanged(reachable) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let dict = PulseSession.plistSafe(message)
        Task { @MainActor in self.handle(dict) }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        replyHandler([:])
        let dict = PulseSession.plistSafe(message)
        Task { @MainActor in self.handle(dict) }
    }

    /// Only the two string fields cross the actor boundary.
    nonisolated private static func plistSafe(_ message: [String: Any]) -> [String: String] {
        var out: [String: String] = [:]
        if let p = message[PulseProtocol.keyPath] as? String { out[PulseProtocol.keyPath] = p }
        if let j = message[PulseProtocol.keyJson] as? String { out[PulseProtocol.keyJson] = j }
        return out
    }
}
