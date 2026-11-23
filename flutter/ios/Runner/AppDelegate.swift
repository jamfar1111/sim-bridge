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
    // Hand-written native bridges (not pub plugins, so not auto-registered).
    let registry = engineBridge.pluginRegistry
    if let r = registry.registrar(forPlugin: "BlePlugin") { BlePlugin.register(with: r) }
    if let r = registry.registrar(forPlugin: "CallKitPlugin") { CallKitPlugin.register(with: r) }
    if let r = registry.registrar(forPlugin: "AudioPlugin") { AudioPlugin.register(with: r) }
  }
}
