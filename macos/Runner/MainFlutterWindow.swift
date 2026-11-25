import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    MacFilesChannel.register(with: flutterViewController.registrar(forPlugin: "MacFilesChannel"))
    VersionChannel.register(with: flutterViewController.registrar(forPlugin: "VersionChannel"))

    super.awakeFromNib()
  }
}

/// Answers the updater's "info" (lib/update/updater.dart) with this app's
/// version, so Settings shows it and updates know what's newer (see
/// _installOnMac in lib/update/updater.dart).
final class VersionChannel: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "photo_organizer/update", binaryMessenger: registrar.messenger)
    registrar.addMethodCallDelegate(VersionChannel(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "info" else { return result(FlutterMethodNotImplemented) }
    result(["version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""])
  }
}

/// Mac-only file helpers for lib/platform/desktop_library.dart.
final class MacFilesChannel: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "photo_organizer/mac_files", binaryMessenger: registrar.messenger)
    registrar.addMethodCallDelegate(MacFilesChannel(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "trash":
      // Moves the files to the Trash (restorable from Finder) without
      // asking to control Finder. Returns the paths that went.
      let paths = (call.arguments as? [String: Any])?["paths"] as? [String] ?? []
      var moved: [String] = []
      for path in paths {
        do {
          try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
          moved.append(path)
        } catch {
          // Gone already, locked, or on a drive without a Trash.
        }
      }
      result(moved)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
