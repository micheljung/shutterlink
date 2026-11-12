import Flutter
import Photos
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "RawPhotoSaver") {
      RawPhotoSaver.register(messenger: registrar.messenger())
    }
  }
}

enum RawPhotoSaver {
  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "ch.micheljung.shutterlink/photos", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "saveRaw",
        let arguments = call.arguments as? [String: Any],
        let raw = arguments["raw"] as? String
      else {
        result(FlutterMethodNotImplemented)
        return
      }
      save(raw: raw, jpeg: arguments["jpeg"] as? String) { error in
        DispatchQueue.main.async { result(error) }
      }
    }
  }

  private static func save(
    raw: String, jpeg: String?, completion: @escaping (FlutterError?) -> Void
  ) {
    PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
      guard status == .authorized || status == .limited else {
        completion(FlutterError(code: "denied", message: "Photo library access denied", details: nil))
        return
      }
      PHPhotoLibrary.shared().performChanges({
        let request = PHAssetCreationRequest.forAsset()
        let rawUrl = URL(fileURLWithPath: raw)
        if let jpeg = jpeg {
          request.addResource(with: .photo, fileURL: URL(fileURLWithPath: jpeg), options: nil)
          request.addResource(with: .alternatePhoto, fileURL: rawUrl, options: nil)
        } else {
          request.addResource(with: .photo, fileURL: rawUrl, options: nil)
        }
      }) { success, error in
        completion(
          success
            ? nil
            : FlutterError(
              code: "save_failed", message: error?.localizedDescription, details: nil))
      }
    }
  }
}
