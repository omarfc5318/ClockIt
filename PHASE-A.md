# Phase A — restructure, dependency, occlusion instrumentation, mic permission

Four things, nothing else. Phase B (double-trigger fix, `Task<WhisperKit, Error>`
load, `reset()` threading, the smaller items) is deliberately untouched.

## File moves

The package, all three targets and the test target were renamed from `TapToTalk*`
to `ClockIt*` in the same pass. The "was" column below refers to the original
pre-Phase-A layout, under the old name.

```
Package.swift                          rewritten
Sources/ClockItCore/                   was Sources/TapToTalk/, minus main.swift
  AudioRecorder.swift                    changed — permission
  CleanupEngine.swift                    unchanged
  GestureTrigger.swift                   unchanged
  HandSample.swift                       NEW
  HandTracker.swift                      changed — public, instrumentation
  PoseDetector.swift                     changed — Equatable, inContact
  SessionController.swift                changed — public, permission
  TextInjector.swift                     unchanged
  Transcriber.swift                      changed — default model
Sources/ClockIt/main.swift             was Sources/TapToTalk/main.swift
Sources/ClockItTuner/                  was Tuning/ (outside the package)
  TuningApp.swift                        changed — activation policy
  TuningView.swift                       changed — readouts, −Equatable ext
Tests/ClockItCoreTests/                was Tests/TapToTalkTests/
  PoseDetectorTests.swift                changed — import only, no test bodies
Phase2/CleanupEngine.swift             unchanged, still not compiled
```

## 1. Three targets

`ClockItCore` (library) · `ClockIt` (executable, main.swift only) ·
`ClockItTuner` (executable) · `ClockItCoreTests`.

The library exists because an executable target cannot be imported — that is the
only reason `Tuning/` had to sit outside the package, and why it was never
actually compiled by anything.

Public surface is the minimum the two executables need:

- **Tuner:** `HandTracker` (+ every `@Published` it reads, `session`, `onEvent`,
  `start`/`stop`/`applyConfig`/`resetStats`, and the two confidence floors as
  statics so the bars can draw their tick marks), `PoseConfig`, `PoseState`,
  `GestureEvent`, `PoseDetector`, `HandSample`, `LandmarkConfidence`,
  `TrackingStats`.
- **App:** `SessionController` and its `Phase`.

`AudioRecorder`, `Transcriber`, `CleanupEngine` and `TextInjector` stay
**internal**. Nothing outside the core touches them and there is no reason to
widen that later.

`PoseConfig` now declares `: Equatable` (all stored properties are `Double`, so
it is synthesized). The hand-written `==` is deleted from the tuner, where it
would otherwise have become a cross-module retroactive conformance.

`PoseDetector.inContact` changed from `private` to `public private(set)`. Read
only — the instrumentation needs it to tell "the landmarks vanished while the
fingers were touching" apart from "the hand was somewhere else." No behaviour
change; nothing outside `PoseDetector.swift` can write it.

## 2. Package.swift

`argmaxinc/WhisperKit` was renamed to `argmaxinc/argmax-oss-swift` at v1.0.0
(May 2026); WhisperKit is now one product there alongside `ArgmaxOSS`, `TTSKit`
and `SpeakerKit`. The old URL still redirects, but SwiftPM derives package
identity from the URL's last path component, so the old URL forced `package:`
to name a package that no longer exists under that name. Both are now correct.

The range is `"1.1.0" ..< "1.2.0"` rather than `.upToNextMinor(from:)`, which is
deprecated at tools-version 5.6+.

`Transcriber.swift` needed **no** changes for v1.1.0 —
`WhisperKitConfig(model:prewarm:download:)`,
`DecodingOptions(task:language:detectLanguage:skipSpecialTokens:withoutTimestamps:)`
and `transcribe(audioArray:decodeOptions:) async throws -> [TranscriptionResult]`
all still have exactly the shape the file assumed, in the right declaration order.

Default model is now `openai_whisper-large-v3-v20240930_turbo_632MB` (~630 MB
instead of ~3 GB), still injectable. Alternatives are listed in a comment on the
property.

## 3. Occlusion instrumentation

New types in `HandSample.swift`:

- `LandmarkConfidence` — thumbTip, thumbIP, middleTip, middleDIP, middlePIP,
  wrist, middleMCP. `nil` = Vision returned no point; `0.0` = it returned one and
  doesn't believe it.
- `HandSample` — `distance` (tip pair, the only value the detector consumes),
  `altDistance` (thumbIP↔middlePIP, **displayed only**), `confidence`.
- `TrackingStats` — `contactFrames`, `contactNilFrames`, `contactAltNilFrames`,
  `longestDropout`, `longestAltDropout`, and rates derived from them.

`HandTracker.normalizedDistance` became `sample(from:aspect:)`: same aspect
correction, same wrist-to-middleMCP normalizer, same confidence floors, same nil
conditions for the tip pair — it just reads five more joints and derives a second
distance from two of them.

The counters are sampled **before** `detector.update(...)`, so `inContact` still
reflects the last confident measurement rather than this frame's verdict. On a nil
frame `update` doesn't touch `inContact` at all, which is what makes it usable as
the denominator. Only frames on which Vision actually ran are counted, so the
5fps idle scan can't dilute the rate.

`longestDropout` is measured from the last *good* timestamp, so it is directly
comparable to `trackingGrace` — the tuner paints it red above the grace, because
a blackout longer than the grace is a dictation that would have been cut off.

`resetStats()` clears the counters; the tuner has a Reset button, because a
lifetime average goes stale the moment you change how you hold your hand.

`framesSinceHand` and the "two seconds of grace" comment are untouched.

## 4. Microphone permission

Nothing ever called `AVCaptureDevice.requestAccess(for: .audio)`. Before TCC
resolves, `engine.inputNode.outputFormat(forBus: 0)` reports 0 Hz / 0 channels,
and `installTap` on that raises an Objective-C exception no Swift `try` can
catch. The quiet version of the same failure is `AVAudioConverter(from:to:)`
returning `nil` and every dictation transcribing to empty string.

`AudioRecorder` now has `static func requestMicrophoneAccess() async -> Bool`
(static so the caller can await it from the main actor without passing a
non-Sendable recorder across an isolation boundary), and `prepare()` stays
synchronous and `throws`, with a `channelCount > 0 && sampleRate > 0` guard
before the tap and an explicit `converterUnavailable` case instead of a silent
`guard let converter else { return }`.

`SessionController.start()` awaits permission, then prepares, and reports which
of the four failures happened.

## Running it

```
swift build
swift test                      # 11 PoseDetector tests, no camera needed
swift run ClockItTuner        # the harness
swift run ClockIt             # the app
```

Unbundled binaries have no Info.plist and inherit the camera/mic grant of
whatever launched them, so run both from the same terminal and grant that
terminal Camera and Microphone. `TunerAppDelegate` sets `.regular` activation
policy and activates — without it a SwiftUI `App` from `swift run` opens behind
your terminal or appears not to open at all.

## What to measure

Hold the pose 20–30 s at your real desk height, turning your hand the way you do
while talking, then read the two rows in "dropouts while in contact":

- **tip pair nil % low, worst well under the grace** → occlusion theory is dead,
  keep `thumbTip↔middleTip`, tune `contactEnter`/`contactExit` off the top gauge.
- **tip pair nil % high or worst red, IP/PIP clean** → switch the detector's
  input to `thumbIP↔middlePIP` and retune. The IP/PIP gauge already shows you
  where its contact and open values sit, so you'll have the new thresholds before
  you change any code.
- **both bad** → it's framing, not the joint pair. Check the preview.

Watch the confidence bars while you do it. If `middleTip` dives under its 0.50
tick every time the thumb crosses it, that is the occlusion, visible directly.

## Not verified by a compiler

Written without a macOS toolchain to hand. The pure-Swift parts are
straightforward; the parts to eyeball first on your machine are the SwiftUI
formatting helpers in `TuningView`, the `public` annotation on the
`captureOutput` delegate method, and whether your toolchain treats top-level code
in `main.swift` as main-actor isolated (if `SessionController()` errors there,
that's the cause and it's a one-line fix, not a design problem).

## Two small deviations from the Phase A list

- Removed `import SwiftUI` and the unused `observation` property from
  `main.swift`. Both were dead and would have warned on every build.
- Rewrote the stale "the double tap takes 300-500ms" line in `AudioRecorder`'s
  header, since I was rewriting the doc comment immediately below it. The
  matching stale comment in `GestureTrigger` is untouched and still on the
  Phase B list.

## 5. Vision perform guard, pulled forward from Phase B

`try? handler.perform([request])` discarded the error while `request` is reused
across frames and keeps its last results — so on a throw, `request.results` still
held the *previous* frame's observation. That would have reported a phantom hand
at a stale distance and counted as a successful measurement, biasing the nil rate
**downward**: a false all-clear, in the one direction that matters here.

Now a `do`/`catch`. On failure nothing is read, `measured` stays empty, the
detector sees `nil` and `trackingGrace` absorbs it — the honest outcome, since we
genuinely don't know where the hand is.

Failed frames are excluded from the occlusion counters (`visionRan` is only set
on success), because a failed inference isn't occlusion and folding it in would
bias the rate upward instead. But they are counted in
`TrackingStats.visionFailures` and shown in the tuner, because a denominator that
silently shrinks is how a sampling bug survives a measurement session. Expect 0.

One asymmetry on purpose: `longestDropout` is *not* gated on `visionRan`. A frame
Vision failed on is still a frame with no measurement, so it does extend the
blackout the grace has to absorb. Rates attribute cause; durations model
consequence.
