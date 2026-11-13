# TestFlight: Energy Controller for Powston

## Status (2026-11-13)

- **1.3 (11), iPhone: prepared, not uploaded.** It carries the October work (`docs/api-review-2026-10.md`: Amber, Battery ROI, Data Diagnosis, Tuning extras, P2P labels) plus the Debug-only guard below. It goes to **Internal Testing** first, so it can be tried on a device before any external group.
- Rick, 2026-11-13, on the plan "1.3 (11); commit the October work and send it to Internal Testing only; limit the developer option to debug builds; push secret as its own job; iPhone first; build on the build box after checking with deeplog-01": "I basically agree … Agree with the other decisions."

## App Store Connect

- **App:** "Energy Controller for Powston", app id 6757072169, bundle `com.bollar.Powston`, team J56G3UQQLN.
- **On sale:** iOS 1.2 and 1.0, and tvOS 1.0 (the Apple TV app shares the iPhone's record and bundle id).
- **Last builds:**
  - iOS 1.2.2 (5–10), 2026-02-10 to 2026-03-20, all expired.
  - tvOS 1.0 (4, 5) and 1.0.1 (4), January 2026.
- **Beta groups:**
  - Internal: Battery Debug, Internal Testing, Watch, iPad.
  - External: External Testing.
- **Read-only lookup** (from the build box, using TrueOffset's API helper):
  ```
  ssh admin@10.0.0.2 'cd ~/trueoffset/Scripts && python3 -c "from asc_profile import req; print(req(\"GET\",\"/apps?filter[bundleId]=com.bollar.Powston\"))"'
  ```
  `req` takes paths without `/v1`.

## Versions

- **1.3 (11):** set on the iPhone app, its widget, the watch app and the watch widgets (Debug and Release).
- **tvOS targets:** untouched at 1.0 (4). The Top Shelf extension is `com.bollar.PowstonTV.PowstonTopShelf`, which isn't prefixed by the app's `com.bollar.Powston`. Check that before the next Apple TV build.
- **Watch app:** the project has no "Embed Watch Content" phase, so the iPhone archive doesn't carry the watch app. How earlier builds delivered it is not known yet.

## App Review 2.5.19 (hidden features)

- **Before 1.3:** a long-press on the About disclaimer in Settings revealed "Use Dev Server" (dev.inverterintelligence.com) and "Experimental Features" (the Strategy / Action Items card on Decisions) in Release builds.
- **Now:** both are Debug-only. The long-press and the section are inside `#if DEBUG`. `PowstonAPI.useDevServer` and `DecisionsView.experimentalFeaturesOn` return false in Release, even if the stored switch was left on.
- **Checked 2026-11-13:** the Release simulator binary has no "Use Dev Server" string; the Debug one has it.

## Security (open, a separate job)

- `Powston/Services/PushNotificationService.swift` carries the push.bollar.com shared secret as a string. It has been in git since 2077bb4 (2026-02-02), and the GitHub mirror rbollar/PowstonApp is public.
- Fix: rotate it on push.bollar.com, and stop shipping a static secret in the app.
- Rick, 2026-11-13: handle it as its own job; a new build doesn't widen the exposure.

## Recipes

- **Simulator build** (Xcode 27.1, on the dev Mac):
  ```
  xcodebuild build -project Powston.xcodeproj -scheme Powston -configuration Release -destination 'generic/platform=iOS Simulator' -derivedDataPath <scratch> CODE_SIGNING_ALLOWED=NO
  ```
  Both Debug and Release succeeded on 2026-11-13. The repo is no longer in iCloud, so the old xcodebuild hang doesn't apply.

## Open

- Upload 1.3 (11) from the build box. This needs App Store profiles for `com.bollar.Powston` and `com.bollar.Powston.PowstonWidget`, and box time that doesn't clash with DeepSix 1.1 (review on 2026-11-15).
- Add the build to Internal Testing; test Battery ROI, Controller Health and Amber setup on a device.
- The watch app and Apple TV builds.
- Rotate the push secret.
