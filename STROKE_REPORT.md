# Stroke Validator Report — Agent abb4215b

Worktree: `C:\Users\joygi\Nextcloud\CLOUD\My files\Progetti\HandWriter\.claude\worktrees\agent-abb4215b`
Branch: `worktree-agent-abb4215b`
HandWriter version: v0.36.9+38

Baseline `flutter analyze`: **0 issues**
Post-edit `flutter analyze`: **0 issues**

---

## B1 — Stroke break mid-pen-down  (FIX APPLIED)

### Root cause (high confidence)

The `Listener` widget in `_buildCanvas` (canvas_screen.dart:2228) wraps a
`GestureDetector` that registers `onScaleStart` / `onScaleUpdate` /
`onDoubleTap`. `GestureDetector` instantiates a `ScaleGestureRecognizer` for
**every** pointer kind, including stylus. Once the stylus pointer is
declared as a competitor in Flutter's gesture arena, the recognizer in
`scale.dart` resolves `accepted` as soon as a single criterion is met:

```dart
// flutter/packages/flutter/lib/src/gestures/scale.dart:744-749
final double focalPointDelta =
    (_currentFocalPoint! - _initialFocalPoint).distance;
if (spanDelta > computeScaleSlop(event.kind) ||
    focalPointDelta > computePanSlop(event.kind, gestureSettings) ||
    math.max(_scaleFactor / _pointerScaleFactor,
             _pointerScaleFactor / _scaleFactor) > 1.05) {
  resolve(GestureDisposition.accepted);
}
```

For a **single stylus pointer**, `computePanSlop(stylus)` is `kPanSlop = 36`
logical pixels. As soon as the cumulative pen movement from pointerDown
exceeds 36 px, `ScaleGestureRecognizer` claims the pointer. The
surrounding `Listener` then receives a `PointerCancel(stylus)` event
which routes into `_onPointerCancel`. That handler currently:

- branches `event.kind == touch && _stylusDown → return` (palm-rejection
  protection landed previously),
- but for `event.kind == stylus` it tears down the active stroke:
  `_activeStrokeNotifier.clear()` + `cancelStroke()`.

The user keeps the pen on glass; the next pen-move event creates a brand
new stroke at the current position. Visually: **the stroke "breaks" and
restarts** at the same place — exactly the reported symptom.

The existing `if (_stylusDown) return;` guards inside `_onScaleStart` /
`_onScaleUpdate` (canvas_screen.dart:1394, 1406) only suppress the
callback body — they do NOT prevent the recognizer from claiming the
pointer in the arena.

### Fix applied (chirurgical, ~10 lines including comment)

`GestureDetector.supportedDevices` constrains every recognizer the
detector spawns to a whitelist of pointer kinds. Setting it to
`{touch, mouse, trackpad}` keeps the stylus completely out of the
arena, so it can never be `PointerCancel`'d by the scale recognizer.

```dart
// canvas_screen.dart, GestureDetector (~line 2262)
child: GestureDetector(
  supportedDevices: const {
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
  },
  onScaleStart: _onScaleStart,
  onScaleUpdate: _onScaleUpdate,
  onDoubleTap: ...,
)
```

### Why this is safe

- iPad pinch-to-zoom uses two **touch** pointers — still supported.
- Trackpad pinch on macOS / Windows uses **trackpad** kind — still supported.
- Mouse wheel zoom goes via `Listener.onPointerSignal`, not GestureDetector
  — unaffected.
- Apple Pencil / desktop graphics tablet stylus → no longer enters the
  scale arena, no more PointerCancel during writing.
- Pre-bug "happy" pen path (single stylus stroke, no scale gesture) is
  bit-equivalent: the only thing that changes is the recognizer never
  fires for stylus, which means it can never cancel.
- Cost is one missed feature: stylus double-tap on the canvas in
  `pan` / `image` tool no longer toggles zoom. Touch / mouse double-tap
  still works, and stylus double-tap on the canvas was never documented
  as a primary interaction.

### Caveat (residual risk)

I cannot execute on iPad to confirm the cancel path is actually how the
user is reaching the bug. Other plausible (but less convincing)
candidates left untreated:

- A renderer rebuild that swaps the `Listener` callbacks during a stroke
  — examined, all closures here are stable (`_onPointerDown` / Move / Up
  are state methods bound by reference, not rebuilt).
- A `PointerCancel` from iOS palm-rejection on the stylus pointer itself
  (extremely rare, requires the OS to demote the pen pointer mid-touch).
  If this is what the user hits, my fix does not help — the existing
  `_onPointerCancel` already handles touch-cancel-during-stylus, but a
  stylus-cancel from the OS still tears down the stroke.

---

## B2 — Write freeze multi-secondi  (PROPOSED, not applied)

The write-freeze symptom has at least 5 plausible causes and **no
unambiguous evidence** in the codebase pointing at one over the others.
Without a profiler trace from an iPad reproduction, applying any of
these speculatively risks regressing the writing path — high-risk
territory pre-release. I leave them proposed for the consensus pass.

### Investigated candidates

1. **`_pullRemoteChanges()` 2-second timer awaiting WebDAV**
   (`canvas_provider.dart:5478`)
   Every 2 s the timer fires and `await syncService.getRemoteChangeState`
   issues two parallel PROPFINDs on the main isolate. On Tailscale these
   typically take ~50–200 ms but can spike to several seconds on poor
   wifi or roaming. The await itself does NOT block pointer dispatch
   (it's async), but if the response races into a `state.copyWith(...)`
   whose new value differs deeply (many `pages`), the resulting Riverpod
   rebuild can cause `CanvasScreen.build` to walk a large widget tree
   on the main thread and drop frames.
   *Proposed fix*: skip the pull tick entirely while
   `_activeStrokeNotifier.isActive == true`. Requires exposing the
   notifier's state to the provider (or a callback). ~10 lines but
   cross-cuts the widget/provider boundary; touches the writing path,
   so I do not apply speculatively.

2. **`_saveInner` `_acquireSyncLock` mutex blocking sequential save**
   (`canvas_provider.dart:5025–5043`)
   `save()` waits up to 30 s for the lock if a previous save or pull is
   still holding it. `_triggerAutoSave` already gates with
   `_activeStrokeNotifier.isActive` and defers (canvas_screen.dart:238),
   so the writing path itself never blocks here. But if a pull holds
   the lock, then a stroke ends, then auto-save fires, the save's first
   `state.copyWith(metadata: ...)` happens on lock release — and that
   rebuild can land on the next pointer-down. The 1-2 frame drop noted
   in the existing comment at canvas_screen.dart:233 might be the floor
   the user hits; the multi-second freeze would require the lock to be
   held for several seconds, e.g. a slow remote ZIP upload during
   `_remoteSync`.
   *Proposed fix*: none — the architecture is already correct (save off
   the writing path), and tightening the timeout could regress sync
   correctness. Worth verifying with logs.

3. **`Image.memory` / `ui.instantiateImageCodec` on the main thread**
   Examined: image decoding goes through `_decodeAndCacheImage` which
   uses `ui.instantiateImageCodec` (Flutter's async decoder). The
   `unawaited(_decodeAssetsThrottled(...))` loop at provider:455 paces
   to one decode per ~16 ms frame on desktop. iPad uses the
   ±`_mobileAssetWindow=2` window with LRU max 12 — bounded.
   *Probably not the cause.*

4. **GC pause from per-point allocation in the hot draw path**
   `_smoothStrokePoints` (`canvas_provider.dart:1380`) allocates a fresh
   `List<StrokePoint>` plus N new `StrokePoint` instances on commit —
   but only on commit, not per pointer move. The hot draw path is in
   `ActiveStrokeNotifier.addPoint` which already allocates one
   `StrokePoint` per accepted move. Stable across iOS releases; if this
   is the cause, it would manifest as periodic 1-frame stutter, not
   multi-second freeze.

5. **Riverpod `ref.invalidate` cascade rebuild**
   No `ref.invalidate` calls on the writing path. `ref.watch` in
   `CanvasScreen.build` (canvas_screen.dart:1821) reads the entire
   `canvasProvider`. Every `state.copyWith` triggers `build`, which
   re-creates the widget tree. The toolbar / page-nav are in the same
   tree but Flutter element-update is normally cheap. Could become slow
   on a 70+ page notebook — measurable but speculative without a trace.

### What I would do next (for the consensus author)

- Add `print('[Pointer]', ...)` traces at `_onPointerDown` /
  `_onPointerCancel` / `commitAndEndStroke` and ask the user to capture
  a log on iPad while reproducing the freeze. The log will instantly
  distinguish between cause #1 (no pointer events arrive for N
  seconds) and a stroke-break (PointerCancel mid-stroke).
- If logs confirm cause #1, the fix is to gate `_schedulePullTick`
  (`canvas_provider.dart:5445`) on a notifier the writing path bumps.

---

## Files touched

- `lib/features/canvas/presentation/canvas_screen.dart`
  (B1 fix at the GestureDetector wrapping the canvas painter)

## Files NOT touched

- All `*.freezed.dart`, `*.g.dart`, `pubspec.*`, `build.yaml`
- Models in `lib/shared/models/`
- WebDAV / sync protocol code
- ZIP / sidecar format code
- Mouse / touchpad pseudo-pressure path (`canvas_painter_notifiers.dart`)
- Provider stroke methods (`startStroke` / `continueStroke` /
  `commitAndEndStroke`)

## Top residual risks

1. The B1 fix has not been runtime-verified on iPad. If the user's
   stroke-break is actually triggered by an OS-level stylus cancel
   (palm-rejection, screen-edge palm protection, rotation lock, etc.),
   the fix does not help and a deeper change in `_onPointerCancel`
   would be needed (e.g. preserve in-flight stroke points on
   stylus-cancel and commit them as a finalized stroke instead of
   discarding).
2. B2 root cause is unknown. The 5+ candidates have overlapping
   symptoms and cannot be distinguished from the codebase alone.
3. Stylus double-tap on the canvas in `pan`/`image` tool no longer
   toggles fit-zoom. If the user relies on this, it's a regression of
   convenience (not correctness).
