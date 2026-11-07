import Foundation

/// Pulse watch <-> phone protocol v1 (docs/PULSE.md). Compiled into both the
/// watch app (FeltNotesWatch) and the iPhone app (Runner), and checked against
/// test/pulse/protocol_vectors.json by tool/watch_ios/check_protocol.sh.
///
/// Over WatchConnectivity a message is the dictionary
/// `["path": <path>, "json": <payload>]`, the same strings as Wear OS uses.
/// Foundation only: no WatchConnectivity, HealthKit or Flutter here.
enum PulseProtocol {
    static let version = 1
    static let pathHr = "/feltnotes/pulse/v1/hr"
    static let pathCtl = "/feltnotes/pulse/v1/ctl"
    static let pathState = "/feltnotes/pulse/v1/state"

    /// WCSession dictionary keys.
    static let keyPath = "path"
    static let keyJson = "json"

    struct Sample: Equatable {
        /// Epoch milliseconds on the watch clock.
        var tMs: Int64
        var bpm: Int
    }

    enum Command: String {
        case start
        case stop
    }

    enum Message: Equatable {
        case hr([Sample])
        case state(running: Bool, err: String?)
        case ctl(Command)
    }

    // MARK: Decoding

    /// Parses one message, or nil if the path, version, JSON or fields are not
    /// v1. Range checks on bpm and ordering are left to Dart.
    static func decode(path: String, json: String) -> Message? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any],
              let v = dict["v"] as? NSNumber, !isBool(v), v.intValue == version, v.doubleValue == Double(version)
        else { return nil }
        switch path {
        case pathHr:
            guard let raw = dict["s"] as? [Any] else { return nil }
            var samples: [Sample] = []
            samples.reserveCapacity(raw.count)
            for item in raw {
                guard let pair = item as? [Any], pair.count == 2,
                      let t = pair[0] as? NSNumber, !isBool(t),
                      let b = pair[1] as? NSNumber, !isBool(b)
                else { return nil }
                samples.append(Sample(tMs: t.int64Value, bpm: Int(b.doubleValue.rounded())))
            }
            return .hr(samples)
        case pathState:
            guard let running = dict["running"] as? NSNumber, isBool(running) else { return nil }
            let errValue = dict["err"]
            var err: String?
            if errValue == nil || errValue is NSNull {
                err = nil
            } else if let s = errValue as? String {
                err = s
            } else {
                return nil
            }
            return .state(running: running.boolValue, err: err)
        case pathCtl:
            guard let s = dict["cmd"] as? String, let cmd = Command(rawValue: s) else { return nil }
            return .ctl(cmd)
        default:
            return nil
        }
    }

    /// Decodes a WCSession message / userInfo / applicationContext dictionary.
    static func decode(dictionary: [String: Any]) -> Message? {
        guard let path = dictionary[keyPath] as? String,
              let json = dictionary[keyJson] as? String
        else { return nil }
        return decode(path: path, json: json)
    }

    // MARK: Encoding

    /// The wire path and JSON string for a message. Key order is fixed so the
    /// output matches the test vectors byte for byte.
    static func encode(_ message: Message) -> (path: String, json: String) {
        switch message {
        case .hr(let samples):
            let s = samples.map { "[\($0.tMs),\($0.bpm)]" }.joined(separator: ",")
            return (pathHr, "{\"v\":\(version),\"s\":[\(s)]}")
        case .state(let running, let err):
            let e = err.map(jsonString) ?? "null"
            return (pathState, "{\"v\":\(version),\"running\":\(running),\"err\":\(e)}")
        case .ctl(let cmd):
            return (pathCtl, "{\"v\":\(version),\"cmd\":\(jsonString(cmd.rawValue))}")
        }
    }

    /// The `["path": ..., "json": ...]` dictionary sent with WCSession.
    static func wcMessage(_ message: Message) -> [String: Any] {
        let e = encode(message)
        return [keyPath: e.path, keyJson: e.json]
    }

    /// The map the iPhone's EventChannel("feltnotes/pulse/events") emits.
    /// Also used for ctl so the vector check covers every message.
    static func channelMap(_ message: Message) -> [String: Any] {
        switch message {
        case .hr(let samples):
            return ["type": "hr", "s": samples.map { [NSNumber(value: $0.tMs), NSNumber(value: $0.bpm)] }]
        case .state(let running, let err):
            return ["type": "state", "running": running, "err": err ?? NSNull()]
        case .ctl(let cmd):
            return ["type": "ctl", "cmd": cmd.rawValue]
        }
    }

    // MARK: Helpers

    private static func isBool(_ n: NSNumber) -> Bool {
        CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    private static func jsonString(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s], options: [.fragmentsAllowed]),
              let arr = String(data: data, encoding: .utf8)
        else { return "\"\"" }
        // "[\"...\"]" -> "\"...\""
        return String(arr.dropFirst().dropLast())
    }
}
