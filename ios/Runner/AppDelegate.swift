import AVFoundation
import Flutter
import UIKit

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate {
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
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
