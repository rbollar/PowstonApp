# TestFlight: Energy Controller for Powston

## Status (2026-11-13)

- **1.3 (11), iPhone: prepared, not uploaded.** It carries the October work (`docs/api-review-2026-10.md`: Amber, Battery ROI, Data Diagnosis, Tuning extras, P2P labels) plus the Debug-only guard below. It goes to **Internal Testing** first, so it can be tried on a device before any external group.
- Rick, 2026-11-13, on the plan "1.3 (11); commit the October work and send it to Internal Testing only; limit the developer option to debug builds; push secret as its own job; iPhone first; build on the build box after checking with deeplog-01": "I basically agree … Agree with the other decisions."

## Builds sent (2026-11-13)

All builds are 1.3, built on the build box with Xcode 27.1 and answered "no non-exempt encryption". Rick: "Answer it that way."
- **(11):** the October work. In Internal Testing.
- **(12):** the rotated push secret. In Internal Testing.
- **(13):** adds Acknowledgements. In Internal Testing and submitted to **External Testing** (27 testers, public link) for Beta App Review; WAITING_FOR_BETA_REVIEW. Rick: "Make a build 13 and send that to testers."
  - What to Test: "1.3 adds Amber Electric support alongside Localvolts, a Battery ROI screen (open it from Profit Intelligence), and a Data Diagnosis section in Controller Health. Please check that your retailer shows correctly and that Battery ROI looks right for yesterday, the last 7 days and the last 30 days."
  - App-level beta review notes: "No account needed: on the Dashboard, tap Try Demo Mode to explore the app with sample data. Controls that change an inverter are off in demo mode."
- **Ship recipe:** `git archive HEAD` to `admin@10.0.0.2:powston/`, then `Scripts/tf_ship_ios.sh` there, with KEYCHAIN_PW on stdin and `DEVELOPER_DIR=~/xcode-ga/...`. Check with deeplog-01 first, because the box is shared with DeepSix. To release: answer encryption on the build, set `betaBuildLocalizations` whatsNew, add the groups, then POST `betaAppReviewSubmissions`.

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

## Security: the push secret leak (fixed 2026-11-13)

Rick, 2026-11-13: "Fix the GitHub secret leak."

- **The leak:** `PushNotificationService.swift` carried the push.bollar.com secret from 2077bb4 (2026-02-02), and the GitHub mirror is public. That secret also unlocked `POST /api/push/alert`, which sends any title and body to **every** subscriber (34 on 2026-11-13). So anyone could push messages to every user's phone.
- **Server** (harriet `/data/powston`, service `powston-push`; files backed up as `*.bak-secret-20261113`, and the unit as `/root/powston-push.service.bak-secret-20261113`):
  - The secrets moved out of the world-readable unit into `/etc/powston-push.env` (root, 600), loaded with `EnvironmentFile=`.
  - **PUSH_SECRET** is new; the app sends it.
  - **PUSH_LEGACY_SECRET** is the leaked one. It can still register and unregister devices, so the App Store 1.2 app and TestFlight 1.3 (11) keep working, but it can't send alerts.
  - **PUSH_ADMIN_SECRET** is new and is the only secret `/api/push/alert` accepts. The alert endpoint also refuses any request carrying `CF-Connecting-IP`, so it can't be reached through the Cloudflare tunnel, only from harriet itself.
  - The defaults that were hard-coded in `push_server.py` are gone.
  - The alert callers (`health_check.py`, `powston_failsafe.py`, `cron_wrapper.sh`) read the admin secret from the env file.
- **Tests** (a throwaway copy on port 8499 with an empty subscriber database, so a failed check couldn't reach anyone):
  - Alert with the leaked secret: 403. With the app secret: 403. With the admin secret plus a CF header: 403. With the admin secret locally: ok.
  - Register with a wrong secret: 401. With the legacy secret: 200. With the new secret: 200.
- **App:** reads `PowstonPushSecret` from Info.plist and skips registration when it's empty (local builds). `Scripts/tf_ship_ios.sh` writes the key from `~/powston-secrets/push_secret` (box, 600, copied from harriet's env file) into the box's throwaway copy. The secret is not in git.
- **History:** the old secret stays in the public GitHub history; it can no longer send alerts. Drop `PUSH_LEGACY_SECRET` once every user is on 1.3 or later, which ends its last use.
- **Copy the app secret to the box:**
  ```
  ssh root@harriet 'sed -n "s/^PUSH_SECRET=//p" /etc/powston-push.env' | ssh admin@10.0.0.2 'umask 077; mkdir -p ~/powston-secrets; tr -d "\n" > ~/powston-secrets/push_secret'
  ```

## GitHub and license (2026-11-13)

- **Repo:** https://github.com/rbollar/PowstonApp is public, MIT ("Copyright (c) 2025 rbollar", `LICENSE`, 3f454bc), with default branch main. Gitea `rick/powston-app` is the private copy.
- **In the app (until build 12):** there was no link to the source and no license or acknowledgements text.
- **Since 1e41945+1:** Settings › About › Acknowledgements (`Powston/Views/Components/AcknowledgementsView.swift`). It has "Source Code on GitHub", the app's MIT License, and each package with its full license text, copied verbatim from the checked-out packages. Rick, 2026-11-13: "Yes on both" (push the commits; add the acknowledgements). It builds in Debug for the simulator, but nobody has looked at it on screen yet. It first ships in the build after 12.
- **Packages:** GRDB.swift 7.9.0 (MIT), socket.io-client-swift 16.1.1 (MIT), Starscream 4.0.8 (Apache 2.0). Their licenses ask for their notices to ship with the app.

## Recipes

- **Simulator build** (Xcode 27.1, on the dev Mac):
  ```
  xcodebuild build -project Powston.xcodeproj -scheme Powston -configuration Release -destination 'generic/platform=iOS Simulator' -derivedDataPath <scratch> CODE_SIGNING_ALLOWED=NO
  ```
  Both Debug and Release succeeded on 2026-11-13. The repo is no longer in iCloud, so the old xcodebuild hang doesn't apply.

## Open

- Test Battery ROI, Controller Health and Amber setup on a device.
- The watch app and Apple TV builds.
- Drop PUSH_LEGACY_SECRET on the push server when 1.2 users have moved to 1.3.
- Look at Acknowledgements on a device (build 13).
- Watch build 13's Beta App Review; external testers get it once Apple approves.
