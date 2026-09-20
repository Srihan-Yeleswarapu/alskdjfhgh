# WATCH_CHANGES_DISABLING — Apple Watch integration parked, iOS/CarPlay fixes kept

Date: 2026-09-12 · Branch: `version2` · Thread of origin: "Speedio for Apple Watch Ideas"

The Apple Watch thread implemented Phases 0–2 of the watch integration
(Smart Stack mirroring, watchOS app, phone↔watch pairing). The app wasn't
ready to carry all of it, so the **watch-specific** code was disabled
(commented out / parked) while every **CarPlay and iPhone** change from that
thread (TestFlight 2.3.0 feedback fixes) was kept intact.

Nothing was deleted. Everything needed to bring the watch back lives in this
folder.

---

## 1. What was DISABLED (Apple Watch only)

### 1a. Commented out inside tracked source files

Look for `[WATCH-DISABLED]` markers — every commented block is tagged with it.

| File | What is commented out | Restore note |
|---|---|---|
| `SmartSpeedCompanion/App/AppDelegate.swift` | The two lines activating the WCSession bridge in `application(_:didFinishLaunchingWithOptions:)`: `WatchSessionController.shared.activate()` + `WatchSessionController.shared.observe(viewModel: Self.sharedDriveViewModel)` | Delete nothing — just remove the `// ` from the two call lines (keep or drop the explanatory comment as you like). Requires `Core/WatchSessionController.swift` restored (see 1b). |
| `SmartSpeedCompanion/Features/iOS26/LiveActivities/SpeedActivityAttributes.swift` | The whole `public static var supplementalActivityFamilies: [ActivityFamily]` computed property (declares the `.small` family for watchOS 11 Smart Stack mirroring). | Remove `// ` from the tagged block. WidgetKit compiles this in the widget target; it pairs with the modifier in `SpeedLiveActivityView.swift` — restore both together. |
| `SmartSpeedCompanion/Features/iOS26/LiveActivities/SpeedLiveActivityView.swift` | (a) the `.supplementalActivityFamilies([.small])` modifier on the `WidgetConfiguration`; (b) the `@Environment(\.activityFamily)` + `@Environment(\.isLuminanceReduced)` properties; (c) the family-`switch` `body`; (d) the entire wrist-sized Smart Stack card: `watchCard`, `watchSecondaryLine`, `watchAccessibilityLabel`. | ⚠️ **Not a blind uncomment.** The file currently has an active `var body: some View { lockScreenCard }` that must be *replaced* by the commented-out switch body (otherwise there are two `body` declarations). Concretely: delete the 3-line active `body` and uncomment the tagged switch `body` block in the same struct. Everything else (a, b, d) is a plain `// ` removal. |

The refactoring from the watch thread that was **kept** in
`SpeedLiveActivityView.swift` (it is iOS behavior, not watch behavior):

- `lockScreenView(context:)` was converted to the `lockScreenCard` computed
  property inside `SpeedLiveActivityContentView` — identical Lock Screen /
  StandBy rendering, just split out of the widget struct.
- The Dynamic Island builders were extracted into private methods.
- Shared helpers were hoisted to file-private free functions:
  `speedStatusColor`, `dynamicIslandManeuverLabel`, `formatNavigationDistance`,
  `formatElapsedTime`.

**One real build bug was fixed while disabling** (it would have broken the
iOS widget target on its own): `expandedWithManeuver` called
`formatDistance(...)` — a symbol that no longer exists in this module after
the helper hoist. It now calls `formatNavigationDistance(...)`.

### 1b. Untracked watch-only files moved into `parked/`

These were never tracked by git; they were moved out of the source tree so
they cannot be glob-compiled into the iOS app (`Core/` is a source path in
`project.yml`, so `WatchLink.swift` + `WatchSessionController.swift` would
have compiled into the main app even with no watch targets).

| Original location | Parked location |
|---|---|
| `SmartSpeedCompanion/Core/WatchLink.swift` | `parked/WatchLink.swift` |
| `SmartSpeedCompanion/Core/WatchSessionController.swift` | `parked/WatchSessionController.swift` |
| `SmartSpeedCompanion/Resources/Entitlements/SmartSpeedCompanionWatch.entitlements` | `parked/SmartSpeedCompanionWatch.entitlements` |
| `SmartSpeedCompanion/Resources/Entitlements/SmartSpeedCompanionWatchWidget.entitlements` | `parked/SmartSpeedCompanionWatchWidget.entitlements` |
| `SmartSpeedCompanionWatch/` (WatchApp, WatchDriveViewModel, WatchHaptics, WatchHomeView, WatchPhoneConnector, WatchSettingsView) | `parked/SmartSpeedCompanionWatch/` |
| `SmartSpeedCompanionWatchWidget/` (WatchComplications) | `parked/SmartSpeedCompanionWatchWidget/` |
| `SmartSpeedCompanionWatchTests/` (WatchLogicTests) | `parked/SmartSpeedCompanionWatchTests/` |
| `WATCH_SETUP.md` (manual signing/provisioning guide) | `parked/WATCH_SETUP.md` |
| `project.yml.watchos-backup` (backup of project.yml taken when the watch work started — the repo's `project.yml` itself never gained watch targets, so this is identical to committed `project.yml`; kept only for provenance) | `parked/project.yml.watchos-backup` |

`project.yml` in the repo was **not** modified — it has no watch targets, so
no project-file edit was needed to disable anything.

---

## 2. What was KEPT untouched (CarPlay / iPhone — TestFlight 2.3.0 fixes)

All of these remain live in the working tree and are covered by the new
`SmartSpeedCompanionTests/HUDChromeFeedbackTests.swift`:

- `CarPlay/CarPlayNavigationManager.swift` — POI-first search ranking
  (`poiFirst`) so CarPlay rows lead with places, not the street you're
  parked on (b653).
- `CarPlay/CarPlayNamedLocationsController.swift` — navigation start no
  longer presents the "Navigating to …" confirmation modal; unwinds to the
  map (`unwindToMapAfterNavigationStart`).
- `CarPlay/CarPlayNavigationRootTemplate.swift` — stop-added confirmation
  modal removed; success unwinds to the map (`unwindAfterStopAdded`),
  failures still alert.
- `Views/Drive/MapWithHUDView.swift` — new `TopChromeBottomKey` preference
  measuring the real top-chrome bottom edge; empty-search submit no longer
  exits search mode (b643); Add Stops row no longer horizontally scrollable
  (b653).
- `Views/Drive/LiveMapView.swift` — compass/tracking buttons drop below the
  *measured* chrome bottom instead of the stale 155+35+40 estimate.
- `ViewModels/DriveViewModel.swift` — new `topChromeBottom` published
  property; empty search query keeps search mode (b643).
- `Features/iOS26/LiveActivities/SpeedActivityAttributes.swift` and
  `SpeedLiveActivityView.swift` — the structural refactor + `formatDistance`
  → `formatNavigationDistance` fix (watch bits commented, see §1a).
- `App/AppDelegate.swift` — only the WCSession lines are commented; CarPlay
  scene handling untouched.
- Untracked, kept as-is: `SmartSpeedCompanionTests/HUDChromeFeedbackTests.swift`,
  `website/AppDescription.txt`, `website/WhatsNew.txt`, and the scratch dirs
  `.feedback_2026-09-06*_tmp/`, `.video_jitter_tmp/` (from other threads —
  unrelated to the watch work, left alone).

---

## 3. Snapshot of the pre-disable diffs

`raw-diffs.patch` was captured with `git diff` **before** any disabling
edits. It contains the complete working-tree diff vs HEAD at that moment —
the original watch code in tracked files *and* all the kept iOS/CarPlay
fixes. Use it as the authoritative reference for what the watch thread
changed inside tracked files. (CRLF line endings were normalized to LF by
git's text filter when the patch was written; the Swift files themselves
are CRLF on disk and were kept CRLF during editing.)

To see what the tracked-file watch code looked like originally, read the
hunks for `AppDelegate.swift`, `SpeedActivityAttributes.swift`, and
`SpeedLiveActivityView.swift` in that patch.

---

## 4. How to restore (later, when the app is ready)

### Phase 0 — Smart Stack mirroring (tracked files only)

1. `SpeedActivityAttributes.swift` — uncomment the tagged
   `supplementalActivityFamilies` static.
2. `SpeedLiveActivityView.swift` — uncomment the tagged
   `.supplementalActivityFamilies([.small])` modifier, the two
   `@Environment` properties, `watchCard`, `watchSecondaryLine`, and
   `watchAccessibilityLabel`; then **replace** the active
   `var body: some View { lockScreenCard }` with the commented switch body:

   ```swift
   var body: some View {
       switch activityFamily {
       case .small:
           watchCard
               .preferredColorScheme(.light)
       default:
           lockScreenCard
       }
   }
   ```
3. Verify with the widget scheme build
   (`SmartSpeedCompanionWidget` target compiles both edited files).

### Phase 1 + 2 — watch app & pairing

1. Move the parked files back:
   ```bash
   mv WATCH_CHANGES_DISABLING/parked/WatchLink.swift            SmartSpeedCompanion/Core/
   mv WATCH_CHANGES_DISABLING/parked/WatchSessionController.swift SmartSpeedCompanion/Core/
   mv WATCH_CHANGES_DISABLING/parked/SmartSpeedCompanionWatch.entitlements  SmartSpeedCompanion/Resources/Entitlements/
   mv WATCH_CHANGES_DISABLING/parked/SmartSpeedCompanionWatchWidget.entitlements SmartSpeedCompanion/Resources/Entitlements/
   mv WATCH_CHANGES_DISABLING/parked/SmartSpeedCompanionWatch     .
   mv WATCH_CHANGES_DISABLING/parked/SmartSpeedCompanionWatchWidget .
   mv WATCH_CHANGES_DISABLING/parked/SmartSpeedCompanionWatchTests .
   mv WATCH_CHANGES_DISABLING/parked/WATCH_SETUP.md               .
   ```
2. Uncomment the two `WatchSessionController` lines in `AppDelegate.swift`.
3. Re-add the watch targets to `project.yml` (they were never committed —
   the targets block must be recreated; `parked/project.yml.watchos-backup`
   is just a pre-work copy of the plain file and does **not** contain them).
   Follow the manual-signing checklist in `parked/WATCH_SETUP.md`
   (App IDs `com.speedsense.app.watchkitapp` + widget suffix, App Group
   `group.com.smartspeedcompanion.app.watch`, profiles `Speedio Watch App
   Store` / `Speedio Watch Widget App Store`).
4. `xcodegen generate`, then build the `SmartSpeedCompanionWatch` scheme and
   run `WatchLogicTests` on a watchOS simulator.

### Reference material

- Phase-by-phase design & rationale: conversation thread "Speedio for Apple
  Watch Ideas" (Phases 0/1/2 as shipped) — summarized in `parked/WATCH_SETUP.md`.
- Original in-file code: `raw-diffs.patch` (tracked files) and the parked
  sources (untracked files), both verbatim.

---

## 5. Verification performed when disabling

- `grep` over all of `SmartSpeedCompanion/` + `SmartSpeedCompanionTests/`:
  **zero** non-comment references to `WatchSessionController`, `WatchLink`,
  `WatchPhoneState`, `WatchCommand`, `WatchSettingsSync`,
  `supplementalActivityFamilies`, or `activityFamily`.
- Brace balance of active (non-comment) code in `SpeedLiveActivityView.swift`
  verified 67 `{` / 67 `}`.
- CRLF line endings of all three edited files preserved (no spurious
  whole-file diffs).
- `.github/` workflows contain no watch references; `project.yml` untouched.
