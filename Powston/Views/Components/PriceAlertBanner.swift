//
//  PriceAlertBanner.swift
//  Powston
//
//  Shows in-app banner when price thresholds are breached or spikes are forecast
//

import SwiftUI

// MARK: - Alert Types
enum PriceAlertType: Equatable {
    case sellAbove(current: Double, threshold: Double)
    case sellBelow(current: Double, threshold: Double)
    case buyAbove(current: Double, threshold: Double)
    case buyBelow(current: Double, threshold: Double)
    case spike(time: String, peakRRP: Double)  // peakRRP in $/MWh
    case spikeCleared
    
    var icon: String {
        switch self {
        case .sellAbove: return "🚀"
        case .sellBelow: return "⚠️"
        case .buyAbove: return "⚠️"
        case .buyBelow: return "💰"
        case .spike: return "⚡"
        case .spikeCleared: return "✅"
        }
    }
    
    var title: String {
        switch self {
        case .sellAbove: return "High Sell Price!"
        case .sellBelow: return "Low Sell Price"
        case .buyAbove: return "High Buy Price!"
        case .buyBelow: return "Low Buy Price!"
        case .spike(let time, _): return "Spike \(time)"
        case .spikeCleared: return "Spike Cleared"
        }
    }
    
    var message: String {
        switch self {
        case .sellAbove(let current, let threshold):
            return "Sell: \(String(format: "%.1f", current))¢ (threshold: \(Int(threshold))¢)"
        case .sellBelow(let current, let threshold):
            return "Sell: \(String(format: "%.1f", current))¢ (threshold: \(Int(threshold))¢)"
        case .buyAbove(let current, let threshold):
            return "Buy: \(String(format: "%.1f", current))¢ (threshold: \(Int(threshold))¢)"
        case .buyBelow(let current, let threshold):
            return "Buy: \(String(format: "%.1f", current))¢ (threshold: \(Int(threshold))¢)"
        case .spike(_, let peakRRP):
            return "RRP $\(formatRRP(peakRRP))/MWh"
        case .spikeCleared:
            return "Forecast spike no longer expected"
        }
    }
    
    var color: Color {
        switch self {
        case .sellAbove: return .green
        case .sellBelow: return .orange
        case .buyAbove: return .red
        case .buyBelow: return .blue
        case .spike: return .orange
        case .spikeCleared: return .green
        }
    }
    
    private func formatRRP(_ value: Double) -> String {
        if value >= 1000 {
            return String(format: "%.0f", value)
        } else {
            return String(format: "%.0f", value)
        }
    }
}

// MARK: - Price Alert Banner View
struct PriceAlertBanner: View {
    @EnvironmentObject var api: PowstonAPI
    
    // User settings
    @AppStorage("price_alerts_enabled") private var priceAlertsEnabled: Bool = false
    @AppStorage("sell_above_enabled") private var sellAboveEnabled: Bool = false
    @AppStorage("sell_above_threshold") private var sellAboveThreshold: Double = 40.0
    @AppStorage("sell_below_enabled") private var sellBelowEnabled: Bool = false
    @AppStorage("sell_below_threshold") private var sellBelowThreshold: Double = 5.0
    @AppStorage("buy_above_enabled") private var buyAboveEnabled: Bool = false
    @AppStorage("buy_above_threshold") private var buyAboveThreshold: Double = 40.0
    @AppStorage("buy_below_enabled") private var buyBelowEnabled: Bool = false
    @AppStorage("buy_below_threshold") private var buyBelowThreshold: Double = 15.0
    @AppStorage("spike_alerts_enabled") private var spikeAlertsEnabled: Bool = false
    @AppStorage("spike_threshold") private var spikeThreshold: Double = 50.0
    
    // Track dismissed alerts to avoid nagging
    @State private var dismissedAlerts: Set<String> = []
    @State private var lastSpikeSignature: String? = nil
    
    var activeAlerts: [PriceAlertType] {
        guard priceAlertsEnabled, let data = api.data else { return [] }
        
        var alerts: [PriceAlertType] = []
        
        // Check current price thresholds
        if let sellPrice = data.sellPrice {
            if sellAboveEnabled && sellPrice >= sellAboveThreshold {
                alerts.append(.sellAbove(current: sellPrice, threshold: sellAboveThreshold))
            }
            if sellBelowEnabled && sellPrice <= sellBelowThreshold {
                alerts.append(.sellBelow(current: sellPrice, threshold: sellBelowThreshold))
            }
        }
        
        if let buyPrice = data.buyPrice {
            if buyAboveEnabled && buyPrice >= buyAboveThreshold {
                alerts.append(.buyAbove(current: buyPrice, threshold: buyAboveThreshold))
            }
            if buyBelowEnabled && buyPrice <= buyBelowThreshold {
                alerts.append(.buyBelow(current: buyPrice, threshold: buyBelowThreshold))
            }
        }
        
        // Check spike forecasts
        if spikeAlertsEnabled, let forecasts = data.forecasts {
            let spikeInfo = findSpike(forecasts: forecasts, threshold: spikeThreshold, startTime: data.forecastStartDate)
            
            if let spike = spikeInfo {
                alerts.append(.spike(time: spike.timeString, peakRRP: spike.peakRRP))
            }
        }
        
        // Filter out dismissed alerts
        return alerts.filter { alert in
            !dismissedAlerts.contains(alertKey(alert))
        }
    }
    
    var body: some View {
        if let alert = activeAlerts.first {
            HStack(spacing: 10) {
                Text(alert.icon)
                    .font(.title3)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(alert.title)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Text(alert.message)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // Show count if multiple alerts
                if activeAlerts.count > 1 {
                    Text("+\(activeAlerts.count - 1)")
                        .font(.caption)
                        .fontWeight(.medium)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.3))
                        .cornerRadius(8)
                }
                
                Button(action: { dismissAlert(alert) }) {
                    Image(systemName: "xmark")
                        .font(.caption)
                        .fontWeight(.bold)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(alert.color.opacity(0.15))
            .foregroundColor(alert.color)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(alert.color.opacity(0.3), lineWidth: 1)
            )
            .onTapGesture {
                // Navigate to price alerts settings
                TabSelection.shared.selectedTab = .settings
            }
        }
    }
    
    private func alertKey(_ alert: PriceAlertType) -> String {
        switch alert {
        case .sellAbove: return "sell_above"
        case .sellBelow: return "sell_below"
        case .buyAbove: return "buy_above"
        case .buyBelow: return "buy_below"
        case .spike(let time, _): return "spike_\(time)"
        case .spikeCleared: return "spike_cleared"
        }
    }
    
    private func dismissAlert(_ alert: PriceAlertType) {
        dismissedAlerts.insert(alertKey(alert))
        
        // Clear dismissals after 30 minutes so alerts can reappear if conditions persist
        DispatchQueue.main.asyncAfter(deadline: .now() + 1800) {
            dismissedAlerts.remove(alertKey(alert))
        }
    }
    
    // MARK: - Spike Detection
    
    private struct SpikeInfo {
        let timeString: String
        let peakRRP: Double  // in $/MWh
    }
    
    private func findSpike(forecasts: [Double], threshold: Double, startTime: Date?) -> SpikeInfo? {
        // Find forecasts above threshold (forecasts are in ¢/kWh)
        var spikePeriods: [(index: Int, value: Double)] = []
        
        for (i, forecast) in forecasts.enumerated() {
            if forecast >= threshold {
                spikePeriods.append((i, forecast))
            }
        }
        
        guard !spikePeriods.isEmpty else { return nil }
        
        // Calculate time of first spike
        let baseTime = startTime ?? Date()
        
        // Align to next :00 or :30
        let calendar = Calendar.current
        var components = calendar.dateComponents(in: powstonTimezone(), from: baseTime)
        let currentMinute = components.minute ?? 0
        
        if currentMinute < 30 {
            components.minute = 30
        } else {
            components.minute = 0
            components.hour = (components.hour ?? 0) + 1
        }
        components.second = 0
        
        let nextBoundary = calendar.date(from: components) ?? baseTime
        
        // Find first and last consecutive spike periods
        let firstIndex = spikePeriods[0].index
        var lastIndex = firstIndex
        var peakValue = spikePeriods[0].value
        
        for period in spikePeriods {
            if period.index <= lastIndex + 1 {
                lastIndex = period.index
                peakValue = max(peakValue, period.value)
            } else {
                break  // Gap in spikes, stop at first block
            }
        }
        
        let spikeStart = nextBoundary.addingTimeInterval(TimeInterval(firstIndex * 30 * 60))
        let spikeEnd = nextBoundary.addingTimeInterval(TimeInterval((lastIndex + 1) * 30 * 60))
        
        // Format time string
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm"
        formatter.timeZone = powstonTimezone()
        
        let endFormatter = DateFormatter()
        endFormatter.dateFormat = "h:mm a"
        endFormatter.timeZone = powstonTimezone()
        
        let timeString: String
        if lastIndex > firstIndex {
            timeString = "\(formatter.string(from: spikeStart))-\(endFormatter.string(from: spikeEnd))"
        } else {
            timeString = endFormatter.string(from: spikeStart)
        }
        
        // Convert ¢/kWh to $/MWh for display
        let peakRRP = peakValue * 10
        
        return SpikeInfo(timeString: timeString, peakRRP: peakRRP)
    }
}

// MARK: - Preview
#Preview {
    VStack {
        PriceAlertBanner()
            .padding()
        Spacer()
    }
    .environmentObject(PowstonAPI())
}
