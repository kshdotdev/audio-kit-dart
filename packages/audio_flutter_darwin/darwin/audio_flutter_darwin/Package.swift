// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "audio_flutter_darwin",
  platforms: [
    .iOS("17.0"),
    // The plugin shell, microphone capture, and playback support macOS 12.
    // Process-tap system audio remains runtime-gated to macOS 14.4 in the
    // implementation, so applications can launch on macOS 12/13.
    .macOS("12.0"),
  ],
  products: [
    .library(name: "audio-flutter-darwin", targets: ["audio_flutter_darwin"])
  ],
  dependencies: [],
  targets: [
    .target(
      name: "audio_flutter_darwin",
      dependencies: [],
      resources: []
    )
  ]
)
