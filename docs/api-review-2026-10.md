# API / retailer review — 2026-10-02

Status: review done and the changes below are built (iOS simulator build succeeded
2026-10-02) but uncommitted and not run on a device. Tests were not run.

## Scope and decisions

- Rick's request: "Review this project against the current powston api and code. make sure
  that all p2p is gone. See if there are any featuers that we should add. Make sure we
  support Amber as well as localvolts."
- Asked which repo, Rick chose: "Documents/Powston (Recommended)" — this repo, not the
  Dec 2025 scaffold in `Documents/PowstonApp` (one commit `f9e8b49`; no P2P, Amber, or
  Localvolts code; its only call, `GET /api/inverters/{id}/data`, returns 404).
- For live checks Rick said: "A powston api key is probably available to you on Harriet
  root@harriet /data/powston". The key is hardcoded as the `POWSTON_API_KEY` default in
  `/data/powston/data_collector.py:48`. One read-only run was made from harriet; a second was
  blocked by the Claude Code permission classifier.

## P2P

Changed 2026-10-02 (strings and comments only):

| File | Change |
|---|---|
| `Powston/Models/InverterAction.swift` | labels "P2P Exp"/"P2P Imp" → "Ltd Exp"/"Ltd Imp" |
| `Powston/Views/DashboardView.swift` | same label, and the `actionCategory` matches |
| `Powston/Views/Components/RetailerComparisonView.swift` | "Wholesale/P2P pricing" → "Wholesale pricing" |
| `ActionsTableView.swift`, `DecisionsView.swift`, `ActionRecord+InverterAction.swift` | comments |

"Ltd" was picked to keep the label at 7 characters for the table columns.

Deliberately kept:

- `LVSettlementRecord.swift`, `PowstonDataStore+LVSettlement.swift`,
  `SavingsAnalysisCalculator.swift:347`: `matchEnergy`/`matchAmount`, `energy_sold_p2p_kwh`,
  `p2p_matched_revenue`. Real Localvolts settlement data; removing it changes LV revenue
  totals and a SQLite schema.
- `PowstonApp.swift:39-42`, `PowstonDataStore.swift:1793-1798`: one-time cleanup of old P2P
  blobs and tables.
- `lvclient.py` (git-ignored): Python tool that still fetches P2P trades.
- `LocalVoltsSetupView.swift:227` still says "Your trade data will be preserved."

No P2P references in the Watch, TV, widget, or Top Shelf targets or in `project.pbxproj`.
The Powston API still has P2P (`/api/p2p_settings/{site_id}`, `/api/p2p_guide/{site_id}`,
`P2P_*` tuning fields); the app uses none of it.

## Powston API conformance (spec fetched 2026-10-02)

Every Powston path the app calls exists in the spec.

- **`amber_key` is gone from `/api/sites` — confirmed live 2026-10-02.** For both sites (1 and
  65) the list response has no `amber_key`, `localvolts_key`, `mqtt_password`, or
  `pvoutput_api_key`. It does have `active_retailer` (site 1 `localvolts`, site 65 `amber`),
  `amber_site_id` (set for 65), and `localvolts_partner_id` (set for 1).
  The app only ever loads sites from `/api/sites` (`PowstonAPI+Sites.swift:35`), so
  `site.amberKey` is always nil and the "Key provided by Powston" path
  (`AmberService.swift:62`, `AmberViews.swift:29`) is dead: Amber needs a manual key.
- `GET /api/site/1` does return the secret fields (`localvolts_key`, `mqtt_password`,
  `pvoutput_api_key` present; `amber_key` empty for that LV site). Whether `GET /api/site/65`
  returns `amber_key` was **not tested** (blocked run).
- **`meter_records` query names.** The app sends `from=`/`to=`
  (`PowstonAPI+MeterRecords.swift:127, 274`, `PowstonTV/TVAPI.swift:548`); the spec documents
  `start_date`/`end_date`. Live, both forms returned data for site 1 and no params returned
  nothing, so `from`/`to` is honored. Record counts were not compared (blocked run).
- `updateSite` posts `pvoutput_api_key` (`PowstonAPI+Sites.swift:96`); the spec's `SiteUpdate`
  does not list that field. Not tested.
- `active_retailer` is one of `amber`, `localvolts`, `flowpower`, `globird`, `other`.

## Amber and Localvolts support

Works for both: prices, forecasts, history, and overrides come from Powston and are
retailer-agnostic. Watch, TV, and widgets have no retailer-specific code.

Gaps (1-4 fixed 2026-10-02, see "Built"):

1. Amber automatic key is dead (above). `AmberSetupView` tells the user "Powston has no Amber
   key for this site" even when Powston has one.
2. `RetailerComparisonView` is Localvolts-only ("Your LocalVolts Costs", "LocalVolts isn't on
   EME") but is linked for every site from `ProfitIntelligenceView.swift:543`, and falls back
   to Powston data labeled as Localvolts (`RetailerComparisonView.swift:292`). Amber sites see
   Localvolts wording. Amber usage/cost data is fetched but only shown on the Prices tab.
3. Localvolts features are gated on stored credentials, not `active_retailer`
   (`LocalVoltsService.swift:332`, `HistoryView.swift:132, 1345`). A site that moved to Amber
   but still has LV credentials keeps running the daily LV sync.
4. `MapViews.swift:150, 1082, 1092` infer the retailer from key/partner fields, Localvolts
   first, and ignore `active_retailer`.
5. Demo site hardcodes `activeRetailer: "localvolts"` (`PowstonAPI+InverterData.swift:237`).

## Feature candidates (in the spec, unused by the app)

- `GET/POST/DELETE /api/scheduled_changes/{site_id}` — schedule a hold or tuning change.
- `GET /api/market_roi/{inverter_id}` — arbitrage / solar time-shift / self-supply breakdown
  from settled meter data; fits the Profit Intelligence Hub.
- `POST /api/auth/mobile/request` + `/exchange`, `GET /api/auth/devices` — email-link sign-in
  with a per-device key, replacing the pasted API key.
- Tuning: the app sends 8 fields (`min_soc`, `max_soc`, `c_rating`, `BATTERY_SOC_NEEDED`,
  `BATTERY_SOC_AC`, `ALWAYS_IMPORT_SOC`, `DEFAULT_EXPORT`, `IMPORT_FACTOR`). The spec adds
  `MIN_EXPORT_MARGIN`, `GOOD_SUN_HOUR`, the `OVERNIGHT_LOAD_*` model, `EV_*` charger fields,
  `GRID_MEASURE`, and an audit `reason`.
- `GET /api/inverter_actions_summary/{inverter_id}` — action list without the heavy `values`
  payload; the app pages the full `/api/inverter_actions`.
- `GET /api/diagnose/runtime/{inverter_id}` — single-verdict stale-data diagnosis for the
  controller health screen.
- `GET /api/fleet/latest_action` — freshest action across sites; cheap poll for widgets.
- Site fields now returned: `control_state`, `subscription_status`, `readiness_hold`,
  `support_*` contact details.

## Recipes

```bash
# Spec (no auth)
curl -sS -o openapi.json https://app.powston.com/api/openapi.json
# Sources are iCloud-evicted; materialize before grepping
brctl download Powston; brctl download PowstonTV
# P2P sweep
grep -rn -i "p2p" Powston PowstonWidget PowstonTV "PowstonWatch Watch App" \
  PowstonWatchWidgetExtension --include="*.swift"
# Endpoints the app calls
grep -rn -E "/api/[a-z_]+" Powston PowstonWidget PowstonTV "PowstonWatch Watch App" --include="*.swift"
# Live check (from harriet; Cloudflare needs a browser User-Agent)
curl -s -H "Authorization: Bearer $POWSTON_API_KEY" -A "Mozilla/5.0 Safari/605.1.15" \
  https://app.powston.com/api/sites | python3 -c 'import json,sys; [print(s["id"], s.get("active_retailer"), "amber_key" in s) for s in json.load(sys.stdin)]'
```

## Built 2026-10-02

Rick: "Build the missing features. You are authorized to use the call from harriet. I don't
care if they're named P2P."

| Change | Files |
|---|---|
| Amber key: `fetchSites` swaps in `GET /api/site/{id}` for Amber sites, which still returns `amber_key` | `PowstonAPI+Sites.swift` (`withRetailerKeys`, `fetchSiteDetail`) |
| `Site.retailerName` / `Site.isLocalVoltsSite`, driven by `active_retailer` with field fallback | `Site.swift`, used in `MapViews.swift` |
| Localvolts daily sync skipped when `active_retailer` is another retailer | `LocalVoltsService.swift` + 3 callers |
| Retailer comparison: LV wording and LV settlement only for LV sites; others get "Your Energy Costs" from the Powston summary | `RetailerComparisonView.swift` |
| Battery ROI screen (`/api/market_roi`), periods yesterday / 7 / 30 days, linked from Profit Intelligence | new `PowstonAPI+MarketROI.swift`, `MarketROIView.swift`; `ProfitIntelligenceView.swift`; `project.pbxproj` |
| Tuning: `MIN_EXPORT_MARGIN`, `GOOD_SUN_HOUR`, shown only when the site returns them | `PowstonAPI+TrainingParameters.swift`, `TrainingParametersView.swift` |
| Data Diagnosis section (`/api/diagnose/runtime`) per inverter | `PowstonAPI+ControllerHealth.swift`, `ControllerHealthView.swift` |

Live evidence (harriet, 2026-10-02):

- `GET /api/site/65` returns `amber_key` (36 chars) and every field type matches the `Site` model.
- `meter_records`: `from=2026-09-22&to=2026-09-23` → 576 records (inclusive);
  `start_date`/`end_date` for the same dates → 288 (end-exclusive). The app's `from`/`to` is fine.
- Site 65 now has one inverter, 73009 (Sungrow Logger1000), not 43923/43924.
- `market_roi/73009` 2026-09-24..30: arbitrage $2.81, solar shift $13.56, self-supply $81.62.
- `training_parameters/65` returns `MIN_EXPORT_MARGIN` but not `GOOD_SUN_HOUR`.
- Server action names include `export_p2p` (seen on site 1).

Not built, and why:

- **Scheduled changes**: `ScheduleRequest.kind` values are undocumented and site 65's list is
  empty, so neither the request nor the item shape is known. Needs one example from Powston.
- **Email-link sign-in** (`/api/auth/mobile/*`): how the emailed token reaches the app (URL
  scheme / universal link) is not in the spec.
- **`inverter_actions_summary`**: the actions table needs `optimal_discharging` from the full
  `values` payload, which the summary omits.

Build recipe: `xcodebuild` hangs when the project is opened from the iCloud folder. Copy the
sources to a local folder (`rsync -a --exclude build --exclude .git ./ /tmp/PowstonCopy/`) and run
`xcodebuild build -project Powston.xcodeproj -scheme Powston -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO` there.

## Open items

- Commit; run on a device and check the Battery ROI, Controller Health, and Amber setup screens.
- Get `kind` values and an example item for scheduled changes; get the mobile sign-in link format.
- `IMPORT_FACTOR` is a float in the API but `Int?` in the app; a fractional value would fail the decode.
- The label rename "P2P Exp/Imp" → "Ltd Exp/Imp" can be reverted if preferred (Rick doesn't mind either name).
