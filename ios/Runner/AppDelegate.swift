import Flutter
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
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "FilesChannel") {
      FilesChannel.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "VersionChannel") {
      VersionChannel.register(with: registrar)
    }
  }
}

/// Answers the updater's "info" (lib/update/updater.dart) with this app's
/// version, so Settings shows it. iOS apps can't update themselves: the
/// rest of the updater stays off here.
final class VersionChannel: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "photo_organizer/update", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(VersionChannel(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "info" else { return result(FlutterMethodNotImplemented) }
    result(["version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""])
  }
}

/// iOS side of NativeFiles (lib/share/native_files.dart): opens a received
/// file in Quick Look (or offers the apps that can open it) and web links
/// in the browser. Saving is done in Dart, into the app's Documents folder,
/// which the Files app shows under On My iPhone › ShareBro.
final class FilesChannel: NSObject, FlutterPlugin, UIDocumentInteractionControllerDelegate {
  /// The open preview; UIKit doesn't keep it alive by itself.
  private var document: UIDocumentInteractionController?

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "photo_organizer/files", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(FilesChannel(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "open":
      let uri = (call.arguments as? [String: Any])?["uri"] as? String ?? ""
      open(uri, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func open(_ uri: String, result: @escaping FlutterResult) {
    let isFile = uri.hasPrefix("/") || uri.hasPrefix("file:")
    guard isFile else {
      guard let url = URL(string: uri), url.scheme != nil else { return result(false) }
      UIApplication.shared.open(url) { result($0) }
      return
    }
    let url = uri.hasPrefix("/") ? URL(fileURLWithPath: uri) : URL(string: uri)
    guard let url = url, FileManager.default.fileExists(atPath: url.path),
          let top = FilesChannel.topController() else { return result(false) }
    let doc = UIDocumentInteractionController(url: url)
    doc.delegate = self
    document = doc
    if doc.presentPreview(animated: true) { return result(true) }
    // Quick Look can't show it: offer the apps that can open it.
    result(doc.presentOptionsMenu(from: top.view.bounds, in: top.view, animated: true))
  }

  func documentInteractionControllerViewControllerForPreview(
    _ controller: UIDocumentInteractionController
  ) -> UIViewController {
    FilesChannel.topController() ?? UIViewController()
  }

  func documentInteractionControllerDidEndPreview(_ controller: UIDocumentInteractionController) {
    document = nil
  }

  func documentInteractionControllerDidDismissOptionsMenu(_ controller: UIDocumentInteractionController) {
    document = nil
  }

  private static func topController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    var top = scene?.windows.first { $0.isKeyWindow }?.rootViewController ?? scene?.windows.first?.rootViewController
    while let presented = top?.presentedViewController { top = presented }
    return top
  }
}
