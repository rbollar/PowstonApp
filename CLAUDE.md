# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Powston is a multi-platform Swift app for smart energy management and battery inverter monitoring. It connects to the Powston API to display real-time energy data, price forecasts, and allows manual control of inverter modes.

## Build Commands

```bash
# Build iOS app
xcodebuild -scheme Powston -configuration Debug

# Build for iOS simulator
xcodebuild -scheme Powston -destination 'platform=iOS Simulator,name=iPhone 15'

# Build Watch app
xcodebuild -scheme "PowstonWatch Watch App" -configuration Debug

# Build tvOS app
xcodebuild -scheme PowstonTV -configuration Debug

# Run tests
xcodebuild test -scheme Powston

# Run specific test target
xcodebuild test -scheme Powston -only-testing PowstonTests
```

## Target Structure

- **Powston** - Main iOS app
- **PowstonWidget/PowstonWidgetExtension** - iOS home screen and lock screen widgets
- **PowstonWatch Watch App** - WatchOS companion app
- **PowstonWatchWidgetExtension** - Watch complications
- **PowstonTV** - tvOS app for Apple TV
- **PowstonTopShelf** - tvOS top shelf extension

## Architecture

### Service Layer
The API is split into extensions for maintainability:
- `PowstonAPI.swift` - Core API client with `@Published` state
- `PowstonAPI+Sites.swift` - Site discovery
- `PowstonAPI+InverterData.swift` - Real-time inverter data
- `PowstonAPI+MeterRecords.swift` - Historical consumption
- `PowstonAPI+Actions.swift` - Action history
- `PowstonAPI+Overrides.swift` - Manual override commands

### Data Persistence
- **GRDB (SQLite)** for local storage at `Database/powston_data.sqlite` in the app group container
- Delta syncing: only fetches new data since last sync
- In-memory caches with TTL (meter records: 60min, actions: 5min)

### Cross-Platform Data Sharing
All targets share data via App Group: `group.com.bollar.powston`
- `SharedConstants.swift` defines common keys and identifiers
- UserDefaults synced across iOS/Watch/Widget via app group
- Database located in shared container

### Refresh Strategy (SmartRefreshManager)
Polling aligned to AEMO's 5-minute dispatch intervals:
- Target: :35 past each 5-minute mark
- Retry every 10 seconds if data not ready (max 2 minutes)
- Confirmation poll 30 seconds after successful update
- Random 0-10 second jitter to spread server load

## Key Data Models

**InverterResponse** - Real-time data from API:
- `batterySoc`, `batteryPower`, `solarPower`, `gridPower`, `housePower`
- `buyPrice`, `sellPrice`, `rrp` (current prices)
- `buyForecast`, `sellForecast` (30-period forecasts, 30 min each)
- `intervalTime` - ISO8601 timestamp for forecast start
- `action`, `reason` - Current mode and decision explanation

**ManualAction** - Override commands:
- `mode` - Target inverter mode
- `startTime`, `endTime` - Override duration
- Status tracked: pending → scheduled → active → completed

## API Details

Base URL: `https://app.powston.com`

Key endpoints:
- `GET /api/inverter_params/{inverterId}` - Real-time data
- `GET /api/sites` - List user's sites
- `POST /api/manual-actions` - Create override
- `DELETE /api/manual-actions/{id}` - Cancel override

Authentication: Bearer token in Authorization header

## Important Implementation Details

### Time Handling
- All forecasts align to `interval_time` from API
- Each forecast period is 30 minutes
- Use `posebonstTimezone()` for timezone-aware calculations

### Multi-Inverter Support
- `RuntimeParamsContainer` handles nested inverter data
- SOC is weighted average across batteries
- Power values are summed across inverters

### Price Alerts
- Configurable buy/sell thresholds with above/below options
- 30-minute throttling to prevent notification spam
- Storage keys: `sell_price_alert_type`, `buy_price_alerts_enabled`, etc.

### Demo Mode
Toggle `demo_mode_enabled` in Settings for testing without API calls.

## Current Development Focus

### Active Features (as of Aug 2026)
- **Profit Intelligence Hub** - Peak Export Analysis, Decision Efficiency tracking, Export Replacement analysis
- **Amber Electric integration** - Direct Amber API (prices/forecasts/usage); key auto-sourced from Powston site `amber_key`, manual override in Settings (app-group UserDefaults, not Keychain)

### Recent Completions
- **P2P feature removal (Aug 2026)** — all P2P trading UI/analysis and the LV trading layer (orders, market overview, counterparties, contract snapshots) deleted. LV retailer core kept: credentials, settlement/cashflow sync, history gap-fill, retailer comparison. Orphaned SQLite tables (p2p_*, lv_orders, lv_market_contracts, lv_interval_trades, lv_*_snapshots) are left in place but no longer created or read.
- App Store naming resolved: "Energy Controller for Powston"
- Apple Watch standalone support
- Live Activities and Dynamic Island integration
- Apple Intelligence summaries integration

## Architectural Decisions

### Data Flow Principles
1. **Cache-through pattern**: Finalized historical data served from SQLite; recent/live data fetched from API
2. **Single source of truth**: Use `meter_records` for financial calculations (not `day_rates` or `tariff_rates` which can be inconsistent)
3. **All calculations must match Powston web interface exactly** - reconcilable, transparent math

### API Endpoint Notes
- Different endpoints (`day_rates` vs `tariff_rates` vs `meter_records`) can return inconsistent data
- Always verify which endpoint is authoritative for the specific use case

### LocalVolts Integration (retailer core only — P2P trading code removed Aug 2026)
- Rick no longer has LV access (switched to Amber July 2026); LV code retained for other sites (e.g. site 1) — leave it alone
- **Settlement only**: the Socket.IO client now parses only settlement data (Identity + QtyReport); trade/order/market parsing was removed with the P2P feature
- **Timezone**: Always AEST (Australia/Brisbane, UTC+10) - same as AEMO
- **Protocol**: Socket.IO v2 (EIO=3) with `suffix=` query parameter required for identification
- **Date convention**: LocalVolts WebSocket APIs return actual trading dates, NOT settlement dates (T+1). Use dates as-is.

### Amber Electric Integration
- Base URL `https://api.amber.com.au/v1`, Bearer token. OpenAPI spec at `https://app.amber.com.au/swagger.json`
- Endpoints: `/sites`, `/sites/{id}/prices`, `/sites/{id}/prices/current?next=N&resolution=5|30`, `/sites/{id}/usage?startDate&endDate`
- Prices in c/kWh incl. GST; feedIn perKwh is NEGATIVE when you are paid — display abs()
- Usage `kwh` negative for generation; `cost` in cents, negative = earnings; `quality` estimated|billable (finalized ~T+1)
- Key sources: Powston site `amber_key`/`amber_site_id` (auto), or manual override in `amber_api_key` (app-group UserDefaults; deliberately NOT Keychain)
- Rick's Amber site: 5-min billing intervals, channels E1 (general) + B1 (feedIn), network Energex, active from 2026-07-02

### Timezone Handling
- Use `Australia/Sydney` for NSW users, `Australia/Brisbane` for QLD
- Rick's system is in Queensland (no DST)

### SwiftUI Patterns
- `@MainActor` required for ObservableObject classes to ensure thread safety
- Protocol-based architecture with shared components across platforms
- `AppleIntelligenceIndicator` is defined in shared Helpers — don't redeclare

## Hardware Context (Rick's Test System)
- Dual Sungrow SH10RT inverters
- 101.2 kWh battery capacity
- 30 kW solar array
- Location: Sunshine Coast, Queensland

## Key Insights
- **100% charge remains optimal** in current price environment despite occasional losing trades
- Battery management script uses 15-level priority system (P100 emergency drain → P1 default auto)
- Powston API `sites` response now includes `active_retailer` ("amber" | "localvolts" | ...), `amber_key`, `amber_site_id`, `subscription_status`, `control_state`, EV charger fields — the app's Site model decodes the retailer/amber fields

## Working With This Codebase
- Validate algorithms in Python first, then port to Swift
- Provide complete code context before making changes
- Ask for current files before editing — project files in chat may be stale
- When adding Apple Intelligence features, use fact-based prompting to avoid hallucinations
