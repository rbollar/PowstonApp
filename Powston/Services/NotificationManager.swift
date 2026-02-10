//
//  NotificationManager.swift
//  Powston
//

import Foundation
import UserNotifications
import UIKit
import Combine

@MainActor
class NotificationManager: ObservableObject {
    static let shared = NotificationManager()
    
    @Published var isAuthorized = false
    @Published var deviceToken: String?
    
    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            DispatchQueue.main.async {
                self.isAuthorized = granted
                if granted {
                    print("✅ Notification permission granted")
                    // Register for remote notifications now that we have permission
                    UIApplication.shared.registerForRemoteNotifications()
                } else {
                    print("❌ Notification permission denied")
                }
            }
        }
    }
    
    func checkAuthorization() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                self.isAuthorized = settings.authorizationStatus == .authorized
            }
        }
    }
    
    /// Get the stored device token (if available)
    func getDeviceToken() -> String? {
        return UserDefaults.standard.string(forKey: "apns_device_token")
    }
    
    func sendAlert(type: String, title: String, price: Double, threshold: Double, priceType: String) {
        let lastAlertKey = "last_\(type)_alert_time"
        let lastAlert = UserDefaults.standard.double(forKey: lastAlertKey)
        let now = Date().timeIntervalSince1970
        
        guard now - lastAlert > 1800 else {
            print("⏰ Skipping \(type) alert - sent one recently")
            return
        }
        
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = "\(priceType) price is \(String(format: "%.1f¢", price))/kWh (threshold: \(String(format: "%.1f¢", threshold)))"
        content.sound = .default
        content.badge = 1
        
        let request = UNNotificationRequest(
            identifier: "\(type)_alert_\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("❌ Error sending \(type) notification: \(error)")
            } else {
                print("✅ \(type) alert sent!")
                UserDefaults.standard.set(now, forKey: lastAlertKey)
            }
        }
    }
    
    func clearBadge() {
        UNUserNotificationCenter.current().setBadgeCount(0)
    }
}
