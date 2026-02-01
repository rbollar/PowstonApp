//
//  PowstonActivityAttributes.swift
//  Powston
//
//  Data model for Live Activities - add to BOTH main app and widget extension targets
//

import ActivityKit
import Foundation

struct PowstonActivityAttributes: ActivityAttributes {
    
    // Fixed data that doesn't change during the activity
    public struct ContentState: Codable, Hashable {
        var status: OverrideStatus
        var mode: String
        var endTime: Date?
        var startTime: Date?
        var inverterCount: Int
        var progress: Double // 0.0 to 1.0 for active overrides
        
        // Computed helpers
        var remainingTime: TimeInterval? {
            guard let end = endTime else { return nil }
            return max(0, end.timeIntervalSince(Date()))
        }
        
        var timeUntilStart: TimeInterval? {
            guard let start = startTime else { return nil }
            return max(0, start.timeIntervalSince(Date()))
        }
        
        var formattedRemaining: String {
            guard let remaining = remainingTime else { return "" }
            let minutes = Int(remaining / 60)
            if minutes < 60 {
                return "\(minutes)m"
            } else {
                let hours = minutes / 60
                let mins = minutes % 60
                return mins > 0 ? "\(hours)h \(mins)m" : "\(hours)h"
            }
        }
        
        var formattedStartsIn: String {
            guard let until = timeUntilStart else { return "" }
            let minutes = Int(until / 60)
            if minutes < 60 {
                return "in \(minutes)m"
            } else {
                let hours = minutes / 60
                let mins = minutes % 60
                return mins > 0 ? "in \(hours)h \(mins)m" : "in \(hours)h"
            }
        }
    }
    
    // Static data set when activity starts
    var activityId: String // UUID to track this activity
    var siteName: String
}

// MARK: - Override Status Enum

enum OverrideStatus: String, Codable, Hashable {
    case pending = "pending"
    case scheduled = "scheduled"
    case active = "active"
    case completed = "completed"
    case cancelled = "cancelled"
    
    var displayName: String {
        switch self {
        case .pending: return "Verifying"
        case .scheduled: return "Scheduled"
        case .active: return "Active"
        case .completed: return "Completed"
        case .cancelled: return "Cancelled"
        }
    }
    
    var icon: String {
        switch self {
        case .pending: return "arrow.trianglehead.2.clockwise"
        case .scheduled: return "clock.fill"
        case .active: return "bolt.fill"
        case .completed: return "checkmark.circle.fill"
        case .cancelled: return "xmark.circle.fill"
        }
    }
    
    var color: String {
        switch self {
        case .pending: return "blue"
        case .scheduled: return "blue"
        case .active: return "orange"
        case .completed: return "green"
        case .cancelled: return "red"
        }
    }
}
