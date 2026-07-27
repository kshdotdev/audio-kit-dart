# audio_flutter_platform_interface

The typed federated platform contract used by `audio_flutter`.

It defines capture, playback, device, process, permission, status, and batched
PCM transport messages without exposing provider SDK types.

Application code should normally depend on
[`audio_flutter`](https://pub.dev/packages/audio_flutter), not this package.
Platform implementations depend on this package when implementing another
operating system backend.

See the [federated implementation](https://github.com/kshdotdev/audio-kit-dart/tree/main/packages/audio_flutter_darwin)
for a complete Apple backend.
