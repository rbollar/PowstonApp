//
//  DashboardView.swift
//  Powston
//

import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var api: PowstonAPI
    @State private var currentTime = Date()
    
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    
    var body: some View {
        NavigationStack {
            ScrollView {
                if let d = api.data {
                    VStack(spacing: 24) {
                        // Demo mode banner
                        if api.isDemoMode {
                            HStack {
                                Image(systemName: "theatermasks.fill")
                                    .foregroundColor(.orange)
                                Text("Demo Mode Active")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                Spacer()
                                Text("Using sample data")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding()
                            .background(Color.orange.opacity(0.15))
                            .cornerRadius(12)
                            .padding(.horizontal)
                        }
                        
                        // Data freshness indicator
                        if let intervalTime = d.forecastStartDate {
                            VStack(spacing: 4) {
                                HStack(spacing: 8) {
                                    Image(systemName: "clock")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text("Forecast from: \(formatDateTime(intervalTime))")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                if let lastFetch = api.lastFetchTime {
                                    HStack(spacing: 8) {
                                        Circle()
                                            .fill(dataAgeColor(lastFetch))
                                            .frame(width: 8, height: 8)
                                        Text("Updated \(timeAgo(lastFetch))")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                            .padding(.horizontal)
                            .padding(.top, 8)
                        }
                        
                        // SOC
                        VStack(spacing: 8) {
                            Text(String(format: "%.1f%%", d.batterySoc))
                                .font(.system(size: 64, weight: .bold, design: .rounded))
                                .foregroundColor(socColor(d.batterySoc))
                            
                            ProgressView(value: d.batterySoc / 100)
                                .tint(socColor(d.batterySoc))
                                .scaleEffect(x: 1, y: 3, anchor: .center)
                                .padding(.horizontal, 40)
                        }
                        .padding(.top, 20)
                        
                        // Action Badge
                        HStack {
                            Image(systemName: actionIcon(d.action))
                            Text(d.action.uppercased())
                                .fontWeight(.bold)
                        }
                        .foregroundColor(actionColor(d.action))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(actionColor(d.action).opacity(0.1))
                        .cornerRadius(12)
                        
                        // Power Flow
                        HStack(spacing: 24) {
                            PowerItem(icon: "sun.max.fill", value: String(format: "%.1f", d.solarKw), unit: "kW", label: "Solar", color: .yellow)
                            PowerItem(icon: "bolt.fill", value: String(format: "%.1f", d.gridKw), unit: "kW", label: "Grid", color: .blue)
                            PowerItem(icon: "house.fill", value: String(format: "%.1f", d.houseKw), unit: "kW", label: "Home", color: .purple)
                        }
                        .padding()
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(16)
                        .padding(.horizontal)
                        
                        // Prices
                        HStack(spacing: 12) {
                            PriceCard(title: "Buy", price: String(format: "%.2f", d.buyPrice), color: .blue)
                            PriceCard(title: "Sell", price: String(format: "%.2f", d.sellPrice), color: .green)
                            PriceCard(title: "RRP", price: String(format: "$%.0f", d.rrp), color: .orange, subtitle: "/MWh")
                        }
                        .padding(.horizontal)
                    }
                } else if api.isLoading {
                    ProgressView("Loading...")
                        .padding(.top, 100)
                } else if api.selectedInverterId == 0 {
                    WelcomeView()
                } else if let err = api.error {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundColor(.orange)
                        Text(err)
                            .foregroundColor(.secondary)
                        Button("Retry") {
                            Task { await api.fetchData() }
                        }
                    }
                    .padding(.top, 100)
                }
            }
            .background(Color.gray.opacity(0.05))
            .navigationTitle(api.isDemoMode ? "Powston (Demo)" : "Powston")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button(action: { Task { await api.fetchData() } }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(api.isLoading)
                }
            }
            .onReceive(timer) { _ in
                currentTime = Date()
            }
        }
    }
    
    func formatDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        formatter.timeZone = powstonTimezone()
        return formatter.string(from: date)
    }
    
    func timeAgo(_ date: Date) -> String {
        let seconds = Int(currentTime.timeIntervalSince(date))
        
        if seconds < 60 {
            return "just now"
        } else if seconds < 120 {
            return "1 minute ago"
        } else if seconds < 3600 {
            return "\(seconds / 60) minutes ago"
        } else if seconds < 7200 {
            return "1 hour ago"
        } else {
            return "\(seconds / 3600) hours ago"
        }
    }
    
    func dataAgeColor(_ date: Date) -> Color {
        let seconds = currentTime.timeIntervalSince(date)
        
        if seconds < 300 { return .green }
        else if seconds < 600 { return .yellow }
        else if seconds < 1800 { return .orange }
        else { return .red }
    }
    
    func socColor(_ soc: Double) -> Color {
        if soc >= 80 { return .green }
        if soc >= 40 { return .yellow }
        if soc >= 20 { return .orange }
        return .red
    }
    
    func actionIcon(_ action: String) -> String {
        switch action.lowercased() {
        case "import": return "arrow.down.circle.fill"
        case "export": return "arrow.up.circle.fill"
        case "charge": return "battery.100.bolt"
        default: return "arrow.triangle.2.circlepath"
        }
    }
    
    func actionColor(_ action: String) -> Color {
        switch action.lowercased() {
        case "import": return .blue
        case "export": return .green
        case "charge": return .yellow
        default: return .gray
        }
    }
}

// MARK: - Welcome View
struct WelcomeView: View {
    @EnvironmentObject var api: PowstonAPI
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "bolt.slash.circle")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            
            VStack(spacing: 8) {
                Text("Welcome to Powston")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Text("Monitor your solar, battery, and energy optimization")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            VStack(spacing: 16) {
                Button(action: {
                    api.demoModeEnabled = true
                    api.loadDemoData()
                }) {
                    VStack(spacing: 8) {
                        HStack {
                            Image(systemName: "theatermasks.fill")
                                .font(.title3)
                            Text("Try Demo Mode")
                                .font(.headline)
                        }
                        Text("Explore the app with sample data")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.orange.opacity(0.15))
                    .foregroundColor(.orange)
                    .cornerRadius(12)
                }
                
                NavigationLink(destination: SettingsView()) {
                    VStack(spacing: 8) {
                        HStack {
                            Image(systemName: "key.fill")
                                .font(.title3)
                            Text("Connect Your Account")
                                .font(.headline)
                        }
                        Text("Enter your API key to get started")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.green.opacity(0.15))
                    .foregroundColor(.green)
                    .cornerRadius(12)
                }
            }
            .padding(.horizontal, 30)
            
            VStack(spacing: 4) {
                Text("Not a Powston customer?")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Link("Learn more about Powston", destination: URL(string: "https://powston.com.au")!)
                    .font(.caption)
            }
            .padding(.top, 8)
        }
        .padding(.top, 60)
        .padding(.horizontal, 20)
    }
}
