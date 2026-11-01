import AVFoundation
import CoreImage
import CoreLocation
import Flutter
import UIKit

/// Record the table (lib/record/record_native.dart), channel
/// `felt_notes/record`: the back ultra-wide lens's id, JPEG encoding of
/// camera stream frames off the main thread, thermal state, free storage,
/// device model and one coarse location fix.
final class RecordChannel: NSObject, CLLocationManagerDelegate {
  private let channel: FlutterMethodChannel
  private let encodeQueue = DispatchQueue(label: "felt_notes.record.jpeg", qos: .userInitiated)
  private lazy var ciContext = CIContext(options: [.useSoftwareRenderer: false])
  private var locationManager: CLLocationManager?
  private var locationWaiters: [FlutterResult] = []
  private var askingAuthorization = false

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "felt_notes/record", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result)
    }
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "ultraWideCamera":
      result(AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)?.uniqueID)
    case "encodeJpeg":
      encodeJpeg(args, result)
    case "thermal":
      switch ProcessInfo.processInfo.thermalState {
      case .nominal: result("nominal")
      case .fair: result("fair")
      case .serious: result("serious")
      case .critical: result("critical")
      @unknown default: result("unknown")
      }
    case "storage":
      let url = URL(fileURLWithPath: args["path"] as? String ?? NSHomeDirectory())
      let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
      result([
        "free": v?.volumeAvailableCapacityForImportantUsage ?? 0,
        "total": v?.volumeTotalCapacity ?? 0,
      ])
    case "device":
      var sys = utsname()
      uname(&sys)
      let machine = withUnsafePointer(to: &sys.machine) {
        $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
      }
      result([
        "manufacturer": "Apple",
        "model": machine,
        "device": UIDevice.current.model,
        "os": "iOS \(UIDevice.current.systemVersion)",
      ])
    case "location":
      location(ask: args["ask"] as? Bool ?? false, result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // ---------------------------------------------------------------- JPEG

  private func encodeJpeg(_ args: [String: Any], _ result: @escaping FlutterResult) {
    guard let path = args["path"] as? String,
          let w = args["width"] as? Int, let h = args["height"] as? Int,
          let planes = args["planes"] as? [FlutterStandardTypedData],
          let rows = args["rowStrides"] as? [Int]
    else {
      result(FlutterError(code: "encode", message: "bad arguments", details: nil))
      return
    }
    let format = args["format"] as? String ?? "yuv420"
    let quality = Double(args["quality"] as? Int ?? 85) / 100.0
    encodeQueue.async { [weak self] in
      guard let self = self else { return }
      let t0 = CACurrentMediaTime()
      do {
        let image = try self.ciImage(w: w, h: h, format: format, planes: planes, rows: rows)
        let opts: [CIImageRepresentationOption: Any] = [
          CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality,
        ]
        guard let data = self.ciContext.jpegRepresentation(
          of: image, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: opts)
        else { throw NSError(domain: "encode", code: 1) }
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Atomic: only whole files get the final name.
        try data.write(to: url, options: .atomic)
        let ms = Int((CACurrentMediaTime() - t0) * 1000)
        DispatchQueue.main.async { result(["bytes": data.count, "ms": ms]) }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "encode", message: "\(error)", details: nil))
        }
      }
    }
  }

  /// The camera plugin's stream frame (420v: Y + interleaved CbCr, or
  /// BGRA) back in a pixel buffer, for Core Image.
  private func ciImage(w: Int, h: Int, format: String, planes: [FlutterStandardTypedData], rows: [Int]) throws -> CIImage {
    let bgra = format == "bgra"
    let type = bgra ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    var pb: CVPixelBuffer?
    let attrs = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary
    guard CVPixelBufferCreate(nil, w, h, type, attrs, &pb) == kCVReturnSuccess, let buf = pb else {
      throw NSError(domain: "encode", code: 2)
    }
    CVPixelBufferLockBaseAddress(buf, [])
    defer { CVPixelBufferUnlockBaseAddress(buf, []) }
    let count = bgra ? 1 : 2
    guard planes.count >= count, rows.count >= count else { throw NSError(domain: "encode", code: 3) }
    for p in 0..<count {
      let dst = bgra ? CVPixelBufferGetBaseAddress(buf) : CVPixelBufferGetBaseAddressOfPlane(buf, p)
      let dstRow = bgra ? CVPixelBufferGetBytesPerRow(buf) : CVPixelBufferGetBytesPerRowOfPlane(buf, p)
      let lines = bgra ? h : CVPixelBufferGetHeightOfPlane(buf, p)
      guard let d = dst else { throw NSError(domain: "encode", code: 4) }
      let src = planes[p].data
      let srcRow = rows[p]
      let n = min(srcRow, dstRow)
      src.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        guard let s = raw.baseAddress else { return }
        for y in 0..<lines where (y * srcRow + n) <= src.count {
          memcpy(d.advanced(by: y * dstRow), s.advanced(by: y * srcRow), n)
        }
      }
    }
    return CIImage(cvPixelBuffer: buf)
  }

  // ------------------------------------------------------------ location

  private func location(ask: Bool, _ result: @escaping FlutterResult) {
    let m = locationManager ?? CLLocationManager()
    if locationManager == nil {
      m.delegate = self
      m.desiredAccuracy = kCLLocationAccuracyKilometer
      locationManager = m
    }
    switch m.authorizationStatus {
    case .notDetermined:
      if !ask { return result(nil) }
      locationWaiters.append(result)
      askingAuthorization = true
      m.requestWhenInUseAuthorization()
    case .authorizedWhenInUse, .authorizedAlways:
      if let l = m.location { return result(Self.map(l)) }
      locationWaiters.append(result)
      m.requestLocation()
      // A basement may have no fix at all: answer null after 5 s.
      DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.finish(nil) }
    default:
      result(nil)
    }
  }

  private func finish(_ l: CLLocation?) {
    let waiters = locationWaiters
    locationWaiters.removeAll()
    for w in waiters { w(l.map(Self.map)) }
  }

  private static func map(_ l: CLLocation) -> [String: Any] {
    [
      "lat": l.coordinate.latitude,
      "lon": l.coordinate.longitude,
      "acc_m": l.horizontalAccuracy,
      "age_s": Int(-l.timestamp.timeIntervalSinceNow),
    ]
  }

  func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
    guard askingAuthorization else { return }
    switch m.authorizationStatus {
    case .notDetermined:
      return
    case .authorizedWhenInUse, .authorizedAlways:
      askingAuthorization = false
      if let l = m.location { return finish(l) }
      m.requestLocation()
      DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.finish(nil) }
    default:
      askingAuthorization = false
      finish(nil)
    }
  }

  func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    finish(locations.last)
  }

  func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
    finish(nil)
  }
}
