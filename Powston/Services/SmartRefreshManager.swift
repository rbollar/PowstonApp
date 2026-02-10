//
//  SmartRefreshManager.swift
//  Powston
//
//  Efficient polling aligned to AEMO's 5-minute dispatch intervals.
//  Instead of polling every 60s, we poll at :35 past each 5-min mark
//  and retry until we get new data, then do a confirmation poll 30s later
//  to catch any data that wasn't ready on the first successful fetch.
//
//  Works with both iOS (PowstonAPI) and tvOS (TVAPI) via protocol.
//

import Foundation
import Combine

// MARK: - Protocol for refreshable APIs

protocol RefreshableAPI: AnyObject {
    /// Fetch latest data from server
    func fetchData() async
    
    /// Get the current interval timestamp for change detection
    var currentIntervalTime: String? { get }
    
    /// Check if the API is ready to poll (e.g., has selected inverter)
    var isReadyToPoll: Bool { get }
}

// MARK: - Smart Refresh Manager

@MainActor
class SmartRefreshManager: ObservableObject {
    static let shared = SmartRefreshManager()
    
    @Published var isPolling = false
    @Published var lastUpdateTime: Date?
    @Published var secondsUntilNextPoll = 0
    
    /// Formatted countdown string (e.g., "2:45" or "45s")
    var countdownText: String {
        if isPolling {
            return "Updating..."
        }
        let secs = secondsUntilNextPoll
        if secs >= 60 {
            return String(format: "%d:%02d", secs / 60, secs % 60)
        } else {
            return "\(secs)s"
        }
    }
    
    private var intervalTimer: Timer?
    private var retryTimer: Timer?
    private var countdownTimer: Timer?
    private var confirmationTimer: Timer?
    private var lastDataTimestamp: String?
    private weak var api: RefreshableAPI?
    
    // Configuration
    private let targetOffsetSeconds = 35      // Start polling at :35 past interval
    private let retryIntervalSeconds = 10.0   // Retry every 10 seconds
    private let maxRetryDuration = 120.0      // Give up after 2 minutes
    private let confirmationDelaySeconds = 30.0  // Second poll after successful update
    private let jitterRange = 10.0            // Random 0-10s delay to spread load
    
    private init() {}
    
    /// Start smart refresh polling
    func start(api: RefreshableAPI) {
        self.api = api
        self.lastDataTimestamp = api.currentIntervalTime
        scheduleNextIntervalCheck()
        startCountdownTimer()
        print("⏰ SmartRefresh: Started, waiting for next interval")
    }
    
    /// Stop all polling
    func stop() {
        intervalTimer?.invalidate()
        intervalTimer = nil
        retryTimer?.invalidate()
        retryTimer = nil
        countdownTimer?.invalidate()
        countdownTimer = nil
        confirmationTimer?.invalidate()
        confirmationTimer = nil
        isPolling = false
        print("⏰ SmartRefresh: Stopped")
    }
    
    /// Force an immediate refresh (for pull-to-refresh, etc.)
    func forceRefresh() async {
        guard let api = api else { return }
        await api.fetchData()
        lastDataTimestamp = api.currentIntervalTime
        lastUpdateTime = Date()
    }
    
    // MARK: - Private Methods
    
    private func startCountdownTimer() {
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                self?.updateCountdown()
            }
        }
        updateCountdown()
    }
    
    private func updateCountdown() {
        if isPolling {
            secondsUntilNextPoll = 0
        } else {
            secondsUntilNextPoll = Int(secondsUntilNextPollWindow())
        }
    }
    
    private func scheduleNextIntervalCheck() {
        intervalTimer?.invalidate()
        
        let delay = secondsUntilNextPollWindow() + randomJitter()
        
        #if DEBUG
        print("⏰ SmartRefresh: Next check in \(String(format: "%.1f", delay))s")
        #endif
        
        intervalTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                self?.startPollingForUpdate()
            }
        }
    }
    
    private func secondsUntilNextPollWindow() -> TimeInterval {
        let now = Date()
        let calendar = Calendar.current
        let components = calendar.dateComponents([.minute, .second], from: now)
        let minutes = components.minute ?? 0
        let seconds = components.second ?? 0
        
        // Seconds into current 5-min cycle
        let cycleSeconds = (minutes % 5) * 60 + seconds
        
        if cycleSeconds < targetOffsetSeconds {
            // Target is still ahead in this cycle
            return Double(targetOffsetSeconds - cycleSeconds)
        } else {
            // Target passed, wait for next cycle
            return Double(300 - cycleSeconds + targetOffsetSeconds)
        }
    }
    
    private func randomJitter() -> TimeInterval {
        return Double.random(in: 0...jitterRange)
    }
    
    private func startPollingForUpdate() {
        guard let api = api else {
            scheduleNextIntervalCheck()
            return
        }
        
        // Don't poll if API not ready
        guard api.isReadyToPoll else {
            scheduleNextIntervalCheck()
            return
        }
        
        isPolling = true
        let startTime = Date()
        
        #if DEBUG
        print("⏰ SmartRefresh: Starting poll cycle")
        #endif
        
        // Immediate first check
        Task { [weak self] in
            await self?.checkForUpdate(startTime: startTime)
        }
        
        // Set up retry timer
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: retryIntervalSeconds, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            Task { @MainActor [weak self] in
                guard let self else {
                    timer.invalidate()
                    return
                }
                
                // Check if we've exceeded max retry duration
                if Date().timeIntervalSince(startTime) >= self.maxRetryDuration {
                    print("⏰ SmartRefresh: Max retry duration reached, giving up")
                    timer.invalidate()
                    self.retryTimer = nil
                    self.isPolling = false
                    self.scheduleNextIntervalCheck()
                    return
                }
                
                await self.checkForUpdate(startTime: startTime)
            }
        }
    }
    
    private func checkForUpdate(startTime: Date) async {
        guard let api = api else { return }
        
        await api.fetchData()
        
        let newTimestamp = api.currentIntervalTime
        
        if let new = newTimestamp, new != lastDataTimestamp {
            // Got new data!
            let elapsed = Date().timeIntervalSince(startTime)
            print("⏰ SmartRefresh: New data received in \(String(format: "%.1f", elapsed))s")
            
            lastDataTimestamp = new
            lastUpdateTime = Date()
            
            // Stop retry polling
            retryTimer?.invalidate()
            retryTimer = nil
            isPolling = false
            
            // Schedule confirmation poll to catch any data that wasn't ready
            scheduleConfirmationPoll()
        } else {
            #if DEBUG
            print("⏰ SmartRefresh: No new data yet, retrying...")
            #endif
        }
    }
    
    private func scheduleConfirmationPoll() {
        confirmationTimer?.invalidate()
        
        print("⏰ SmartRefresh: Scheduling confirmation poll in \(Int(confirmationDelaySeconds))s")
        
        confirmationTimer = Timer.scheduledTimer(withTimeInterval: confirmationDelaySeconds, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self, let api = self.api else { return }
                
                print("⏰ SmartRefresh: Confirmation poll executing")
                await api.fetchData()
                
                // Update timestamp if newer data arrived
                if let newTimestamp = api.currentIntervalTime {
                    self.lastDataTimestamp = newTimestamp
                }
                self.lastUpdateTime = Date()
                
                // Now schedule next interval
                self.scheduleNextIntervalCheck()
            }
        }
    }
}
