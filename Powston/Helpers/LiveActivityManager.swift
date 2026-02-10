//
//  LiveActivityManager.swift
//  Powston
//
//  Manages Live Activities for manual overrides
//  Add to main app target
//

import ActivityKit
import Foundation
import Combine

@MainActor
class LiveActivityManager: ObservableObject {
    static let shared = LiveActivityManager()
    
    @Published private(set) var currentActivity: Activity<PowstonActivityAttributes>?
    
    private init() {
        // Check for any existing activities on launch
        if let existing = Activity<PowstonActivityAttributes>.activities.first {
            currentActivity = existing
        }
    }
    
    // MARK: - Check Support
    
    var areActivitiesEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }
    
    // MARK: - Start Activity
    
    /// Start a new Live Activity for a pending override
    func startPendingOverride(
        activityId: String,
        mode: String,
        inverterCount: Int,
        siteName: String,
        endTime: Date?,
        startTime: Date? = nil
    ) {
        guard areActivitiesEnabled else {
            print("⚠️ Live Activities not enabled")
            return
        }
        
        let attributes = PowstonActivityAttributes(
            // ... rest of code
            activityId: activityId,
            siteName: siteName
        )
        
        let initialState = PowstonActivityAttributes.ContentState(
            status: .pending,
            mode: mode,
            endTime: endTime,
            startTime: startTime,
            inverterCount: inverterCount,
            progress: 0
        )
        
        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: .init(state: initialState, staleDate: nil),
                pushType: nil
            )
            currentActivity = activity
            print("✅ Started Live Activity: \(activity.id)")
        } catch {
            print("❌ Failed to start Live Activity: \(error)")
        }
    }
    
    // MARK: - Update Activity
    
    /// Update to scheduled state (override confirmed, waiting for start time)
    func updateToScheduled(startTime: Date, endTime: Date) async {
        guard let activity = currentActivity else { return }
        
        let duration = endTime.timeIntervalSince(startTime)
        let elapsed: TimeInterval = 0
        let progress = duration > 0 ? elapsed / duration : 0
        
        let state = PowstonActivityAttributes.ContentState(
            status: .scheduled,
            mode: activity.content.state.mode,
            endTime: endTime,
            startTime: startTime,
            inverterCount: activity.content.state.inverterCount,
            progress: progress
        )
        
        await activity.update(.init(state: state, staleDate: startTime))
        print("📅 Updated Live Activity to scheduled")
    }
    
    /// Update to active state (override is now running)
    func updateToActive(endTime: Date, startTime: Date? = nil) async {
        guard let activity = currentActivity else { return }
        
        let start = startTime ?? Date()
        let duration = endTime.timeIntervalSince(start)
        let elapsed = Date().timeIntervalSince(start)
        let progress = duration > 0 ? min(1.0, max(0, elapsed / duration)) : 0
        
        let state = PowstonActivityAttributes.ContentState(
            status: .active,
            mode: activity.content.state.mode,
            endTime: endTime,
            startTime: start,
            inverterCount: activity.content.state.inverterCount,
            progress: progress
        )
        
        await activity.update(.init(state: state, staleDate: endTime))
        print("⚡ Updated Live Activity to active")
    }
    
    /// Update progress of active override
    /// Sync Live Activity state with current overrides from API
        /// Call this when app opens or refreshes override data
        func syncWithOverrides(
            currentOverrides: [ManualAction],
            scheduledOverrides: [ManualAction],
            siteName: String,
            currentInverterCount: Int = 1,
            scheduledInverterCount: Int = 1
        ) async {
            let hasActiveOverride = !currentOverrides.isEmpty
            let hasScheduledOverride = !scheduledOverrides.isEmpty
            let hasAnyOverride = hasActiveOverride || hasScheduledOverride
            
            // If no overrides but we have a Live Activity, end it
            if !hasAnyOverride {
                if currentActivity != nil {
                    await endAsCompleted()
                }
                return
            }
            
            // Determine which override to show (active takes priority over scheduled)
            if hasActiveOverride, let active = currentOverrides.first {
                let mode = active.action
                let inverterCount = max(1, currentInverterCount)
                
                if currentActivity == nil {
                    // No Live Activity - create one in active state
                    startPendingOverride(
                        activityId: UUID().uuidString,
                        mode: mode,
                        inverterCount: inverterCount,
                        siteName: siteName,
                        endTime: active.endDate ?? Date().addingTimeInterval(3600),
                        startTime: active.startDate
                    )
                    // Immediately update to active
                    if let endTime = active.endDate {
                        await updateToActive(endTime: endTime, startTime: active.startDate)
                    }
                } else {
                    // Live Activity exists - update to active if not already
                    if let endTime = active.endDate {
                        await updateToActive(endTime: endTime, startTime: active.startDate)
                    }
                }
            } else if hasScheduledOverride, let scheduled = scheduledOverrides.first {
                let mode = scheduled.action
                let inverterCount = max(1, scheduledInverterCount)
                
                if currentActivity == nil {
                    // No Live Activity - create one in scheduled state
                    startPendingOverride(
                        activityId: UUID().uuidString,
                        mode: mode,
                        inverterCount: inverterCount,
                        siteName: siteName,
                        endTime: scheduled.endDate ?? Date().addingTimeInterval(3600),
                        startTime: scheduled.startDate
                    )
                    // Immediately update to scheduled
                    if let startTime = scheduled.startDate, let endTime = scheduled.endDate {
                        await updateToScheduled(startTime: startTime, endTime: endTime)
                    }
                } else {
                    // Live Activity exists - update to scheduled
                    if let startTime = scheduled.startDate, let endTime = scheduled.endDate {
                        await updateToScheduled(startTime: startTime, endTime: endTime)
                    }
                }
            }
        }
    
    /// Sync Live Activity state with current overrides from API
    /// Call this when app opens or refreshes override data
    func syncWithOverrides(currentOverrides: [ManualAction], scheduledOverrides: [ManualAction], siteName: String) async {
        let hasActiveOverride = !currentOverrides.isEmpty
        let hasScheduledOverride = !scheduledOverrides.isEmpty
        let hasAnyOverride = hasActiveOverride || hasScheduledOverride
        
        // If no overrides but we have a Live Activity, end it
        if !hasAnyOverride {
            if currentActivity != nil {
                await endAsCompleted()
            }
            return
        }
        
        // Determine which override to show (active takes priority over scheduled)
        if hasActiveOverride, let active = currentOverrides.first {
            let mode = active.action
            
            if currentActivity == nil {
                // No Live Activity - create one in active state
                startPendingOverride(
                    activityId: UUID().uuidString,
                    mode: mode,
                    inverterCount: active.inverterId > 0 ? 2 : 1,  // Estimate from grouped data
                    siteName: siteName,
                    endTime: active.endDate ?? Date().addingTimeInterval(3600),
                    startTime: active.startDate
                )
                // Immediately update to active
                if let endTime = active.endDate {
                    await updateToActive(endTime: endTime, startTime: active.startDate)
                }
            } else {
                // Live Activity exists - update to active if not already
                if let endTime = active.endDate {
                    await updateToActive(endTime: endTime, startTime: active.startDate)
                }
            }
        } else if hasScheduledOverride, let scheduled = scheduledOverrides.first {
            let mode = scheduled.action
            
            if currentActivity == nil {
                // No Live Activity - create one in scheduled state
                startPendingOverride(
                    activityId: UUID().uuidString,
                    mode: mode,
                    inverterCount: 2,  // Assume multi-inverter
                    siteName: siteName,
                    endTime: scheduled.endDate ?? Date().addingTimeInterval(3600),
                    startTime: scheduled.startDate
                )
                // Immediately update to scheduled
                if let startTime = scheduled.startDate, let endTime = scheduled.endDate {
                    await updateToScheduled(startTime: startTime, endTime: endTime)
                }
            } else {
                // Live Activity exists - update to scheduled
                if let startTime = scheduled.startDate, let endTime = scheduled.endDate {
                    await updateToScheduled(startTime: startTime, endTime: endTime)
                }
            }
        }
    }
    
    // MARK: - End Activity
    
    /// End with completed status
    /// Check if there's currently an active Live Activity
    var hasActiveActivity: Bool {
        currentActivity != nil
    }

    /// End activity as completed (normal end, not cancelled)
    /// End activity as completed (normal end, not cancelled)
    func endAsCompleted() async {
        guard let activity = currentActivity else { return }
        
        let finalState = PowstonActivityAttributes.ContentState(
            status: .completed,
            mode: activity.content.state.mode,
            endTime: Date(),
            startTime: activity.content.state.startTime,
            inverterCount: activity.content.state.inverterCount,
            progress: 1.0
        )
        
        await activity.end(
            ActivityContent(state: finalState, staleDate: nil),
            dismissalPolicy: .after(.now + 5)
        )
        
        currentActivity = nil
        print("✅ Live Activity ended as completed")
    }
    
    /// End with cancelled status
    func endAsCancelled() async {
        guard let activity = currentActivity else { return }
        
        let finalState = PowstonActivityAttributes.ContentState(
            status: .cancelled,
            mode: activity.content.state.mode,
            endTime: activity.content.state.endTime,
            startTime: activity.content.state.startTime,
            inverterCount: activity.content.state.inverterCount,
            progress: activity.content.state.progress
        )
        
        await activity.end(
            .init(state: finalState, staleDate: nil),
            dismissalPolicy: .after(Date().addingTimeInterval(30)) // Show for 30 seconds
        )
        currentActivity = nil
        print("❌ Ended Live Activity as cancelled")
    }
    
    /// End immediately without final state
    func endCurrentActivity() async {
        guard let activity = currentActivity else { return }
        await activity.end(nil, dismissalPolicy: .immediate)
        currentActivity = nil
        print("🛑 Ended Live Activity immediately")
    }
    
    /// End all activities (cleanup)
    func endAllActivities() async {
        for activity in Activity<PowstonActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        currentActivity = nil
        print("🧹 Ended all Live Activities")
    }
    
    // MARK: - Helpers
    
    /// Check if we have an active Live Activity for a specific override
    func hasActivityForOverride(activityId: String) -> Bool {
        currentActivity?.attributes.activityId == activityId
    }
    
    /// Get current activity status
    var currentStatus: OverrideStatus? {
        currentActivity?.content.state.status
    }
}
