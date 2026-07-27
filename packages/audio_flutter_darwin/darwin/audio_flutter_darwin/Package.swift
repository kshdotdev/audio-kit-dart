// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "audio_flutter_darwin",
  platforms: [
    .iOS("17.0"),
    .macOS("14.0"),
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

