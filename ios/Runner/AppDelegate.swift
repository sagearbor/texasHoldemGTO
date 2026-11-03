import AVFoundation
import Flutter
import UIKit

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate {
  // Native channels kept alive for the app's lifetime.
  private var record: RecordChannel?
  private var nearby: NearbyChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    // Watch my cards speaker-leak guard (lib/camera/watch_voice.dart): the
    // outputs audio would play through right now.
    if let messenger = registrar(forPlugin: "FeltAudioRoute")?.messenger() {
      let channel = FlutterMethodChannel(name: "felt_notes/audio_route", binaryMessenger: messenger)
      channel.setMethodCallHandler { call, result in
        guard call.method == "outputs" else {
          result(FlutterMethodNotImplemented)
          return
        }
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs.map { port -> String in
          switch port.portType {
          case .headphones: return "headphones"
          case .bluetoothA2DP: return "bluetooth_a2dp"
          case .bluetoothHFP: return "bluetooth_sco"
          case .bluetoothLE: return "ble_headset"
          case .builtInSpeaker: return "speaker"
          case .builtInReceiver: return "earpiece"
          default: return "other:" + port.portType.rawValue
          }
        }
        result(["route": true, "outputs": outputs])
      }
    }
    // "Show on the TV" (lib/ui/tv/show_on_tv.dart): the TV link in Safari.
    // iOS has no cast-settings page to open (AirPlay is in Control Center).
    if let messenger = registrar(forPlugin: "FeltTvCast")?.messenger() {
      let channel = FlutterMethodChannel(name: "felt_notes/tv_cast", binaryMessenger: messenger)
      channel.setMethodCallHandler { call, result in
        guard call.method == "openUrl",
          let args = call.arguments as? [String: Any],
          let s = args["url"] as? String, let url = URL(string: s)
        else {
          result(false)
          return
        }
        UIApplication.shared.open(url, options: [:]) { ok in result(ok) }
      }
    }
    // Record the table (lib/record/record_native.dart).
    if let messenger = registrar(forPlugin: "FeltRecord")?.messenger() {
      record = RecordChannel(messenger: messenger)
    }
    // Nearby games and the seating experiment (lib/nearby/).
    if let messenger = registrar(forPlugin: "FeltNearby")?.messenger() {
      nearby = NearbyChannel(messenger: messenger)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
