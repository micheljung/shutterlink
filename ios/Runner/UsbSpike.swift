import Foundation
import ImageCaptureCore

// Feasibility spike for USB cameras on iOS (plan Phase 3 step 4). It only has
// to compile in CI: nothing registers or calls it, and Phase 6 replaces it
// with UsbCameraBridge.swift. The findings are in .omc/plans/open-questions.md.
enum UsbSpike {
  /// Asks for control of attached cameras; the result decides whether PTP
  /// pass-through is allowed at all.
  static func requestAuthorization(
    browser: ICDeviceBrowser, completion: @escaping (Bool) -> Void
  ) {
    browser.requestControlAuthorization { status in
      completion(status == .authorized)
    }
  }

  /// ImageCaptureCore owns the PTP session; the transport answers
  /// OpenSession and CloseSession locally.
  static func open(_ camera: ICCameraDevice) {
    camera.requestOpenSession()
  }

  static func close(_ camera: ICCameraDevice) {
    camera.requestCloseSession()
  }

  /// One whole transaction. `command` is a 12-byte-header USB command
  /// container. There is no data-out phase, so `outData` is nil. The first
  /// completion buffer is taken as the data-in phase and the second as the
  /// response container, but the Dart side finds the response by its
  /// container type, so a swapped order still decodes. The completion takes
  /// `Any?` so that only the argument count has to match the SDK.
  static func send(
    _ camera: ICCameraDevice, command: Data,
    completion: @escaping (Any?, Any?, Any?) -> Void
  ) {
    camera.requestSendPTPCommand(command, outData: nil) { data, response, error in
      completion(data, response, error)
    }
  }
}
