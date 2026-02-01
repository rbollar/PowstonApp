# Local Price Alerts Implementation

## Overview
The Powston app now supports **local price alerts** that notify users when the sell price reaches their desired threshold. These notifications are completely **FREE** and require no server infrastructure.

## Features

### ✅ What's Implemented

1. **Notification Permission Management**
   - Request permission from iOS
   - Check authorization status
   - Show clear UI when permissions needed

2. **Configurable Price Threshold**
   - Set custom sell price threshold (0-100¢)
   - Slider with 0.5¢ increments
   - Quick preset buttons: 30¢, 40¢, 50¢, 60¢
   - Shows current sell price for reference

3. **Smart Alert Delivery**
   - Only sends when sell price ≥ threshold
   - 30-minute cooldown between alerts (no spam!)
   - Works automatically with 5-minute refresh
   - Badge notification on app icon

4. **User Interface**
   - New "Price Alerts" section in Settings
   - Enable/disable toggle
   - Visual feedback for current price vs threshold
   - Permission request button if not authorized

## How It Works

### Flow Diagram
```
┌─────────────────────────────────────────────────────┐
│ 1. User enables Price Alerts in Settings           │
│    - Grants notification permission                │
│    - Sets threshold (e.g., 40¢/kWh)                │
└─────────────────────────────────────────────────────┘
                      ↓
┌─────────────────────────────────────────────────────┐
│ 2. App refreshes data every 5 minutes              │
│    - Fetches latest inverter data                  │
│    - Gets current sell price                       │
└─────────────────────────────────────────────────────┘
                      ↓
┌─────────────────────────────────────────────────────┐
│ 3. Check if sell price ≥ threshold                 │
│    - Yes: Send notification (if not sent recently) │
│    - No: Do nothing                                 │
└─────────────────────────────────────────────────────┘
                      ↓
┌─────────────────────────────────────────────────────┐
│ 4. User receives notification                       │
│    🚀 High Sell Price Alert!                       │
│    Sell price is 42.5¢/kWh (threshold: 40¢)       │
└─────────────────────────────────────────────────────┘
```

### Code Structure

```swift
// 1. NotificationManager - Handles all notification logic
NotificationManager.shared.requestPermission()
NotificationManager.shared.sendPriceAlert(sellPrice: 42.5, threshold: 40.0)

// 2. PowstonAPI - Checks prices after each fetch
func checkPriceAlert(_ sellPrice: Double) {
    // Checks settings and sends notification if needed
}

// 3. Settings UI - User configuration
@AppStorage("price_alerts_enabled") var priceAlertsEnabled: Bool
@AppStorage("sell_price_alert_threshold") var sellPriceThreshold: Double
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
│ Alert when sell price reaches: 40.0¢   │
│ [0¢ ────●────────────── 100¢]          │
│                                         │
│ Common thresholds:                      │
│ [30¢] [40¢] [50¢] [60¢]                │
│                                         │
│ ℹ️ Alerts won't repeat within 30 min   │
│                                         │
│ Current sell price:    12.5¢/kWh       │
└─────────────────────────────────────────┘
```

## User Experience

### Example Scenario:

**9:00 AM** - User sets threshold to 40¢
```
Settings → Price Alerts → Enable → Set 40¢
```

**2:15 PM** - Price hits 42¢
```
🚀 High Sell Price Alert!
Sell price is 42.5¢/kWh (threshold: 40.0¢)
```

**2:30 PM** - Price still at 45¢
```
(No notification - waiting 30 min cooldown)
```

**3:00 PM** - Price drops to 38¢
```
(No notification - below threshold)
```

**4:30 PM** - Price rises to 48¢
```
🚀 High Sell Price Alert!
Sell price is 48.0¢/kWh (threshold: 40.0¢)
(30+ minutes since last alert, so sent again)
```

## Technical Details

### Cooldown Logic
```swift
let lastAlert = UserDefaults.standard.double(forKey: "last_price_alert_time")
let now = Date().timeIntervalSince1970

// Wait at least 30 minutes (1800 seconds) between alerts
guard now - lastAlert > 1800 else { return }
```

### Notification Content
```swift
content.title = "🚀 High Sell Price Alert!"
content.body = "Sell price is 42.5¢/kWh (threshold: 40.0¢)"
content.sound = .default
content.badge = 1  // Shows badge on app icon
```

### Storage Keys
```swift
"price_alerts_enabled"           → Bool (default: false)
"sell_price_alert_threshold"     → Double (default: 40.0)
"last_price_alert_time"          → Double (timestamp)
```

## Limitations

### ⚠️ What Doesn't Work:
1. **App Must Be Active**: Won't notify if app is fully terminated
2. **5-Minute Delay**: Only checks every 5 minutes with auto-refresh
3. **Requires Backgrounding**: iOS may suspend background refresh

### ✅ What Does Work:
1. **App Active**: Notifications work perfectly
2. **App Backgrounded**: iOS usually allows background refresh for ~30 min
3. **No Cost**: Completely free, no server needed
4. **Battery Friendly**: Piggybacks on existing 5-min refresh

## Testing

### How to Test:

1. **Enable Alerts:**
   ```
   Settings → Price Alerts → Enable Notifications → Enable Price Alerts
   ```

2. **Set Low Threshold:**
   ```
   Set threshold to 0¢ (or below current price)
   ```

3. **Trigger Refresh:**
   ```
   Dashboard → Tap refresh button
   ```

4. **Check Notification:**
   ```
   Should receive notification immediately
   ```

5. **Test Cooldown:**
   ```
   Refresh again within 30 minutes → No notification
   Wait 30+ minutes → Refresh → Notification appears
   ```

### Debug Mode:
To test without waiting 30 minutes, temporarily change cooldown:
```swift
// In NotificationManager.sendPriceAlert()
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
- Threshold value (¢/kWh)
- Last alert timestamp
- **No data sent to server**

## Future Enhancements (Optional)

### Possible Additions:

1. **Multiple Thresholds**
   - Different alerts for different price ranges
   - "Very High" vs "High" alerts

2. **Buy Price Alerts**
   - Alert when buy price is low
   - Good time to charge battery

3. **Quiet Hours**
   - Don't send alerts during sleep hours
   - User-configurable time range

4. **Alert Sounds**
   - Custom notification sounds
   - Different sounds for different thresholds

5. **Notification History**
   - Log of past alerts
   - View alert history in app

6. **Smart Cooldown**
   - Longer cooldown if price stays high
   - Shorter if price fluctuates

### Example: Quiet Hours
```swift
@AppStorage("quiet_hours_enabled") var quietHoursEnabled: Bool
@AppStorage("quiet_start_hour") var quietStart: Double = 22.0  // 10 PM
@AppStorage("quiet_end_hour") var quietEnd: Double = 7.0       // 7 AM

func isQuietHours() -> Bool {
    let hour = Calendar.current.component(.hour, from: Date())
    if quietStart < quietEnd {
        return hour >= Int(quietStart) && hour < Int(quietEnd)
    } else {
        return hour >= Int(quietStart) || hour < Int(quietEnd)
    }
}
```

## Cost Analysis

### Complete Cost Breakdown:

| Component | Cost |
|-----------|------|
| iOS UserNotifications API | **FREE** |
| Local notification delivery | **FREE** |
| No server required | **FREE** |
| No third-party services | **FREE** |
| No ongoing fees | **FREE** |
| **TOTAL** | **$0.00** |

### Comparison to Remote Push:
- Local: **$0/month**
- Remote with server: **$5-10/month**
- **Savings: 100%** ✅

## Summary

✅ **Implemented:** Local price alerts with threshold configuration  
✅ **Cost:** Completely free  
✅ **Setup Time:** Already done!  
✅ **User Control:** Full control over threshold and enable/disable  
✅ **Smart Delivery:** 30-minute cooldown prevents spam  
✅ **Works With:** Existing 5-minute auto-refresh  
✅ **Privacy:** All data stored locally, no server needed  

The feature is ready to use! Users just need to:
1. Go to Settings
2. Enable notifications when prompted
3. Turn on Price Alerts
4. Set their desired threshold
5. Enjoy automatic alerts when prices are high! 🚀
