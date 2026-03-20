//
//  PeerPowerView.swift
//  Powston
//
//  Detail view for P2P trading opportunity analysis and contract tracking
//

import SwiftUI
import Charts

// MARK: - Educational Disclosure Component

struct P2PEducationalDisclosure: View {
    let title: String
    let content: [String]
    @Binding var isExpanded: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    
                    Text(title)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            
            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(content, id: \.self) { item in
                        HStack(alignment: .top, spacing: 8) {
                            Text("•")
                                .foregroundColor(.secondary)
                            Text(item)
                                .foregroundColor(.secondary)
                        }
                        .font(.caption)
                    }
                }
                .padding(10)
                .background(Color(.tertiarySystemBackground))
                .cornerRadius(8)
            }
        }
    }
}

// MARK: - Tab Selection (within Selling/Buying modes)

enum PeerPowerTab: String, CaseIterable {
    case analysis = "Analysis"
    case contracts = "Contracts"
    case counterparties = "Counterparties"  // Display name set dynamically based on trade direction
}

// MARK: - View Mode (Selling vs Buying vs Market - top level)

enum P2PViewMode: String, CaseIterable {
    case selling = "Selling"
    case buying = "Buying"
    case market = "Market"
}

// MARK: - Contract Period Selection

enum ContractPeriod: String, CaseIterable {
    case sevenDay = "7 Day"
    case fourWeek = "4 Wk"
    case custom = "Custom"

    var days: Int? {
        switch self {
        case .sevenDay: return 7
        case .fourWeek: return 28
        case .custom: return nil
        }
    }
}

// MARK: - Main View

struct PeerPowerView: View {
    @EnvironmentObject var api: PowstonAPI
    @StateObject private var analysis = PeerPowerAnalysis()
    @StateObject private var lvService = LocalVoltsService.shared
    @State private var showLVSetup = false  // For LV credentials setup
    @State private var selectedTab: PeerPowerTab = .analysis
    @State private var viewMode: P2PViewMode = .selling  // Selling or Buying analysis mode
    @State private var refreshTrigger = UUID()  // Triggers view refresh after import

    // Disclosure expansion states
    @State private var showHowItWorks = false
    @State private var showSpreadHelp = false
    // Note: showRecommendationHelp, showTradeoffHelp removed - no longer needed after reorganization
    @State private var showScenariosHelp = false
    @State private var showHourlyHelp = false

    // Contract period selection
    @State private var contractPeriod: ContractPeriod = {
        if let raw = UserDefaults.standard.string(forKey: "contract_suggestion_period"),
           let period = ContractPeriod(rawValue: raw) {
            return period
        }
        return .sevenDay
    }()
    @State private var customDays: Int = UserDefaults.standard.object(forKey: "contract_suggestion_custom_days") as? Int ?? 30

    // P2P Export Override via Training Parameters
    @State private var p2pParams: TrainingParameters?
    @State private var isLoadingP2PParams = true
    @State private var showP2PConfig = false
    @State private var isSavingP2PParams = false

    // Editing values for P2P config sheet
    @State private var editPower: Int = 0
    @State private var editStartHour: Int = 17
    @State private var editEndHour: Int = 20

    // Current (saved) values - to show comparison
    @State private var currentPower: Int = 0
    @State private var currentStartHour: Int = 17
    @State private var currentEndHour: Int = 20
    @State private var currentLvBudget: Double? = nil

    // Recommended values from analysis (passed when opening sheet)
    @State private var recommendedPower: Int = 0
    @State private var recommendedStartHour: Int = 17
    @State private var recommendedEndHour: Int = 20

    // LV Export Budget (weekly kWh limit)
    @State private var editLvBudget: Double = 0
    @State private var hasLvBudgetSet: Bool = false

    // Track when we're waiting for analysis to start
    @State private var isStartingAnalysis = false

    // First-visit P2P onboarding popup
    @AppStorage("p2p_first_visit_seen") private var p2pFirstVisitSeen: Bool = false
    @State private var showP2POnboarding = false

    // Market demand detail disclosure
    @State private var showMarketDemandDetail = false
    @State private var showScenariosDetail = false

    // Analysis detail tab selection (Market Demand vs Trade Scenarios)
    @State private var analysisDetailTab: AnalysisDetailTab = .demand

    enum AnalysisDetailTab: String, CaseIterable {
        case demand = "Market Demand"
        case scenarios = "Win-Win"
    }

    var config: AnalysisConfig? {
        guard let site = api.selectedSite else { return nil }
        return AnalysisConfig.from(site: site)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Top-level mode picker (Selling / Buying / Market)
            viewModePicker
                .padding(.horizontal)
                .padding(.top, 8)

            // Tab segmented control - only shown for Selling/Buying modes
            if viewMode != .market {
                Picker("View", selection: $selectedTab) {
                    ForEach(PeerPowerTab.allCases, id: \.self) { tab in
                        Text(tabDisplayName(for: tab)).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 4)
                .padding(.bottom, 4)
            }

            // Content based on mode
            if viewMode == .market {
                // Market mode - show market overview directly
                marketTab
            } else {
                // Selling/Buying modes - show tab content
                switch selectedTab {
                case .analysis:
                    analysisTab
                case .contracts:
                    contractsTab
                case .counterparties:
                    counterpartiesTab
                }
            }
        }
        .navigationTitle("Peer Power")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if !p2pFirstVisitSeen {
                showP2POnboarding = true
            }
        }
        .sheet(isPresented: $showP2POnboarding) {
            P2POnboardingSheet(onDismiss: {
                p2pFirstVisitSeen = true
                showP2POnboarding = false
            })
        }
        // Manual CSV import available via P2PTradeImportView if needed
    }

    // Returns display name for tab - counterparties tab is dynamic based on trade direction
    private func tabDisplayName(for tab: PeerPowerTab) -> String {
        switch tab {
        case .analysis:
            return "Analysis"
        case .contracts:
            return "Contracts"
        case .counterparties:
            // In selling mode, show buyers; in buying mode, show sellers
            return viewMode == .selling ? "Buyers" : "Sellers"
        }
    }
    
    // MARK: - Analysis Tab

    private var analysisTab: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Content based on trade direction (picker is now at top level)
                if viewMode == .selling {
                    sellingAnalysisContent
                } else {
                    buyingAnalysisContent
                }
            }
            .padding()
        }
        .onAppear {
            loadCachedOrRun()
            Task { await loadP2PParams() }
        }
    }

    // MARK: - Top-Level Mode Picker (Selling / Buying / Market)

    private var viewModePicker: some View {
        HStack(spacing: 0) {
            ForEach(P2PViewMode.allCases, id: \.self) { mode in
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewMode = mode
                    }
                }) {
                    Text(mode.rawValue)
                        .font(.subheadline)
                        .fontWeight(viewMode == mode ? .semibold : .regular)
                        .foregroundColor(viewMode == mode ? .white : .primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            viewMode == mode ? modeColor(for: mode) : Color.clear
                        )
                }
            }
        }
        .background(Color(.secondarySystemBackground))
        .cornerRadius(8)
    }

    private func modeColor(for mode: P2PViewMode) -> Color {
        switch mode {
        case .selling: return .green
        case .buying: return .orange
        case .market: return .purple
        }
    }

    // MARK: - Selling Analysis Content

    private var sellingAnalysisContent: some View {
        VStack(spacing: 20) {
            if analysis.isAnalyzing || isStartingAnalysis {
                loadingView
            } else if let result = analysis.result {
                resultsView(result)
            } else if let error = analysis.error {
                errorView(error)
            } else {
                startView
            }
        }
    }

    // MARK: - Buying Analysis Content

    private var buyingAnalysisContent: some View {
        VStack(spacing: 20) {
            if analysis.isAnalyzingBuyer {
                buyerLoadingView
            } else if let result = analysis.buyerResult {
                buyerResultsView(result)
            } else if let error = analysis.buyerError {
                buyerErrorView(error)
            } else {
                buyerStartView
            }
        }
        .onAppear {
            loadCachedOrRunBuyer()
        }
    }

    // MARK: - Buyer Start View

    private var buyerStartView: some View {
        VStack(spacing: 20) {
            Image(systemName: "cart.fill")
                .font(.system(size: 50))
                .foregroundColor(.orange)

            Text("P2P Buying Analysis")
                .font(.title2.bold())

            Text("Analyze your import patterns to find optimal P2P buy prices during solar hours.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            // Quick tip before analysis
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "sparkles")
                        .foregroundColor(.yellow)
                    Text("Quick Start")
                        .font(.caption.bold())
                }

                Text("For solar hours (10am-4pm), try **6¢ / 5¢** (buy now / standing). Set contracts 5-7 days ahead for best fill rates.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(12)
            .background(Color(.tertiarySystemBackground))
            .cornerRadius(8)

            Button(action: runBuyerAnalysis) {
                Label("Run Analysis", systemImage: "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.orange)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
            .padding(.top)
        }
        .padding()
    }

    // MARK: - Buyer Loading View

    private var buyerLoadingView: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .stroke(Color.orange.opacity(0.2), lineWidth: 4)
                    .frame(width: 60, height: 60)

                Circle()
                    .trim(from: 0, to: 0.7)
                    .stroke(Color.orange, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .frame(width: 60, height: 60)
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: analysis.isAnalyzingBuyer)

                ProgressView()
                    .scaleEffect(1.5)
            }

            VStack(spacing: 8) {
                Text("Analyzing Import Patterns")
                    .font(.headline)
                    .foregroundColor(.primary)

                Text(analysis.progress)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
        .padding(.horizontal, 40)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(16)
    }

    // MARK: - Buyer Error View

    private func buyerErrorView(_ error: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundColor(.orange)

            Text(error)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button("Try Again", action: runBuyerAnalysis)
                .buttonStyle(.bordered)
        }
        .padding()
    }

    // MARK: - Buyer Results View

    private func buyerResultsView(_ result: P2PBuyerResult) -> some View {
        VStack(spacing: 20) {
            // 1. Tiered contract recommendation - the actionable output
            if let tiered = result.tieredRecommendation {
                buyerTieredContractCard(tiered)
            }

            // 2. Hedge metrics - why this matters
            buyerHedgeCard(result)

            // 3. Price scenarios table
            buyerScenariosCard(result)

            // 4. Hourly breakdown
            buyerHourlyCard(result)

            // 5. Strategy tips
            buyerStrategyCard

            // Footer
            buyerFooterView(result)
        }
    }

    // MARK: - Buyer Tiered Contract Card

    private func buyerTieredContractCard(_ tiered: P2PBuyTieredRecommendation) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "doc.text.fill")
                    .foregroundColor(.orange)
                Text("Buy Contract")
                    .font(.headline)
                Spacer()
                Text("Weekly")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.2))
                    .cornerRadius(4)
            }

            Divider()

            // Window
            HStack {
                Image(systemName: "clock")
                    .foregroundColor(.cyan)
                Text("\(formatHour(tiered.startHour)) - \(formatHour(tiered.endHour))")
                    .font(.title3.bold())
                Spacer()
                Text("\(String(format: "%.1f", tiered.totalWeeklyKwh)) kWh")
                    .font(.title3.bold())
                    .foregroundColor(.orange)
            }

            Text(tiered.windowRationale)
                .font(.caption)
                .foregroundColor(.secondary)

            // Basis
            HStack {
                Text("Based on min daily import:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(String(format: "%.1f", tiered.minDailyImportKwh)) kWh/day")
                    .font(.caption.bold())
            }

            Divider()

            // Tier table header
            HStack(spacing: 4) {
                Text("Price")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 45, alignment: .leading)
                Text("Alloc")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 45, alignment: .trailing)
                Text("kWh")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 50, alignment: .trailing)
                Text("Fill%")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 45, alignment: .trailing)
                Text("Cost")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 4)

            // Tier rows
            ForEach(tiered.tiers) { tier in
                HStack(spacing: 4) {
                    Text(String(format: "%.0f¢", tier.priceCents))
                        .font(.caption.monospaced())
                        .foregroundColor(.orange)
                        .frame(width: 45, alignment: .leading)

                    Text(String(format: "%.0f%%", tier.percentage))
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                        .frame(width: 45, alignment: .trailing)

                    Text(String(format: "%.1f", tier.weeklyKwh))
                        .font(.caption.monospaced())
                        .frame(width: 50, alignment: .trailing)

                    Text(String(format: "%.0f%%", tier.expectedFillRate))
                        .font(.caption.monospaced())
                        .foregroundColor(fillRateColor(tier.expectedFillRate))
                        .frame(width: 45, alignment: .trailing)

                    Text(String(format: "$%.2f", tier.expectedCost))
                        .font(.caption.monospaced())
                        .foregroundColor(.cyan)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            }

            Divider()

            // Totals
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Expected cost")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(String(format: "$%.2f/wk", tiered.expectedWeeklyCost))
                        .font(.subheadline.bold())
                        .foregroundColor(.cyan)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("Hedge value")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(String(format: "$%.2f", tiered.hedgeValue))
                        .font(.subheadline.bold())
                        .foregroundColor(.green)
                }
            }

            // Protection explanation
            Text("Protected up to \(String(format: "%.0f", tiered.maxSpikeProtection))¢ spike. Unfilled tiers fall back to spot (no extra cost).")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(8)
                .background(Color.green.opacity(0.1))
                .cornerRadius(6)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    // MARK: - Buyer Hedge Card

    private func buyerHedgeCard(_ result: P2PBuyerResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "shield.fill")
                    .foregroundColor(.green)
                Text("Hedge Analysis")
                    .font(.headline)
                Spacer()
            }

            Divider()

            // Price distribution
            HStack(spacing: 0) {
                VStack(spacing: 2) {
                    Text(String(format: "%.0f¢", result.p25SpotPrice))
                        .font(.title3.bold())
                        .foregroundColor(.green)
                    Text("25th %ile")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)

                VStack(spacing: 2) {
                    Text(String(format: "%.0f¢", result.p50SpotPrice))
                        .font(.title3.bold())
                        .foregroundColor(.cyan)
                    Text("Median")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)

                VStack(spacing: 2) {
                    Text(String(format: "%.0f¢", result.p75SpotPrice))
                        .font(.title3.bold())
                        .foregroundColor(.orange)
                    Text("75th %ile")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)

                VStack(spacing: 2) {
                    Text(String(format: "%.0f¢", result.maxSpotPrice))
                        .font(.title3.bold())
                        .foregroundColor(.red)
                    Text("Max spike")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
            }

            // Spike frequency
            HStack {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundColor(.orange)
                    .font(.caption)
                Text("Spikes (>15¢): \(result.spikeIntervals) intervals (\(String(format: "%.1f", result.spikePercent))%)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Hedge value explanation
            VStack(alignment: .leading, spacing: 4) {
                Text("Why hedge?")
                    .font(.caption.bold())
                    .foregroundColor(.primary)
                Text("P2P buy contracts protect against spikes. If spot hits \(String(format: "%.0f", result.maxSpotPrice))¢ but your P2P fills at 8¢, you save \(String(format: "%.0f", result.maxSpotPrice - 8))¢/kWh. Cost of hedge: $0 (unfilled P2P = spot).")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(8)
            .background(Color.green.opacity(0.1))
            .cornerRadius(6)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    // MARK: - Buyer Recommendation Card

    private func buyerRecommendationCard(_ result: P2PBuyerResult) -> some View {
        let rec = result.recommendation

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "target")
                    .foregroundColor(.orange)
                Text("Recommended Strategy")
                    .font(.headline)
                Spacer()
            }

            Divider()

            // Key metrics
            HStack(spacing: 0) {
                VStack(spacing: 2) {
                    Text(String(format: "%.0f¢", rec.priceCap))
                        .font(.title2.bold())
                        .foregroundColor(.orange)
                    Text("Price Cap")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)

                VStack(spacing: 2) {
                    Text(String(format: "%.0f%%", rec.expectedFillRate))
                        .font(.title2.bold())
                        .foregroundColor(.green)
                    Text("Fill Rate")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)

                VStack(spacing: 2) {
                    Text(String(format: "$%.2f", rec.expectedSavings))
                        .font(.title2.bold())
                        .foregroundColor(.cyan)
                    Text("Savings/wk")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
            }

            // Window
            HStack {
                Image(systemName: "clock")
                    .foregroundColor(.secondary)
                Text("Import Window: \(formatHour(rec.startHour))-\(formatHour(rec.endHour))")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(Int(rec.weeklyBudgetKwh)) kWh/week")
                    .font(.subheadline.bold())
                    .foregroundColor(.orange)
            }

            // Rationale
            Text(rec.rationale)
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(8)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(6)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    // MARK: - Buyer Scenarios Card

    private func buyerScenariosCard(_ result: P2PBuyerResult) -> some View {
        // Compute scenarios to show BEFORE the ViewBuilder
        let scenariosToShow = computeBuyerScenariosToShow(result)
        let recCap = result.recommendation.priceCap
        let minCap = result.scenarios.map { $0.priceCap }.min() ?? 0
        let maxCap = result.scenarios.map { $0.priceCap }.max() ?? 20

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "slider.horizontal.3")
                    .foregroundColor(.orange)
                Text("Price Cap Analysis")
                    .font(.headline)
                Spacer()
            }

            Divider()

            // Show price distribution summary
            HStack {
                Text("Range: \(String(format: "%.0f", minCap))¢ to \(String(format: "%.0f", maxCap))¢")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(result.scenarios.count) scenarios")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Table header
            HStack(spacing: 4) {
                Text("Cap")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 32, alignment: .leading)
                Text("Fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 36, alignment: .trailing)
                Text("Eff¢")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 32, alignment: .trailing)
                Text("Spot")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 50, alignment: .trailing)
                Text("Grid")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 50, alignment: .trailing)
            }
            .padding(.horizontal, 4)

            ForEach(scenariosToShow) { scenario in
                let isRecommended = abs(scenario.priceCap - recCap) < 0.5

                HStack(spacing: 4) {
                    Text(String(format: "%.0f¢", scenario.priceCap))
                        .font(.caption.monospaced())
                        .foregroundColor(isRecommended ? .orange : .primary)
                        .fontWeight(isRecommended ? .bold : .regular)
                        .frame(width: 32, alignment: .leading)

                    Text(String(format: "%.0f%%", scenario.expectedFillRate))
                        .font(.caption.monospaced())
                        .foregroundColor(fillRateColor(scenario.expectedFillRate))
                        .frame(width: 36, alignment: .trailing)

                    Text(String(format: "%.1f", scenario.effectivePrice))
                        .font(.caption.monospaced())
                        .foregroundColor(.primary)
                        .frame(width: 32, alignment: .trailing)

                    // vs Spot (primary metric for solar hours)
                    Text(formatSavingsShort(scenario.savingsVsSpot))
                        .font(.caption.monospaced())
                        .foregroundColor(scenario.savingsVsSpot >= 0 ? .green : .red)
                        .frame(width: 50, alignment: .trailing)

                    // vs Grid
                    Text(formatSavingsShort(scenario.savingsVsGrid))
                        .font(.caption.monospaced())
                        .foregroundColor(scenario.savingsVsGrid > 0 ? .cyan : .secondary)
                        .frame(width: 50, alignment: .trailing)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
                .background(isRecommended ? Color.orange.opacity(0.2) : Color.clear)
                .cornerRadius(4)
            }

            // Legend - compact
            Text("Fill = P2P fill% • Eff¢ = blended cost • Spot/Grid = weekly savings vs baseline")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.top, 4)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    /// Compute which scenarios to show in the buyer scenarios table
    private func computeBuyerScenariosToShow(_ result: P2PBuyerResult) -> [P2PBuyPriceScenario] {
        let recCap = result.recommendation.priceCap

        // 1. All scenarios near recommendation (±3¢)
        let nearRec = result.scenarios.filter { abs($0.priceCap - recCap) <= 3 }
        // 2. Key scenarios at 5¢ intervals
        let atFives = result.scenarios.filter { Int($0.priceCap) % 5 == 0 }
        // 3. Min and max
        let endpoints = [result.scenarios.first, result.scenarios.last].compactMap { $0 }

        var scenariosToShow: [P2PBuyPriceScenario] = []
        var seenCaps: Set<Double> = []

        // Add in priority order, deduplicating
        for scenario in (nearRec + atFives + endpoints) {
            if !seenCaps.contains(scenario.priceCap) {
                scenariosToShow.append(scenario)
                seenCaps.insert(scenario.priceCap)
            }
        }

        // Sort by price cap
        return scenariosToShow.sorted { $0.priceCap < $1.priceCap }
    }

    private func fillRateColor(_ rate: Double) -> Color {
        if rate >= 80 { return .green }
        if rate >= 50 { return .yellow }
        if rate >= 20 { return .orange }
        return .secondary
    }

    private func formatSavings(_ value: Double) -> String {
        if abs(value) < 0.01 { return "$0" }
        return String(format: "%@$%.2f", value >= 0 ? "" : "-", abs(value))
    }

    private func formatSavingsShort(_ value: Double) -> String {
        if abs(value) < 0.01 { return "$0" }
        // Compact format: $12 or -$5
        if abs(value) >= 10 {
            return String(format: "%@$%.0f", value >= 0 ? "" : "-", abs(value))
        }
        return String(format: "%@$%.1f", value >= 0 ? "" : "-", abs(value))
    }

    // MARK: - Buyer Hourly Card

    private func buyerHourlyCard(_ result: P2PBuyerResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "clock.fill")
                    .foregroundColor(.orange)
                Text("Hourly Import Pattern")
                    .font(.headline)
                Spacer()
            }

            Divider()

            // Table header
            HStack(spacing: 0) {
                Text("Hour")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 60, alignment: .leading)
                Text("kWh")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 50, alignment: .trailing)
                Text("Grid¢")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 50, alignment: .trailing)
                Text("Spot¢")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 4)

            ForEach(result.hourlyBreakdown) { hourData in
                HStack(spacing: 0) {
                    Text(formatHour(hourData.hour))
                        .font(.caption.monospaced())
                        .frame(width: 60, alignment: .leading)

                    Text(String(format: "%.1f", hourData.dailyKwh))
                        .font(.caption.monospaced())
                        .foregroundColor(.orange)
                        .frame(width: 50, alignment: .trailing)

                    Text(String(format: "%.0f", hourData.avgGridPrice))
                        .font(.caption.monospaced())
                        .foregroundColor(.red)
                        .frame(width: 50, alignment: .trailing)

                    Text(String(format: "%.0f", hourData.avgSpotPrice))
                        .font(.caption.monospaced())
                        .foregroundColor(.cyan)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    // MARK: - Buyer Strategy Card

    private var buyerStrategyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "lightbulb.fill")
                    .foregroundColor(.yellow)
                Text("Buying Strategy")
                    .font(.headline)
                Spacer()
            }

            Divider()

            // Recommended pricing
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "target")
                        .foregroundColor(.orange)
                        .font(.caption)
                    Text("Recommended for Solar Hours (10am-4pm)")
                        .font(.caption.bold())
                }

                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Buy Now")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("6¢")
                            .font(.title3.bold())
                            .foregroundColor(.orange)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Standing")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("5¢")
                            .font(.title3.bold())
                            .foregroundColor(.green)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Expected")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("~5.5¢")
                            .font(.subheadline.bold())
                            .foregroundColor(.cyan)
                        Text("blended")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(10)
                .background(Color(.tertiarySystemBackground))
                .cornerRadius(8)
            }

            Divider()

            // Strategy tips
            VStack(alignment: .leading, spacing: 6) {
                strategyRow(num: "1", text: "Set contracts 5-7 days ahead — sellers commit at lower prices when planning")
                strategyRow(num: "2", text: "Most sellers price at 5-6¢ during solar surplus hours")
                strategyRow(num: "3", text: "Below 4¢ has little supply; above 6¢ has diminishing returns")
                strategyRow(num: "4", text: "Unfilled P2P falls back to spot automatically")
            }

            Text("Advance contracts typically achieve 5-5.5¢ blended vs 6.5-7¢ for same-week. The standing offer (5¢) does most of the work.")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 4)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    // MARK: - Buyer Footer View

    private func buyerFooterView(_ result: P2PBuyerResult) -> some View {
        VStack(spacing: 8) {
            Text("Based on \(result.periodDays) days of import data")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(spacing: 16) {
                Button(action: runBuyerAnalysis) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.bordered)

                Button(action: {
                    if let config = config {
                        analysis.clearBuyerCache(config: config)
                    }
                }) {
                    Label("Clear Cache", systemImage: "trash")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
        }
    }

    private func strategyRow(num: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(num)
                .font(.caption.bold())
                .foregroundColor(.orange)
                .frame(width: 16)
            Text(text)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // Helper to get import statistics from meter records
    private func getImportStats(siteId: Int) -> (totalKwh: Double, peakHours: (start: Int, end: Int), avgGridPrice: Double) {
        // Get last 7 days of meter records
        let calendar = Calendar.current
        let endDate = Date()
        guard let startDate = calendar.date(byAdding: .day, value: -7, to: endDate) else {
            return (0, (0, 0), 0)
        }

        let records = PowstonDataStore.shared.getMeterRecordsLocal(siteId: siteId, from: startDate, to: endDate)

        guard !records.isEmpty else { return (0, (0, 0), 0) }

        // Sum imports
        let totalImport = records.compactMap { $0.energyImport }.reduce(0, +)

        // Find peak import hours
        var hourlyImport: [Int: Double] = [:]
        for record in records {
            let hour = calendar.component(.hour, from: record.intervalTime)
            hourlyImport[hour, default: 0] += record.energyImport ?? 0
        }

        // Find contiguous window with highest import
        var bestStart = 0
        var bestEnd = 0
        var bestTotal: Double = 0

        for start in 0..<24 {
            for windowSize in 3...8 {  // 3-8 hour windows
                let end = start + windowSize
                if end > 24 { break }

                var windowTotal: Double = 0
                for hour in start..<end {
                    windowTotal += hourlyImport[hour] ?? 0
                }

                if windowTotal > bestTotal {
                    bestTotal = windowTotal
                    bestStart = start
                    bestEnd = end
                }
            }
        }

        // Average price - derive from costs/import (costs are in cents)
        // Filter to records with both costs and import
        var totalCosts: Double = 0
        var totalImportForCost: Double = 0
        for record in records {
            if let costs = record.costs, let imp = record.energyImport, imp > 0 {
                totalCosts += costs
                totalImportForCost += imp
            }
        }
        let avgPrice = totalImportForCost > 0 ? totalCosts / totalImportForCost : 0

        return (totalImport, (bestStart, bestEnd), avgPrice)
    }

    // MARK: - Contracts Tab
    
    private var contractsTab: some View {
        ScrollView {
            VStack(spacing: 10) {
                P2PSummaryView(directionFilter: viewMode == .selling ? .sell : .buy)

                P2PContractHistoryView(directionFilter: viewMode == .selling ? .sell : .buy)
            }
            .padding()
        }
        .id("\(refreshTrigger)-\(viewMode)")  // Force refresh after import or direction change
    }

    // MARK: - Counterparties Tab

    private var counterpartiesTab: some View {
        // When selling, show Buyers (people buying from you) → filter by .sell direction
        // When buying, show Sellers (people selling to you) → filter by .buy direction
        P2PCounterpartyView(directionFilter: viewMode == .selling ? .sell : .buy)
            .id("\(refreshTrigger)-\(viewMode)")  // Force refresh after import or direction change
    }

    // MARK: - Market Tab

    private var marketTab: some View {
        LVMarketOverviewView()
            .id(refreshTrigger)  // Force refresh after import
    }

    // MARK: - Loading View

    private var loadingView: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .stroke(Color.purple.opacity(0.2), lineWidth: 4)
                    .frame(width: 60, height: 60)

                Circle()
                    .trim(from: 0, to: 0.7)
                    .stroke(Color.purple, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .frame(width: 60, height: 60)
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: analysis.isAnalyzing)

                ProgressView()
                    .scaleEffect(1.5)
            }

            VStack(spacing: 8) {
                Text("Analyzing P2P Opportunities")
                    .font(.headline)
                    .foregroundColor(.primary)

                Text(analysis.progress)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                Text("This may take 10-15 seconds...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
        .padding(.horizontal, 40)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(16)
    }
    
    // MARK: - Start View
    
    private var startView: some View {
        VStack(spacing: 20) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 50))
                .foregroundColor(.purple)
            
            Text("Peer Power Analysis")
                .font(.title2.bold())
            
            Text("Analyze your peak exports to find P2P trading opportunities. Compare what you earned at spot vs what buyers paid to identify the sweet spot for P2P offers.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            Button(action: runAnalysis) {
                Label("Run Analysis", systemImage: "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.purple)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
            .padding(.top)
        }
        .padding()
    }
    
    // MARK: - Error View
    
    private func errorView(_ error: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundColor(.orange)
            
            Text(error)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            Button("Try Again", action: runAnalysis)
                .buttonStyle(.bordered)
        }
        .padding()
    }
    
    // MARK: - Results View

    private func resultsView(_ result: PeerPowerResult) -> some View {
        VStack(spacing: 20) {
            // 1. Recommendation first - the answer
            if let tiered = result.tieredRecommendation {
                tieredRecommendationCard(tiered, periodDays: effectiveContractDays)
            } else {
                noTradeHistoryCard
            }

            // 2. Win/Win Price Spread - why this range works
            spreadCard(result)

            // 3. Combined Analysis Details (Market Demand + Trade Scenarios in tabs)
            analysisDetailsCard(result)

            // 4. Hourly Breakdown - supporting detail
            hourlyCard(result)

            // 5. How P2P Works - reference/education at bottom
            p2pHowItWorksCard

            footerView(result)
        }
    }

    // MARK: - No Trade History Card

    private var noTradeHistoryCard: some View {
        Group {
            // If there's already trade data, don't show the full sync prompt
            // The data exists, it just doesn't form enough clusters for recommendations
            if lvService.tradeCount > 0 {
                // Show a simple status card instead of a sync prompt
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "chart.bar.fill")
                            .foregroundColor(.purple)
                        Text("Building Recommendations")
                            .font(.headline)
                        Spacer()
                    }

                    Text("You have \(lvService.tradeCount) trades synced. More data or varied pricing needed to generate tier recommendations.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    // Offer to fill missing days if credentials are available
                    if lvService.hasCredentials {
                        Button(action: { syncLVTrades() }) {
                            HStack(spacing: 6) {
                                if lvService.isSyncing {
                                    ProgressView()
                                        .tint(.purple)
                                } else {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                        .font(.caption)
                                }
                                Text(lvService.isSyncing ? "Syncing..." : "Refresh trades")
                                    .font(.caption)
                            }
                            .foregroundColor(.purple)
                        }
                        .buttonStyle(.plain)
                        .disabled(lvService.isSyncing)
                    }
                }
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)
            } else if lvService.hasCredentials {
                // No trade data, has credentials - show sync prompt
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "doc.text.fill")
                            .foregroundColor(.orange)
                        Text("Sync Your P2P Trades")
                            .font(.headline)
                        Spacer()
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Get personalized contract recommendations by syncing your LocalVolts trade history.")
                            .font(.subheadline)
                            .foregroundColor(.primary)

                        VStack(alignment: .leading, spacing: 6) {
                            benefitRow(icon: "chart.line.uptrend.xyaxis", text: "See which prices actually filled vs. fell through")
                            benefitRow(icon: "target", text: "Get tier recommendations based on real fill rates")
                            benefitRow(icon: "dollarsign.circle", text: "Optimize your blended price for maximum revenue")
                            benefitRow(icon: "clock.arrow.circlepath", text: "Track contract performance over time")
                        }
                        .padding(.vertical, 4)

                        Button(action: { syncLVTrades() }) {
                            HStack {
                                if lvService.isSyncing {
                                    ProgressView()
                                        .tint(.white)
                                        .padding(.trailing, 4)
                                }
                                Text(lvService.isSyncing ? "Syncing..." : "Sync Trade History")
                            }
                            .font(.subheadline.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(lvService.isSyncing ? Color.gray : Color.purple)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                        }
                        .disabled(lvService.isSyncing)
                        .padding(.top, 4)
                    }
                }
                .padding()
                .background(Color(.secondarySystemBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.orange.opacity(0.5), lineWidth: 1)
                )
                .cornerRadius(12)
            } else {
                // No credentials - show LV onboarding
                LVCredentialsPromptCard(
                    title: "Connect LocalVolts",
                    subtitle: "Get personalized P2P contract recommendations",
                    benefits: [
                        "Automatic trade history sync",
                        "See which prices actually filled vs. fell through",
                        "Get tier recommendations based on real fill rates",
                        "Track contract performance over time"
                    ]
                )
                .environmentObject(api)
            }
        }
    }

    private func benefitRow(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(.purple)
                .frame(width: 20)
            Text(text)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    // MARK: - How P2P Works Card
    
    private var p2pHowItWorksCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showHowItWorks.toggle()
                }
            }) {
                HStack {
                    Image(systemName: "book.fill")
                        .foregroundColor(.purple)
                    Text("How P2P Trading Works")
                        .font(.headline)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(showHowItWorks ? 90 : 0))
                }
            }
            .buttonStyle(.plain)
            
            if showHowItWorks {
                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    Text("You're selling directly to other LocalVolts customers instead of the grid.")
                        .font(.subheadline)

                    Text("The opportunity:")
                        .font(.caption.weight(.medium))
                        .foregroundColor(.secondary)
                        .padding(.top, 4)

                    VStack(alignment: .leading, spacing: 8) {
                        helpBullet("You receive ~10¢/kWh selling to spot", color: .orange)
                        helpBullet("Buyers pay ~33¢/kWh buying from grid", color: .red)
                        helpBullet("The ~22¢ gap is the P2P opportunity zone", color: .purple)
                    }

                    Text("With P2P, you agree on a price in between — you earn more than spot, buyers pay less than grid.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.top, 4)

                    Divider()

                    Text("How matching works:")
                        .font(.caption.weight(.medium))
                        .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 6) {
                        helpBullet("Trades match by: 1) buyer preferences, 2) price at buyer's location, 3) trade placement time", color: .purple)
                        helpBullet("Price is competitive — lower offers get matched first in a seller-heavy market", color: .orange)
                        helpBullet("Each site gets an individual price based on its grid location, not just distance", color: .secondary)
                        helpBullet("You can book a trade right up until the interval starts", color: .secondary)
                    }

                    Divider()

                    Text("Settlement:")
                        .font(.caption.weight(.medium))
                        .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 6) {
                        helpBullet("No penalties for missing trades — settlement is on actual meter data", color: .green)
                        helpBullet("You can never sell more than you generate or buy more than you consume", color: .secondary)
                        helpBullet("Forward matched amounts adjust automatically as new forecasts arrive", color: .secondary)
                        helpBullet("Unmatched P2P offers fall back to spot — no downside risk", color: .green)
                        helpBullet("Cross-state trades can match but won't settle if the interconnector is constrained", color: .secondary)
                    }
                }
                .padding(12)
                .background(Color(.tertiarySystemBackground))
                .cornerRadius(8)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    private func helpBullet(_ text: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .padding(.top, 5)
            Text(text)
                .font(.caption)
                .foregroundColor(.primary)
        }
    }
    
    // MARK: - Summary Card
    
    private func summaryCard(_ result: PeerPowerResult) -> some View {
        VStack(spacing: 12) {
            HStack {
                Text("Peak Export Summary")
                    .font(.headline)
                Spacer()
                Text("\(formatHour(result.peakStartHour))–\(formatHour(result.peakEndHour))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Divider()
            
            HStack(spacing: 16) {
                VStack(spacing: 4) {
                    Text(String(format: "%.0f", result.totalPeakExportKwh))
                        .font(.title2.bold())
                        .foregroundColor(.purple)
                    Text("kWh exported")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                VStack(spacing: 4) {
                    Text(formatCurrency(result.totalPeakExportRevenue))
                        .font(.title3.bold())
                        .foregroundColor(.green)
                    Text("earned at spot")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                VStack(spacing: 4) {
                    Text("\(result.periodDays)")
                        .font(.title3.bold())
                        .foregroundColor(.secondary)
                    Text("days")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    // MARK: - Spread Card

    private func spreadCard(_ result: PeerPowerResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "arrow.left.arrow.right")
                    .foregroundColor(.blue)
                Text("Win/Win Price Spread")
                    .font(.headline)
                Spacer()
            }
            
            Divider()
            
            HStack(spacing: 0) {
                VStack(spacing: 4) {
                    Text(String(format: "%.1f¢", result.avgSellPrice))
                        .font(.title3.bold())
                        .foregroundColor(.orange)
                    Text("You received")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                
                Image(systemName: "arrow.right")
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                
                VStack(spacing: 4) {
                    Text(String(format: "%.1f¢", result.avgSpread))
                        .font(.title3.bold())
                        .foregroundColor(.purple)
                    Text("Spread")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                
                Image(systemName: "arrow.right")
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                
                VStack(spacing: 4) {
                    Text(String(format: "%.1f¢", result.avgBuyPrice))
                        .font(.title3.bold())
                        .foregroundColor(.red)
                    Text("Buyers paid")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
            
            Text("The spread is the gap where P2P can benefit both parties. You offer somewhere in the middle — more than spot, less than grid.")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 4)
            
            P2PEducationalDisclosure(
                title: "What is the spread?",
                content: [
                    "Spot price (\(String(format: "%.1f¢", result.avgSellPrice))): What you actually received selling to the grid during peak hours.",
                    "Grid price (\(String(format: "%.1f¢", result.avgBuyPrice))): What buyers paid to import from the grid at the same time.",
                    "Spread (\(String(format: "%.1f¢", result.avgSpread))): The difference between buyer and seller prices — the opportunity zone.",
                    "A P2P offer in this zone means you earn more than spot, and buyers pay less than grid."
                ],
                isExpanded: $showSpreadHelp
            )
            .padding(.top, 4)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    // MARK: - Combined Analysis Details Card (Demand + Scenarios)

    private func analysisDetailsCard(_ result: PeerPowerResult) -> some View {
        let siteId = config?.siteId ?? 0
        let demandData = PowstonDataStore.shared.getP2PMarketDemandByPrice(siteId: siteId)
        let hasDemandData = !demandData.isEmpty

        // Calculate market demand optimal price
        let contracts = PowstonDataStore.shared.getP2PContracts(siteId: siteId)
        let lvAllocation: Double? = contracts.sorted { $0.startDate > $1.startDate }.first?.totalVolumeKwh

        let sortedByPriceDesc = demandData.sorted { $0.priceCents > $1.priceCents }
        var cumulativeVolume: Double = 0
        var priceAnalysis: [(price: Double, rawVolume: Double, cappedVolume: Double, revenue: Double)] = []
        for demand in sortedByPriceDesc {
            cumulativeVolume += demand.totalVolumeKwh
            let cappedVolume = lvAllocation.map { min(cumulativeVolume, $0) } ?? cumulativeVolume
            let revenueAtThisPrice = cappedVolume * demand.priceCents / 100.0
            priceAnalysis.append((price: demand.priceCents, rawVolume: cumulativeVolume, cappedVolume: cappedVolume, revenue: revenueAtThisPrice))
        }
        let marketOptimal = priceAnalysis.max(by: { $0.revenue < $1.revenue })
        let marketOptimalPrice = marketOptimal?.price ?? 0

        // Trade scenarios optimal price
        let tradeOptimalPrice = result.recommendation.offerPrice

        // Price range for display
        let minPrice = min(marketOptimalPrice, tradeOptimalPrice)
        let maxPrice = max(marketOptimalPrice, tradeOptimalPrice)

        // Calculate weekly extra for each methodology, capped at LV allocation
        // Formula: LV budget × win% × (price - spot)
        // Only win% of exports trade at P2P price; the rest goes to spot (no extra)
        let avgSpotPrice: Double = 10.0
        let lvCap = lvAllocation ?? 100.0  // Default to 100 kWh if no allocation

        // Market Demand: use fill rate as proxy for "win%" (demand at price / total demand)
        let marketCappedVolume = marketOptimal?.cappedVolume ?? lvCap
        let totalMarketDemand = priceAnalysis.first?.rawVolume ?? lvCap  // Total demand at lowest price
        let marketFillRate = totalMarketDemand > 0 ? min(1.0, marketCappedVolume / totalMarketDemand) : 1.0
        let marketWeeklyExtra = lvCap * marketFillRate * (marketOptimalPrice - avgSpotPrice) / 100.0

        // Win-Win: LV budget × win% × (price - spot)
        let winWinScenario = result.scenarios.first { $0.offerPrice == tradeOptimalPrice }
        let winWinPercent = (winWinScenario?.winWinPercent ?? 50) / 100.0  // Convert to decimal
        let winWinWeeklyExtra = lvCap * winWinPercent * (tradeOptimalPrice - avgSpotPrice) / 100.0

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "chart.bar.doc.horizontal")
                    .foregroundColor(.cyan)
                Text("Analysis Details")
                    .font(.headline)
                Spacer()
            }

            VStack(spacing: 8) {
                // Price row
                HStack(spacing: 0) {
                    VStack(spacing: 2) {
                        Text(hasDemandData ? "\(Int(marketOptimalPrice))¢" : "–")
                            .font(.title3.bold())
                            .foregroundColor(.cyan)
                        Text("Market")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)

                    VStack(spacing: 2) {
                        if hasDemandData && marketOptimalPrice != tradeOptimalPrice {
                            Text("\(Int(minPrice))–\(Int(maxPrice))¢")
                                .font(.subheadline.bold())
                                .foregroundColor(.purple)
                        } else {
                            Text("\(Int(tradeOptimalPrice))¢")
                                .font(.subheadline.bold())
                                .foregroundColor(.purple)
                        }
                        Text("Price Range")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)

                    VStack(spacing: 2) {
                        Text("\(Int(tradeOptimalPrice))¢")
                            .font(.title3.bold())
                            .foregroundColor(.green)
                        Text("Win-Win")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }

                Divider()

                // Revenue row - separate values for each methodology
                HStack {
                    Text("Extra vs Spot:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    if hasDemandData {
                        Text("+\(formatCurrency(marketWeeklyExtra))/wk")
                            .font(.caption.bold())
                            .foregroundColor(.cyan)
                        Text("•")
                            .foregroundColor(.secondary)
                    }
                    Text("+\(formatCurrency(winWinWeeklyExtra))/wk")
                        .font(.caption.bold())
                        .foregroundColor(.green)
                }
            }
            .padding(10)
            .background(Color(.tertiarySystemBackground))
            .cornerRadius(8)

            // Tab selector - only show if we have demand data
            if hasDemandData {
                Picker("Detail View", selection: $analysisDetailTab) {
                    ForEach(AnalysisDetailTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
            }

            Divider()

            // Tab content
            if hasDemandData && analysisDetailTab == .demand {
                marketDemandContent
            } else {
                scenariosContent(result)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    @available(iOS 16.0, *)
    private func comparisonChart(marketPrice: Double, tradePrice: Double, scenarios: [P2PPriceScenario], demandData: [P2PPriceDemand]) -> some View {
        // Calculate market extra revenue at each price point (vs ~10¢ spot)
        let avgSpotPrice: Double = 10.0
        let sortedDemand = demandData.sorted { $0.priceCents < $1.priceCents }  // Sort ascending for line chart
        var cumulativeVolume: Double = 0

        // Build cumulative volumes from high price down
        var volumeAtPrice: [Double: Double] = [:]
        for demand in demandData.sorted(by: { $0.priceCents > $1.priceCents }) {
            cumulativeVolume += demand.totalVolumeKwh
            volumeAtPrice[demand.priceCents] = cumulativeVolume
        }

        // Calculate extra revenue per day at each price
        var marketData: [(price: Double, extraPerDay: Double)] = []
        for demand in sortedDemand {
            let cumVol = volumeAtPrice[demand.priceCents] ?? 0
            let extraPerDay = (cumVol * (demand.priceCents - avgSpotPrice) / 100.0) / 7.0
            marketData.append((price: demand.priceCents, extraPerDay: extraPerDay))
        }

        // Sort scenarios by price for line chart
        let sortedScenarios = scenarios.sorted { $0.offerPrice < $1.offerPrice }

        return Chart {
            // Market demand line (cyan)
            ForEach(Array(marketData.enumerated()), id: \.offset) { _, item in
                LineMark(
                    x: .value("Price", item.price),
                    y: .value("Extra", item.extraPerDay)
                )
                .foregroundStyle(Color.cyan)
                .lineStyle(StrokeStyle(lineWidth: 2))
            }

            // Market optimal point
            if let marketOptimal = marketData.max(by: { $0.extraPerDay < $1.extraPerDay }) {
                PointMark(
                    x: .value("Price", marketOptimal.price),
                    y: .value("Extra", marketOptimal.extraPerDay)
                )
                .foregroundStyle(Color.cyan)
                .symbolSize(100)
            }

            // Trade scenario line (green)
            ForEach(sortedScenarios) { scenario in
                LineMark(
                    x: .value("Price", scenario.offerPrice),
                    y: .value("Extra", scenario.additionalRevenue)
                )
                .foregroundStyle(Color.green)
                .lineStyle(StrokeStyle(lineWidth: 2))
            }

            // Trade optimal point
            if let tradeOptimal = sortedScenarios.max(by: { $0.additionalRevenue < $1.additionalRevenue }) {
                PointMark(
                    x: .value("Price", tradeOptimal.offerPrice),
                    y: .value("Extra", tradeOptimal.additionalRevenue)
                )
                .foregroundStyle(Color.green)
                .symbolSize(100)
            }
        }
        .chartXAxisLabel("Price (¢)", position: .bottom)
        .chartYAxisLabel("Extra $/day", position: .leading)
        .chartXScale(domain: 15...40)
        .chartLegend(position: .top, spacing: 8) {
            HStack(spacing: 16) {
                HStack(spacing: 4) {
                    Circle().fill(Color.cyan).frame(width: 8, height: 8)
                    Text("Market Demand").font(.caption2).foregroundColor(.secondary)
                }
                HStack(spacing: 4) {
                    Circle().fill(Color.green).frame(width: 8, height: 8)
                    Text("Win-Win Trade").font(.caption2).foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Market Demand Content (extracted for tab)

    private var marketDemandContent: some View {
        let siteId = config?.siteId ?? 0
        let demandData = PowstonDataStore.shared.getP2PMarketDemandByPrice(siteId: siteId)

        // Get LV allocation limit from contracts
        let contracts = PowstonDataStore.shared.getP2PContracts(siteId: siteId)
        let lvAllocation: Double? = contracts
            .sorted { $0.startDate > $1.startDate }
            .first?.totalVolumeKwh

        // Calculate optimal price
        let sortedByPriceDesc = demandData.sorted { $0.priceCents > $1.priceCents }
        var cumulativeVolume: Double = 0
        var priceAnalysis: [(price: Double, rawVolume: Double, cappedVolume: Double, revenue: Double)] = []

        for demand in sortedByPriceDesc {
            cumulativeVolume += demand.totalVolumeKwh
            let cappedVolume = lvAllocation.map { min(cumulativeVolume, $0) } ?? cumulativeVolume
            let revenueAtThisPrice = cappedVolume * demand.priceCents / 100.0
            priceAnalysis.append((price: demand.priceCents, rawVolume: cumulativeVolume, cappedVolume: cappedVolume, revenue: revenueAtThisPrice))
        }

        let optimal = priceAnalysis.max(by: { $0.revenue < $1.revenue })
        let optimalPrice = optimal?.price ?? 0
        let optimalVolume = optimal?.cappedVolume ?? 0
        _ = optimal?.revenue ?? 0
        _ = cumulativeVolume

        // Calculate extra revenue vs spot
        // Market demand uses capped volume (assumes buyers always available at this price)
        let avgSpotPrice: Double = 10.0  // Approximate spot price in cents
        let extraRevenueWeekly = optimalVolume * (optimalPrice - avgSpotPrice) / 100.0

        return VStack(alignment: .leading, spacing: 10) {
            // Methodology explanation
            Text("Based on actual buyer demand from your imported trades. Assumes buyers at this price are always available (optimistic).")
                .font(.caption)
                .foregroundColor(.secondary)

            // Result summary - consistent format with Win-Win tab
            VStack(alignment: .leading, spacing: 4) {
                Text("Optimal: \(Int(optimalPrice))¢")
                    .font(.subheadline.bold())
                    .foregroundColor(.cyan)
                Text("\(Int(optimalVolume)) kWh → +\(formatCurrency(extraRevenueWeekly))/wk extra")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color.cyan.opacity(0.1))
            .cornerRadius(8)

            // Disclosure for detail
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showMarketDemandDetail.toggle()
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(showMarketDemandDetail ? 90 : 0))
                    Text("Price breakdown")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            if showMarketDemandDetail {
                VStack(spacing: 8) {
                    HStack {
                        Text("Price")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Volume")
                            .frame(width: 65, alignment: .trailing)
                        Text("Capped")
                            .frame(width: 65, alignment: .trailing)
                        Text("Extra/wk")
                            .frame(width: 70, alignment: .trailing)
                    }
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)

                    // Filter to optimal +/- 10 cents
                    let filteredAnalysis = priceAnalysis
                        .filter { $0.price >= optimalPrice - 10 && $0.price <= optimalPrice + 10 }
                        .sorted { $0.price < $1.price }

                    ForEach(Array(filteredAnalysis.enumerated()), id: \.offset) { _, item in
                        let isOptimal = item.price == optimalPrice
                        let extraWeekly = item.cappedVolume * (item.price - avgSpotPrice) / 100.0
                        HStack {
                            Text("\(Int(item.price))¢")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .foregroundColor(isOptimal ? .cyan : .primary)
                                .fontWeight(isOptimal ? .bold : .regular)

                            let originalVol = demandData.first { $0.priceCents == item.price }?.totalVolumeKwh ?? 0
                            Text(String(format: "%.0f", originalVol))
                                .frame(width: 65, alignment: .trailing)
                                .foregroundColor(.secondary)

                            Text(String(format: "%.0f", item.cappedVolume))
                                .frame(width: 65, alignment: .trailing)

                            Text("+\(formatCurrency(extraWeekly))")
                                .frame(width: 70, alignment: .trailing)
                                .foregroundColor(isOptimal ? .green : (extraWeekly > 0 ? .primary : .secondary))
                                .fontWeight(isOptimal ? .bold : .regular)
                        }
                        .font(.caption.monospacedDigit())
                        .padding(.vertical, 2)
                        .background(isOptimal ? Color.cyan.opacity(0.1) : Color.clear)
                        .cornerRadius(4)
                    }

                    Text("Extra/wk = capped kWh × (price - ~10¢ spot)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
                .padding(10)
                .background(Color(.tertiarySystemBackground))
                .cornerRadius(8)
            }
        }
    }

    // MARK: - Scenarios Content (extracted for tab)

    private func scenariosContent(_ result: PeerPowerResult) -> some View {
        let rec = result.recommendation
        let bestScenario = result.scenarios.first { $0.offerPrice == rec.offerPrice }

        // Get LV allocation for capping
        let siteId = config?.siteId ?? 0
        let contracts = PowstonDataStore.shared.getP2PContracts(siteId: siteId)
        let lvAllocation: Double = contracts.sorted { $0.startDate > $1.startDate }.first?.totalVolumeKwh ?? 100.0

        // Calculate weekly extra: LV budget × win% × (price - spot)
        // Only win% of exports trade at P2P price; the rest goes to spot
        let avgSpotPrice: Double = 10.0
        let winWinPct = (bestScenario?.winWinPercent ?? 50) / 100.0
        let extraWeekly = lvAllocation * winWinPct * (rec.offerPrice - avgSpotPrice) / 100.0

        return VStack(alignment: .leading, spacing: 10) {
            // Methodology explanation
            Text("Analyzes your historical exports. Only counts intervals where price > spot AND price < grid (realistic fill rate).")
                .font(.caption)
                .foregroundColor(.secondary)

            // Result summary - consistent format with Market Demand tab
            VStack(alignment: .leading, spacing: 4) {
                Text("Optimal: \(Int(rec.offerPrice))¢")
                    .font(.subheadline.bold())
                    .foregroundColor(.green)
                Text("\(Int(winWinPct * 100))% win-win → +\(formatCurrency(extraWeekly))/wk extra")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color.green.opacity(0.1))
            .cornerRadius(8)

            // Disclosure for detail
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showScenariosDetail.toggle()
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(showScenariosDetail ? 90 : 0))
                    Text("Price scenarios")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            if showScenariosDetail {
                VStack(spacing: 8) {
                    HStack {
                        Text("Price")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Win%")
                            .frame(width: 50, alignment: .trailing)
                        Text("P2P kWh")
                            .frame(width: 60, alignment: .trailing)
                        Text("Extra/wk")
                            .frame(width: 70, alignment: .trailing)
                    }
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)

                    // Filter to optimal +/- 10 cents
                    let filteredScenarios = result.scenarios
                        .filter { $0.offerPrice >= rec.offerPrice - 10 && $0.offerPrice <= rec.offerPrice + 10 }
                        .sorted { $0.offerPrice < $1.offerPrice }

                    ForEach(filteredScenarios) { scenario in
                        let isRecommended = scenario.offerPrice == rec.offerPrice
                        // Extra = LV budget × win% × (price - spot)
                        let scenarioWinPct = scenario.winWinPercent / 100.0
                        let p2pKwh = lvAllocation * scenarioWinPct  // Effective P2P volume
                        let extraWeeklyCapped = p2pKwh * (scenario.offerPrice - avgSpotPrice) / 100.0

                        HStack {
                            Text("\(Int(scenario.offerPrice))¢")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .foregroundColor(isRecommended ? .green : .primary)
                                .fontWeight(isRecommended ? .bold : .regular)
                            Text(String(format: "%.0f%%", scenario.winWinPercent))
                                .frame(width: 50, alignment: .trailing)
                                .foregroundColor(.secondary)
                            Text(String(format: "%.0f", p2pKwh))
                                .frame(width: 60, alignment: .trailing)
                                .foregroundColor(.secondary)
                            Text("+\(formatCurrency(extraWeeklyCapped))")
                                .frame(width: 70, alignment: .trailing)
                                .foregroundColor(extraWeeklyCapped > 0 ? .green : .secondary)
                                .fontWeight(isRecommended ? .bold : .regular)
                        }
                        .font(.caption.monospacedDigit())
                        .padding(.vertical, 2)
                        .background(isRecommended ? Color.green.opacity(0.1) : Color.clear)
                        .cornerRadius(4)
                    }

                    Text("Extra = LV budget × win% × (price - spot)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
                .padding(10)
                .background(Color(.tertiarySystemBackground))
                .cornerRadius(8)
            }
        }
    }

    // MARK: - Contract Period Picker

    private var effectiveContractDays: Int {
        contractPeriod.days ?? max(7, min(90, customDays))
    }

    private var contractPeriodTitle: String {
        switch contractPeriod {
        case .sevenDay: return "7-Day Contract Suggestion"
        case .fourWeek: return "4-Week Contract Suggestion"
        case .custom: return "\(effectiveContractDays)-Day Contract Suggestion"
        }
    }

    private var contractPeriodPicker: some View {
        VStack(spacing: 6) {
            Picker("Contract Period", selection: $contractPeriod) {
                ForEach(ContractPeriod.allCases, id: \.self) { period in
                    Text(period.rawValue).tag(period)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: contractPeriod) {
                UserDefaults.standard.set(contractPeriod.rawValue, forKey: "contract_suggestion_period")
            }

            if contractPeriod == .custom {
                HStack(spacing: 8) {
                    Text("Days:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("Days", value: $customDays, format: .number)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                        .onChange(of: customDays) {
                            let clamped = max(7, min(90, customDays))
                            if clamped != customDays { customDays = clamped }
                            UserDefaults.standard.set(clamped, forKey: "contract_suggestion_custom_days")
                        }
                    Stepper("", value: $customDays, in: 7...90)
                        .labelsHidden()
                    Spacer()
                }
            }
        }
    }

    // MARK: - Tiered Contract Recommendation Card

    private func tieredRecommendationCard(_ tiered: P2PTieredRecommendation, periodDays: Int = 7) -> some View {
        let scaled = tiered.scaled(toDays: periodDays)
        let periodLabel = periodDays == 7 ? "Weekly" : "\(periodDays)-Day"

        return VStack(alignment: .leading, spacing: 12) {
            // Header with data-driven badge
            HStack {
                Image(systemName: "doc.text.fill")
                    .foregroundColor(.purple)
                Text(contractPeriodTitle)
                    .font(.headline)
                Spacer()
                if tiered.hasHistoricalData {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundColor(.green)
                            .font(.caption)
                        Text("Data-driven")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .foregroundColor(.orange)
                            .font(.caption)
                        Text("Estimated")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
            }

            // Contract period selector (inline within card)
            contractPeriodPicker

            // Only show sync prompt if there's NO trade data at all
            // If there's data but no clusters formed, don't pester - data exists
            if !tiered.hasHistoricalData && lvService.tradeCount == 0 && !tiered.tiers.contains(where: { $0.historicalVolumeKwh > 0 }) {
                if lvService.hasCredentials {
                    // Has credentials - prompt to sync
                    Button(action: { syncLVTrades() }) {
                        HStack(spacing: 8) {
                            if lvService.isSyncing {
                                ProgressView()
                                    .tint(.purple)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .foregroundColor(.purple)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(lvService.isSyncing ? "Syncing..." : "Sync your LocalVolts trades")
                                    .font(.caption.bold())
                                    .foregroundColor(.primary)
                                Text("See actual fill rates and get data-driven recommendations")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        .padding(10)
                        .background(Color.purple.opacity(0.1))
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .disabled(lvService.isSyncing)
                } else {
                    // No credentials - prompt to connect LocalVolts
                    LVCredentialsBanner(message: "Connect LocalVolts to get data-driven recommendations")
                        .environmentObject(api)
                }
            }

            // Recommendation change alert
            if tiered.recommendationChanged, let reason = tiered.changeReason {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(reason)
                        .font(.caption)
                        .foregroundColor(.primary)
                }
                .padding(10)
                .background(Color.orange.opacity(0.15))
                .cornerRadius(8)
            }

            // Renewal urgency alert
            if tiered.renewalUrgency != .none {
                renewalUrgencyBanner(tiered)
            }

            // Historical data summary
            HStack(spacing: 10) {
                if tiered.tradesAnalyzed > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.swap")
                            .foregroundColor(.cyan)
                            .font(.caption2)
                        Text("\(tiered.tradesAnalyzed)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                if tiered.forecastTradesIncluded > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundColor(.blue)
                            .font(.caption2)
                        Text("\(tiered.forecastTradesIncluded) fwd")
                            .font(.caption)
                            .foregroundColor(.blue)
                    }
                }
                if tiered.outlierTradesExcluded > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "xmark.circle")
                            .foregroundColor(.orange)
                            .font(.caption2)
                        Text("\(tiered.outlierTradesExcluded)")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
                if tiered.contractsAnalyzed > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "doc.on.doc")
                            .foregroundColor(.cyan)
                            .font(.caption2)
                        Text("\(tiered.contractsAnalyzed) contracts")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            // Divergence warning
            if let divergence = tiered.recommendationDivergence {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.yellow)
                    Text(divergence)
                        .font(.caption)
                        .foregroundColor(.primary)
                }
                .padding(10)
                .background(Color.yellow.opacity(0.15))
                .cornerRadius(8)
            }

            Divider()

            // System constraints info
            VStack(spacing: 4) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Battery")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("\(Int(tiered.batteryCapacityKwh))")
                            .font(.subheadline.bold())
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Overnight")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("\(Int(tiered.overnightLoadKwh))")
                            .font(.subheadline.bold())
                            .foregroundColor(.orange)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Exportable")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("\(Int(tiered.effectiveExportableKwh))")
                            .font(.subheadline.bold())
                            .foregroundColor(.cyan)
                    }
                    if let lvLimit = tiered.lvContractLimitKwh {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("LV Limit")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text("\(Int(lvLimit / 7))")
                                .font(.subheadline.bold())
                                .foregroundColor(.purple)
                        }
                    }
                    Spacer()
                    if let singlePrice = tiered.singlePriceRecommendation {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("Win-Win")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text("\(Int(singlePrice))¢")
                                .font(.subheadline.bold())
                                .foregroundColor(.green)
                        }
                    }
                }
                Text("Overnight, Exportable, LV Limit shown as daily kWh")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 4)

            // System size assessment
            P2PSystemSizeAssessment(
                batteryCapacityKwh: tiered.batteryCapacityKwh,
                effectiveExportableKwh: tiered.effectiveExportableKwh,
                inverterExportKw: tiered.inverterExportKw
            )

            // Consistency tracker
            P2PConsistencyTracker(tiered: tiered)

            Divider()

            // Tier breakdown header
            Text("Recommended Tiers (\(tiered.tiers.count))")
                .font(.subheadline.bold())
                .foregroundColor(.secondary)

            ForEach(tiered.tiers) { tier in
                tierRow(tier, showHistorical: tiered.hasHistoricalData, periodMultiplier: scaled.multiplier)
            }

            // LV Entry Format
            VStack(alignment: .leading, spacing: 4) {
                Text("LocalVolts Entry")
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack(spacing: 8) {
                    ForEach(tiered.tiers.sorted(by: { $0.priceCents > $1.priceCents })) { tier in
                        HStack(spacing: 2) {
                            Text(String(format: "%.0f%%", tier.percentage))
                                .font(.caption.bold().monospacedDigit())
                                .foregroundColor(.cyan)
                            Text("@")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(String(format: "%.0f¢", tier.priceCents))
                                .font(.caption.bold().monospacedDigit())
                                .foregroundColor(.purple)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color(.tertiarySystemBackground))
                        .cornerRadius(4)
                    }
                }
            }
            .padding(.vertical, 4)

            Divider()

            // Period totals (scaled from weekly base)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(periodLabel)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("\(Int(scaled.totalKwh)) kWh")
                        .font(.headline)
                }

                Spacer()

                VStack(alignment: .center, spacing: 2) {
                    Text("Blended")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(String(format: "%.0f¢", tiered.blendedPriceCents))
                        .font(.headline)
                        .foregroundColor(.purple)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("Est. Revenue")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(formatCurrency(scaled.estimatedRevenue))
                        .font(.headline)
                        .foregroundColor(.green)
                }
            }

            // Daily projection + period total
            HStack {
                Text("≈ \(formatCurrency(tiered.weeklyEstimatedRevenue / 7))/day")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                if periodDays == 7 {
                    Text("≈ \(formatCurrency(tiered.weeklyEstimatedRevenue * 4.3))/month")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("≈ \(formatCurrency(scaled.estimatedRevenue)) for \(periodDays) days")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Comparison to previous contract
            if let previous = tiered.previousContract {
                previousContractComparison(previous, newBlendedPrice: tiered.blendedPriceCents)
            }

            // Trading window and export rate
            VStack(alignment: .leading, spacing: 6) {
                // Show effective window (filtered by win-win)
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .foregroundColor(.secondary)

                    // Show filtered window if different from original
                    if tiered.filteredStartHour != tiered.startHour || tiered.filteredEndHour != tiered.endHour {
                        Text("\(formatHour(tiered.filteredStartHour))–\(formatHour(tiered.filteredEndHour))")
                            .font(.caption.bold())
                            .foregroundColor(.green)
                        Text("(from \(formatHour(tiered.startHour))–\(formatHour(tiered.endHour)))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("\(formatHour(tiered.startHour))–\(formatHour(tiered.endHour)) AEST")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Text("•")
                        .foregroundColor(.secondary)
                    Text("\(tiered.effectiveWindowHours)h")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("•")
                        .foregroundColor(.secondary)
                    Text(String(format: "%.1f kW", tiered.requiredExportRateKw))
                        .font(.caption.bold())
                        .foregroundColor(tiered.systemCanSustain ? .green : .red)
                }

                // Show excluded hours
                if !tiered.excludedHours.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "minus.circle")
                            .foregroundColor(.orange)
                            .font(.caption)
                        Text("Excluded: \(tiered.excludedHours.map { formatHour($0) }.joined(separator: ", ")) (win-win <\(Int(tiered.winWinThreshold))%)")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }

                // Warning if system can't sustain
                if let warning = tiered.effectiveWindowWarning {
                    HStack(alignment: .top, spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .font(.caption)
                        Text(warning)
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
            }
            .padding(.top, 4)

            Divider()

            // Script Configuration Section
            scriptConfigSection(tiered)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(borderColor(for: tiered), lineWidth: 1)
        )
        .cornerRadius(12)
    }

    private func scriptConfigSection(_ tiered: P2PTieredRecommendation) -> some View {
        // tiered.requiredExportRateKw is already the power in kW
        // (calculated as weeklyTotalKwh / (windowHours * 7) in PeerPowerAnalysis)
        // Just convert to watts
        let recommendedPowerW = Int(tiered.requiredExportRateKw * 1000)
        let recommendedStart = tiered.filteredStartHour
        let recommendedEnd = tiered.filteredEndHour

        return VStack(alignment: .leading, spacing: 12) {
            // P2P Export Override Section
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.circle.fill")
                        .foregroundColor(.purple)
                    Text("P2P Export Override")
                        .font(.caption.bold())
                        .foregroundColor(.primary)
                }

                if isLoadingP2PParams {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading settings...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else if let params = p2pParams {
                    let isEnabled = (params.p2pExportPower ?? 0) > 0
                    let power = params.p2pExportPower ?? 0
                    let startHour = params.p2pExportStartHour ?? 17
                    let endHour = params.p2pExportEndHour ?? 20

                    // Check if recommendation differs significantly from current
                    let powerDiff = abs(recommendedPowerW - power)
                    let hasRecommendedUpdate = recommendedPowerW > 0 && (powerDiff > 500 || recommendedStart != startHour || recommendedEnd != endHour)

                    // Status display
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(isEnabled ? Color.green : Color.gray)
                                    .frame(width: 8, height: 8)
                                Text(isEnabled ? "Active" : "Disabled")
                                    .font(.caption.bold())
                                    .foregroundColor(isEnabled ? .green : .secondary)

                                // Show update indicator if recommendation differs
                                if hasRecommendedUpdate {
                                    Text("Update available")
                                        .font(.caption2.bold())
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.cyan)
                                        .cornerRadius(4)
                                }
                            }

                            if isEnabled {
                                Text(formatPowerDisplay(power) + " from \(formatHour(startHour)) to \(formatHour(endHour))")
                                    .font(.subheadline.bold())
                                    .foregroundColor(.purple)

                                // Show recommended if different
                                if hasRecommendedUpdate {
                                    Text("Recommended: \(formatPowerDisplay(recommendedPowerW))")
                                        .font(.caption)
                                        .foregroundColor(.cyan)
                                }
                            } else {
                                Text("Configure to enable daily P2P exports")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }

                        Spacer()

                        Button {
                            // Store current (saved) values for comparison
                            currentPower = power
                            currentStartHour = startHour
                            currentEndHour = endHour

                            // Always start with recommended values (user can review and adjust)
                            editPower = recommendedPowerW
                            editStartHour = recommendedStart
                            editEndHour = recommendedEnd

                            // Store recommended values for "Use" button
                            recommendedPower = recommendedPowerW
                            recommendedStartHour = recommendedStart
                            recommendedEndHour = recommendedEnd

                            // Initialize LV budget from UserDefaults
                            if let siteId = api.selectedSite?.id {
                                let lvBudgetKey = "lv_export_budget_kwh_\(siteId)"
                                if let storedBudget = UserDefaults.standard.object(forKey: lvBudgetKey) as? Double {
                                    editLvBudget = storedBudget
                                    currentLvBudget = storedBudget
                                    hasLvBudgetSet = true
                                } else {
                                    editLvBudget = 100  // Default
                                    currentLvBudget = nil
                                    hasLvBudgetSet = true  // Default to ON so users set their budget
                                }
                            }

                            showP2PConfig = true
                        } label: {
                            Text(hasRecommendedUpdate ? "Update" : "Configure")
                                .font(.caption.bold())
                                .foregroundColor(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(hasRecommendedUpdate ? Color.cyan : Color.purple)
                                .cornerRadius(6)
                        }
                    }

                    Divider()

                    // How it works explanation
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "wand.and.stars")
                                .font(.caption)
                                .foregroundColor(.blue)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Magic Mode")
                                    .font(.caption.bold())
                                    .foregroundColor(.primary)
                                Text("Forces battery export at the configured power during the time window daily.")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }

                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("These variables are available to your custom Powston scripts:")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text("P2P_EXPORT_POWER")
                                            .font(.caption2.monospaced())
                                        Spacer()
                                        Text("\(power) W")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                    HStack {
                                        Text("P2P_EXPORT_START_HOUR")
                                            .font(.caption2.monospaced())
                                        Spacer()
                                        Text("\(startHour) (\(formatHour(startHour)))")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                    HStack {
                                        Text("P2P_EXPORT_END_HOUR")
                                            .font(.caption2.monospaced())
                                        Spacer()
                                        Text("\(endHour) (\(formatHour(endHour)))")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .padding(8)
                                .background(Color(.tertiarySystemBackground))
                                .cornerRadius(6)

                                Text("Use these to control your inverter during peak P2P hours while letting Magic Mode handle off-peak optimization.")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.top, 4)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "terminal")
                                    .font(.caption)
                                    .foregroundColor(.green)
                                    .frame(width: 16)
                                Text("Custom Scripts")
                                    .font(.caption.bold())
                                    .foregroundColor(.primary)
                            }
                        }
                    }
                } else {
                    // No params loaded
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundColor(.orange)
                        Text("Could not load settings")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("Retry") {
                            Task { await loadP2PParams() }
                        }
                        .font(.caption)
                    }
                }
            }
        }
        .sheet(isPresented: $showP2PConfig) {
            p2pConfigSheet
        }
    }

    private func formatPowerDisplay(_ watts: Int) -> String {
        if watts >= 1000 {
            let kw = Double(watts) / 1000.0
            if kw == Double(Int(kw)) {
                return "\(Int(kw)),000W"
            } else {
                return String(format: "%.1fkW", kw)
            }
        }
        return "\(watts)W"
    }

    private var p2pConfigSheet: some View {
        // Current (saved) settings calculations
        let currentDuration = currentEndHour > currentStartHour ? currentEndHour - currentStartHour : (24 - currentStartHour + currentEndHour)
        let currentDailyKwh = Double(currentPower) * Double(currentDuration) / 1000.0
        let currentWeeklyKwh = currentDailyKwh * 7

        // New (edit) settings calculations
        let duration = editEndHour > editStartHour ? editEndHour - editStartHour : (24 - editStartHour + editEndHour)
        let dailyKwh = Double(editPower) * Double(duration) / 1000.0
        let weeklyKwh = dailyKwh * 7

        // Check if settings differ from current
        let hasChanges = editPower != currentPower || editStartHour != currentStartHour || editEndHour != currentEndHour

        return NavigationStack {
            Form {
                // Current settings (if configured)
                if currentPower > 0 {
                    Section {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Currently configured:")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text("\(formatPowerDisplay(currentPower)) from \(formatHour(currentStartHour)) to \(formatHour(currentEndHour))")
                                    .font(.subheadline.bold())
                                    .foregroundColor(.purple)
                                Text("\(String(format: "%.0f", currentWeeklyKwh)) kWh/week")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if hasChanges {
                                Button("Keep") {
                                    editPower = currentPower
                                    editStartHour = currentStartHour
                                    editEndHour = currentEndHour
                                }
                                .font(.caption.bold())
                                .foregroundColor(.purple)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.purple.opacity(0.15))
                                .cornerRadius(6)
                            }
                        }
                    } header: {
                        Text("Current Settings")
                    }
                }

                // Recommended - only show if different from edit values
                if recommendedPower > 0 && (editPower != recommendedPower || editStartHour != recommendedStartHour || editEndHour != recommendedEndHour) {
                    Section {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Based on your P2P analysis:")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text("\(formatPowerDisplay(recommendedPower)) from \(formatHour(recommendedStartHour)) to \(formatHour(recommendedEndHour))")
                                    .font(.subheadline.bold())
                                    .foregroundColor(.cyan)
                            }
                            Spacer()
                            Button("Use") {
                                editPower = recommendedPower
                                editStartHour = recommendedStartHour
                                editEndHour = recommendedEndHour
                            }
                            .font(.caption.bold())
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.cyan)
                            .cornerRadius(6)
                        }
                    } header: {
                        Text("Recommended")
                    }
                }

                // Power setting
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Export Power")
                            Spacer()
                            Text(editPower > 0 ? formatPowerDisplay(editPower) : "Disabled")
                                .foregroundColor(editPower > 0 ? .purple : .secondary)
                                .font(.headline)
                        }

                        Slider(
                            value: Binding(
                                get: { Double(editPower) },
                                set: { editPower = Int($0) }
                            ),
                            in: 0...30000,
                            step: 500
                        )
                        .tint(.purple)

                        // Quick presets
                        HStack(spacing: 6) {
                            ForEach([0, 5000, 10000, 15000, 20000], id: \.self) { watts in
                                Button {
                                    editPower = watts
                                } label: {
                                    Text(watts == 0 ? "Off" : "\(watts/1000)kW")
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 4)
                                        .background(editPower == watts ? Color.purple : Color(.tertiarySystemBackground))
                                        .foregroundColor(editPower == watts ? .white : .primary)
                                        .cornerRadius(4)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                } header: {
                    Text("Power (Watts)")
                } footer: {
                    Text("Set to 0 to disable. Power (W) × Hours = Energy (Wh). 1000 Wh = 1 kWh.")
                }

                // Time window
                Section {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Start")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Picker("Start", selection: $editStartHour) {
                                ForEach(0..<24, id: \.self) { hour in
                                    Text(formatHour(hour)).tag(hour)
                                }
                            }
                            .pickerStyle(.wheel)
                            .frame(height: 100)
                            .onChange(of: editStartHour) { _, newValue in
                                if editEndHour <= newValue {
                                    editEndHour = min(23, newValue + 1)
                                }
                            }
                        }

                        VStack(alignment: .leading) {
                            Text("End")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Picker("End", selection: $editEndHour) {
                                ForEach(0..<24, id: \.self) { hour in
                                    Text(formatHour(hour)).tag(hour)
                                }
                            }
                            .pickerStyle(.wheel)
                            .frame(height: 100)
                        }
                    }

                    // Duration display
                    HStack {
                        Image(systemName: "clock")
                            .foregroundColor(.secondary)
                        Text("\(formatHour(editStartHour)) to \(formatHour(editEndHour))")
                        Spacer()
                        Text("\(duration) hour\(duration == 1 ? "" : "s")")
                            .foregroundColor(.secondary)
                    }
                    .font(.subheadline)
                } header: {
                    Text("Time Window")
                }

                // LV Export Budget
                Section {
                    Toggle("Limit weekly exports", isOn: $hasLvBudgetSet)

                    if hasLvBudgetSet {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Weekly Budget")
                                Spacer()
                                Text(String(format: "%.0f kWh", editLvBudget))
                                    .font(.headline)
                                    .foregroundColor(.orange)
                            }

                            Slider(
                                value: $editLvBudget,
                                in: 50...500,
                                step: 10
                            )
                            .tint(.orange)

                            // Quick presets
                            HStack(spacing: 6) {
                                ForEach([100, 150, 200, 300, 400], id: \.self) { kwh in
                                    Button {
                                        editLvBudget = Double(kwh)
                                    } label: {
                                        Text("\(kwh)")
                                            .font(.caption2)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 4)
                                            .background(Int(editLvBudget) == kwh ? Color.orange : Color(.tertiarySystemBackground))
                                            .foregroundColor(Int(editLvBudget) == kwh ? .white : .primary)
                                            .cornerRadius(4)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }

                            // Warning if export exceeds budget
                            if weeklyKwh > editLvBudget && editPower > 0 {
                                HStack(spacing: 4) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(.red)
                                    Text("Weekly export (\(Int(weeklyKwh)) kWh) exceeds budget!")
                                        .font(.caption)
                                        .foregroundColor(.red)
                                }
                            }
                        }
                    }
                } header: {
                    Text("LocalVolts Budget")
                } footer: {
                    Text("Set your LocalVolts weekly export limit. This caps contract recommendations and P2P analysis.")
                }

                // Summary with W to kWh explanation
                Section {
                    if editPower > 0 || currentPower > 0 {
                        VStack(alignment: .leading, spacing: 12) {
                            // Show comparison if settings changed
                            if currentPower > 0 && hasChanges {
                                // Current vs New comparison
                                HStack(spacing: 16) {
                                    // Current
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Current")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        Text(String(format: "%.0f kWh/wk", currentWeeklyKwh))
                                            .font(.subheadline)
                                            .foregroundColor(.secondary)
                                    }

                                    Image(systemName: "arrow.right")
                                        .foregroundColor(.secondary)

                                    // New
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("New")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        HStack(spacing: 4) {
                                            Text(String(format: "%.0f kWh/wk", weeklyKwh))
                                                .font(.subheadline.bold())
                                                .foregroundColor(editPower > 0 ? .purple : .secondary)
                                            if hasLvBudgetSet {
                                                Text("/ \(Int(editLvBudget))")
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                            }
                                        }
                                    }

                                    Spacer()

                                    // Change indicator
                                    let diff = weeklyKwh - currentWeeklyKwh
                                    if abs(diff) > 1 {
                                        Text(diff > 0 ? "+\(Int(diff))" : "\(Int(diff))")
                                            .font(.caption.bold())
                                            .foregroundColor(diff > 0 ? .green : .orange)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background((diff > 0 ? Color.green : Color.orange).opacity(0.15))
                                            .cornerRadius(4)
                                    }
                                }

                                Divider()
                            }

                            // Calculation details
                            if editPower > 0 {
                                HStack(alignment: .top) {
                                    Image(systemName: "bolt.fill")
                                        .foregroundColor(.purple)
                                        .frame(width: 20)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(String(format: "%.0f kWh/week", weeklyKwh))
                                            .font(.headline)
                                            .foregroundColor(.purple)
                                        Text("\(formatPowerDisplay(editPower)) × \(duration)h × 7 days ÷ 1000")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            } else {
                                HStack {
                                    Image(systemName: "moon.zzz.fill")
                                        .foregroundColor(.secondary)
                                    Text("Export override will be disabled")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    } else {
                        HStack {
                            Image(systemName: "moon.zzz.fill")
                                .foregroundColor(.secondary)
                            Text("P2P Export Override is disabled")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("Energy Output")
                } footer: {
                    if editPower > 0 {
                        Text("Magic Mode will force \(formatPowerDisplay(editPower)) export from \(formatHour(editStartHour)) to \(formatHour(editEndHour)) every day.")
                    }
                }
            }
            .navigationTitle("P2P Export Override")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showP2PConfig = false
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await saveP2PConfig() }
                    } label: {
                        if isSavingP2PParams {
                            ProgressView()
                        } else {
                            Text("Save")
                        }
                    }
                    .disabled(isSavingP2PParams)
                }
            }
        }
    }

    private func saveP2PConfig() async {
        guard let siteId = api.selectedSite?.id else { return }

        isSavingP2PParams = true

        // Save LV budget to UserDefaults
        let lvBudgetKey = "lv_export_budget_kwh_\(siteId)"
        if hasLvBudgetSet {
            UserDefaults.standard.set(editLvBudget, forKey: lvBudgetKey)
        } else {
            UserDefaults.standard.removeObject(forKey: lvBudgetKey)
        }

        // Create params with just the P2P values updated
        var updatedParams = p2pParams ?? TrainingParameters.empty
        updatedParams.p2pExportPower = editPower
        updatedParams.p2pExportStartHour = editStartHour
        updatedParams.p2pExportEndHour = editEndHour

        let result = await api.updateTrainingParameters(siteId: siteId, params: updatedParams)

        await MainActor.run {
            isSavingP2PParams = false
            switch result {
            case .success:
                p2pParams = updatedParams
                showP2PConfig = false
                // Invalidate analysis cache to recalculate with new budget
                if hasLvBudgetSet {
                    PowstonDataStore.shared.invalidateAnalysisCache(siteId: siteId)
                }
            case .failure(let error):
                print("❌ Failed to save P2P config: \(error)")
            }
        }
    }

    private func loadP2PParams() async {
        guard let siteId = api.selectedSite?.id else {
            await MainActor.run { isLoadingP2PParams = false }
            return
        }

        let params = await api.fetchTrainingParameters(siteId: siteId)
        await MainActor.run {
            p2pParams = params
            isLoadingP2PParams = false
        }
    }

    private func borderColor(for tiered: P2PTieredRecommendation) -> Color {
        if tiered.renewalUrgency == .urgent || tiered.renewalUrgency == .overdue {
            return Color.orange.opacity(0.5)
        } else if tiered.recommendationChanged {
            return Color.yellow.opacity(0.5)
        } else if tiered.hasHistoricalData {
            return Color.green.opacity(0.3)
        } else {
            return Color.purple.opacity(0.3)
        }
    }

    private func renewalUrgencyBanner(_ tiered: P2PTieredRecommendation) -> some View {
        let (icon, color, message) = renewalUrgencyInfo(tiered)

        return HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(color)
            Text(message)
                .font(.caption)
                .foregroundColor(.primary)
            Spacer()
        }
        .padding(10)
        .background(color.opacity(0.15))
        .cornerRadius(8)
    }

    private func renewalUrgencyInfo(_ tiered: P2PTieredRecommendation) -> (icon: String, color: Color, message: String) {
        switch tiered.renewalUrgency {
        case .overdue:
            return ("exclamationmark.circle.fill", .red, "Contract ended — schedule new contract now")
        case .urgent:
            if let days = tiered.daysUntilRenewal {
                return ("clock.badge.exclamationmark.fill", .orange, "Schedule within \(abs(days)) days for optimal booking")
            }
            return ("clock.badge.exclamationmark.fill", .orange, "Schedule soon for optimal booking window")
        case .upcoming:
            if let days = tiered.daysUntilRenewal {
                return ("calendar.badge.clock", .blue, "Good time to schedule — \(days) days until ideal deadline")
            }
            return ("calendar.badge.clock", .blue, "Good time to schedule next contract")
        case .none:
            return ("checkmark.circle", .green, "")
        }
    }

    private func previousContractComparison(_ previous: P2PPreviousContractSummary, newBlendedPrice: Double) -> some View {
        let priceDiff = newBlendedPrice - previous.blendedPrice
        let priceDirection = priceDiff > 0 ? "↑" : priceDiff < 0 ? "↓" : "→"
        let priceColor: Color = priceDiff > 0 ? .green : priceDiff < 0 ? .orange : .secondary

        return VStack(alignment: .leading, spacing: 4) {
            Divider()
            HStack {
                Text("vs Previous")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(previous.tierPrices.map { "\(Int($0))¢" }.joined(separator: "/"))")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(priceDirection)
                    .font(.caption.bold())
                    .foregroundColor(priceColor)
                Text(String(format: "%.1f¢", previous.blendedPrice))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func tierRow(_ tier: P2PRecommendedTier, showHistorical: Bool, periodMultiplier: Double = 1.0) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                // Percentage - prominent for LV entry (fixed width to prevent wrapping)
                Text(String(format: "%.0f", tier.percentage))
                    .font(.title3.bold())
                    .foregroundColor(.cyan)
                + Text("%")
                    .font(.subheadline)
                    .foregroundColor(.cyan)

                // Price
                Text(String(format: "%.0f¢", tier.priceCents))
                    .font(.headline)
                    .foregroundColor(.purple)

                Spacer()

                // Volume (reference) - scaled by period multiplier
                Text(String(format: "%.0f", tier.weeklyKwh * periodMultiplier))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                + Text(" kWh")
                    .font(.caption)
                    .foregroundColor(.secondary)

                // Revenue - scaled by period multiplier
                Text(formatCurrency(tier.weeklyRevenue * periodMultiplier))
                    .font(.subheadline.bold())
                    .foregroundColor(.green)
            }

            // Secondary info row
            HStack {
                // Confidence indicator with trade count
                HStack(spacing: 4) {
                    Circle()
                        .fill(confidenceColor(tier.confidence))
                        .frame(width: 6, height: 6)
                    if tier.basedOnTrades > 0 {
                        Text("\(tier.basedOnTrades) trades")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    } else {
                        Text(tier.confidence.rawValue)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                // Fill rate if available
                if showHistorical, let histRate = tier.historicalFillRate {
                    Text("•")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(String(format: "%.0f%% fill", histRate))
                        .font(.caption2)
                        .foregroundColor(histRate >= 70 ? .green : histRate >= 50 ? .orange : .red)
                }

                if tier.historicalVolumeKwh > 0 {
                    Text("•")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(String(format: "%.0f kWh hist", tier.historicalVolumeKwh))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(tier.confidence == .proven ? Color.green.opacity(0.1) : Color(.tertiarySystemBackground))
        .cornerRadius(8)
    }

    private func confidenceColor(_ confidence: TierConfidence) -> Color {
        switch confidence {
        case .proven: return .green
        case .high: return .green
        case .medium: return .orange
        case .low: return .red
        }
    }

    @available(iOS 16.0, *)
    private func scenarioChart(_ scenarios: [P2PPriceScenario], recommended: Double) -> some View {
        Chart {
            ForEach(scenarios) { scenario in
                BarMark(
                    x: .value("Price", "\(Int(scenario.offerPrice))¢"),
                    y: .value("Revenue", scenario.additionalRevenue)
                )
                .foregroundStyle(scenario.offerPrice == recommended ? Color.purple : Color.purple.opacity(0.4))
                .annotation(position: .top, alignment: .center) {
                    if scenario.offerPrice == recommended {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundColor(.yellow)
                    }
                }
            }
        }
        .chartYAxisLabel("Extra Revenue ($)")
    }
    
    // MARK: - Hourly Card

    private func hourlyCard(_ result: PeerPowerResult) -> some View {
        let rec = result.recommendation

        // Filter hours with meaningful data and sort by hour (sequential)
        let hoursWithData = result.hourlyBreakdown
            .filter { $0.dailyKwh > 0.1 }
            .sorted { $0.hour < $1.hour }

        // Find best/worst for summary
        let bestHour = hoursWithData.max { $0.dailyExtraAtRecommended < $1.dailyExtraAtRecommended }
        _    = hoursWithData.min { $0.dailyExtraAtRecommended < $1.dailyExtraAtRecommended }

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "clock.fill")
                    .foregroundColor(.orange)
                Text("Hourly Breakdown")
                    .font(.headline)
                Spacer()
                Text("at \(Int(rec.offerPrice))¢")
                    .font(.caption)
                    .foregroundColor(.purple)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.purple.opacity(0.15))
                    .cornerRadius(6)
            }

            Divider()

            Text("Daily opportunity by hour at your recommended price:")
                .font(.caption)
                .foregroundColor(.secondary)

            if #available(iOS 16.0, *) {
                hourlyExtraChart(result.hourlyBreakdown, recommendedStart: rec.startHour, recommendedEnd: rec.endHour)
                    .frame(height: 160)
            }

            VStack(spacing: 4) {
                HStack {
                    Text("Hour")
                        .frame(width: 60, alignment: .leading)
                    Text("kWh/day")
                        .frame(width: 60, alignment: .trailing)
                    Text("Win-Win")
                        .frame(width: 60, alignment: .trailing)
                    Text("Extra $/day")
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.secondary)

                ForEach(hoursWithData) { hourData in
                    let isInWindow = hourData.hour >= rec.startHour && hourData.hour < rec.endHour
                    let isBest = hourData.hour == bestHour?.hour

                    HStack {
                        HStack(spacing: 2) {
                            Text(formatHour(hourData.hour))
                            if isBest {
                                Image(systemName: "star.fill")
                                    .font(.caption2)
                                    .foregroundColor(.yellow)
                            }
                        }
                        .lineLimit(1)
                        .frame(width: 60, alignment: .leading)

                        Text(String(format: "%.1f", hourData.dailyKwh))
                            .frame(width: 60, alignment: .trailing)
                            .foregroundColor(isInWindow ? .primary : .secondary)

                        Text(String(format: "%.0f%%", hourData.winWinAtRecommended))
                            .frame(width: 60, alignment: .trailing)
                            .foregroundColor(isInWindow ?
                                (hourData.winWinAtRecommended >= 70 ? .green : hourData.winWinAtRecommended >= 50 ? .orange : .red) :
                                .secondary)

                        Text("+\(formatCurrency(hourData.dailyExtraAtRecommended))")
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .foregroundColor(isInWindow ?
                                (hourData.dailyExtraAtRecommended > 0.5 ? .green : .primary) :
                                .secondary)
                    }
                    .font(.caption.monospacedDigit())
                    .fontWeight(isInWindow ? .medium : .regular)
                    .foregroundColor(isInWindow ? .primary : .secondary)
                    .opacity(isInWindow ? 1.0 : 0.6)
                    .padding(.vertical, 1)
                    .background(isBest && isInWindow ? Color.green.opacity(0.1) : Color.clear)
                    .cornerRadius(4)
                }
            }

            if rec.endHour > rec.startHour {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundColor(.purple)
                    Text("Recommended: \(formatHour(rec.startHour))–\(formatHour(rec.endHour)) → +\(formatCurrency(rec.dailyExtraRevenue))/day")
                        .font(.caption)
                }
                .padding(8)
                .background(Color.purple.opacity(0.1))
                .cornerRadius(8)
            }

            P2PEducationalDisclosure(
                title: "Which hours matter?",
                content: [
                    bestHour.map { "Best hour: \(formatHour($0.hour)) — +\(formatCurrency($0.dailyExtraAtRecommended))/day with \(String(format: "%.0f", $0.winWinAtRecommended))% win-win." } ?? "No significant hours found.",
                    "Green text = in recommended window. Dimmed = not recommended for P2P.",
                    "Hours outside the window remain available for opportunistic spot exports.",
                    "Early evening (5-7pm) typically has highest export volume and buyer demand."
                ].filter { !$0.isEmpty },
                isExpanded: $showHourlyHelp
            )
            .padding(.top, 4)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    @available(iOS 16.0, *)
    private func hourlyExtraChart(_ hours: [P2PHourlyBreakdown], recommendedStart: Int, recommendedEnd: Int) -> some View {
        let maxExtra = hours.map { $0.dailyExtraAtRecommended }.max() ?? 1
        
        return Chart {
            ForEach(hours.filter { $0.intervalCount > 0 }) { hour in
                let isInWindow = hour.hour >= recommendedStart && hour.hour < recommendedEnd
                
                BarMark(
                    x: .value("Hour", formatHour(hour.hour)),
                    y: .value("Extra", hour.dailyExtraAtRecommended)
                )
                .foregroundStyle(isInWindow ? Color.green : Color.orange)
            }
        }
        .chartYAxisLabel("Extra $/day")
        .chartYScale(domain: 0...(max(0.1, maxExtra * 1.15)))
    }
    
    // MARK: - Footer
    
    private func footerView(_ result: PeerPowerResult) -> some View {
        VStack(spacing: 12) {
            Button(action: runAnalysis) {
                Label("Refresh Analysis", systemImage: "arrow.clockwise")
                    .font(.subheadline)
            }
            .buttonStyle(.bordered)

            Text("Based on \(result.periodDays) days of peak export data (\(result.intervalsWithExport) intervals)")
                .font(.caption)
                .foregroundColor(.secondary)

            Text("Adjust peak hours in Settings → Peak Hours")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.top)
    }
    
    // MARK: - Helpers
    
    private func formatHour(_ hour: Int) -> String {
        let h = hour % 12 == 0 ? 12 : hour % 12
        let suffix = hour < 12 ? "am" : "pm"
        return "\(h)\(suffix)"
    }
    
    private func formatHour24(_ hour: Int) -> String {
        return String(format: "%02d:00", hour)
    }
    
    private static let currencyFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencySymbol = "$"
        f.maximumFractionDigits = 2
        f.minimumFractionDigits = 2
        return f
    }()
    
    private func formatCurrency(_ value: Double) -> String {
        Self.currencyFormatter.string(from: NSNumber(value: abs(value))) ?? "$0.00"
    }
    
    private func loadCachedOrRun() {
        if let config = config, let cached = analysis.getCachedResult(config: config) {
            analysis.result = cached
        }
    }

    private func runAnalysis() {
        guard let config = config else { return }
        guard !analysis.isAnalyzing && !isStartingAnalysis else { return }  // Prevent double-tap

        // Show loading immediately
        isStartingAnalysis = true
        analysis.result = nil
        analysis.error = nil
        analysis.clearCache(config: config)

        Task {
            // Refresh data availability before analysis
            await api.refreshLatestCompleteDataDate()
            await analysis.runAnalysis(api: api, config: config)
            isStartingAnalysis = false
        }
    }

    /// Sync trade history directly from LocalVolts API
    private func syncLVTrades() {
        guard let siteId = api.selectedSite?.id else {
            print("📊 syncLVTrades: no siteId")
            return
        }
        guard !lvService.isSyncing else {
            print("📊 syncLVTrades: already syncing, skipped")
            return
        }

        print("📊 syncLVTrades: starting (siteId=\(siteId))")
        Task {
            do {
                // Sync last 7 days of trades
                print("📊 syncLVTrades: calling syncWeek...")
                try await lvService.syncWeek(siteId: siteId, force: true)
                print("📊 syncLVTrades: syncWeek done, calling fetchOrders...")

                // Also sync orders/contracts
                _ = try await lvService.fetchOrders(siteId: siteId, force: true)

                // Refresh the view
                refreshTrigger = UUID()

                // Re-run analysis with new data
                if let config = config {
                    analysis.clearCache(config: config)
                    await analysis.runAnalysis(api: api, config: config)
                }
            } catch {
                print("❌ LV sync failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Buyer Analysis Helpers

    private func loadCachedOrRunBuyer() {
        if let config = config, let cached = analysis.getCachedBuyerResult(config: config) {
            analysis.buyerResult = cached
        }
    }

    private func runBuyerAnalysis() {
        guard let config = config else { return }
        guard !analysis.isAnalyzingBuyer else { return }  // Prevent double-tap

        // Show loading immediately
        analysis.buyerResult = nil
        analysis.buyerError = nil
        analysis.clearBuyerCache(config: config)

        Task {
            // Refresh data availability before analysis
            await api.refreshLatestCompleteDataDate()
            await analysis.runBuyerAnalysis(api: api, config: config)
        }
    }
}

// MARK: - P2P Onboarding Sheet

struct P2POnboardingSheet: View {
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Hero
                    VStack(spacing: 8) {
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.purple)
                        Text("P2P Trading")
                            .font(.title.bold())
                        Text("Sell your excess energy directly to other LocalVolts customers at prices better than spot.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)

                    Divider()

                    // Key concepts
                    onboardingPoint(
                        icon: "chart.line.uptrend.xyaxis",
                        color: .green,
                        title: "The Opportunity",
                        detail: "Without P2P, you receive ~10¢/kWh at spot. Buyers pay ~33¢/kWh from grid. P2P lets you agree on a price in between — you earn more, they pay less."
                    )

                    onboardingPoint(
                        icon: "clock.badge.checkmark",
                        color: .blue,
                        title: "Consistency is Key",
                        detail: "Your fill rate is earned over 2+ weeks of consistent delivery. You must export your contracted amount every 5-minute period during your window. The first ~12 days are ramp-up."
                    )

                    onboardingPoint(
                        icon: "doc.text.fill",
                        color: .orange,
                        title: "Contracts are Commitments",
                        detail: "Buyers book in advance — some more than a month ahead. Better capture comes when you can commit early. Missing committed trades damages your future allocation. Set contracts you can reliably deliver, even on cloudy days."
                    )

                    onboardingPoint(
                        icon: "battery.75percent",
                        color: .cyan,
                        title: "System Size Matters",
                        detail: "Larger batteries (60+ kWh) see meaningful returns. Smaller systems may only generate modest additional income. Factor in battery cycling costs."
                    )

                    onboardingPoint(
                        icon: "dollarsign.arrow.circlepath",
                        color: .purple,
                        title: "Pricing Matters",
                        detail: "If you price below the spot rate during a spike, you lose that opportunity cost. Our pricing strategy helps ensure you come out ahead overall, but P2P is not risk-free."
                    )
                }
                .padding()
            }
            .navigationTitle("Before You Start")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Got It") {
                        onDismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private func onboardingPoint(icon: String, color: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.bold())
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - System Size Assessment

struct P2PSystemSizeAssessment: View {
    let batteryCapacityKwh: Double
    let effectiveExportableKwh: Double
    let inverterExportKw: Double

    private var tier: SystemTier {
        if effectiveExportableKwh >= 40 {
            return .large
        } else if effectiveExportableKwh >= 15 {
            return .medium
        } else {
            return .small
        }
    }

    private enum SystemTier {
        case large, medium, small

        var title: String {
            switch self {
            case .large: return "Well Suited for P2P"
            case .medium: return "Moderate P2P Potential"
            case .small: return "Consider Carefully"
            }
        }

        var icon: String {
            switch self {
            case .large: return "checkmark.circle.fill"
            case .medium: return "minus.circle.fill"
            case .small: return "exclamationmark.triangle.fill"
            }
        }

        var color: Color {
            switch self {
            case .large: return .green
            case .medium: return .yellow
            case .small: return .orange
            }
        }

        func detail(exportableKwh: Double) -> String {
            switch self {
            case .large:
                return "Your \(Int(exportableKwh)) kWh exportable capacity supports strong P2P returns."
            case .medium:
                return "Your \(Int(exportableKwh)) kWh exportable capacity can generate moderate P2P income. Keep contracts conservative."
            case .small:
                return "With \(Int(exportableKwh)) kWh exportable, P2P returns may be modest. Daily battery cycling also adds wear. Consider whether the extra revenue justifies the commitment."
            }
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: tier.icon)
                .foregroundStyle(tier.color)
                .font(.subheadline)

            VStack(alignment: .leading, spacing: 2) {
                Text(tier.title)
                    .font(.caption.bold())
                    .foregroundStyle(tier.color)
                Text(tier.detail(exportableKwh: effectiveExportableKwh))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(tier.color.opacity(0.1))
        .cornerRadius(8)
    }
}

// MARK: - Consistency Tracker Card

struct P2PConsistencyTracker: View {
    let tiered: P2PTieredRecommendation

    private var dailyTargetKwh: Double {
        tiered.weeklyTotalKwh / 7.0
    }

    private var dailyExportableKwh: Double {
        tiered.effectiveExportableKwh
    }

    private var fillRateCapability: Double {
        guard dailyTargetKwh > 0 else { return 1.0 }
        return min(1.0, dailyExportableKwh / dailyTargetKwh)
    }

    /// Aggregate fill rate from all tiers that have historical data (returns 0-1 ratio)
    private var historicalFillRate: Double? {
        let tiersWithData = tiered.tiers.filter { $0.historicalFillRate != nil }
        guard !tiersWithData.isEmpty else { return nil }
        let totalVol = tiersWithData.reduce(0.0) { $0 + $1.historicalVolumeKwh }
        guard totalVol > 0 else { return nil }
        // Volume-weighted fill rate; tier values are 0-100 percentage, convert to 0-1 ratio
        let weightedPct = tiersWithData.reduce(0.0) { $0 + ($1.historicalFillRate ?? 0) * $1.historicalVolumeKwh } / totalVol
        return weightedPct / 100.0
    }

    private var rampUpDaysEstimate: Int {
        // ~12 days ramp-up based on community data
        if let fillRate = historicalFillRate, fillRate > 0.8 {
            return 0  // Already ramped up
        }
        return 12
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "chart.bar.fill")
                    .foregroundStyle(.cyan)
                Text("Consistency Tracker")
                    .font(.caption.bold())
            }

            // Fill rate bar
            if let fillRate = historicalFillRate {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Observed Fill Rate")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.0f%%", fillRate * 100))
                            .font(.caption.bold())
                            .foregroundStyle(fillRateColor(fillRate))
                    }

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(.tertiarySystemFill))
                                .frame(height: 8)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(fillRateColor(fillRate))
                                .frame(width: max(0, geo.size.width * fillRate), height: 8)
                        }
                    }
                    .frame(height: 8)

                    fillRateMessage(fillRate)
                }
            } else {
                // No historical data yet
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "hourglass")
                            .foregroundStyle(.orange)
                            .font(.caption)
                        Text("No fill rate data yet")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text("Expect ~12 days of ramp-up before your fill rate stabilizes. Consistency during this period builds your allocation.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            // System capability check
            if fillRateCapability < 1.0 {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.caption2)
                    Text("Your daily exportable capacity (\(Int(dailyExportableKwh)) kWh) is less than the daily target (\(Int(dailyTargetKwh)) kWh). Consider reducing contract volume.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(10)
        .background(Color(.tertiarySystemBackground))
        .cornerRadius(8)
    }

    private func fillRateColor(_ rate: Double) -> Color {
        if rate >= 0.8 { return .green }
        if rate >= 0.5 { return .yellow }
        return .orange
    }

    private func fillRateMessage(_ rate: Double) -> some View {
        Group {
            if rate >= 0.9 {
                Text("Excellent consistency. Your allocation should be at or near maximum.")
                    .font(.caption2)
                    .foregroundStyle(.green)
            } else if rate >= 0.7 {
                Text("Good consistency. Keep delivering to build your allocation further.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if rate >= 0.5 {
                Text("Fill rate is building. Ensure you can export the contracted amount every 5-min period during your window.")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
            } else {
                Text("Low fill rate. Missing trades reduces future allocation. Consider reducing contract volume to what you can reliably deliver.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        PeerPowerView()
            .environmentObject(PowstonAPI())
    }
}
