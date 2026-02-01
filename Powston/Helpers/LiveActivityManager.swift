//
//  LiveActivityManager.swift
//  Powston
//
//  Manages Live Activities for manual overrides
//  Add to main app target
//

import ActivityKit
import Foundation

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
        
        // End any existing activity first
        Task {
            await endCurrentActivity()
        }
        
        let attributes = PowstonActivityAttributes(
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
    func updateProgress(endTime: Date, startTime: Date) async {
        guard let activity = currentActivity,
              activity.content.state.status == .active else { return }
        
        let duration = endTime.timeIntervalSince(startTime)
        let elapsed = Date().timeIntervalSince(startTime)
        let progress = duration > 0 ? min(1.0, max(0, elapsed / duration)) : 0
        
        let state = PowstonActivityAttributes.ContentState(
            status: .active,
            mode: activity.content.state.mode,
            endTime: endTime,
            startTime: startTime,
            inverterCount: activity.content.state.inverterCount,
            progress: progress
        )
        
        await activity.update(.init(state: state, staleDate: nil))
    }
    
    // MARK: - End Activity
    
    /// End with completed status
    func endAsCompleted() async {
        guard let activity = currentActivity else { return }
        
        let finalState = PowstonActivityAttributes.ContentState(
            status: .completed,
            mode: activity.content.state.mode,
            endTime: activity.content.state.endTime,
            startTime: activity.content.state.startTime,
            inverterCount: activity.content.state.inverterCount,
            progress: 1.0
        )
        
        await activity.end(
            .init(state: finalState, staleDate: nil),
            dismissalPolicy: .after(Date().addingTimeInterval(60)) // Show for 1 minute
        )
        currentActivity = nil
        print("✅ Ended Live Activity as completed")
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
