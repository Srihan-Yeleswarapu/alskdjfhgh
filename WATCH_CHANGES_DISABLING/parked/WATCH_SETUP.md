# Speedio on Apple Watch

Three surfaces, three phases:

| Phase | Surface | Where it lives | Requires manual setup? |
|-------|---------|----------------|------------------------|
| 0 | **Smart Stack mirroring** — the existing Live Activity renders on the watch | `SpeedActivityAttributes` + `SpeedLiveActivityView` | No |
| 1 | **Watch app** — watch-owned GPS sessions + native haptic speeding alerts + complications | `SmartSpeedCompanionWatch/` + `SmartSpeedCompanionWatchWidget/` | Yes (signing, below) |
| 2 | **Phone↔watch pairing** — remote start/end/snooze, live phone chip, settings sync | `Core/WatchLink.swift`, `Core/WatchSessionController.swift`, `WatchPhoneConnector.swift` | No (needs Phase 1 targets) |

## How it works

### Phase 0 — Smart Stack (watchOS 11+, zero new targets)
watchOS 11 mirrors iPhone Live Activities onto the Watch Smart Stack and
auto-launches it when a session starts. `SpeedLiveActivityView` opts into
`.supplementalActivityFamilies([.small])` and renders a wrist-shaped card
(hero speed, limit chip, REC timer / next-maneuver line) with an
`isLuminanceReduced` always-on variant. The card is **read-only** and only
visible while a Live Activity is running — that is what Phases 1–2 add.

### Phase 1 — Watch app
- **GPS authority:** per product decision, the watch ALWAYS runs its own
  `LocationManager` + `SpeedEngine` when a watch session is active (works
  phone-less; phone + watch each track independently). Phone readings
  arrive over WCSession and render as a secondary "Phone" chip.
- **Haptics:** `WatchHaptics` fires real `WKInterfaceDevice` pulses with
  the same 15 s cadence as the phone's `BackgroundHapticBridge` — but
  natively, without the silent-notification hack (watchOS allows haptics
  from an active session; iOS does not from the background).
- **Shared Core:** the watch target compiles a Firebase-free subset of
  `Core/` (audited: no UIKit/MapKit/Firebase/SwiftData references).
  Status thresholds, the HERE continuity guard, and the display-unit
  contract are byte-identical to the phone.
- **Complications:** recording state + last recorded speed from the
  watch-local App Group, refreshed only on session start/end (watch
  timeline budget makes live speed infeasible — by design).

### Phase 2 — Pairing
`WatchLink.swift` (compiled into both targets) defines the schema:
`WatchPhoneState` (phone→watch, via `updateApplicationContext`,
latest-wins), `WatchCommand` (watch→phone: start/end/snooze/requestState),
`WatchSettingsSync` (bidirectional units/buffer/haptics). The phone
executes commands on `AppDelegate.sharedDriveViewModel` — the same entry
points Siri and CarPlay use.

## One-time manual setup (developer.apple.com)

Mirrors the widget-target flow documented in the project.yml comments:

1. **App IDs** — register:
   - `com.speedsense.app.watchkitapp` (watchOS App ID)
   - `com.speedsense.app.watchkitapp.SpeedWidget` (watch widget App ID)
2. **App Group** — create `group.com.smartspeedcompanion.app.watch` and
   enable it on BOTH App IDs above. (This group is watch-local; the
   iPhone group `group.com.smartspeedcompanion.app` is unchanged.)
3. **Provisioning profiles** — create two App Store profiles and name
   them exactly:
   - `Speedio Watch App Store`
   - `Speedio Watch Widget App Store`
4. **CI** — if the distribute workflow fabricates entitlements blobs for
   the widget (the `[DBG-WIDGET-ENT]` pattern), replicate it for the two
   watch targets; otherwise the entitlements files in
   `SmartSpeedCompanion/Resources/Entitlements/` are already wired via
   `CODE_SIGN_ENTITLEMENTS` in `project.yml`.

Versions are pinned to the project-level `MARKETING_VERSION` /
`CURRENT_PROJECT_VERSION`, satisfying ASC's "watch app version must match
companion iOS app" rule automatically.

## Building & testing

```bash
xcodegen generate
xcodebuild -project SmartSpeedCompanion.xcodeproj \
  -scheme SmartSpeedCompanion \
  -destination 'generic/platform=iOS' build

# watchOS unit tests (payload schema, haptic cadence, formatting):
xcodebuild -project SmartSpeedCompanion.xcodeproj \
  -scheme SmartSpeedCompanionWatch \
  -destination 'platform=watchOS Simulator,name=Apple Watch Series 10 (46mm)' test
```

Device verification checklist:
- [ ] Paired devices: start a phone session → watch Smart Stack card
      appears (Phase 0) and the "Phone" chip goes live (Phase 2)
- [ ] Start Watch Drive with the phone locked/in pocket → overspeed
      haptic pulses within ~1 s of crossing limit+buffer (Phase 1)
- [ ] Watch "End Phone Drive" button ends the phone session
- [ ] Change units on the wrist → phone Settings + widget follow
- [ ] Airplane-mode phone, watch-only run on watch GPS
- [ ] CarPlay active → watch haptics still fire (no double-buzz on the
      phone: `BackgroundHapticBridge` already suppresses during CarPlay)

## Known limitations
- Smart Stack mirror is read-only (Apple platform behavior); actions live
  in the watch app.
- WCSession state delivery is budgeted by watchOS; the watch falls back to
  its own GPS rendering when phone data is >6 s stale
  (`WatchPhoneState.stalenessWindow`).
- HERE/Geoapify credentials do not sync iPhone↔watch (Keychain isolation).
  On-watch limit lookups work with the bundled `HERE-Config.plist` — add
  it to the watch target's resources if on-device lookups are desired.
