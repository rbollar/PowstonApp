# Local Price Alerts Implementation

## Overview
The Powston app now supports **local price alerts** that notify users when buy or sell prices reach their desired thresholds. These notifications are completely **FREE** and require no server infrastructure.

## Features

### ✅ What's Implemented

1. **Notification Permission Management**
   - Request permission from iOS
   - Check authorization status
   - Show clear UI when permissions needed

2. **Configurable Price Thresholds**
   - **Sell Price Alerts**: Alert when price goes above OR below threshold
   - **Buy Price Alerts**: Alert when price goes above OR below threshold
   - Set custom thresholds (0-100¢) with 0.5¢ increments
   - Quick preset buttons for common values
   - Shows current prices for reference
   - Independent enable/disable for each alert type

3. **Smart Alert Delivery**
   - Separate alerts for buy and sell prices
   - Configurable above/below conditions
   - 30-minute cooldown between alerts of the same type (no spam!)
   - Works automatically with 5-minute refresh
   - Badge notification on app icon

4. **User Interface**
   - "Price Alerts" section in Settings
   - Master enable/disable toggle for all alerts
   - Sell Price section with above/below picker
   - Buy Price section with independent enable toggle and above/below picker
   - Visual feedback for current price vs threshold
   - Permission request button if not authorized

## How It Works

### Flow Diagram
```
┌─────────────────────────────────────────────────────┐
│ 1. User enables Price Alerts in Settings           │
│    - Grants notification permission                │
│    - Sell: Alert when above 40¢/kWh                │
│    - Buy: Alert when below 15¢/kWh                 │
└─────────────────────────────────────────────────────┘
                      ↓
┌─────────────────────────────────────────────────────┐
│ 2. App refreshes data every 5 minutes              │
│    - Fetches latest inverter data                  │
│    - Gets current buy and sell prices              │
└─────────────────────────────────────────────────────┘
                      ↓
┌─────────────────────────────────────────────────────┐
│ 3. Check conditions                                 │
│    - Sell price ≥ threshold (if above selected)    │
│    - Sell price ≤ threshold (if below selected)    │
│    - Buy price ≤ threshold (if below selected)     │
│    - Buy price ≥ threshold (if above selected)     │
└─────────────────────────────────────────────────────┘
                      ↓
┌─────────────────────────────────────────────────────┐
│ 4. User receives notifications                      │
│    🚀 High Sell Price Alert!                       │
│    Sell price is 42.5¢/kWh (threshold: 40¢)       │
│                                                     │
│    💰 Low Buy Price Alert!                         │
│    Buy price is 12.3¢/kWh (threshold: 15¢)        │
└─────────────────────────────────────────────────────┘
```

### Code Structure

```swift
// 1. PriceAlertType - Defines alert conditions
enum PriceAlertType: String, Codable {
    case above
    case below
}

// 2. NotificationManager - Handles all notification logic
NotificationManager.shared.sendPriceAlert(sellPrice: 42.5, threshold: 40.0)
NotificationManager.shared.sendBuyPriceAlert(buyPrice: 12.3, threshold: 15.0)

// 3. PowstonAPI - Checks prices after each fetch
func checkPriceAlert(_ sellPrice: Double, _ buyPrice: Double) {
    // Checks settings and sends notifications if needed
}

// 4. Settings UI - User configuration
@AppStorage("price_alerts_enabled") var priceAlertsEnabled: Bool
@AppStorage("sell_price_alert_threshold") var sellPriceThreshold: Double
@AppStorage("sell_price_alert_type") var sellPriceAlertType: PriceAlertType
@AppStorage("buy_price_alerts_enabled") var buyPriceAlertsEnabled: Bool
@AppStorage("buy_price_alert_threshold") var buyPriceThreshold: Double
@AppStorage("buy_price_alert_type") var buyPriceAlertType: PriceAlertType
```

## Settings UI

### When Notifications Not Enabled:
```
┌─────────────────────────────────────────┐
│ Price Alerts                            │
├─────────────────────────────────────────┤
│ 🔕 Notifications not enabled            │
│                                         │
│ [Enable Notifications]                  │
│                                         │
│ Allow notifications to receive price   │
│ alerts                                  │
└─────────────────────────────────────────┘
```

### When Enabled:
```
┌─────────────────────────────────────────┐
│ Price Alerts                            │
├─────────────────────────────────────────┤
│ Enable Price Alerts        ✓ ON         │
│                                         │
│ ━━━ Sell Price Alerts ━━━               │
│ [Above] [Below]  ← Selected: Above      │
│                                         │
│ Alert when above: 40.0¢/kWh             │
│ [0¢ ────●────────────── 100¢]          │
│                                         │
│ Common thresholds:                      │
│ [20¢] [30¢] [40¢] [50¢]                │
│                                         │
│ Current sell price:    12.5¢/kWh       │
│                                         │
│ ━━━ Buy Price Alerts ━━━                │
│ Enable Buy Price Alerts    ✓ ON         │
│ [Above] [Below]  ← Selected: Below      │
│                                         │
│ Alert when below: 15.0¢/kWh             │
│ [0¢ ────●────────────── 100¢]          │
│                                         │
│ Common thresholds:                      │
│ [10¢] [15¢] [20¢] [25¢]                │
│                                         │
│ Current buy price:     18.2¢/kWh       │
│                                         │
│ ℹ️ Alerts won't repeat within 30 min   │
└─────────────────────────────────────────┘
```

## User Experience

### Example Scenario:

**9:00 AM** - User configures alerts
```
Settings → Price Alerts → Enable
Sell: Alert when ABOVE 40¢
Buy: Alert when BELOW 15¢
```

**2:15 PM** - Sell price hits 42¢
```
🚀 High Sell Price Alert!
Sell price is 42.5¢/kWh (threshold: 40.0¢)
```

**2:30 PM** - Sell price still at 45¢
```
(No notification - waiting 30 min cooldown)
```

**3:00 PM** - Buy price drops to 12¢
```
💰 Low Buy Price Alert!
Buy price is 12.3¢/kWh (threshold: 15.0¢)
(Different alert type, so sent immediately)
```

**4:30 PM** - Sell price rises to 48¢
```
🚀 High Sell Price Alert!
Sell price is 48.0¢/kWh (threshold: 40.0¢)
(30+ minutes since last sell alert, so sent again)
```

## Technical Details

### Alert Types

#### Sell Price Alerts
- **Above**: Alert when sell price goes above threshold
  - Use case: Know when it's profitable to export to grid
  - Icon: 🚀 High Sell Price Alert!
  - Color: Green
  
- **Below**: Alert when sell price drops below threshold
  - Use case: Know when export becomes less profitable
  - Icon: ⚠️ Low Sell Price Alert
  - Color: Orange

#### Buy Price Alerts
- **Above**: Alert when buy price goes above threshold
  - Use case: Know when importing from grid is expensive
  - Icon: ⚠️ High Buy Price Alert
  - Color: Red
  
- **Below**: Alert when buy price drops below threshold
  - Use case: Know when it's cheap to charge battery from grid
  - Icon: 💰 Low Buy Price Alert!
  - Color: Blue

### Cooldown Logic
```swift
// Separate cooldowns for buy and sell alerts
let lastSellAlert = UserDefaults.standard.double(forKey: "last_sell_price_alert_time")
let lastBuyAlert = UserDefaults.standard.double(forKey: "last_buy_price_alert_time")
let now = Date().timeIntervalSince1970

// Wait at least 30 minutes (1800 seconds) between alerts of same type
guard now - lastAlert > 1800 else { return }
```

### Notification Content
```swift
// Sell price above threshold
content.title = "🚀 High Sell Price Alert!"
content.body = "Sell price is 42.5¢/kWh (threshold: 40.0¢)"

// Sell price below threshold
content.title = "⚠️ Low Sell Price Alert"
content.body = "Sell price is 18.5¢/kWh (threshold: 20.0¢)"

// Buy price below threshold
content.title = "💰 Low Buy Price Alert!"
content.body = "Buy price is 12.3¢/kWh (threshold: 15.0¢)"

// Buy price above threshold
content.title = "⚠️ High Buy Price Alert"
content.body = "Buy price is 45.0¢/kWh (threshold: 40.0¢)"
```

### Storage Keys
```swift
"price_alerts_enabled"           → Bool (default: false)
"sell_price_alert_threshold"     → Double (default: 40.0)
"sell_price_alert_type"          → String (default: "above")
"buy_price_alerts_enabled"       → Bool (default: false)
"buy_price_alert_threshold"      → Double (default: 15.0)
"buy_price_alert_type"           → String (default: "below")
"last_sell_price_alert_time"     → Double (timestamp)
"last_buy_price_alert_time"      → Double (timestamp)
```

## Use Cases

### High Sell Price Alert (Above)
**When:** Sell price goes above 40¢
**Action:** Export excess solar to grid for maximum profit
**Notification:** 🚀 High Sell Price Alert!

### Low Sell Price Alert (Below)
**When:** Sell price drops below 20¢
**Action:** Stop exporting, keep energy for later
**Notification:** ⚠️ Low Sell Price Alert

### Low Buy Price Alert (Below)
**When:** Buy price drops below 15¢
**Action:** Good time to charge battery from grid
**Notification:** 💰 Low Buy Price Alert!

### High Buy Price Alert (Above)
**When:** Buy price goes above 40¢
**Action:** Avoid importing, use battery instead
**Notification:** ⚠️ High Buy Price Alert

## Testing

### How to Test:

1. **Enable Alerts:**
   ```
   Settings → Price Alerts → Enable Notifications → Enable Price Alerts
   ```

2. **Set Test Thresholds:**
   ```
   Sell: Above, threshold below current price
   Buy: Below, threshold above current price
   ```

3. **Trigger Refresh:**
   ```
   Dashboard → Tap refresh button
   ```

4. **Check Notifications:**
   ```
   Should receive notifications immediately
   ```

5. **Test Cooldown:**
   ```
   Refresh again within 30 minutes → No notifications
   Wait 30+ minutes → Refresh → Notifications appear
   ```

### Debug Mode:
To test without waiting 30 minutes, temporarily change cooldown:
```swift
// In NotificationManager methods
// Change this line:
guard now - lastAlert > 1800 else { return }  // 30 minutes

// To this (for testing only):
guard now - lastAlert > 60 else { return }  // 1 minute
```

## Privacy & Permissions

### What Users See:

**First Time:**
```
"Powston" Would Like to Send You Notifications
Notifications may include alerts, sounds, and icon badges.

[Don't Allow]  [Allow]
```

**iOS Settings:**
```
Settings → Notifications → Powston
→ Allow Notifications: ON
→ Sounds: ON
→ Badges: ON
```

### Data Stored Locally:
- Alert preferences (enabled/disabled)
- Threshold values (¢/kWh)
- Alert types (above/below)
- Last alert timestamps
- **No data sent to server**

## Summary

✅ **Implemented:** Both buy and sell price alerts with above/below thresholds  
✅ **Cost:** Completely free  
✅ **Setup Time:** Already done!  
✅ **User Control:** Full control over thresholds, types, and enable/disable  
✅ **Smart Delivery:** 30-minute cooldown per alert type prevents spam  
✅ **Works With:** Existing 5-minute auto-refresh  
✅ **Privacy:** All data stored locally, no server needed  
✅ **Flexible:** 4 different alert scenarios supported  

The feature is ready to use! Users can:
1. Go to Settings
2. Enable notifications when prompted
3. Turn on Price Alerts
4. Configure sell price alerts (above/below threshold)
5. Optionally enable buy price alerts (above/below threshold)
6. Enjoy automatic alerts when conditions are met! 🚀💰
