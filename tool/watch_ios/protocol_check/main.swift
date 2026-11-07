// Checks ios/PulseShared/PulseProtocol.swift against
// test/pulse/protocol_vectors.json. Run: tool/watch_ios/check_protocol.sh
import Foundation

let args = CommandLine.arguments
guard args.count == 2, let data = FileManager.default.contents(atPath: args[1]),
      let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let valid = root["valid"] as? [[String: Any]],
      let invalid = root["invalid"] as? [[String: Any]]
else {
    FileHandle.standardError.write("usage: protocol_check <protocol_vectors.json>\n".data(using: .utf8)!)
    exit(2)
}

var failures = 0
var checks = 0

func fail(_ msg: String) {
    failures += 1
    print("FAIL: \(msg)")
}

/// Canonical JSON text, so maps compare regardless of key order and number type.
func canonical(_ obj: Any) -> String {
    let data = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .fragmentsAllowed])
    return String(data: data, encoding: .utf8)!
}

for (i, vec) in valid.enumerated() {
    let path = vec["path"] as! String
    let json = vec["json"] as! String
    let expect = vec["expect"]!
    checks += 1
    guard let msg = PulseProtocol.decode(path: path, json: json) else {
        fail("valid[\(i)] did not decode: \(path) \(json)")
        continue
    }
    let got = canonical(PulseProtocol.channelMap(msg))
    let want = canonical(expect)
    if got != want { fail("valid[\(i)] map \(got) != \(want)") }

    // Encoding gives back the vector's exact bytes, and the dictionary form round-trips.
    let enc = PulseProtocol.encode(msg)
    if enc.path != path || enc.json != json { fail("valid[\(i)] encode \(enc.path) \(enc.json) != \(json)") }
    if PulseProtocol.decode(dictionary: PulseProtocol.wcMessage(msg)) != msg { fail("valid[\(i)] wc round trip") }
}

for (i, vec) in invalid.enumerated() {
    checks += 1
    let path = vec["path"] as! String
    let json = vec["json"] as! String
    if let msg = PulseProtocol.decode(path: path, json: json) {
        fail("invalid[\(i)] (\(vec["why"] ?? "")) decoded as \(msg)")
    }
}

// An error string with characters that need escaping survives a round trip.
checks += 1
let tricky = PulseProtocol.Message.state(running: false, err: "a \"quote\" / back\\slash")
let e = PulseProtocol.encode(tricky)
if PulseProtocol.decode(path: e.path, json: e.json) != tricky { fail("escaped err round trip: \(e.json)") }

if failures > 0 {
    print("\(failures) of \(checks) protocol checks failed")
    exit(1)
}
print("OK: \(checks) protocol checks passed (\(valid.count) valid, \(invalid.count) invalid, 1 extra)")
