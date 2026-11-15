import Flutter
import Foundation
import ImageCaptureCore

/// USB cameras through ImageCaptureCore, as whole PTP transactions. Dart frames
/// the containers and holds every timeout; this class only moves them. The
/// channel names match the Android UsbBridge.
///
/// Methods: `start` and `stop` browse for cameras, `requestPermission` asks for
/// control authorization (app-wide on iOS), `open{deviceName}` opens a session,
/// `send{bytes}` runs one transaction and returns `{data, response}`, and
/// `close` closes the session. Events: `attached{device, enumerated}`,
/// `detached{deviceName}`, `closed{deviceName}` and `interrupt{bytes}`.
final class UsbCameraBridge: NSObject, FlutterStreamHandler, ICDeviceBrowserDelegate,
  ICDeviceDelegate
{
  private static let responseType: UInt16 = 3
  private static let headerSize = 12

  private let browser = ICDeviceBrowser()
  private var browsing = false
  /// While true, added cameras were already plugged in when browsing started.
  private var enumerating = false
  private var browseGeneration = 0
  private var sink: FlutterEventSink?
  private var authorized = false
  /// Cameras the browser reported, by the id Dart knows them by.
  private var cameras: [String: ICCameraDevice] = [:]
  private var fallbackIds: [ObjectIdentifier: String] = [:]
  private var openCamera: ICCameraDevice?
  private var pendingOpen: FlutterResult?
  /// Cameras whose session Dart closed, until ImageCaptureCore confirms it, so
  /// that a late confirmation does not end a reopened session.
  private var closing = Set<ObjectIdentifier>()

  /// The caller keeps the returned bridge: ImageCaptureCore holds its
  /// delegates weakly.
  static func register(messenger: FlutterBinaryMessenger) -> UsbCameraBridge {
    let bridge = UsbCameraBridge()
    let methods = FlutterMethodChannel(
      name: "ch.micheljung.shutterlink/usb", binaryMessenger: messenger)
    methods.setMethodCallHandler { [weak bridge] call, result in
      guard let bridge = bridge else {
        result(FlutterMethodNotImplemented)
        return
      }
      bridge.handle(call, result: result)
    }
    let events = FlutterEventChannel(
      name: "ch.micheljung.shutterlink/usb/events", binaryMessenger: messenger)
    events.setStreamHandler(bridge)
    return bridge
  }

  override init() {
    super.init()
    browser.delegate = self
  }

  // MARK: Method channel

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let arguments = call.arguments as? [String: Any]
    switch call.method {
    case "start":
      if !browsing {
        browsing = true
        enumerating = true
        browseGeneration += 1
        let generation = browseGeneration
        // Bounds the enumeration in case the browser never says it is done.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
          if self.browseGeneration == generation { self.enumerating = false }
        }
        browser.start()
      }
      result(nil)
    case "stop":
      if browsing {
        browsing = false
        enumerating = false
        browser.stop()
      }
      // Unplugs go unreported while not browsing; the next start reports
      // every camera again.
      cameras = cameras.filter { $0.value === openCamera }
      result(nil)
    case "requestPermission":
      browser.requestControlAuthorization { status in
        UsbCameraBridge.onMain {
          self.authorized = status == .authorized
          result(self.authorized)
        }
      }
    case "open":
      guard let deviceName = arguments?["deviceName"] as? String,
        let camera = cameras[deviceName]
      else {
        result(FlutterError(code: "no_device", message: "Camera not attached", details: nil))
        return
      }
      closeSession()
      openCamera = camera
      pendingOpen = result
      camera.delegate = self
      camera.requestOpenSession()
    case "send":
      guard let camera = openCamera, pendingOpen == nil else {
        result(FlutterError(code: "not_open", message: "No camera session", details: nil))
        return
      }
      guard let command = (arguments?["bytes"] as? FlutterStandardTypedData)?.data else {
        result(FlutterError(code: "bad_arguments", message: "Missing bytes", details: nil))
        return
      }
      // No data-out phase is in scope, so outData is nil.
      camera.requestSendPTPCommand(command, outData: nil) { data, response, error in
        let reply = UsbCameraBridge.reply(
          command: command, data: (data as Data?) ?? Data(),
          response: (response as Data?) ?? Data(), error: error as Error?)
        UsbCameraBridge.onMain { result(reply) }
      }
    case "close":
      closeSession()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func closeSession() {
    guard let camera = openCamera else { return }
    openCamera = nil
    failPendingOpen("Session closed")
    closing.insert(ObjectIdentifier(camera))
    camera.requestCloseSession()
  }

  private func failPendingOpen(_ message: String) {
    guard let result = pendingOpen else { return }
    pendingOpen = nil
    result(FlutterError(code: "open_failed", message: message, details: nil))
  }

  // MARK: Event channel

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    sink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  private func emit(_ event: [String: Any]) {
    sink?(event)
  }

  // MARK: ICDeviceBrowserDelegate

  func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
    UsbCameraBridge.onMain {
      guard let camera = device as? ICCameraDevice else { return }
      let id = self.identifier(of: camera)
      self.cameras[id] = camera
      self.emit([
        "type": "attached",
        "device": [
          "deviceName": id,
          "vendorId": UsbCameraBridge.usbId(camera, "usbVendorID"),
          "productId": UsbCameraBridge.usbId(camera, "usbProductID"),
          "product": camera.name ?? "USB camera",
          "hasPermission": self.authorized,
        ] as [String: Any],
        "enumerated": self.enumerating,
      ])
    }
  }

  /// Optional in ICDeviceBrowserDelegate: the cameras already plugged in are
  /// all reported.
  func deviceBrowserDidEnumerateLocalDevices(_ browser: ICDeviceBrowser) {
    UsbCameraBridge.onMain { self.enumerating = false }
  }

  func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
    UsbCameraBridge.onMain { self.removed(device) }
  }

  // MARK: ICDeviceDelegate

  func didRemove(_ device: ICDevice) {
    UsbCameraBridge.onMain { self.removed(device) }
  }

  func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
    UsbCameraBridge.onMain {
      guard device === self.openCamera, let result = self.pendingOpen else { return }
      self.pendingOpen = nil
      if let error = error {
        self.openCamera = nil
        result(
          FlutterError(code: "open_failed", message: error.localizedDescription, details: nil))
      } else {
        result(nil)
      }
    }
  }

  func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
    UsbCameraBridge.onMain {
      if self.closing.remove(ObjectIdentifier(device)) != nil { return }
      guard let camera = self.openCamera, device === camera else { return }
      self.openCamera = nil
      self.failPendingOpen(error?.localizedDescription ?? "Session closed")
      self.emit(["type": "closed", "deviceName": self.identifier(of: camera)])
    }
  }

  /// ICCameraDeviceDelegate's PTP event callback. The class does not adopt
  /// that protocol, to stay clear of its many required methods; the explicit
  /// selector lets ImageCaptureCore find this method anyway.
  @objc(cameraDevice:didReceivePTPEvent:)
  func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {
    UsbCameraBridge.onMain {
      guard camera === self.openCamera else { return }
      self.emit(["type": "interrupt", "bytes": FlutterStandardTypedData(bytes: eventData)])
    }
  }

  // MARK: Helpers

  private func removed(_ device: ICDevice) {
    guard let id = cameras.first(where: { $0.value === device })?.key else { return }
    cameras.removeValue(forKey: id)
    closing.remove(ObjectIdentifier(device))
    if device === openCamera {
      openCamera = nil
      failPendingOpen("Camera detached")
    }
    emit(["type": "detached", "deviceName": id])
  }

  private func identifier(of camera: ICCameraDevice) -> String {
    if let uuid = camera.uuidString, !uuid.isEmpty { return uuid }
    let key = ObjectIdentifier(camera)
    if let id = fallbackIds[key] { return id }
    let id = UUID().uuidString
    fallbackIds[key] = id
    return id
  }

  /// A USB id read by key, so that the build does not depend on the property
  /// being exposed to Swift on iOS. 0 when it is missing, which no profile
  /// claims.
  private static func usbId(_ device: ICDevice, _ key: String) -> Int {
    guard device.responds(to: NSSelectorFromString(key)) else { return 0 }
    return (device.value(forKey: key) as? NSNumber)?.intValue ?? 0
  }

  private static func onMain(_ block: @escaping () -> Void) {
    if Thread.isMainThread {
      block()
    } else {
      DispatchQueue.main.async(execute: block)
    }
  }

  /// The completion's buffers for Dart, which finds the response container in
  /// either of them. A response without its container header is wrapped into
  /// one; when neither buffer can be read as a response, an ImageCaptureCore
  /// error fails the call, and otherwise Dart rejects the buffers.
  static func reply(command: Data, data: Data, response: Data, error: Error?) -> Any {
    var responseOut = response
    if !isContainer(response, type: responseType) && !isContainer(data, type: responseType) {
      if let wrapped = wrapBareResponse(response, command: command) {
        responseOut = wrapped
      } else if let error = error {
        return FlutterError(
          code: "send_failed", message: error.localizedDescription, details: nil)
      }
    }
    return [
      "data": FlutterStandardTypedData(bytes: data),
      "response": FlutterStandardTypedData(bytes: responseOut),
    ]
  }

  /// Whether [bytes] is exactly one container of [type].
  private static func isContainer(_ bytes: Data, type: UInt16) -> Bool {
    let b = [UInt8](bytes)
    guard b.count >= headerSize else { return false }
    var length = 0
    for i in (0..<4).reversed() {
      length = length << 8 | Int(b[i])
    }
    let kind = UInt16(b[4]) | UInt16(b[5]) << 8
    return length == b.count && kind == type
  }

  /// A bare response, assumed to be `[u16 code][u32 params...]` with at most 5
  /// params, as a response container with the command's transaction ID.
  private static func wrapBareResponse(_ bare: Data, command: Data) -> Data? {
    let b = [UInt8](bare)
    let c = [UInt8](command)
    guard b.count >= 2, (b.count - 2) % 4 == 0, (b.count - 2) / 4 <= 5, c.count >= headerSize
    else { return nil }
    let length = UInt32(headerSize + b.count - 2)
    var out: [UInt8] = [
      UInt8(truncatingIfNeeded: length),
      UInt8(truncatingIfNeeded: length >> 8),
      UInt8(truncatingIfNeeded: length >> 16),
      UInt8(truncatingIfNeeded: length >> 24),
      UInt8(truncatingIfNeeded: responseType),
      UInt8(truncatingIfNeeded: responseType >> 8),
      b[0], b[1],
    ]
    out.append(contentsOf: c[8..<12])
    out.append(contentsOf: b[2...])
    return Data(out)
  }
}
