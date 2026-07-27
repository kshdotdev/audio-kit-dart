#if os(iOS)
  import Flutter
  import UIKit
#elseif os(macOS)
  import Cocoa
  import FlutterMacOS
#endif

public final class AudioFlutterDarwinPlugin: NSObject, FlutterPlugin {
  private let host: DarwinAudioHostApiImpl

  init(host: DarwinAudioHostApiImpl) {
    self.host = host
  }

  deinit {
    host.teardown()
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    #if os(iOS)
      let messenger = registrar.messenger()
    #elseif os(macOS)
      let messenger = registrar.messenger
    #endif
    let events = SessionEventsHandler()
    SessionEventsStreamHandler.register(with: messenger, streamHandler: events)
    let host = DarwinAudioHostApiImpl(events: events)
    DarwinAudioHostApiSetup.setUp(binaryMessenger: messenger, api: host)
    let plugin = AudioFlutterDarwinPlugin(host: host)

    #if os(iOS)
      registrar.publish(plugin)
    #elseif os(macOS)
      let channel = FlutterMethodChannel(
        name: "audio_flutter_darwin/lifetime",
        binaryMessenger: messenger
      )
      registrar.addMethodCallDelegate(plugin, channel: channel)
    #endif
  }

  public func handle(
    _ call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    result(FlutterMethodNotImplemented)
  }

  #if os(iOS)
    public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
      host.teardown()
    }
  #endif
}

