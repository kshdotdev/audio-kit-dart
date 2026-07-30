# Releasing Audio Kit

Audio Kit is a pub workspace, but every package under `packages/` is a separate
pub.dev package. All package manifests use hosted constraints; workspace
resolution selects the matching local members during development.

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
   `audio_flutter_darwin`, `audio_flutter_linux`, `audio_flutter_windows`
3. `audio_aec`, `speech_sherpa`, `audio_flutter`, `voice_core`,
   `speech_deepgram`, `speech_openai_tts`, `speech_fluidaudio`, `speech_mlx`
4. `voice_flutter`

This is the same order `tool/publish_dry_run.sh` iterates; keep the two in
sync. Four of those packages are at `0.1.0` but have never been
published: `audio_flutter_linux`, `audio_flutter_windows`, `audio_aec`, and
`speech_sherpa`.

The [conversation-kit-dart](https://github.com/kshdotdev/conversation-kit-dart)
packages (`speech_pipeline`, `turn_detection`, `transcript_kit`, `meeting_kit`,
`conversation_core`) are **internal and never published**. All five carry
`publish_to: none`; that repository has no publish workflows and no release
tags, and applications consume it as path dependencies from a side-by-side
kshdotdev checkout. Nothing in this repository's release order waits on it, and
nothing there waits on a tag here — it only needs the hosted `audio_core`,
`audio_processing`, and `speech_core` contracts it compiles against to exist,
which is a development concern rather than a release one.

Two already-published packages are blocked behind the four unpublished ones
above and cannot be re-released until their new dependencies are live on pub.dev
at a stable version and the prerelease constraints are widened to `^0.1.0`:

- `audio_flutter` depends on `audio_flutter_linux` and `audio_flutter_windows`;
- `voice_flutter` depends on `audio_aec`.

A tag pushed for either before that point fails the preflight, which copies the
package outside the workspace and resolves it against pub.dev only.

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

The repository has a package-specific workflow for every publishable workspace
member: 17 `publish-<package>.yml` files, one per directory under `packages/`,
each triggered only by a `<package>-v*` tag. (`packages/audio_flutter/example`
is a workspace member too, but it is `publish_to: none` and has no workflow.)
Adding a package means adding its workflow in the same change. Only the publish
job receives `id-token: write`; no pub token is stored.

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
