//
//  WatchContentView.swift
//  PowstonWatch
//

import SwiftUI

struct WatchContentView: View {
    @EnvironmentObject var api: WatchAPI
    @Environment(\.scenePhase) var scenePhase
    @State private var showSettings = false
    
    var body: some View {
        NavigationStack {
            Group {
                switch api.authState {
                case .checking:
                    ProgressView()
                    
                case .notConfigured:
                    notConfiguredView
                    
                case .configured, .demoMode:
                    if api.isLoading && api.data == nil {
                        ProgressView()
                    } else if let data = api.data {
                        mainView(data)
                    } else if let error = api.errorMessage {
                        errorView(error)
                    } else {
                        ProgressView()
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gear")
                            .font(.caption)
                    }
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            WatchSettingsView()
        }
        .task {
            await api.fetchData()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task { await api.fetchData() }
            }
        }
    }
    
    // MARK: - Main View
    
    func mainView(_ data: WatchData) -> some View {
        ScrollView {
            VStack(spacing: 8) {
                // Demo indicator
                if api.isDemoMode {
                    HStack(spacing: 4) {
                        Image(systemName: "theatermasks.fill")
                            .font(.system(size: 10))
                        Text("DEMO")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundColor(.orange)
                }
                
                // SOC Ring + Battery Flow
                HStack(spacing: 12) {
                    // SOC Ring
                    ZStack {
                        Circle()
                            .stroke(Color.gray.opacity(0.3), lineWidth: 8)
                        
                        Circle()
                            .trim(from: 0, to: data.soc / 100)
                            .stroke(socColor(data.soc), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        
                        Text("\(Int(data.soc))")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                    }
                    .frame(width: 80, height: 80)
                    
                    // Battery flow
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(format: "%.1f", data.batteryKw))
                            .font(.system(size: 32, weight: .bold, design: .rounded).monospacedDigit())
                        
                        HStack(spacing: 4) {
                            Image(systemName: data.isCharging ? "bolt.fill" : "arrow.down.circle.fill")
                                .font(.system(size: 14))
                            Text(data.isCharging ? "Chg kW" : "Dchg kW")
                                .font(.system(size: 14, weight: .medium))
                        }
                        .foregroundColor(data.isCharging ? .green : .orange)
                    }
                }
                
                Divider()
                    .padding(.vertical, 4)
                
                // Action badge
                HStack {
                    Text(data.action.uppercased())
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(actionColor(data.action).opacity(0.2))
                        .foregroundColor(actionColor(data.action))
                        .cornerRadius(6)
                    
                    Spacer()
                }
                
                // Prices
                HStack(spacing: 0) {
                    VStack(spacing: 2) {
                        Text("BUY")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                        Text(formatPrice(data.buyPrice))
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .foregroundColor(buyPriceColor(data.buyPrice))
                    }
                    .frame(maxWidth: .infinity)
                    
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 1, height: 36)
                    
                    VStack(spacing: 2) {
                        Text("SELL")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                        Text(formatPrice(data.sellPrice))
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .foregroundColor(sellPriceColor(data.sellPrice))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 4)
        }
    }
    
    // MARK: - Error View
    
    func errorView(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundColor(.orange)
            Text("Error")
                .font(.headline)
            Text(message)
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry") {
                Task { await api.fetchData() }
            }
            .font(.caption)
        }
    }
    
    // MARK: - Not Configured View
    
    var notConfiguredView: some View {
        VStack(spacing: 12) {
            Image(systemName: "icloud.and.arrow.down")
                .font(.title)
                .foregroundColor(.blue)
            
            Text("Setup Required")
                .font(.headline)
            
            Text("Open Powston on iPhone to sync, or configure manually in Settings.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            Button {
                showSettings = true
            } label: {
                Label("Settings", systemImage: "gear")
            }
            .padding(.top, 4)
        }
        .padding()
    }
    
    // MARK: - Helpers
    
    func socColor(_ soc: Double) -> Color {
        if soc >= 80 { return .green }
        if soc >= 50 { return .yellow }
        if soc >= 20 { return .orange }
        return .red
    }
    
    func actionColor(_ action: String) -> Color {
        switch action.lowercased() {
        case "import": return .blue
        case "export": return .green
        case "charge": return .yellow
        case "curtail": return .orange
        default: return .gray
        }
    }
    
    func buyPriceColor(_ price: Double) -> Color {
        if price < 0 { return .green }
        if price >= 50 { return .red }
        return .blue
    }
    
    func sellPriceColor(_ price: Double) -> Color {
        if price < 0 { return .red }
        if price >= 50 { return .green }
        return .green.opacity(0.8)
    }
    
    func formatPrice(_ price: Double) -> String {
        if abs(price) >= 100 {
            return String(format: "$%.2f", price / 100)
        }
        if price < 0 {
            return String(format: "-%.1f¢", abs(price))
        }
        return String(format: "%.1f¢", price)
    }
}

#Preview {
    WatchContentView()
        .environmentObject(WatchAPI())
}
