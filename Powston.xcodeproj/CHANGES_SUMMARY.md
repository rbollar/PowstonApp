# Changes Summary - December 27, 2025

## Overview
Three main improvements have been made to the Powston app:

1. **API Configuration in Drawer** - Cleaned up settings UI
2. **Fixed Inverter ID Display** - No more comma formatting
3. **Enhanced Price Alerts** - Buy and sell pricing with above/below thresholds

---

## 1. API Configuration in Collapsible Drawer

### What Changed
The API Configuration section in Settings is now collapsible using a `DisclosureGroup`.

### Before
```
Settings
├─ Appearance
├─ Demo Mode
├─ Peak Hours
├─ Price Alerts
├─ API Configuration (always visible)
│   ├─ API Key field
│   ├─ How to get API key
│   ├─ Connect & Discover button
│   └─ Debug info
├─ Select Site (separate section)
└─ Select Inverter (separate section)
```

### After
```
Settings
├─ Appearance
├─ Demo Mode
├─ Peak Hours
├─ Price Alerts
└─ API Configuration
    └─ [Expand] API Key & Connection
        ├─ API Key field
        ├─ How to get API key
        ├─ Connect & Discover button
        ├─ Debug info
        ├─ Select Site (nested inside)
        └─ Select Inverter (nested inside)
```

### Benefits
- Cleaner UI - API setup is hidden until needed
- All API-related settings in one collapsible section
- Less scrolling required
- Better organization for first-time setup

---

## 2. Fixed Inverter ID Display

### What Changed
The selected inverter ID now displays without comma formatting.

### Before
```
Status
├─ Connected
└─ Selected Inverter: #43,924
```

### After
```
Status
├─ Connected
└─ Selected Inverter: #43924
```

### Technical Change
```swift
// Before
Text("#\(api.selectedInverterId)")

// After
Text("#\(String(api.selectedInverterId))")
```

### Why This Matters
- IDs should be displayed as plain numbers
- Matches API documentation format
- Easier to copy/paste for debugging
- More professional appearance

---

## 3. Enhanced Price Alerts

### What Changed
Price alerts now support both buy and sell prices with configurable above/below thresholds.

### New Features

#### Sell Price Alerts
- **Above Threshold**: Alert when sell price goes above set value
  - Use case: Know when it's profitable to export
  - Notification: 🚀 High Sell Price Alert!
  
- **Below Threshold**: Alert when sell price drops below set value
  - Use case: Know when export becomes less profitable
  - Notification: ⚠️ Low Sell Price Alert

#### Buy Price Alerts
- **Above Threshold**: Alert when buy price goes above set value
  - Use case: Know when importing is expensive
  - Notification: ⚠️ High Buy Price Alert
  
- **Below Threshold**: Alert when buy price drops below set value
  - Use case: Know when it's cheap to charge from grid
  - Notification: 💰 Low Buy Price Alert!

### UI Changes

#### Before
```
Price Alerts
├─ Enable Price Alerts (toggle)
└─ Alert when sell price reaches: 40.0¢
    ├─ Slider (0-100¢)
    └─ Common thresholds: [30¢] [40¢] [50¢] [60¢]
```

#### After
```
Price Alerts
├─ Enable Price Alerts (master toggle)
│
├─ Sell Price Alerts
│   ├─ Alert type: [Above] [Below] (segmented picker)
│   ├─ Alert when above/below: 40.0¢/kWh
│   ├─ Slider (0-100¢)
│   ├─ Common thresholds: [20¢] [30¢] [40¢] [50¢]
│   └─ Current sell price: 12.5¢/kWh
│
├─ Buy Price Alerts
│   ├─ Enable Buy Price Alerts (toggle)
│   ├─ Alert type: [Above] [Below] (segmented picker)
│   ├─ Alert when above/below: 15.0¢/kWh
│   ├─ Slider (0-100¢)
│   ├─ Common thresholds: [10¢] [15¢] [20¢] [25¢]
│   └─ Current buy price: 18.2¢/kWh
│
└─ ℹ️ Alerts won't repeat within 30 minutes
```

### Code Changes

#### New Enum
```swift
enum PriceAlertType: String, Codable {
    case above
    case below
}
```

#### New State Variables
```swift
@AppStorage("sell_price_alert_type") private var sellPriceAlertType: PriceAlertType = .above
@AppStorage("buy_price_alerts_enabled") private var buyPriceAlertsEnabled: Bool = false
@AppStorage("buy_price_alert_threshold") private var buyPriceThreshold: Double = 15.0
@AppStorage("buy_price_alert_type") private var buyPriceAlertType: PriceAlertType = .below
```

#### Updated NotificationManager
```swift
// New method for buy price alerts
func sendBuyPriceAlert(buyPrice: Double, threshold: Double) {
    // Checks buy_price_alerts_enabled
    // Checks buy_price_alert_type (above/below)
    // Sends notification if conditions met
}

// Updated method for sell price alerts
func sendPriceAlert(sellPrice: Double, threshold: Double) {
    // Now checks sell_price_alert_type (above/below)
    // Sends appropriate notification
}
```

#### Updated API Check
```swift
// Before
func checkPriceAlert(_ sellPrice: Double)

// After
func checkPriceAlert(_ sellPrice: Double, _ buyPrice: Double) {
    // Checks both sell and buy prices
    // Calls appropriate notification methods
}
```

### Storage Keys Added
```
"sell_price_alert_type"        → "above" or "below"
"buy_price_alerts_enabled"     → Bool
"buy_price_alert_threshold"    → Double (0-100)
"buy_price_alert_type"         → "above" or "below"
"last_buy_price_alert_time"    → Double (timestamp)
```

### Use Case Examples

#### Example 1: Export When Profitable
```
Sell Price Alert: Above 40¢
→ Get notified when sell price > 40¢
→ Export excess solar for maximum profit
```

#### Example 2: Charge When Cheap
```
Buy Price Alert: Below 15¢
→ Get notified when buy price < 15¢
→ Charge battery from grid during cheap periods
```

#### Example 3: Avoid Expensive Imports
```
Buy Price Alert: Above 45¢
→ Get notified when buy price > 45¢
→ Use battery instead of importing
```

#### Example 4: Monitor Low Sell Prices
```
Sell Price Alert: Below 20¢
→ Get notified when sell price < 20¢
→ Stop exporting, keep energy for later use
```

---

## Testing the Changes

### 1. Test API Drawer
1. Open Settings
2. Scroll to "API Configuration"
3. Tap to expand/collapse the drawer
4. Verify all API settings are inside
5. Verify sites and inverters appear nested

### 2. Test Inverter ID Display
1. Connect to API
2. Select an inverter
3. Scroll to "Status" section
4. Verify ID shows as "#43924" (no comma)

### 3. Test Enhanced Alerts
1. Go to Settings → Price Alerts
2. Enable notifications
3. Enable Price Alerts
4. Configure Sell Price:
   - Set to "Above"
   - Set threshold below current price
   - Refresh data
   - Should receive 🚀 High Sell Price Alert!
5. Enable Buy Price Alerts:
   - Set to "Below"
   - Set threshold above current price
   - Refresh data
   - Should receive 💰 Low Buy Price Alert!
6. Verify 30-minute cooldown works
7. Test "Below" threshold for sell price
8. Test "Above" threshold for buy price

---

## Files Modified

1. **ContentView.swift**
   - Added `PriceAlertType` enum
   - Updated `SettingsView` with new state variables
   - Wrapped API Configuration in `DisclosureGroup`
   - Fixed inverter ID display (removed comma formatting)
   - Enhanced Price Alerts UI with buy/sell sections
   - Updated `NotificationManager.sendPriceAlert()` to handle above/below
   - Added `NotificationManager.sendBuyPriceAlert()` method
   - Updated `PowstonAPI.checkPriceAlert()` to handle both prices

2. **PRICE_ALERTS.md**
   - Updated documentation to reflect new features
   - Added examples for all 4 alert types
   - Updated code examples
   - Added new storage keys documentation

3. **CHANGES_SUMMARY.md** (this file)
   - Created to document all changes

---

## Backwards Compatibility

### Existing Users
- All existing settings are preserved
- Sell price alerts continue to work as before
- Default behavior: sell alerts for "above" threshold
- Buy alerts are disabled by default
- API drawer starts collapsed (cleaner first impression)

### Default Values
```swift
sell_price_alert_type: .above         // Same behavior as before
sell_price_alert_threshold: 40.0      // Unchanged
buy_price_alerts_enabled: false       // New, opt-in
buy_price_alert_threshold: 15.0       // New
buy_price_alert_type: .below          // New, logical default
```

---

## Future Enhancement Ideas

### Smart Presets
- "Export Mode": Sell above 35¢
- "Charge Mode": Buy below 15¢
- "Avoid Peak": Buy above 40¢
- "Optimize": All alerts enabled with smart thresholds

### Alert History
- Log of past alerts
- View in dedicated tab
- Statistics (alerts per day/week)

### Quiet Hours
- Don't send alerts during sleep
- Configurable time ranges
- Different settings for weekdays/weekends

### Advanced Conditions
- Alert only during peak hours
- Alert based on price trends
- Combine multiple conditions

### Notification Actions
- "View Dashboard" quick action
- "Dismiss for 1 hour" action
- "Change threshold" action

---

## Summary

✅ **Drawer Implementation**: All API settings are now in a clean collapsible section  
✅ **Fixed Formatting**: Inverter IDs display correctly without commas  
✅ **Enhanced Alerts**: Full buy/sell pricing alerts with above/below thresholds  
✅ **Backwards Compatible**: Existing users' settings preserved  
✅ **Well Documented**: Updated markdown files with examples  
✅ **User Friendly**: Intuitive UI with segmented pickers and visual feedback  

The app is now more organized, more powerful, and easier to use! 🚀
