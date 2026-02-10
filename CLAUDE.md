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

### Active Features (as of Feb 2026)
- **Profit Intelligence Hub** - Peak Export Analysis, Decision Efficiency tracking, Export Replacement analysis
- **Counterparty Tracking** - P2P trading identification, smart business name classification, manual overrides
- **LocalVolts API Monitoring** - Schema change detection, version tracking

### Recent Completions
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

### LocalVolts Integration
- **No CSV export**: LocalVolts does not provide CSV export of any kind
- **No historical API**: Trade information is NOT available through their API
- **WebSocket only returns today**: The Socket.IO identity response only contains current day's P2P trades
- **Historical data**: Only available through the web portal (would require screen scraping)
- **Date convention**: LocalVolts WebSocket APIs return actual trading dates, NOT settlement dates (T+1). Use dates as-is without adjustment. This applies to both Identity response (QtyReport) and ContractTable.
- **Timezone**: Always AEST (Australia/Brisbane, UTC+10) - same as AEMO
- **Protocol**: Socket.IO v2 (EIO=3) with `suffix=` query parameter required for identification

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
- **P2P price wars are counterproductive**: All sellers within a buyer's price range get equal allocation — community coordination beats undercutting
- **100% charge remains optimal** in current price environment despite occasional losing trades
- Battery management script uses 15-level priority system (P100 emergency drain → P1 default auto)

## Working With This Codebase
- Validate algorithms in Python first, then port to Swift
- Provide complete code context before making changes
- Ask for current files before editing — project files in chat may be stale
- When adding Apple Intelligence features, use fact-based prompting to avoid hallucinations
