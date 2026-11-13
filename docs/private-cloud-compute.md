# Apple Private Cloud Compute in Powston (planning)

Status: design discussion started 2026-11-14. Nothing built yet.

## What exists today

- The app already uses Apple's on-device model through the Foundation Models framework:
  - `Powston/Services/DecisionReasonService.swift` explains controller decisions
  - `Powston/Services/IntelligentSummaryService.swift` writes performance summaries, forecast explanations and enhanced notifications
  - `Powston/Services/PriceForecastService.swift` explains price forecasts
- Settings has an "Apple Intelligence" toggle (iOS 26+). Its footer says "All processing happens privately on your device." That stops being true once anything runs on Private Cloud Compute.
- Deployment targets: iPhone app 17.6 (the AI code is behind `#available(iOS 26.0, *)`), widgets 26.2, watch 10.6.

## Powston's MCP server (the model Rick pointed at)

Documented in the ha-powston README ("Connecting an AI agent to Powston") and in
<https://app.powston.com/api/agent-setup/prompt.md> (read 2026-11-14):

- Endpoint `https://app.powston.com/api/mcp`, Streamable HTTP, stateless.
- Auth: OAuth 2.1 (90-day tokens) or a static Profile API key. Default scope `read:site`; writes need an opt-in on the consent screen (`write:tuning`, `write:holds`).
- Read tools: `list_my_sites`, `get_site_snapshot`, `get_battery_soc`, `get_current_price`, `get_today_summary`, `get_upcoming_actions`, `get_inverter_status`, `get_inverter_connection`, `get_ev_charger`, `search_ev_models`, `get_command_history`, `get_interval_detail`, `get_daily_history`, `get_tariff_info`, `get_roi`, `get_bill_to_date`, `get_tuning_parameters`, `get_tuning_history`, `get_code_edit_history`, `list_scheduled_changes`, `get_p2p_starter_plan`, `get_decision_code_reference`, `simulate_decision_code`, `get_support_history`, `get_release_notes`, `get_controller_help`, `report_problem` (draft only).
- Write tools: `update_tuning_parameters`, `schedule_tuning_change`, `schedule_battery_hold`, `cancel_scheduled_change`.
- Agent rules: show the exact change and get agreement before any write (a battery hold commands real hardware); inverter telemetry is not meter data, so never present it as billing evidence.

## Apple Private Cloud Compute for third-party apps (WWDC26)

Sources: session 319 "Build with the new Apple Foundation Model on Private Cloud Compute"
(<https://developer.apple.com/videos/play/wwdc2026/319/>) and the WWDC26 machine-learning guide
(<https://developer.apple.com/wwdc26/guides/machine-learning/>), read 2026-11-14.

- API: `LanguageModelSession(model: PrivateCloudComputeLanguageModel())`; check `isAvailable` and fall back.
- 32K context (on-device is 4K on 26, 8K on 27 on newer devices). Reasoning levels `.light`, `.moderate`, `.deep`.
- `@Generable` structured output and `tools:` work as on-device.
- Eligibility: apps with fewer than 2 million first-time App Store downloads; apply on the developer site. Some blogs name an entitlement `com.apple.developer.private-cloud-compute`; Apple's pages don't.
- No token cost to the developer. A per-user daily quota counts against the user's iCloud account (iCloud+ raises it); `quotaUsage` reports it and Xcode can simulate the limits.
- Needs an Apple Intelligence device and a network connection. Callable from watchOS.
- Apple says request data is never stored and the claims are independently verified.
- The framework also accepts third-party providers (Claude, Gemini) through the Language Model protocol (session 339). Nothing about MCP.

- SDK check (Xcode 27.1, 2026-11-14): `PrivateCloudComputeLanguageModel` is `@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0)` and unavailable on tvOS.

## Decisions (Rick, 2026-11-14, round 1)

1. Build an in-app chat on PCC. Its tools mirror Powston's MCP read tools but run natively over the app's own API client and data. The app does not call Powston's MCP endpoint.
2. Read-only in v1: no tuning changes, battery holds or scheduled changes.
3. PCC for the chat, on-device for the short summaries, falling back to on-device when PCC isn't available. No bring-your-own Claude or Gemini. Rick: "our on-device use would benefit from improvement, possibly informed by PCC."
4. Rick already has PCC access: "Just need to add the entitlement."
5. iPhone only in v1.
6. "Powston" means the service; "the app" means our client (GLOSSARY.md). The feature name is still open.

## Decisions (Rick, 2026-11-14, round 2: "Agree on all")

7. When PCC isn't available (offline, out of quota, iOS 26), the chat answers single questions with the on-device model and the same tools, with a "limited mode" note.
8. Improving the on-device features: (i) the summaries get the same read-only tools in place of data pasted into the prompt; (ii) PCC answers serve as the reference when testing on-device prompts with the Evaluations framework. (iii) A PCC morning summary cached for offline reading is deferred.
9. v1 tools: site snapshot, battery SoC, current price, today's summary, upcoming actions, inverter status, command history, interval detail, daily history, tariff info, ROI, bill to date. Out: the P2P starter plan (P2P is gone in 1.3), the decision-code simulator, support history, release notes and problem reports. Drop any the API client can't serve yet.
10. The instructions carry Powston's rule: inverter telemetry isn't meter data and is never billing evidence. Bill to date is labeled an estimate.
11. Tools default to the site selected in the app; the user can name another.
12. One "Apple Intelligence" toggle; the footer will say that short summaries run on the iPhone and questions use Private Cloud Compute. Wording goes through house-style.md. The App Privacy label doesn't change.
13. Show Apple's nearing-limit note. At the limit, switch to limited mode and offer Apple's "Show options" button.

## Decisions (Rick, 2026-11-14, round 3: "Agree on all")

14. A Dashboard toolbar button opens the chat in a sheet; no new tab.
15. The chat works in Try Demo Mode on the sample data. Review notes will say so and that it uses Private Cloud Compute.
16. A conversation lasts until the sheet closes; nothing is stored or synced.
17. An empty chat offers three or four starter questions.
18. Button and sheet title "Ask"; placeholder "Ask about your battery, prices or savings".
19. Ships in 1.4 on the iOS 27 SDK, TestFlight first. 1.3 (14) ships as it is.

## Entitlement and profile (2026-11-14)

- Rick enabled Private Cloud Compute on the App ID `com.bollar.Powston` in the developer portal. The API lists it as capability `PRIVATE_CLOUD_COMPUTE`.
- Xcode 27.1 has no record of the entitlement key. A new App Store profile showed it: `com.apple.developer.private-cloud-compute = true`.
- New profile "Powston iOS AppStore 1.4" (5YLC36WSGT, IOS_APP_STORE, certificate WS9V8H6G44). The old "Powston iOS AppStore" (J74Q3DW9VR) predates the capability and stays untouched; `Scripts/tf_ship_ios.sh` now uses the 1.4 name.
- The key is in `Powston/Powston.entitlements`.
- Before Rick signed the pending agreement, the ASC API answered 403 `FORBIDDEN.REQUIRED_AGREEMENTS_MISSING_OR_EXPIRED` on every endpoint, including `GET /apps/{id}`.

Recipe to read a capability's entitlement key: create a profile for the App ID (`POST /profiles` with the bundleId and distribution certificate), base64-decode `profileContent`, `security cms -D -i file.mobileprovision`, then print `:Entitlements` with PlistBuddy.

## What's built (2026-11-14, first pass)

- `Powston/Services/AskTools.swift`: twelve read-only tools named after the MCP read tools: `list_sites`, `get_site_snapshot`, `get_price_forecast`, `get_upcoming_actions`, `get_inverter_status`, `get_today_summary`, `get_command_history`, `get_daily_history`, `get_interval_detail`, `get_tariff_info`, `get_roi`, `get_bill_to_date`. On-device limited mode gets four of them (snapshot, forecast, today, daily history) to fit its small context.
- `Powston/Services/AskAssistant.swift`: picks the model, keeps one PCC session per sheet, falls back to a fresh on-device session per question, tracks the quota and maps errors (iOS 27 `LanguageModelError`, iOS 26 `GenerationError`).
- `Powston/Views/AskView.swift`: the sheet, with starter questions, a limited-mode or nearing-limit banner with Apple's "Show options", and a stop button.
- `DashboardView`: an "Ask" toolbar button (leading), shown on iOS 26+ when the Settings toggle is on.
- `SettingsView` footer: "Summaries and explanations are written on your iPhone. Ask uses Apple's Private Cloud Compute, which Apple says doesn't store your data. When Private Cloud Compute isn't available, Ask answers on your iPhone."
- Debug simulator build passes with no warnings in the new files (Xcode 27.1). The button shows on the Dashboard in demo mode. The sheet and answers haven't been tried yet: that needs a device with Apple Intelligence on iOS 27.

Data map (from a read of the code, 2026-11-14):

- Live data (`api.data`) is for the selected inverter only. Prices are ¢/kWh, `rrp` is $/MWh, battery power is negative when charging, grid power is positive when exporting.
- Forecasts are 30-minute periods from `intervalTime`. `actionPattern` is decoded but unused and undocumented, so the tools don't present a plan. The controller decides every few minutes.
- Tools that can read another site without switching the app's selection: today, command history, interval detail (forced refresh, because the meter cache key uses the selected site), ROI and inverter status. Snapshot, forecast, daily history, tariff and bill to date are selected-site only and say so.
- Bill to date uses `fetchCurrentMonthSummary()` (to the last complete day, including supply). Today's figures come from 5-minute action records and exclude supply.
- `controllerHealthStatus` and `powstonServiceOnline` are never set outside demo mode, so the inverter tool asks `fetchRuntimeDiagnosis` per inverter.
- Demo mode stores no history, so the history tools return fixed sample figures headed "Demo mode: these are sample figures, not a real site."

## Build 15 on Rick's iPhone (2026-11-14)

- Rick asked "How did yesterday go?" and "Did we make money?" on his iPhone (iOS 27, airplane mode with Wi-Fi). Both answers showed "Something went wrong answering that. Please try again." No limited-mode banner appeared, so the session was on PCC and the error wasn't a `PrivateCloudComputeLanguageModel.Error`. The app didn't keep the error. Rick's guess: "Maybe a timeout?"
- The shipped IPA has `com.apple.developer.private-cloud-compute = true` (checked with `codesign -d --entitlements` on the box's export).
- Simulator findings:
  - Unsigned (`CODE_SIGNING_ALLOWED=NO`), FoundationModels stops the app: "FoundationModels/ErrorConversion.swift:140: Fatal error: Missing entitlement: com.apple.developer.private-cloud-compute".
  - Ad-hoc signed (`CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual PROVISIONING_PROFILE_SPECIFIER=`), PCC answers in demo mode with tools (the log shows the server model `instruct_server_v2`).
- The likely difference is real data. Daily history, ROI and bill to date make Powston API calls; daily history can make several. A slow tool probably made the whole response time out.
- Fixes after 15:
  - Every tool runs under a 15-second limit (`askLookup`). On timeout it tells the model the lookup timed out.
  - Every tool call is logged with its duration (Logger subsystem `com.bollar.Powston`, category `Ask`).
  - Any PCC failure other than a refusal or cancellation now answers the question on-device, and the next question tries PCC again with a fresh session.
  - Error notices show the error's own text in brackets, so testers can report it.
- Debug-only probe: launch with `-AskProbe "question"` to open Ask and ask it. Recipe:
  ```
  xcrun simctl launch --console-pty <sim> com.bollar.Powston -AskProbe "How did yesterday go?"
  xcrun simctl spawn <sim> log show --last 5m --info --debug --predicate 'subsystem == "com.bollar.Powston" AND category == "Ask"'
  ```

## Build 16 on Rick's iPhone (2026-11-14)

- Every question fails on PCC with `PrivateCloudComputeError 32031`, wrapped in `ModelManagerServices.InferenceError 2008`, then `ModelManagerError 1001`, then `FoundationModels.LanguageModelError -1`. The on-device fallback answered both questions.
- It fails the same way with airplane mode plus Wi-Fi and with Wi-Fi alone (there's no cell service where Rick is), so the network path isn't the cause.
- Rick: "The PCC approval is not restricted."
- The same request with the same tools and instructions works in the simulator, which uses this Mac's PCC access.
- 32031 isn't documented. Neighboring codes appear in user reports: 32033 alongside PCC token rate-limit log lines on iOS 27.0.1 (github.com/huamidev/GestaltX/issues/101), and 32080 with Siri failures (github.com/SkyBlue997/enableMacosAI/issues/81).
- On-device answers mixed the wholesale $/MWh in as a "peak" price and wrote "$15.7¢/kWh".

Changes in 17:
- The notice shows only the innermost error, e.g. "(Private Cloud Compute error 32031)". The full chain goes to the log.
- After the first PCC failure in a sheet, the app runs a check: a plain PCC request, then (if that works) one with our instructions but no tools. The notice reports each result.
- The snapshot labels the wholesale price "not what the household pays". The instructions say to write cents as 15.7¢/kWh, never with $, and to mention the wholesale price only if asked.

## Open items

- Try Ask on a device: PCC answers, limited mode (airplane mode), demo mode, the quota banner (Xcode scheme option "Simulate Apple Foundation Models Availability").
- On-device improvements (decision 8): give the summary services the tools, and set up Evaluations against PCC answers.
- Version 1.4 (build numbering, What to Test, review notes saying Ask uses PCC and works in demo mode).
- Model instructions say "Australian English spelling", as the existing services do. The UI strings are US English per house style.
