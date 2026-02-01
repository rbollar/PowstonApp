//
//  LeaderboardSettingsView.swift
//  Powston
//

import SwiftUI

struct LeaderboardSettingsView: View {
    @AppStorage("leaderboard_enabled") private var leaderboardEnabled: Bool = true
    @AppStorage("comparison_buy_rate") private var comparisonBuyRate: Double = 33.0
    @AppStorage("comparison_sell_rate") private var comparisonSellRate: Double = 5.0
    
    var body: some View {
        Form {
            Section {
                Toggle("Show Leaderboard", isOn: $leaderboardEnabled)
            } footer: {
                Text("Compare your site's performance against other Powston users")
            }
            
            if leaderboardEnabled {
                Section("Net Benefit Comparison Rates") {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Set the flat-rate tariff to compare against your actual arbitrage performance")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        HStack(spacing: 24) {
                            VStack(alignment: .center, spacing: 4) {
                                Text("Buy Rate")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Picker("Buy Rate", selection: $comparisonBuyRate) {
                                    ForEach(Array(stride(from: 10.0, through: 60.0, by: 1.0)), id: \.self) { rate in
                                        Text("\(Int(rate))¢").tag(rate)
                                    }
                                }
                                .pickerStyle(.wheel)
                                .frame(width: 100, height: 120)
                                .clipped()
                                Text("per kWh")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            
                            VStack(alignment: .center, spacing: 4) {
                                Text("Sell Rate")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Picker("Sell Rate", selection: $comparisonSellRate) {
                                    ForEach(Array(stride(from: 0.0, through: 20.0, by: 1.0)), id: \.self) { rate in
                                        Text("\(Int(rate))¢").tag(rate)
                                    }
                                }
                                .pickerStyle(.wheel)
                                .frame(width: 100, height: 120)
                                .clipped()
                                Text("per kWh")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                        }
                    }
                    .padding(.vertical, 8)
                }
                
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("How Net Benefit Works", systemImage: "info.circle")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        
                        Text("Net Benefit compares your actual energy costs (using spot pricing and arbitrage) against what you would have paid on a simple flat-rate plan.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Text("A positive value means you're saving money compared to the flat rate. The leaderboard ranks users by this metric.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Leaderboard")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Summary Helper
extension LeaderboardSettingsView {
    /// Returns a summary string for display in parent settings view
    static func summary(enabled: Bool, buyRate: Double, sellRate: Double) -> String {
        guard enabled else { return "Off" }
        return "\(Int(buyRate))¢/\(Int(sellRate))¢"
    }
}

#Preview {
    NavigationStack {
        LeaderboardSettingsView()
    }
}
