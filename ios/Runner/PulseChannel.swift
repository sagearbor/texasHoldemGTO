import Flutter
import Foundation
import WatchConnectivity

/// Pulse mode, iPhone side (docs/PULSE.md): WatchConnectivity <-> Flutter.
///
/// * EventChannel("feltnotes/pulse/events") emits `{"type":"hr",...}` and
///   `{"type":"state",...}` maps, parsed by PulseProtocol and otherwise
///   forwarded unchanged (range checks and ordering are done in Dart).
/// * MethodChannel("feltnotes/pulse/ctl"): status, start, stop, openWatchStore.
///
/// No HealthKit on the iPhone: the watch reads heart rate. Starting the watch
/// app from the phone when it is not open would need
/// HKHealthStore.startWatchApp and so the HealthKit entitlement on Runner;
/// until then `start` only works while the watch app is reachable.
final class PulseChannel: NSObject, FlutterStreamHandler, WCSessionDelegate {
    private let events: FlutterEventChannel
    private let ctl: FlutterMethodChannel
    private var sink: FlutterEventSink?

    init(messenger: FlutterBinaryMessenger) {
        events = FlutterEventChannel(name: "feltnotes/pulse/events", binaryMessenger: messenger)
        ctl = FlutterMethodChannel(name: "feltnotes/pulse/ctl", binaryMessenger: messenger)
        super.init()
        events.setStreamHandler(self)
        ctl.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    // MARK: MethodChannel

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "status":
            guard WCSession.isSupported() else {
                result(["supported": false, "paired": false, "appInstalled": false, "reachable": false])
                return
            }
            let s = WCSession.default
            let active = s.activationState == .activated
            result([
                "supported": true,
                "paired": active && s.isPaired,
                "appInstalled": active && s.isWatchAppInstalled,
                "reachable": active && s.isReachable,
            ])
        case "start":
            result(send(.ctl(.start)))
        case "stop":
            result(send(.ctl(.stop)))
        case "openWatchStore":
            // iOS has no API to open the watch's App Store page. The watch app
            // ships inside the iPhone app and installs from the Watch app.
            result(false)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func send(_ message: PulseProtocol.Message) -> Bool {
        guard WCSession.isSupported() else { return false }
        let s = WCSession.default
        guard s.activationState == .activated, s.isPaired, s.isWatchAppInstalled, s.isReachable else {
            return false
        }
        s.sendMessage(PulseProtocol.wcMessage(message), replyHandler: nil, errorHandler: nil)
        return true
    }

    // MARK: EventChannel

    func onListen(withArguments arguments: Any?, eventSink: @escaping FlutterEventSink) -> FlutterError? {
        // No replay of receivedApplicationContext here: it can be a state
        // from an earlier night. Dart asks the watch with start/stop instead.
        sink = eventSink
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        sink = nil
        return nil
    }

    /// Called on any thread; delivers on the main thread as Flutter requires.
    private func forward(_ dict: [String: Any]) {
        guard let msg = PulseProtocol.decode(dictionary: dict) else { return }
        switch msg {
        case .hr, .state:
            let map = PulseProtocol.channelMap(msg)
            DispatchQueue.main.async { [weak self] in self?.sink?(map) }
        case .ctl:
            break // phone -> watch only
        }
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        // The user switched watches; activate again for the new one.
        session.activate()
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        forward(message)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        replyHandler([:])
        forward(message)
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        forward(applicationContext)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        forward(userInfo)
    }
}
