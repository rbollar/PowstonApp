//
//  TVContentView.swift
//  PowstonTV
//
//  Main dashboard view for Apple TV
//

import SwiftUI

struct TVContentView: View {
    @EnvironmentObject var api: TVAPI
    @State private var showSettings = false
    
    var body: some View {
        Group {
            if !api.isConfigured {
                TVSetupView(showSettings: $showSettings)
            } else if api.isLoading && api.data == nil {
                loadingView
            } else if let data = api.data {
                TVDashboardView(data: data, showSettings: $showSettings)
            } else if let error = api.errorMessage {
                errorView(error)
            } else {
                loadingView
            }
        }
        .task {
            if api.isConfigured {
                await api.fetchData()
                api.startAutoRefresh(interval: 30)
            }
        }
        .onDisappear {
            api.stopAutoRefresh()
        }
        .sheet(isPresented: $showSettings) {
            TVSettingsView()
                .environmentObject(api)
        }
    }
    
    var loadingView: some View {
        VStack(spacing: 24) {
            ProgressView()
                .scaleEffect(2)
            Text("Loading...")
                .font(.title2)
                .foregroundColor(.secondary)
        }
    }
    
    func errorView(_ message: String) -> some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 64))
                .foregroundColor(.orange)
            Text("Error")
                .font(.title)
            Text(message)
                .font(.title3)
                .foregroundColor(.secondary)
            Button("Retry") {
                Task { await api.fetchData() }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Dashboard View

struct TVDashboardView: View {
    let data: TVData
    @Binding var showSettings: Bool
    @EnvironmentObject var api: TVAPI
    @State private var currentTime = Date()
    
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    
    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                colors: [Color.black, Color(white: 0.1)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Header bar
                headerBar
                    .padding(.horizontal, 80)
                    .padding(.top, 40)
                
                Spacer()
                
                // Main content
                HStack(alignment: .center, spacing: 80) {
                    // Left: SOC Ring
                    socRingView
                    
                    // Center: Action + Power Stats
                    VStack(spacing: 40) {
                        actionBadge
                        powerStatsGrid
                    }
                    
                    // Right: Prices + P&L placeholder
                    VStack(spacing: 24) {
                        priceCard(label: "BUY", cents: data.buyPrice, isBuy: true)
                        priceCard(label: "SELL", cents: data.sellPrice, isBuy: false)
                    }
                }
                .padding(.horizontal, 80)
                
                Spacer()
                
                // Footer
                footerBar
                    .padding(.horizontal, 80)
                    .padding(.bottom, 40)
            }
        }
        .onReceive(timer) { _ in
            currentTime = Date()
        }
        .onLongPressGesture(minimumDuration: 1.0) {
            showSettings = true
        }
    }
    
    // MARK: - Header
    
    var headerBar: some View {
        HStack {
            // Logo / App name
            HStack(spacing: 12) {
                Image(systemName: "bolt.circle.fill")
                    .font(.system(size: 36))
                    .foregroundColor(.green)
                Text("POWSTON")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                
                if let siteName = data.siteName {
                    Text("•")
                        .foregroundColor(.gray)
                    Text(siteName)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundColor(.gray)
                }
            }
            
            Spacer()
            
            // Time + Weather placeholder
            HStack(spacing: 24) {
                Text(timeString)
                    .font(.system(size: 32, weight: .medium, design: .rounded))
                    .foregroundColor(.white)
                    .monospacedDigit()
            }
        }
    }
    
    var timeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: currentTime)
    }
    
    // MARK: - SOC Ring
    
    var socRingView: some View {
        ZStack {
            // Background ring
            Circle()
                .stroke(Color.gray.opacity(0.3), lineWidth: 24)
            
            // Progress ring
            Circle()
                .trim(from: 0, to: data.soc / 100)
                .stroke(
                    socColor,
                    style: StrokeStyle(lineWidth: 24, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.5), value: data.soc)
            
            // Center text
            VStack(spacing: 4) {
                Text("\(Int(data.soc))")
                    .font(.system(size: 96, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text("%")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundColor(.gray)
                Text("SOC")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundColor(.gray)
            }
        }
        .frame(width: 300, height: 300)
    }
    
    var socColor: Color {
        if data.soc >= 80 { return .green }
        if data.soc >= 50 { return .yellow }
        if data.soc >= 20 { return .orange }
        return .red
    }
    
    // MARK: - Action Badge
    
    var actionBadge: some View {
        HStack(spacing: 12) {
            Image(systemName: actionIcon)
                .font(.system(size: 32))
            Text(actionText)
                .font(.system(size: 36, weight: .bold, design: .rounded))
        }
        .foregroundColor(actionColor)
        .padding(.horizontal, 40)
        .padding(.vertical, 16)
        .background(actionColor.opacity(0.2))
        .cornerRadius(20)
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(actionColor, lineWidth: 2)
        )
    }
    
    var actionText: String {
        switch data.action.lowercased() {
        case "charge", "import": return "IMPORTING"
        case "discharge", "export": return "EXPORTING"
        case "auto": return data.isGridExporting ? "EXPORTING" : "AUTO"
        case "curtail": return "CURTAILED"
        default: return data.action.uppercased()
        }
    }
    
    var actionIcon: String {
        switch data.action.lowercased() {
        case "charge", "import": return "arrow.down.circle.fill"
        case "discharge", "export": return "arrow.up.circle.fill"
        case "auto": return data.isGridExporting ? "arrow.up.circle.fill" : "arrow.triangle.2.circlepath"
        case "curtail": return "hand.raised.fill"
        default: return "bolt.circle.fill"
        }
    }
    
    var actionColor: Color {
        switch data.action.lowercased() {
        case "charge", "import": return .blue
        case "discharge", "export": return .green
        case "curtail": return .orange
        default: return data.isGridExporting ? .green : .cyan
        }
    }
    
    // MARK: - Power Stats
    
    var powerStatsGrid: some View {
        VStack(spacing: 24) {
            HStack(spacing: 48) {
                powerStat(icon: "sun.max.fill", value: data.solarKw, label: "Solar", color: .yellow)
                powerStat(icon: "house.fill", value: data.houseKw, label: "Home", color: .purple)
            }
            HStack(spacing: 48) {
                powerStat(
                    icon: data.isGridExporting ? "arrow.up.forward.circle.fill" : "arrow.down.backward.circle.fill",
                    value: data.gridKw,
                    label: data.isGridExporting ? "Export" : "Import",
                    color: data.isGridExporting ? .green : .blue
                )
                powerStat(
                    icon: data.isCharging ? "battery.100.bolt" : "battery.75",
                    value: data.batteryKw,
                    label: data.isCharging ? "Charging" : "Discharge",
                    color: data.isCharging ? .green : .orange
                )
            }
        }
    }
    
    func powerStat(icon: String, value: Double, label: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundColor(color)
                .frame(width: 36)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: "%.1f kW", value))
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .monospacedDigit()
                Text(label)
                    .font(.system(size: 18))
                    .foregroundColor(.gray)
            }
        }
        .frame(width: 180, alignment: .leading)
    }
    
    // MARK: - Price Cards
    
    func priceCard(label: String, cents: Double, isBuy: Bool) -> some View {
        let color = isBuy ? buyPriceColor(cents) : sellPriceColor(cents)
        
        return VStack(spacing: 8) {
            Text(label)
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(color)
            
            Text(formatPrice(cents))
                .font(.system(size: 48, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .monospacedDigit()
        }
        .frame(width: 200)
        .padding(.vertical, 24)
        .background(color.opacity(0.15))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(color.opacity(0.5), lineWidth: 2)
        )
    }
    
    func formatPrice(_ cents: Double) -> String {
        if abs(cents) >= 100 {
            return String(format: "$%.2f", cents / 100)
        }
        return String(format: "%.1f¢", cents)
    }
    
    func buyPriceColor(_ cents: Double) -> Color {
        if cents < 0 { return .green }
        if cents >= 50 { return .orange }
        return .blue
    }
    
    func sellPriceColor(_ cents: Double) -> Color {
        if cents < 0 { return .red }
        return .green
    }
    
    // MARK: - Footer
    
    var footerBar: some View {
        HStack {
            // Last updated
            HStack(spacing: 8) {
                Circle()
                    .fill(api.isLoading ? Color.orange : Color.green)
                    .frame(width: 10, height: 10)
                Text(lastUpdatedText)
                    .font(.system(size: 18))
                    .foregroundColor(.gray)
            }
            
            Spacer()
            
            // Hint for settings
            Text("Hold to open settings")
                .font(.system(size: 16))
                .foregroundColor(.gray.opacity(0.5))
        }
    }
    
    var lastUpdatedText: String {
        let seconds = Int(currentTime.timeIntervalSince(data.lastUpdated))
        if seconds < 5 { return "Updated just now" }
        if seconds < 60 { return "Updated \(seconds)s ago" }
        let minutes = seconds / 60
        return "Updated \(minutes)m ago"
    }
}

// MARK: - Setup View (Not Configured)

struct TVSetupView: View {
    @Binding var showSettings: Bool
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            VStack(spacing: 40) {
                Image(systemName: "bolt.circle.fill")
                    .font(.system(size: 120))
                    .foregroundColor(.green)
                
                Text("POWSTON")
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                
                Text("Energy Dashboard")
                    .font(.system(size: 28))
                    .foregroundColor(.gray)
                
                Spacer().frame(height: 40)
                
                Button(action: { showSettings = true }) {
                    HStack(spacing: 12) {
                        Image(systemName: "gear")
                        Text("Configure")
                    }
                    .font(.system(size: 24, weight: .semibold))
                    .padding(.horizontal, 48)
                    .padding(.vertical, 16)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
        }
    }
}

// MARK: - Preview

#Preview {
    let api = TVAPI()
    return TVContentView()
        .environmentObject(api)
}
