# Powston App Implementation Notes

## Recent Updates

### 1. Time Alignment with interval_time
The app now properly aligns forecast times with the `interval_time` from the API.

**How it works:**
- The API provides `"interval_time":"2025-12-26T21:50:00+10:00"` which is the timestamp of the first forecast period
- Each subsequent period is 30 minutes later
- Sunrise, sunset, and peak times are now calculated relative to this start time
- Times displayed in the UI show actual clock times (e.g., "21:50", "22:20") instead of relative offsets

**Example:**
```
interval_time: 21:50
Period 0: 21:50
Period 1: 22:20
Period 2: 22:50
...
```

### 2. Accordion/Disclosure Groups for Forecasts
The buy and sell forecast lists are now collapsible to reduce clutter.

**Benefits:**
- Lists start collapsed by default
- Shows count of periods (e.g., "Show 16 forecast periods")
- User can expand to see full details
- Improves UI performance with long lists
- Less scrolling required

---

## Updating Once Per Minute: Implications

### Pros:
1. **Near Real-Time Data**: Users see current prices and battery status quickly
2. **Accurate Peak Detection**: Important for time-sensitive decisions
3. **Better UX**: Feels responsive and "live"

### Cons:
1. **Battery Drain**: 
   - 60 API calls per hour = 1,440 calls/day
   - Network radio stays active more frequently
   - Could reduce battery life by 10-20% depending on network conditions

2. **API Rate Limits**:
   - Most APIs have rate limits (e.g., 100 requests/hour)
   - You may hit limits and get throttled or banned
   - Check Powston API documentation for limits

3. **Data Costs**:
   - ~200KB per request × 1,440 = ~280MB/day
   - Could be expensive on metered connections
   - Users on limited data plans may not appreciate this

4. **Server Load**:
   - If many users poll every minute, it creates server burden
   - Respectful to use webhooks or push notifications instead

### Recommendations:

#### Option A: Adaptive Polling (Recommended)
```swift
// Poll more frequently during peak hours, less during stable periods
let pollInterval: TimeInterval = {
    let hour = Calendar.current.component(.hour, from: Date())
    if (16...21).contains(hour) {  // Peak hours
        return 60  // 1 minute
    } else if (22...5).contains(hour) {  // Night
        return 600  // 10 minutes
    } else {
        return 180  // 3 minutes
    }
}()
```

#### Option B: Background Fetch
Use iOS Background Fetch to let the system decide when to update:
```swift
// In AppDelegate or App struct
func application(_ application: UIApplication,
                performFetchWithCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
    // Fetch data
    Task {
        await api.fetchData()
        completionHandler(.newData)
    }
}
```

#### Option C: Push Notifications (Best)
Have the server push updates when prices change significantly. See next section.

---

## Push Notifications for Price Alerts: Difficulty Level

### Complexity: **Medium to High** ⚠️

### What You Need:

#### 1. **Server-Side Component** (Most Complex)
You need a backend service that:
- Monitors price changes continuously
- Tracks user preferences (their threshold prices)
- Sends push notifications when thresholds are met

**Options:**
- **Firebase Cloud Messaging (FCM)**: Free, easy to integrate
- **Apple Push Notification Service (APNs)**: Native but requires more setup
- **Third-party service**: OneSignal, Pusher, etc.

**Estimated Time:** 2-5 days for basic implementation

#### 2. **Client-Side Implementation** (Easier)

##### A. Request Permission
```swift
import UserNotifications

func requestNotificationPermission() {
    UNUserNotificationCenter.current().requestAuthorization(
        options: [.alert, .badge, .sound]
    ) { granted, error in
        if granted {
            print("Permission granted")
            // Register device token with your server
        }
    }
}
```

##### B. Store User Preferences
```swift
@AppStorage("sell_price_threshold") var sellPriceThreshold: Double = 50.0
@AppStorage("buy_price_threshold") var buyPriceThreshold: Double = 10.0
@AppStorage("notifications_enabled") var notificationsEnabled: Bool = false
```

##### C. Add Settings UI
```swift
Section("Price Alerts") {
    Toggle("Enable Notifications", isOn: $notificationsEnabled)
    
    if notificationsEnabled {
        VStack(alignment: .leading) {
            Text("Alert when sell price exceeds:")
            HStack {
                Slider(value: $sellPriceThreshold, in: 0...100, step: 1)
                Text("\(String(format: "%.0f", sellPriceThreshold))¢")
            }
        }
    }
}
```

#### 3. **Architecture Options**

##### Option A: Polling Server (Simpler)
- Your server polls Powston API every minute
- Checks against all user thresholds
- Sends notifications when exceeded
- **Cost**: Server costs (~$5-20/month for basic setup)

##### Option B: Webhook (Better)
- If Powston provides webhooks, register for price change events
- Your server receives instant notifications
- Forward to users who meet threshold
- **Cost**: Minimal server costs

##### Option C: Client-Side Polling + Local Notifications (Simplest, Limited)
- App checks prices when active
- Shows local notifications
- **Limitation**: Only works when app is running
- **Pro**: No server needed!

```swift
func checkPriceAndNotify(_ sellPrice: Double) {
    guard sellPrice > sellPriceThreshold else { return }
    
    let content = UNMutableNotificationContent()
    content.title = "High Sell Price Alert!"
    content.body = "Sell price is \(String(format: "%.1f", sellPrice))¢/kWh"
    content.sound = .default
    
    let request = UNNotificationRequest(
        identifier: UUID().uuidString,
        content: content,
        trigger: nil  // Immediate
    )
    
    UNUserNotificationCenter.current().add(request)
}
```

### Recommended Implementation Strategy:

#### Phase 1: Local Notifications (1-2 days)
1. Add notification permission request
2. Add threshold settings UI
3. Check prices when app refreshes
4. Send local notifications
5. **Limitation**: Only works when app is active

#### Phase 2: Server-Side Push (3-5 days)
1. Set up Firebase Cloud Messaging
2. Create simple Node.js/Python server
3. Store user device tokens + thresholds
4. Poll Powston API every minute
5. Send push notifications when thresholds met
6. **Cost**: ~$5-10/month for Heroku/Railway hosting

#### Phase 3: Advanced (Optional)
1. Add notification history
2. Smart throttling (don't spam user)
3. Multiple threshold types (buy/sell/RRP)
4. Quiet hours
5. Notification scheduling

### Code Example: Complete Flow

```swift
// MARK: - Notification Manager
class NotificationManager: ObservableObject {
    static let shared = NotificationManager()
    
    @AppStorage("sell_price_threshold") var sellPriceThreshold: Double = 50.0
    @AppStorage("notifications_enabled") var notificationsEnabled: Bool = false
    
    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .badge, .sound]
        ) { granted, _ in
            if granted {
                DispatchQueue.main.async {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            }
        }
    }
    
    func checkAndNotify(sellPrice: Double) {
        guard notificationsEnabled, sellPrice > sellPriceThreshold else { return }
        
        // Check if we already sent notification recently
        let lastNotificationKey = "last_price_notification"
        let lastTime = UserDefaults.standard.double(forKey: lastNotificationKey)
        let now = Date().timeIntervalSince1970
        
        // Don't spam - wait at least 30 minutes between notifications
        guard now - lastTime > 1800 else { return }
        
        let content = UNMutableNotificationContent()
        content.title = "🚀 High Sell Price!"
        content.body = "Sell price is \(String(format: "%.1f¢/kWh", sellPrice)) - Great time to export!"
        content.sound = .default
        content.badge = 1
        
        let request = UNNotificationRequest(
            identifier: "price_alert_\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request) { error in
            if error == nil {
                UserDefaults.standard.set(now, forKey: lastNotificationKey)
            }
        }
    }
}

// In your API fetch:
func fetchData() async {
    // ... existing code ...
    
    await MainActor.run { 
        self.data = decoded
        NotificationManager.shared.checkAndNotify(sellPrice: decoded.sellPrice)
        isLoading = false
    }
}
```

### Privacy Considerations:
- **User Control**: Always let users opt-in
- **Transparency**: Explain why you need permissions
- **Data Storage**: If using a server, explain what data you store
- **Unsubscribe**: Easy way to disable notifications

### Testing:
```swift
// Test notification without waiting for price changes
func testNotification() {
    let content = UNMutableNotificationContent()
    content.title = "Test Notification"
    content.body = "Notifications are working!"
    content.sound = .default
    
    let request = UNNotificationRequest(
        identifier: "test",
        content: content,
        trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
    )
    
    UNUserNotificationCenter.current().add(request)
}
```

---

## Summary

### Time Alignment: ✅ Implemented
- Forecasts now use absolute times from `interval_time`
- Sunrise/sunset correctly aligned with forecast periods

### Accordions: ✅ Implemented
- Buy/Sell forecasts now use collapsible DisclosureGroups
- Cleaner UI, better performance

### 1-Minute Updates: ⚠️ Be Careful
- **Recommendation**: Use adaptive polling or 2-3 minute intervals
- Consider battery, data usage, and API limits
- Best option: Push notifications from server

### Push Notifications: 🔧 Doable but Requires Work
- **Simple version** (local notifications): 1-2 days
- **Full version** (push notifications): 3-5 days + server costs
- **Best approach**: Start with local, upgrade to push if needed

### Next Steps:
1. Test the accordion implementation
2. Decide on polling interval strategy
3. Add notification settings UI
4. Implement local notifications first
5. Evaluate if server-side push is needed based on user feedback
