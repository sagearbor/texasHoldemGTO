import CoreBluetooth
import Flutter
import Foundation
import NearbyInteraction
import UIKit

/// Nearby games and the seating experiment (lib/nearby/nearby_ble.dart),
/// channel `felt_notes/ble` + event channel `felt_notes/ble_events`.
///
/// * Advertise one Felt Notes service UUID (the payload is in the UUID,
///   ble_payload.dart) and the host's name as the local name. Foreground
///   only: without a Bluetooth background mode iOS stops advertising when
///   the app is suspended (and in the background the UUID would sit in the
///   overflow area, invisible to Android). Accepted, and logged in Dart.
/// * Scan for a few seconds, keeping only Felt Notes adverts.
/// * UWB between iPhones (Nearby Interaction): each phone publishes a GATT
///   service; the phone whose key sorts first connects, writes its install
///   id + discovery token (in chunks), reads the other's back, and both
///   run an NISession. Distances (and direction where the chip gives one)
///   go to Dart as events. Log only.
final class NearbyChannel: NSObject, FlutterStreamHandler, CBCentralManagerDelegate, CBPeripheralManagerDelegate,
  CBPeripheralDelegate, NISessionDelegate
{
  private static let gattService = CBUUID(string: "464E5431-0000-4000-8000-0000000000A0")
  private static let tokenChar = CBUUID(string: "464E5431-0000-4000-8000-0000000000A1")

  private let channel: FlutterMethodChannel
  private let events: FlutterEventChannel
  private var sink: FlutterEventSink?

  private var central: CBCentralManager?
  private var peripheral: CBPeripheralManager?
  private var authWaiters: [FlutterResult] = []

  // Advertising
  private var wantAdvert: (uuid: String, name: String?)?

  // Scanning
  private var scanResults: [[String: Any]] = []
  private var scanReply: FlutterResult?
  private var scanPrefix = ""
  private var scanWanted = false
  private var streaming = false
  private var streamPrefix = ""
  private var scanMs = 4000
  /// Advert UUID (lowercase) -> the peripheral that sent it, for UWB.
  private var seen: [String: CBPeripheral] = [:]

  // UWB
  private var myDeviceId: String?
  private var serviceAdded = false
  private var tokenCharacteristic: CBMutableCharacteristic?
  /// Peer install id -> its session and configuration.
  private var sessions: [String: (NISession, NINearbyPeerConfiguration)] = [:]
  /// Peripheral side: per connecting central, the chunks written so far and
  /// the answer to serve on read.
  private var inbox: [UUID: [Int: Data]] = [:]
  private var answers: [UUID: Data] = [:]
  /// Central side: exchanges in progress, by peripheral.
  private var outgoing: [UUID: Outgoing] = [:]

  private final class Outgoing {
    let uuid: String
    let session: NISession
    var chunks: [Data] = []
    var next = 0
    var characteristic: CBCharacteristic?
    init(uuid: String, session: NISession) {
      self.uuid = uuid
      self.session = session
    }
  }

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "felt_notes/ble", binaryMessenger: messenger)
    events = FlutterEventChannel(name: "felt_notes/ble_events", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in self?.handle(call, result) }
    events.setStreamHandler(self)
  }

  func onListen(withArguments arguments: Any?, eventSink: @escaping FlutterEventSink) -> FlutterError? {
    sink = eventSink
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  private func emit(_ e: [String: Any]) {
    DispatchQueue.main.async { [weak self] in self?.sink?(e) }
  }

  private static var authorization: String {
    switch CBManager.authorization {
    case .allowedAlways: return "allowed"
    case .notDetermined: return "notDetermined"
    case .denied: return "denied"
    case .restricted: return "restricted"
    @unknown default: return "unknown"
    }
  }

  /// Creating the managers shows the Bluetooth prompt the first time, so
  /// they are made only once Dart decided to use Bluetooth.
  private func managers() {
    if central == nil { central = CBCentralManager(delegate: self, queue: nil) }
    if peripheral == nil { peripheral = CBPeripheralManager(delegate: self, queue: nil) }
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "authorization":
      result(Self.authorization)
    case "requestAuthorization":
      if CBManager.authorization != .notDetermined {
        if CBManager.authorization == .allowedAlways { managers() }
        return result(Self.authorization)
      }
      authWaiters.append(result)
      managers()
    case "poweredOn":
      guard CBManager.authorization == .allowedAlways else { return result(false) }
      managers()
      result(central?.state == .poweredOn || central?.state == .unknown || central?.state == .resetting)
    case "advertise":
      guard let uuid = args["uuid"] as? String else { return result(false) }
      wantAdvert = (uuid, args["name"] as? String)
      managers()
      startAdvertisingIfReady()
      result(true)
    case "stopAdvertising":
      wantAdvert = nil
      peripheral?.stopAdvertising()
      result(nil)
    case "scan":
      scan(ms: args["ms"] as? Int ?? 4000, prefix: args["prefix"] as? String ?? "", result)
    case "scanStart":
      // Bluetooth distance test: every advert as an event until stopped.
      guard CBManager.authorization == .allowedAlways else { return result(false) }
      managers()
      streamPrefix = args["prefix"] as? String ?? ""
      streaming = true
      if central?.state == .poweredOn { beginScan() }
      result(true)
    case "scanStop":
      streaming = false
      if scanReply == nil { central?.stopScan() }
      result(nil)
    case "screenOn":
      result(UIApplication.shared.applicationState == .active ? true : nil)
    case "uwbSupported":
      result(Self.uwbSupported)
    case "uwbStart":
      myDeviceId = args["deviceId"] as? String
      managers()
      addServiceIfReady()
      result(nil)
    case "uwbStop":
      stopUwb()
      result(nil)
    case "uwbRange":
      if let uuid = args["uuid"] as? String { range(uuid.lowercased()) }
      result(nil)
    case "uwbPeers":
      result(Array(sessions.keys))
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static var uwbSupported: Bool {
    if #available(iOS 16.0, *) {
      return NISession.deviceCapabilities.supportsPreciseDistanceMeasurement
    }
    return NISession.isSupported
  }

  // ------------------------------------------------------------- states

  func centralManagerDidUpdateState(_ c: CBCentralManager) {
    if c.state != .unknown && c.state != .resetting {
      let waiters = authWaiters
      authWaiters.removeAll()
      for w in waiters { w(Self.authorization) }
    }
    emit(["type": "bt", "on": c.state == .poweredOn])
    if c.state == .poweredOn && (scanWanted || streaming) { beginScan() }
  }

  func peripheralManagerDidUpdateState(_ p: CBPeripheralManager) {
    if p.state == .poweredOn {
      startAdvertisingIfReady()
      addServiceIfReady()
    } else {
      serviceAdded = false
    }
  }

  // --------------------------------------------------------- advertise

  private func startAdvertisingIfReady() {
    guard let p = peripheral, p.state == .poweredOn, let want = wantAdvert else { return }
    p.stopAdvertising()
    var data: [String: Any] = [CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: want.uuid)]]
    if let n = want.name, !n.isEmpty { data[CBAdvertisementDataLocalNameKey] = n }
    p.startAdvertising(data)
  }

  // -------------------------------------------------------------- scan

  private func scan(ms: Int, prefix: String, _ result: @escaping FlutterResult) {
    guard CBManager.authorization == .allowedAlways else { return result([]) }
    if scanReply != nil { return result([]) }
    managers()
    scanResults.removeAll()
    scanReply = result
    scanPrefix = prefix
    scanMs = ms
    scanWanted = true
    if central?.state == .poweredOn { beginScan() }
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms)) { [weak self] in self?.endScan() }
  }

  private func beginScan() {
    // No service filter: each phone's UUID is different (the payload is in
    // it), and a filter cannot match a prefix. Foreground only.
    central?.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
  }

  private func endScan() {
    scanWanted = false
    if !streaming { central?.stopScan() }
    let r = scanReply
    scanReply = nil
    r?(scanResults)
    scanResults.removeAll()
  }

  func centralManager(
    _ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData ad: [String: Any], rssi: NSNumber
  ) {
    guard scanReply != nil || streaming, rssi.intValue != 127 else { return }
    let prefix = scanReply != nil ? scanPrefix : streamPrefix
    var uuids = (ad[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
    uuids += (ad[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID]) ?? []
    let ours = uuids.map { $0.uuidString.lowercased() }
      .filter { $0.replacingOccurrences(of: "-", with: "").hasPrefix(prefix) }
    if ours.isEmpty { return } // nobody else's devices are logged
    for u in ours { seen[u] = p }
    var e: [String: Any] = [
      "u": ours,
      "r": rssi.intValue,
      "t": Int64(Date().timeIntervalSince1970 * 1000),
    ]
    if let tx = ad[CBAdvertisementDataTxPowerLevelKey] as? NSNumber { e["tx"] = tx.intValue }
    if let n = ad[CBAdvertisementDataLocalNameKey] as? String { e["n"] = n }
    if let m = ad[CBAdvertisementDataManufacturerDataKey] as? Data, m.count >= 2, m[0] == 0xFF, m[1] == 0xFF {
      e["m"] = m.dropFirst(2).map { Int($0) }
    }
    if scanReply != nil { scanResults.append(e) }
    if streaming {
      e["type"] = "adv"
      emit(e)
    }
  }

  // ------------------------------------------------------- UWB: GATT

  private func addServiceIfReady() {
    guard Self.uwbSupported, myDeviceId != nil, !serviceAdded, let p = peripheral, p.state == .poweredOn else { return }
    let ch = CBMutableCharacteristic(
      type: Self.tokenChar, properties: [.read, .write], value: nil, permissions: [.readable, .writeable])
    let svc = CBMutableService(type: Self.gattService, primary: true)
    svc.characteristics = [ch]
    tokenCharacteristic = ch
    p.add(svc)
    serviceAdded = true
  }

  private func stopUwb() {
    myDeviceId = nil
    if serviceAdded { peripheral?.removeAllServices() }
    serviceAdded = false
    for (_, s) in sessions { s.0.invalidate() }
    sessions.removeAll()
    for (_, o) in outgoing { o.session.invalidate() }
    outgoing.removeAll()
    inbox.removeAll()
    answers.removeAll()
  }

  /// Payload both ways: 12 bytes install id (ASCII) + archived token.
  private func payload(_ s: NISession) -> Data? {
    guard let id = myDeviceId, let tok = s.discoveryToken,
          let arch = try? NSKeyedArchiver.archivedData(withRootObject: tok, requiringSecureCoding: true)
    else { return nil }
    var d = Data(id.utf8.prefix(12))
    d.append(arch)
    return d
  }

  private func parse(_ d: Data) -> (String, NIDiscoveryToken)? {
    guard d.count > 12, let id = String(data: d.prefix(12), encoding: .utf8),
          let tok = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NIDiscoveryToken.self, from: d.dropFirst(12))
    else { return nil }
    return (id, tok)
  }

  private func run(_ s: NISession, peer: String, token: NIDiscoveryToken) {
    sessions[peer]?.0.invalidate()
    let cfg = NINearbyPeerConfiguration(peerToken: token)
    s.delegate = self
    sessions[peer] = (s, cfg)
    s.run(cfg)
  }

  // Peripheral side: the other phone writes its id + token in chunks of
  // [index, count, bytes...], then reads ours.
  func peripheralManager(_ p: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
    guard let first = requests.first else { return }
    for r in requests {
      guard let v = r.value, v.count >= 2 else { continue }
      let central = r.central.identifier
      var box = inbox[central] ?? [:]
      box[Int(v[0])] = v.dropFirst(2)
      inbox[central] = box
      let count = Int(v[1])
      if box.count == count {
        var all = Data()
        for i in 0..<count { all.append(box[i] ?? Data()) }
        inbox[central] = nil
        if let (peer, token) = parse(all) {
          let s = NISession()
          if let mine = payload(s) {
            answers[central] = mine
            run(s, peer: peer, token: token)
            emit(["type": "uwbState", "peer": peer, "state": "ranging", "side": "peripheral"])
          }
        }
      }
    }
    p.respond(to: first, withResult: .success)
  }

  func peripheralManager(_ p: CBPeripheralManager, didReceiveRead r: CBATTRequest) {
    guard let d = answers[r.central.identifier] else { return p.respond(to: r, withResult: .readNotPermitted) }
    if r.offset > d.count { return p.respond(to: r, withResult: .invalidOffset) }
    r.value = d.subdata(in: r.offset..<d.count)
    p.respond(to: r, withResult: .success)
  }

  // Central side.
  private func range(_ uuid: String) {
    guard Self.uwbSupported, myDeviceId != nil, let c = central, c.state == .poweredOn else {
      return emit(["type": "uwbState", "uuid": uuid, "state": "failed", "why": "not ready"])
    }
    guard let p = seen[uuid] else {
      return emit(["type": "uwbState", "uuid": uuid, "state": "failed", "why": "not seen"])
    }
    if outgoing[p.identifier] != nil { return }
    let o = Outgoing(uuid: uuid, session: NISession())
    outgoing[p.identifier] = o
    p.delegate = self
    c.connect(p)
    // Give up after 15 s (out of range, busy).
    DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self, weak p] in
      guard let self = self, let p = p, let o = self.outgoing[p.identifier] else { return }
      self.fail(p, o, "timeout")
    }
  }

  private func fail(_ p: CBPeripheral, _ o: Outgoing, _ why: String) {
    outgoing[p.identifier] = nil
    central?.cancelPeripheralConnection(p)
    emit(["type": "uwbState", "uuid": o.uuid, "state": "failed", "why": why])
  }

  func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
    p.discoverServices([Self.gattService])
  }

  func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
    if let o = outgoing[p.identifier] { fail(p, o, "connect: \(error?.localizedDescription ?? "?")") }
  }

  func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
    guard let o = outgoing[p.identifier] else { return }
    guard let s = p.services?.first(where: { $0.uuid == Self.gattService }) else { return fail(p, o, "no service") }
    p.discoverCharacteristics([Self.tokenChar], for: s)
  }

  func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
    guard let o = outgoing[p.identifier] else { return }
    guard let ch = s.characteristics?.first(where: { $0.uuid == Self.tokenChar }), let data = payload(o.session) else {
      return fail(p, o, "no token")
    }
    o.characteristic = ch
    let size = max(20, p.maximumWriteValueLength(for: .withResponse) - 2)
    var chunks: [Data] = []
    var i = 0
    while i < data.count {
      chunks.append(data.subdata(in: i..<min(i + size, data.count)))
      i += size
    }
    o.chunks = chunks.enumerated().map { k, c in
      var d = Data([UInt8(k), UInt8(chunks.count)])
      d.append(c)
      return d
    }
    o.next = 0
    writeNext(p, o)
  }

  private func writeNext(_ p: CBPeripheral, _ o: Outgoing) {
    guard let ch = o.characteristic else { return }
    if o.next < o.chunks.count {
      p.writeValue(o.chunks[o.next], for: ch, type: .withResponse)
      o.next += 1
    } else {
      p.readValue(for: ch)
    }
  }

  func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: Error?) {
    guard let o = outgoing[p.identifier] else { return }
    if let e = error { return fail(p, o, "write: \(e.localizedDescription)") }
    writeNext(p, o)
  }

  func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
    guard let o = outgoing[p.identifier] else { return }
    guard error == nil, let v = ch.value, let (peer, token) = parse(v) else { return fail(p, o, "read") }
    outgoing[p.identifier] = nil
    central?.cancelPeripheralConnection(p)
    run(o.session, peer: peer, token: token)
    emit(["type": "uwbState", "uuid": o.uuid, "peer": peer, "state": "ranging", "side": "central"])
  }

  // ------------------------------------------------------ UWB: session

  private func peer(of s: NISession) -> String? {
    sessions.first(where: { $0.value.0 === s })?.key
  }

  func session(_ s: NISession, didUpdate objects: [NINearbyObject]) {
    guard let peer = peer(of: s) else { return }
    for o in objects {
      guard let d = o.distance else { continue }
      var e: [String: Any] = [
        "type": "uwb", "peer": peer, "m": Double(d), "t": Int64(Date().timeIntervalSince1970 * 1000),
      ]
      if let v = o.direction { e["dir"] = [Double(v.x), Double(v.y), Double(v.z)] }
      emit(e)
    }
  }

  func session(_ s: NISession, didRemove objects: [NINearbyObject], reason: NINearbyObject.RemovalReason) {
    guard let peer = peer(of: s) else { return }
    emit(["type": "uwbState", "peer": peer, "state": reason == .peerEnded ? "ended" : "lost"])
    if reason == .peerEnded {
      s.invalidate()
      sessions[peer] = nil
    }
  }

  func sessionWasSuspended(_ s: NISession) {
    if let peer = peer(of: s) { emit(["type": "uwbState", "peer": peer, "state": "suspended"]) }
  }

  func sessionSuspensionEnded(_ s: NISession) {
    guard let peer = peer(of: s), let cfg = sessions[peer]?.1 else { return }
    s.run(cfg)
    emit(["type": "uwbState", "peer": peer, "state": "resumed"])
  }

  func session(_ s: NISession, didInvalidateWith error: Error) {
    guard let peer = peer(of: s) else { return }
    sessions[peer] = nil
    emit(["type": "uwbState", "peer": peer, "state": "ended", "why": error.localizedDescription])
  }
}
