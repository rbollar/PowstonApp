# TestFlight: Energy Controller for Powston

## Status (2026-11-13)

- **1.3 (11), iPhone: prepared, not uploaded.** It carries the October work (`docs/api-review-2026-10.md`: Amber, Battery ROI, Data Diagnosis, Tuning extras, P2P labels) plus the Debug-only guard below. It goes to **Internal Testing** first, so it can be tried on a device before any external group.
- Rick, 2026-11-13, on the plan "1.3 (11); commit the October work and send it to Internal Testing only; limit the developer option to debug builds; push secret as its own job; iPhone first; build on the build box after checking with deeplog-01": "I basically agree … Agree with the other decisions."

## Builds sent (2026-11-13)

All builds are 1.3, built on the build box with Xcode 27.1 and answered "no non-exempt encryption". Rick: "Answer it that way."
- **(11):** the October work. In Internal Testing.
- **(12):** the rotated push secret. In Internal Testing.
- **(13):** adds Acknowledgements. Was submitted for Beta App Review, then **expired** before review. Rick: "Burn 13 and submit 14 with complete test notes."
- **(14):** the background crash fix, the watch app (embedded, with its sources, under the 1.2 bundle ids) and the watch's iCloud store fix. In Internal Testing and submitted to **External Testing** for Beta App Review; WAITING_FOR_BETA_REVIEW.
  - What to Test (complete for 1.3; the P2P line added while in review after Rick: "I think this includes removing LV p2p tracking and management." The removal is 460cb65, 2026-08-27):
    > What's new in 1.3 (14):
    > - Fixes a crash that could happen while the app was in the background.
    > - The Apple Watch app is back. Open it after signing in on your iPhone; it should show your site.
    > - Amber Electric support alongside Localvolts. Your retailer, prices and cost comparison should match your plan.
    > - Battery ROI: open it from Profit Intelligence and check yesterday, the last 7 days and the last 30 days.
    > - Data Diagnosis in Controller Health, for each inverter.
    > - Localvolts peer-to-peer trading is gone: Peer Power contracts, trade history and the counterparty map. Localvolts sites still get settlement, cash flow and the retailer comparison.
    > - Tuning shows two more settings when your site provides them.
    > - Limited export and import show as "Ltd Exp" and "Ltd Imp" in the actions table.
    > - Settings > About > Acknowledgements has a link to the source code and the open-source licenses.
    > - Notifications sign in again behind the scenes. Tell us if price or controller alerts stop arriving.
    >
    > Please tell us if anything looks wrong, especially your retailer, the Battery ROI figures, the watch app, and whether the app still crashes after you leave it in the background.
  - App-level beta review notes: "No account needed: on the Dashboard, tap Try Demo Mode to explore the app with sample data. Controls that change an inverter are off in demo mode."
  - To expire a build: `PATCH /builds/{id}` with `expired: true`.
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
- **tvOS targets:** untouched at 1.0 (4).

## Watch and Apple TV (checked 2026-11-13)

Rick, 2026-11-13: "I don't think we have any AppleTV changes but we need to figure out how to reconnect TV and watch."

- **What the store has:** iOS 1.2 (build 1, 2026-01-18) lists Apple Watch support on the App Store (`itunes.apple.com/lookup?id=6757072169` gives `Watch4` in `supportedDevices`), so that build carried the watch app. tvOS 1.0 is for sale from build 5 (2026-01-10). Both were signed with Xcode-managed "Team Store" profiles, so they were built in Xcode on the Mac, not with a script.
- **Watch, the break:** no committed version of the project embeds the watch app (the first commit after January is 2026-02-10), so 1.3 (11–13) ship without it. An App Store 1.3 built this way would take the watch app away from current users.
- **Watch, the fixes (3521819, 7b5e259, c9ab566):**
  - An "Embed Watch Content" phase (`$(CONTENTS_FOLDER_PATH)/Watch`) and a dependency on the watch target in the Powston target (ids `A1B2C3D4E5F647A8B9C0D1F3`–`F6`).
  - The watch app and watch widgets targets had **no source folders attached** in any committed project, so they built as empty bundles with no executable. `PowstonWatch Watch App/` and `PowstonWatchWidgetExtension/` are now synchronized groups of those targets (`…F7`–`F9`, Info.plist excepted for the widgets).
  - Bundle ids are back to what 1.2 shipped: `com.bollar.Powston.watch` and `com.bollar.Powston.watch.PowstonWatchWidget`. ASC refused `…watchkitapp`: "Attempting to change bundle identifier from com.bollar.Powston.watch to com.bollar.Powston.watchkitapp is disallowed" (90477).
- **Apple TV, the break:** `PowstonTV/TVAPI.swift` and `TVContentView.swift` use `RefreshableAPI` and `SmartRefreshManager` (`Powston/Services/SmartRefreshManager.swift`, written for both platforms), but the file was never added to the PowstonTV target, so tvOS hasn't built since early 2026.
- **Apple TV, the fix (3521819):** `SmartRefreshManager.swift` added to the PowstonTV sources (`A1B2C3D4E5F647A8B9C0D1F2`). The tvOS Release simulator build succeeds.
- **Apple TV changes since 1.0:** the TV code was last committed in the 2026-02 snapshots, after tvOS 1.0 (5) shipped on 2026-01-10, so there is unreleased TV work (at least the smart refresh). No commit marks exactly what shipped.
- **Top Shelf:** `PowstonTopShelf` isn't embedded in the TV app and its id `com.bollar.PowstonTV.PowstonTopShelf` isn't under `com.bollar.Powston`, so it has never shipped. Leave it out, or rename it to `com.bollar.Powston.PowstonTopShelf` and embed it.
- **How the devices get credentials:** the iPhone sends them to the watch over WatchConnectivity (`WatchConnectivityManager`) and writes them to iCloud key-value storage (`CloudCredentialSync`), which the TV and the watch read.
  - The watch used the KVS identifier `…com.bollar.Powston` (capital P, since 2026-02-10) while iPhone and TV use `$(TeamIdentifierPrefix)com.bollar.powston`. Since 3521819 the watch uses the lowercase one too.
- **Bundle ids and profiles (2026-11-13):**
  - App Store profiles made by `Scripts/tf_ship_ios.sh` on the box: "Powston Watch 1.2 iOS AppStore" (`com.bollar.Powston.watch`, 6P4KLAWDKJ) and "Powston Watch Widget 1.2 iOS AppStore" (`com.bollar.Powston.watch.PowstonWatchWidget`, 8NU22MANCH).
  - Unused, made before the bundle id fix: "Powston Watch iOS AppStore" (D5GJ62R282) and "Powston Watch Widgets iOS AppStore" (86YSAF72QD) for the `…watchkitapp` ids, which are registered but never shipped.
  - Capabilities: `com.bollar.Powston.watch` has App Groups and iCloud; its widget has App Groups, but the widget target has no entitlements file, so it can't read the watch app group yet.
- **Shipping the watch:** `tf_ship_ios.sh` signs all four bundles, stops if the archive has no watch app or the watch app has no executable, and re-signs the watch bundles for distribution if the export left them development-signed. That happened while the watch app was an empty bundle: the export skipped it (90161 "Missing code-signing certificate"; then 90896 and 90814, no executable).
- **Apple TV, still to do:** a TVOS_APP_STORE profile for `com.bollar.Powston` and a tvOS variant of the ship script (scheme PowstonTV, `generic/platform=tvOS`, altool `-t appletvos`). tvOS builds are numbered separately; the last was 1.0.1 (4).
- **Read-only ASC lookups from the dev Mac:** the TrueOffset key is in `~/.appstoreconnect/private_keys`; set `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_PATH` as in TrueOffset's `docs/app-store-1.4.md`, then `python3 -c 'import sys; sys.path.insert(0,"Scripts"); from asc_profile import req; …'`. Builds per platform: `/builds?filter[app]=6757072169&filter[preReleaseVersion.platform]=TV_OS`.

## Background crash (0xdead10cc), 2026-11-13

Rick, 2026-11-13: "App crashed in background. I sent to ASC."

- **Report:** TestFlight feedback `AN_7ZlMjc_ab7e403goJCQU`, 1.3 (13), iPhone19,7, iOS 27.3, comment "Crash in background." It is the same story as nine earlier reports on 1.2.2 (9, 10) from March to May ("In background", "Pushed to background"); their logs have expired, so only the newest can be read.
- **Cause:** `Termination Reason: RUNNINGBOARD 0xdead10cc`. iOS killed the app for holding a file lock while suspended. The main thread was inside a GRDB write (`PowstonDataStore.saveActions` → `DatabaseWriter.write`) on `powston_data.sqlite`, which lives in the App Group container `group.com.bollar.powston`. The system frames above it in the log are mis-symbolicated; the Powston and GRDB frames are the real ones.
- **Fix (3521819, in 1.3 (14)):** `PowstonDataStore` sets GRDB's `observesSuspensionNotifications` and posts `Database.suspendNotification` on `didEnterBackground` and `Database.resumeNotification` on `willEnterForeground`. GRDB then interrupts a running write and refuses new ones until the app comes back, so no lock is held when iOS suspends it. A write refused in the background throws and is retried on the next refresh. The Release simulator build succeeds; the crash itself can only be confirmed on a device over time.
- **Not done:** the widget and watch don't open this database, so it could move out of the App Group container, but that needs a data migration.
- **Fetch a crash log:** `GET /apps/6757072169/betaFeedbackCrashSubmissions?sort=-createdDate`, then `GET /betaFeedbackCrashSubmissions/{id}/crashLog` (`data.attributes.logText`). Logs disappear once their build expires.

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

- Ship the 0xdead10cc fix and see whether background crash reports stop.
- Test Battery ROI, Controller Health and Amber setup on a device.
- Try the watch app from build 14 on a watch; it hasn't run from this source before.
- Apple TV: profile, tvOS ship script, a tvOS build.
- Watch widgets: an entitlements file with the watch app group.
- Drop PUSH_LEGACY_SECRET on the push server when 1.2 users have moved to 1.3.
- Look at Acknowledgements on a device (build 14).
- Watch build 14's Beta App Review; external testers get it once Apple approves.
