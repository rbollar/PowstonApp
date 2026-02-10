//
//  PriceAlertsSettingsView.swift
//  Powston
//

import SwiftUI

struct PriceAlertsSettingsView: View {
    @EnvironmentObject var api: PowstonAPI
    @AppStorage("price_alerts_enabled") private var priceAlertsEnabled: Bool = false
    @AppStorage("sell_above_enabled") private var sellAboveEnabled: Bool = false
    @AppStorage("sell_above_threshold") private var sellAboveThreshold: Double = 40.0
    @AppStorage("sell_below_enabled") private var sellBelowEnabled: Bool = false
    @AppStorage("sell_below_threshold") private var sellBelowThreshold: Double = 20.0
    @AppStorage("buy_above_enabled") private var buyAboveEnabled: Bool = false
    @AppStorage("buy_above_threshold") private var buyAboveThreshold: Double = 40.0
    @AppStorage("buy_below_enabled") private var buyBelowEnabled: Bool = false
    @AppStorage("buy_below_threshold") private var buyBelowThreshold: Double = 15.0
    @AppStorage("spike_alerts_enabled") private var spikeAlertsEnabled: Bool = false
    @AppStorage("spike_threshold") private var spikeThreshold: Double = 50.0
    @StateObject private var notificationManager = NotificationManager.shared
    
    @State private var isSyncing = false
    @State private var lastSyncSuccess: Bool?
    
    var body: some View {
        Form {
            if !notificationManager.isAuthorized {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "bell.slash")
                                .foregroundColor(.orange)
                            Text("Notifications not enabled")
                                .font(.subheadline)
                        }
                        Button("Enable Notifications") {
                            notificationManager.requestPermission()
                        }
                        .buttonStyle(.borderedProminent)
                        Text("Allow notifications to receive price alerts")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            } else {
                Section {
                    Toggle("Enable Price & Spike Alerts", isOn: $priceAlertsEnabled)
                        .onChange(of: priceAlertsEnabled) { _, _ in
                            syncWithServer()
                        }
                } footer: {
                    Text("Receive push notifications when prices cross your thresholds, even when the app is closed.")
                }
                
                if priceAlertsEnabled {
                    Section("Export Prices") {
                        PriceAlertRow(
                            icon: "🚀",
                            title: "Sell Above",
                            subtitle: "High export price",
                            enabled: $sellAboveEnabled,
                            threshold: $sellAboveThreshold,
                            currentPrice: api.data?.sellPrice,
                            thresholdColor: .green,
                            isAbove: true,
                            onChanged: syncWithServer
                        )
                        
                        PriceAlertRow(
                            icon: "⚠️",
                            title: "Sell Below",
                            subtitle: "Low export price",
                            enabled: $sellBelowEnabled,
                            threshold: $sellBelowThreshold,
                            currentPrice: api.data?.sellPrice,
                            thresholdColor: .orange,
                            isAbove: false,
                            onChanged: syncWithServer
                        )
                    }
                    
                    Section("Import Prices") {
                        PriceAlertRow(
                            icon: "💰",
                            title: "Buy Below",
                            subtitle: "Low import price",
                            enabled: $buyBelowEnabled,
                            threshold: $buyBelowThreshold,
                            currentPrice: api.data?.buyPrice,
                            thresholdColor: .blue,
                            isAbove: false,
                            onChanged: syncWithServer
                        )
                        
                        PriceAlertRow(
                            icon: "⚠️",
                            title: "Buy Above",
                            subtitle: "High import price",
                            enabled: $buyAboveEnabled,
                            threshold: $buyAboveThreshold,
                            currentPrice: api.data?.buyPrice,
                            thresholdColor: .red,
                            isAbove: true,
                            onChanged: syncWithServer
                        )
                    }
                    
                    Section("Spike Alerts") {
                        SpikeAlertRow(
                            enabled: $spikeAlertsEnabled,
                            threshold: $spikeThreshold,
                            onChanged: syncWithServer
                        )
                    }
                    
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "bolt.fill")
                                    .foregroundColor(.green)
                                    .frame(width: 20)
                                Text("Push notifications are delivered even when the app is closed.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "clock")
                                    .foregroundColor(.blue)
                                    .frame(width: 20)
                                Text("Each alert type won't repeat within 30 minutes.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            // Sync status indicator
                            HStack(alignment: .top, spacing: 8) {
                                if isSyncing {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                        .frame(width: 20)
                                } else if let success = lastSyncSuccess {
                                    Image(systemName: success ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                        .foregroundColor(success ? .green : .orange)
                                        .frame(width: 20)
                                } else {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                        .foregroundColor(.secondary)
                                        .frame(width: 20)
                                }
                                Text(syncStatusText)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Price Alerts")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            notificationManager.checkAuthorization()
        }
    }
    
    private var syncStatusText: String {
        if isSyncing {
            return "Syncing settings..."
        } else if let success = lastSyncSuccess {
            return success ? "Settings synced to notification server." : "Failed to sync. Will retry."
        } else {
            return "Settings will sync when changed."
        }
    }
    
    private func syncWithServer() {
        // Debounce rapid changes (e.g., slider dragging)
        isSyncing = true
        
        Task {
            // Small delay to batch rapid changes
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            
            let success = await PushNotificationService.shared.registerWithCurrentSettings(api: api)
            
            await MainActor.run {
                isSyncing = false
                lastSyncSuccess = success
            }
        }
    }
}

// MARK: - Summary Helper
extension PriceAlertsSettingsView {
    /// Returns a summary string for display in parent settings view
    static func summary(
        enabled: Bool,
        sellAbove: Bool,
        sellBelow: Bool,
        buyAbove: Bool,
        buyBelow: Bool
    ) -> String {
        guard enabled else { return "Off" }
        let count = [sellAbove, sellBelow, buyAbove, buyBelow].filter { $0 }.count
        if count == 0 { return "Enabled" }
        return "\(count) active"
    }
}

// MARK: - Price Alert Row
struct PriceAlertRow: View {
    let icon: String
    let title: String
    let subtitle: String
    @Binding var enabled: Bool
    @Binding var threshold: Double
    let currentPrice: Double?
    let thresholdColor: Color
    let isAbove: Bool
    var onChanged: (() -> Void)? = nil
    
    @State private var showPrecisionEntry = false
    @State private var precisionText = ""
    @FocusState private var isTextFieldFocused: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $enabled) {
                HStack {
                    Text(icon)
                    VStack(alignment: .leading) {
                        Text(title)
                            .fontWeight(.medium)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .onChange(of: enabled) { _, _ in
                onChanged?()
            }
            .accessibilityLabel("\(title) alert: \(subtitle)")
            .accessibilityValue(enabled ? "Enabled, threshold \(String(format: "%.1f", threshold)) cents" : "Disabled")
            
            if enabled {
                VStack(alignment: .leading, spacing: 8) {
                    // Threshold display - tap for precision entry
                    HStack {
                        Text("Threshold:")
                            .font(.subheadline)
                        
                        if showPrecisionEntry {
                            HStack(spacing: 4) {
                                TextField("", text: $precisionText)
                                    .keyboardType(.decimalPad)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 70)
                                    .focused($isTextFieldFocused)
                                    .onSubmit { applyPrecisionValue() }
                                Text("¢/kWh")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                Button("Done") {
                                    applyPrecisionValue()
                                }
                                .font(.subheadline)
                            }
                        } else {
                            Text("\(Int(threshold))¢/kWh")
                                .font(.subheadline)
                                .foregroundColor(thresholdColor)
                                .onTapGesture {
                                    precisionText = String(format: "%.1f", threshold)
                                    showPrecisionEntry = true
                                    isTextFieldFocused = true
                                }
                            
                            Image(systemName: "pencil.circle")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                    }
                    
                    // Whole cent slider (-10 to 100)
                    Slider(value: $threshold, in: -10...100, step: 1)
                        .onChange(of: threshold) { _, _ in
                            onChanged?()
                        }
                        .accessibilityLabel("\(title) threshold")
                        .accessibilityValue("\(Int(threshold)) cents per kilowatt hour")
                    
                    // Range labels
                    HStack {
                        Text("-10¢")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("100¢")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    
                    if let current = currentPrice {
                        let triggered = isAbove ? current >= threshold : current <= threshold
                        HStack {
                            Text("Current:")
                                .font(.caption)
                            Spacer()
                            Text("\(String(format: "%.1f¢", current))/kWh")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(triggered ? thresholdColor : .secondary)
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(6)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Current price: \(String(format: "%.1f", current)) cents\(triggered ? ", alert would trigger" : "")")
                    }
                }
                .padding(.leading, 32)
            }
        }
        .padding(.vertical, 4)
    }
    
    private func applyPrecisionValue() {
        if let value = Double(precisionText) {
            threshold = value
            onChanged?()
        }
        showPrecisionEntry = false
        isTextFieldFocused = false
    }
}

// MARK: - Spike Alert Row
struct SpikeAlertRow: View {
    @Binding var enabled: Bool
    @Binding var threshold: Double
    var onChanged: (() -> Void)? = nil
    
    @State private var showPrecisionEntry = false
    @State private var precisionText = ""
    @FocusState private var isTextFieldFocused: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $enabled) {
                HStack {
                    Text("⚡")
                    VStack(alignment: .leading) {
                        Text("Price Spikes")
                            .fontWeight(.medium)
                        Text("Forecast prices above threshold")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .onChange(of: enabled) { _, _ in
                onChanged?()
            }
            
            if enabled {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Alert when forecast exceeds:")
                            .font(.subheadline)
                        
                        if showPrecisionEntry {
                            HStack(spacing: 4) {
                                TextField("", text: $precisionText)
                                    .keyboardType(.decimalPad)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 70)
                                    .focused($isTextFieldFocused)
                                    .onSubmit { applyPrecisionValue() }
                                Text("¢")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                Button("Done") {
                                    applyPrecisionValue()
                                }
                                .font(.subheadline)
                            }
                        } else {
                            Text("\(Int(threshold))¢/kWh")
                                .font(.subheadline)
                                .foregroundColor(.orange)
                                .onTapGesture {
                                    precisionText = String(format: "%.0f", threshold)
                                    showPrecisionEntry = true
                                    isTextFieldFocused = true
                                }
                            
                            Image(systemName: "pencil.circle")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                    }
                    
                    // Slider with common spike thresholds (20-200 cents)
                    Slider(value: $threshold, in: 20...200, step: 10)
                        .onChange(of: threshold) { _, _ in
                            onChanged?()
                        }
                    
                    HStack {
                        Text("20¢")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("200¢ ($2,000/MWh)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    
                    // Explanation
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle")
                            .foregroundColor(.blue)
                            .frame(width: 20)
                        Text("Get advance warning when forecast prices spike above your threshold in the next 12 hours.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 4)
                }
                .padding(.leading, 32)
            }
        }
        .padding(.vertical, 4)
    }
    
    private func applyPrecisionValue() {
        if let value = Double(precisionText) {
            threshold = value
            onChanged?()
        }
        showPrecisionEntry = false
        isTextFieldFocused = false
    }
}

#Preview {
    NavigationStack {
        PriceAlertsSettingsView()
            .environmentObject(PowstonAPI())
    }
}
