# Releasing Audio Kit

Audio Kit is a pub workspace, but every member is a separate pub.dev package.
All package manifests use hosted constraints; workspace resolution selects the
matching local members during development.

## First publication

Pub.dev requires the first version of every new package to be published
manually. Run the full validation from a clean, pushed commit:

```sh
./tool/verify.sh
./tool/publish_dry_run.sh
```

Publish in dependency order and wait for each package to become visible on
pub.dev before publishing a dependent package:

1. `audio_core`, `audio_flutter_platform_interface`
2. `audio_kit_graph`, `audio_processing`, `speech_core`,
   `audio_flutter_darwin`
3. `audio_flutter`, `voice_core`, `speech_deepgram`, `speech_openai_tts`,
   `speech_fluidaudio`, `speech_mlx`
4. `voice_flutter`

The adapter prerequisites must already be public at the versions required by
their manifests:

- `fluidaudio_dart` `^0.3.1`
- `mlx_audio` `^0.2.0`

Publish one package with:

```sh
cd packages/audio_core
flutter pub publish
```

The CLI opens a browser for the one-time pub.dev authorization when no local
credential exists.

## Enable trusted publishing

After a package exists:

1. Open `https://pub.dev/packages/<package>/admin`.
2. Enable GitHub Actions publishing.
3. Set repository to `kshdotdev/audio-kit-dart`.
4. Set tag pattern to `<package>-v{{version}}`.
5. Require the GitHub environment `pub.dev`.

The repository has a package-specific workflow for every workspace member.
Only its publish job receives `id-token: write`; no pub token is stored.

## Later releases

Update the package pubspec and package changelog, merge the tested change, and
push a matching tag:

```sh
git tag audio_core-v0.1.1
git push origin audio_core-v0.1.1
```

The reusable preflight checks that the tag equals the pubspec version, performs
a publish dry-run, and copies the package outside the workspace to prove that
all hosted dependencies resolve independently. The official Dart publishing
workflow then exchanges GitHub's short-lived OIDC identity for pub.dev access.
