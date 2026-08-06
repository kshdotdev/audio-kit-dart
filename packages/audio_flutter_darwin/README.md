# audio_flutter_darwin

Darwin implementation of the federated `audio_flutter` plugin.

It provides microphone capture and PCM playback on macOS and iOS, plus
system/process audio capture on supported macOS versions. Native capture uses
a bounded ring and batched pulls so audio callbacks never wait on Dart event
delivery.

Applications should depend on
[`audio_flutter`](https://pub.dev/packages/audio_flutter). Flutter selects this
implementation automatically on Apple platforms.

The initial platform scope is macOS 14+, iOS 17+, and system capture on macOS
14.4+ where the required Core Audio APIs are available. The package itself
targets macOS 12 so microphone capture and playback remain usable on macOS
12/13; every process-tap entry point is availability-guarded.
