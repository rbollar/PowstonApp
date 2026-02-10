//
//  LeaderboardSettingsView.swift
//  Powston
//

import SwiftUI

struct LeaderboardSettingsView: View {
    @AppStorage("leaderboard_enabled") private var leaderboardEnabled: Bool = true
    @AppStorage("leaderboard_default_sort") private var defaultSort: String = "efficiency"
    @AppStorage("comparison_buy_rate") private var comparisonBuyRate: Double = 33.0
    @AppStorage("comparison_sell_rate") private var comparisonSellRate: Double = 5.0
    
    @State private var newPinnedSiteId: String = ""
    @State private var pinnedSiteError: String? = nil
    
    private var canAddPinnedSite: Bool {
        guard let siteId = Int(newPinnedSiteId), siteId > 0 else { return false }
        return LeaderboardState.shared.canAddMorePins() && !LeaderboardState.shared.isPinned(siteId)
    }
    
    private func addPinnedSite() {
        pinnedSiteError = nil
        
        guard let siteId = Int(newPinnedSiteId), siteId > 0 else {
            pinnedSiteError = "Enter a valid site ID"
            return
        }
        
        if LeaderboardState.shared.isPinned(siteId) {
            pinnedSiteError = "Site already pinned"
            return
        }
        
        if !LeaderboardState.shared.canAddMorePins() {
            pinnedSiteError = "Maximum 3 pinned sites"
            return
        }
        
        if LeaderboardState.shared.addPinnedSite(siteId) {
            newPinnedSiteId = ""
        }
    }
    
    var body: some View {
        Form {
            Section {
                Toggle("Show Leaderboard", isOn: $leaderboardEnabled)
            } footer: {
                Text("Compare your site's performance against other Powston users")
            }
            
            if leaderboardEnabled {
                Section {
                    Picker("Sort By", selection: Binding(
                        get: { LeaderboardRankingMode(rawValue: defaultSort) ?? .efficiency },
                        set: { defaultSort = $0.rawValue }
                    )) {
                        ForEach(LeaderboardRankingMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Default Ranking")
                } footer: {
                    Text(rankingModeDescription)
                }
                
                // MARK: - Pinned Sites Section
                Section {
                    let pinnedIds = Array(LeaderboardState.shared.pinnedSiteIds).sorted()
                    
                    if pinnedIds.isEmpty {
                        Text("No pinned sites")
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    } else {
                        ForEach(pinnedIds, id: \.self) { siteId in
                            HStack {
                                Image(systemName: "pin.fill")
                                    .foregroundColor(.blue)
                                    .font(.caption)
                                Text("Site \(siteId)")
                                    .font(.subheadline)
                                Spacer()
                                Button {
                                    LeaderboardState.shared.removePinnedSite(siteId)
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                    
                    // Add new pinned site
                    HStack {
                        TextField("Site ID", text: $newPinnedSiteId)
                            .keyboardType(.numberPad)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 120)
                        
                        Button {
                            addPinnedSite()
                        } label: {
                            Text("Add")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canAddPinnedSite)
                        
                        Spacer()
                        
                        Text("\(LeaderboardState.shared.pinnedSiteIds.count)/3")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    if let errorMessage = pinnedSiteError {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                } header: {
                    Text("Pinned Sites")
                } footer: {
                    Text("Pin up to 3 friend or rival sites to always see them on your leaderboard, regardless of filters.")
                }
                
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
                        Label("How Rankings Work", systemImage: "info.circle")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        
                        Text("**Bill** ranks by daily electricity cost. Lower is better—negative values are credits.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Text("**Net Benefit** compares your actual costs against a flat-rate tariff. Higher means more savings from arbitrage.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Text("**Efficiency** is Net Benefit per kWh of battery capacity, normalizing across system sizes.")
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
    
    private var rankingModeDescription: String {
        switch LeaderboardRankingMode(rawValue: defaultSort) ?? .efficiency {
        case .bill: return "Rank by lowest daily electricity bill"
        case .netBenefit: return "Rank by savings vs flat-rate tariff"
        case .efficiency: return "Rank by savings per kWh of battery"
        }
    }
}

// MARK: - Summary Helper
extension LeaderboardSettingsView {
    /// Returns a summary string for display in parent settings view
    static func summary(enabled: Bool, buyRate: Double, sellRate: Double, defaultSort: String = "efficiency") -> String {
        guard enabled else { return "Off" }
        let sortLabel = LeaderboardRankingMode(rawValue: defaultSort)?.displayName ?? "Efficiency"
        return "\(sortLabel)"
    }
}

#Preview {
    NavigationStack {
        LeaderboardSettingsView()
    }
}
