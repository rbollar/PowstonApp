//
//  SmartRefreshManager.swift
//  Powston
//
//  Efficient polling aligned to AEMO's 5-minute dispatch intervals.
//  Instead of polling every 60s, we poll at :20 past each 5-min mark
//  and retry until we get new data, then wait for the next interval.
//

import Foundation
import Combine

@MainActor
class SmartRefreshManager: ObservableObject {
    static let shared = SmartRefreshManager()
    
    @Published var isPolling = false
    @Published var lastUpdateTime: Date?
    
    private var intervalTimer: Timer?
    private var retryTimer: Timer?
    private var lastDataTimestamp: String?
    private var api: PowstonAPI?
    
    // Configuration
    private let targetOffsetSeconds = 25      // Start polling at :25 past interval
    private let retryIntervalSeconds = 5.0    // Retry every 5 seconds
    private let maxRetryDuration = 120.0      // Give up after 2 minutes
    private let jitterRange = 10.0            // Random 0-10s delay to spread load
    
    private init() {}
    
    /// Start smart refresh polling
    func start(api: PowstonAPI) {
        self.api = api
        self.lastDataTimestamp = api.data?.intervalTime
        scheduleNextIntervalCheck()
        print("⏰ SmartRefresh: Started, waiting for next interval")
    }
    
    /// Stop all polling
    func stop() {
        intervalTimer?.invalidate()
        intervalTimer = nil
        retryTimer?.invalidate()
        retryTimer = nil
        isPolling = false
        print("⏰ SmartRefresh: Stopped")
    }
    
    /// Force an immediate refresh (for pull-to-refresh, etc.)
    func forceRefresh() async {
        guard let api = api else { return }
        await api.fetchData()
        lastDataTimestamp = api.data?.intervalTime
        lastUpdateTime = Date()
    }
    
    // MARK: - Private Methods
    
    private func scheduleNextIntervalCheck() {
        intervalTimer?.invalidate()
        
        let delay = secondsUntilNextPollWindow() + randomJitter()
        
        #if DEBUG
        print("⏰ SmartRefresh: Next check in \(String(format: "%.1f", delay))s")
        #endif
        
        intervalTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
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
        
        // Don't poll if no inverter selected
        guard api.selectedInverterId != 0 else {
            scheduleNextIntervalCheck()
            return
        }
        
        isPolling = true
        let startTime = Date()
        
        #if DEBUG
        print("⏰ SmartRefresh: Starting poll cycle")
        #endif
        
        // Immediate first check
        Task {
            await checkForUpdate(api: api, startTime: startTime)
        }
        
        // Set up retry timer
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: retryIntervalSeconds, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self = self else {
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
                
                await self.checkForUpdate(api: api, startTime: startTime)
            }
        }
    }
    
    private func checkForUpdate(api: PowstonAPI, startTime: Date) async {
        await api.fetchData()
        
        let newTimestamp = api.data?.intervalTime
        
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
            
            // Schedule next interval
            scheduleNextIntervalCheck()
        } else {
            #if DEBUG
            print("⏰ SmartRefresh: No new data yet, retrying...")
            #endif
        }
    }
}
