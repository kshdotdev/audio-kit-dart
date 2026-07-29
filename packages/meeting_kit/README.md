# meeting_kit

Meeting-domain building blocks for applications built on Audio Kit: weighted
detection fusion, a recording lifecycle with crash recovery, microphone health,
structured meeting outcomes, and speaker labelling.

Pure Dart. No persistence, no transport, no user interface.

## The boundary

**Domain logic and stage shapes live here; persistence, transport, and UI stay
in the host.** Every piece below is a pure function or a small state machine
that a host drives — so the policy is unit-testable and the storage decisions
stay yours. `MeetingStore` is the one seam where the two meet, and it is an
interface this package never implements.

## What is here

| Area | Entry points |
|---|---|
| Detection | `resolveMeetingCandidate`, `MeetingDetectionPolicy`, `MeetingDetectionStateMachine` |
| Collectors | `MeetingSignalCollector`, `CompositeMeetingSignalCollector`, `ProcessMeetingSignalCollector`, `conferencingApps` |
| Lifecycle | `MeetingStatus`, `MeetingLifecycle`, `MeetingReconciler`, `MeetingStore` |
| Health | `MicHealthTracker`, `MicHealth` |
| Outcomes | `MeetingOutcome`, `MeetingActionItem`, `SpeakerName`, `SpeakerNameSource` |
| Labelling | `personLabel`, `assignSpeakerByOverlap`, `separateTranscriptBySpeaker`, `mergeConsecutiveTurns`, `tokenContainment` |

### Detection

Signals are fused by taking the strongest fresh signal's weight and adding a
corroboration bonus per additional distinct kind. A single strong signal — a
per-meeting conferencing client — carries a meeting on its own; weak signals
such as camera or system audio must corroborate one another.

```dart
final candidate = resolveMeetingCandidate(signals, now: DateTime.now());
final action = machine.update(candidate: candidate, now: DateTime.now());
```

`MeetingDetectionStateMachine` debounces with a minimum presence window,
suppresses a candidate the user dismissed until it clears, and suggests
stopping after a sustained no-signal gap.

Only the process collector ships here. Camera, microphone-in-use, system-audio,
and frontmost-window signals need platform channels; implement
`MeetingSignalCollector` for those and compose them. Detection degrades
gracefully — with only the process collector it still recognizes per-meeting
clients.

### Lifecycle and recovery

`recording → processing → done | failed`, with illegal moves rejected. Two rules
carry the recovery design:

- **One finalizer.** No post-processing step marks a meeting done itself, so a
  single failed step cannot strand a half-written meeting that already claims to
  be finished. Every terminal event — completed, failed, *or cancelled* — goes
  through `MeetingReconciler.handleOutcome`.
- **A startup sweep.** `MeetingReconciler.sweep()` rescues meetings stranded by
  a crash. Capture cannot survive a restart, so a meeting still marked recording
  is recovered exactly as a graceful stop would have left it.

### Microphone health

A microphone that stays silent while the far end is plainly talking is almost
always broken, not merely listening. `MicHealthTracker` confirms that over a
window before reporting it.

It does not compute RMS itself — feed it `AudioMeter` readings, which already
measure every frame:

```dart
tracker.noteNearReading(meter.process(micFrame));
tracker.noteFarReading(meter.process(systemFrame));
if (tracker.isNearSilentWhileFarActive) { /* warn the user */ }
```

## Tuned constants and their provenance

Every threshold is a constructor parameter, not a hard-coded value, because the
defaults were tuned against a specific set of collectors and a specific capture
stack. They are Control Center's, and are documented as such at each site:

| Constant | Default | Notes |
|---|---|---|
| Signal weights | 0.3–0.9 | `defaultMeetingSignalWeights`; re-tune if your collectors differ in reliability |
| Corroboration bonus | 0.15 | per additional distinct active kind |
| Detection threshold | 0.6 | a lone weak signal stays below it by design |
| Freshness / presence / auto-stop | 20 s / 8 s / 90 s | presence debounces a blip; auto-stop needs a sustained gap |
| Near / far amplitude floors | 0.01 / 0.02 | normalized 0–1, see below |
| Confirm / far-recency window | 3 s / 2 s | |
| Turn merge gap | 2 s | doubled for fragments of eight visible characters or fewer |
| Duplicate containment | 0.67 | window-boundary duplicate detection |

**On the amplitude scale.** Control Center's own RMS helper divided PCM16
samples by 32768 before measuring, so its floors were already normalized to 0–1
and carry over to float32 unchanged. This is the opposite of the AEC delay
estimator's `minNearStd`, which genuinely was raw-PCM16-scaled and had to be
rescaled when ported. Both were checked rather than assumed.

## Deliberately not ported

- **The summary pipeline engine.** Control Center runs its post-meeting work as
  a DAG with persisted step runs. That is host infrastructure; six sequential
  stages need a service, not a workflow engine. `MeetingOutcome` gives you the
  contract for the summarizing step without the machinery around it.
- **Workspace scoping and transport.** Multi-tenant identifiers and RPC belong
  to an application, not an SDK.
- **Offline-VAD transcript coverage repair.** Present in the reference
  implementation but unvalidated there — it has complete machinery and tests yet
  no callers, so there is no evidence about how it behaves in practice.
- **Calendar integration.** `SpeakerNameSource.calendarInvitee` exists so a host
  can record that provenance, but resolving invitees needs a calendar the SDK
  does not have.

## Attribution

Substantial portions derive from Control Center, MIT © 2026 Samuel Alev. See
`NOTICE` for the component-by-component mapping.
