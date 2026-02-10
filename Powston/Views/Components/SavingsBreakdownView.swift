//
//  SavingsBreakdownView.swift
//  Powston
//
//  Detail view for savings breakdown analysis
//

import SwiftUI
import Charts

struct SavingsBreakdownView: View {
    @EnvironmentObject var api: PowstonAPI
    @StateObject private var analysis = SavingsBreakdownAnalysis()
    @State private var comparisonMode: PaybackComparisonMode = .flatRate
    
    var config: AnalysisConfig? {
        guard let site = api.selectedSite else { return nil }
        return AnalysisConfig.from(site: site)
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if analysis.isAnalyzing {
                    loadingView
                } else if let result = analysis.result {
                    resultsView(result)
                } else if let error = analysis.error {
                    errorView(error)
                } else {
                    startView
                }
            }
            .padding()
        }
        .navigationTitle("Savings Breakdown")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            loadCachedOrRun()
        }
    }
    
    // MARK: - Loading View
    
    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
            Text(analysis.progress)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
    
    // MARK: - Start View
    
    private var startView: some View {
        VStack(spacing: 20) {
            Image(systemName: "lightbulb.fill")
                .font(.system(size: 50))
                .foregroundColor(.yellow)
            
            Text("Savings Breakdown Analysis")
                .font(.title2.bold())
            
            Text("Analyze 60 days of data to understand where your savings come from and model battery expansion scenarios.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            Button(action: runAnalysis) {
                Label("Run Analysis", systemImage: "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.yellow)
                    .foregroundColor(.black)
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
    
    private func resultsView(_ result: SavingsBreakdownResult) -> some View {
        VStack(spacing: 20) {
            summaryCard(result)
            savingsWaterfallCard(result)
            solarValueCard(result)
            batteryValueCard(result)
            powstonValueCard(result)
            touVsFlatRateCard(result)
            expansionCard(result)
            batteryROISettingsSection(currentCapacity: result.currentBatteryCapacity)
            footerView(result)
        }
    }
    
    // MARK: - Summary Card
    
    private func summaryCard(_ result: SavingsBreakdownResult) -> some View {
        VStack(spacing: 12) {
            HStack {
                Text("60-Day Summary")
                    .font(.headline)
                Spacer()
                Text(result.analysisDate, style: .date)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Divider()
            
            HStack(spacing: 16) {
                VStack(spacing: 4) {
                    Text(formatCurrencyRounded(result.totalSavings))
                        .font(.title2.bold())
                        .foregroundColor(.green)
                    Text("Total Saved")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                VStack(spacing: 4) {
                    Text(formatCurrency(result.dailyAvgSavings))
                        .font(.title3.bold())
                        .foregroundColor(.green)
                    Text("Per Day")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                VStack(spacing: 4) {
                    Text(formatCurrencyRounded(result.gridOnlyCost))
                        .font(.title3.bold())
                        .foregroundColor(.secondary)
                    Text("Grid Only")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    // MARK: - Savings Waterfall
    
    private func savingsWaterfallCard(_ result: SavingsBreakdownResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Savings Breakdown")
                    .font(.headline)
                Spacer()
                if result.usedDerivedData {
                    Label("Estimated", systemImage: "info.circle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            
            VStack(spacing: 8) {
                waterfallRow(icon: "powerplug.fill", color: .gray, label: "Grid only baseline", value: result.gridOnlyCost, valueColor: .secondary)
                waterfallRow(icon: "sun.max.fill", color: .yellow, label: result.solarSavings >= 0 ? "Solar savings" : "Solar cost", value: abs(result.solarSavings), valueColor: result.solarSavings >= 0 ? .green : .red)
                waterfallRow(icon: "battery.100percent", color: .green, label: result.batterySavings >= 0 ? "Battery savings" : "Battery cost", value: abs(result.batterySavings), valueColor: result.batterySavings >= 0 ? .green : .red)
                waterfallRow(icon: "brain.head.profile", color: .purple, label: result.powstonSavings >= 0 ? "Powston savings" : "Powston cost", value: abs(result.powstonSavings), valueColor: result.powstonSavings >= 0 ? .green : .red)
                
                Divider()
                
                waterfallRow(icon: "dollarsign.circle.fill", color: .orange, label: "Actual cost", value: result.actualCost, valueColor: .primary, bold: true)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    private func waterfallRow(icon: String, color: Color, label: String, value: Double, valueColor: Color, bold: Bool = false) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 24)
            Text(label)
                .font(bold ? .subheadline.bold() : .subheadline)
            Spacer()
            Text(formatCurrency(value))
                .font(bold ? .subheadline.bold() : .subheadline)
                .foregroundColor(valueColor)
        }
    }
    
    // MARK: - Solar Value Card
    
    private func solarValueCard(_ result: SavingsBreakdownResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "sun.max.fill").foregroundColor(.yellow)
                Text("Solar Value").font(.headline)
                Spacer()
                Text(formatCurrency(result.solarSavings)).font(.headline).foregroundColor(.green)
            }
            
            Divider()
            
            HStack {
                metricView(value: String(format: "%.0f", result.totalPvGenerationKwh), unit: "kWh", label: "Generated")
                metricView(value: String(format: "%.0f%%", result.selfConsumptionPercent), unit: "", label: "Self-consumed")
                metricView(value: String(format: "%.1f¢", result.avgExportPrice), unit: "", label: "Avg export rate")
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    // MARK: - Battery Value Card
    
    private func batteryValueCard(_ result: SavingsBreakdownResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "battery.100percent").foregroundColor(.green)
                Text("Battery Value").font(.headline)
                Spacer()
                Text(formatCurrency(result.batterySavings)).font(.headline).foregroundColor(result.batterySavings >= 0 ? .green : .red)
            }
            
            Divider()
            
            HStack {
                metricView(value: String(format: "%.0f", result.currentBatteryCapacity), unit: "kWh", label: "Capacity")
                metricView(value: String(format: "%.0f%%", result.batteryUtilizationPercent), unit: "", label: "Utilization")
                metricView(value: String(format: "%.1f¢", result.avgImportPrice), unit: "", label: "Avg import rate")
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    // MARK: - Powston Value Card
    
    private func powstonValueCard(_ result: SavingsBreakdownResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "brain.head.profile").foregroundColor(.purple)
                Text("Powston Value").font(.headline)
                Spacer()
                Text(formatCurrency(result.powstonSavings)).font(.headline).foregroundColor(result.powstonSavings >= 0 ? .green : .red)
            }
            
            Divider()
            
            HStack {
                metricView(value: formatCurrency(result.dailyAvgPowstonValue), unit: "", label: "Daily avg")
                metricView(value: formatCurrency(result.powstonSavings * (365.0 / Double(result.periodDays))), unit: "", label: "Annual (proj)")
                metricView(value: String(format: "%.0f%%", result.powstonSavings / max(1, result.totalSavings) * 100), unit: "", label: "% of total")
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    // MARK: - TOU vs Flat Rate Card
    
    private func touVsFlatRateCard(_ result: SavingsBreakdownResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "chart.bar.fill").foregroundColor(.blue)
                Text("ToU vs Flat Rate").font(.headline)
                Spacer()
            }
            
            let touSavings = result.flatRateSavings
            
            if touSavings > 0 {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    Text("ToU pricing saved you ").font(.subheadline) +
                    Text(formatCurrency(touSavings)).font(.subheadline.bold()).foregroundColor(.green) +
                    Text(" vs flat rate").font(.subheadline)
                }
            } else {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    Text("Flat rate would have saved ").font(.subheadline) +
                    Text(formatCurrency(abs(touSavings))).font(.subheadline.bold()).foregroundColor(.orange)
                }
            }
            
            Text("Compared to \(String(format: "%.0f¢", result.flatBuyRate)) buy / \(String(format: "%.0f¢", result.flatSellRate)) sell flat tariff")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Text("Adjust comparison rates in Settings → Leaderboard")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    // MARK: - Battery Expansion Card
    
    private func expansionCard(_ result: SavingsBreakdownResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "plus.circle.fill").foregroundColor(.green)
                Text("Battery Expansion Analysis").font(.headline)
                Spacer()
            }
            
            Divider()
            
            Text("Diminishing returns curve based on your actual usage patterns:")
                .font(.caption)
                .foregroundColor(.secondary)
            
            if #available(iOS 16.0, *) {
                expansionChart(result.expansionAnalysis, currentCapacity: result.currentBatteryCapacity)
                    .frame(height: 180)
                
                HStack(spacing: 16) {
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 1).stroke(Color.cyan, style: StrokeStyle(lineWidth: 2, dash: [4, 2])).frame(width: 20, height: 2)
                        Text("Battery Only").font(.caption2)
                    }
                    HStack(spacing: 4) {
                        Rectangle().fill(Color.pink).frame(width: 20, height: 2)
                        Text("With Powston").font(.caption2)
                    }
                }.foregroundColor(.secondary).padding(.bottom, 4)
            }
            
            // Comparison mode picker with explanation
            VStack(spacing: 4) {
                Text("Compare payback against:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Picker("Compare against", selection: $comparisonMode) {
                    ForEach(PaybackComparisonMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                
                // Mode explanation
                Group {
                    if comparisonMode == .flatRate {
                        Text("Is battery + TOU worth it vs staying on flat rate with solar?")
                    } else {
                        Text("How much does the battery save vs solar-only on TOU?")
                    }
                }
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, 2)
            }
            .padding(.vertical, 4)
            
            // Table header
            VStack(spacing: 8) {
                // Main headers
                HStack {
                    Text("Capacity")
                        .frame(width: 60, alignment: .leading)
                    Text("Daily")
                        .frame(width: 45, alignment: .trailing)
                    Text("Payback Years")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
                
                // Sub-headers for payback
                HStack {
                    Spacer().frame(width: 60)
                    Spacer().frame(width: 45)
                    HStack(spacing: 0) {
                        Text("Battery Only")
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Text("With Powston")
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .font(.caption2)
                .foregroundColor(.secondary)
                
                // Data rows
                ForEach(result.expansionAnalysis) { point in
                    HStack {
                        HStack(spacing: 2) {
                            if point.isCurrentCapacity {
                                Image(systemName: "arrow.right").font(.caption2).foregroundColor(.green)
                            }
                            Text("\(Int(point.capacityKwh))")
                        }
                        .frame(width: 60, alignment: .leading)
                        .foregroundColor(point.isCurrentCapacity ? .green : .primary)
                        
                        Text(formatCurrency(abs(point.powstonDailyCost)))
                            .frame(width: 45, alignment: .trailing)
                        
                        HStack(spacing: 0) {
                            // Battery Only payback (based on mode)
                            let batteryPayback = comparisonMode == .flatRate ? point.paybackYearsFlatRate : point.paybackYears
                            Text(batteryPayback.map { String(format: "%.0fy", $0) } ?? "—")
                                .foregroundColor(point.isCurrentCapacity ? .green : .primary)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            
                            // With Powston payback (based on mode) - show range if spikes exist
                            let powstonPayback = comparisonMode == .flatRate ? point.powstonPaybackYearsFlatRate : point.powstonPaybackYears
                            let powstonWithSpikes = comparisonMode == .flatRate ? point.powstonPaybackWithSpikesYearsFlatRate : point.powstonPaybackWithSpikesYears
                            
                            if let payback = powstonPayback,
                               let withSpikes = powstonWithSpikes,
                               withSpikes < payback - 0.5 {
                                Text("\(String(format: "%.0f", withSpikes))-\(String(format: "%.0fy", payback))")
                                    .foregroundColor(point.isCurrentCapacity ? .green : .primary)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            } else {
                                Text(powstonPayback.map { String(format: "%.0fy", $0) } ?? "—")
                                    .foregroundColor(point.isCurrentCapacity ? .green : .primary)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                        }
                    }
                    .font(.caption.monospacedDigit())
                }
            }
            
            // Powston improvement callout (use mode-appropriate values)
            if let current = result.expansionAnalysis.first(where: { $0.isCurrentCapacity }) {
                let dumbPayback = comparisonMode == .flatRate ? current.paybackYearsFlatRate : current.paybackYears
                let powstonPayback = comparisonMode == .flatRate ? current.powstonPaybackYearsFlatRate : current.powstonPaybackYears
                
                if let dumb = dumbPayback, let powston = powstonPayback, dumb > powston {
                    let improvement = ((dumb - powston) / dumb) * 100
                    HStack(spacing: 8) {
                        Image(systemName: "bolt.fill").foregroundColor(.green)
                        Text("Powston improves payback by \(String(format: "%.0f%%", improvement))").font(.caption).fontWeight(.medium)
                        Spacer()
                    }
                    .padding(8).background(Color.green.opacity(0.1)).cornerRadius(8)
                }
            }
            
            // Exceptional days callout - only show for TOU mode (spikes need TOU to capture)
            if result.exceptionalDaysCount > 0 && comparisonMode == .tou {
                HStack(spacing: 8) {
                    Image(systemName: "chart.line.uptrend.xyaxis").foregroundColor(.orange)
                    Text("\(result.exceptionalDaysCount) spike days totaled \(formatCurrencyRounded(result.exceptionalDaysTotal)). If recurring, Powston payback shortens to lower range.")
                        .font(.caption)
                    Spacer()
                }
                .padding(8).background(Color.orange.opacity(0.1)).cornerRadius(8)
            }
            
            Text(expansionAssumptionsText(forCapacity: result.currentBatteryCapacity)).font(.caption2).foregroundColor(.gray).padding(.top, 4)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    private func expansionAssumptionsText(forCapacity currentCapacity: Double) -> String {
        let costPerKwh = UserDefaults.standard.double(forKey: "battery_cost_per_kwh")
        let cost = costPerKwh > 0 ? costPerKwh : 800.0
        var text = "Assumes $\(Int(cost))/kWh installed."
        
        let claimedRebate = UserDefaults.standard.bool(forKey: "stc_rebate_claimed")
        if claimedRebate {
            let addedKwh = UserDefaults.standard.double(forKey: "stc_rebate_kwh")
            let year = UserDefaults.standard.integer(forKey: "stc_rebate_year")
            if addedKwh > 0 && year >= 2025 {
                text += String(format: " Includes STC rebate on %.0f kWh (%d).", addedKwh, year)
            }
        }
        return text
    }
    
    // MARK: - Battery ROI Settings
    
    private func batteryROISettingsSection(currentCapacity: Double) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "gearshape.fill").foregroundColor(.gray)
                Text("Payback Assumptions").font(.headline)
                Spacer()
            }
            Divider()
            
            HStack {
                Text("Battery cost")
                Spacer()
                TextField("$/kWh", value: Binding(
                    get: { let s = UserDefaults.standard.double(forKey: "battery_cost_per_kwh"); return s > 0 ? s : 800.0 },
                    set: { UserDefaults.standard.set($0, forKey: "battery_cost_per_kwh") }
                ), format: .number)
                .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 80)
                Text("$/kWh").foregroundColor(.secondary)
            }
            
            Divider()
            stcRebateSection(currentCapacity: currentCapacity)
            Text("Changes apply on next refresh.").font(.caption).foregroundColor(.secondary)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    // MARK: - STC Rebate Section
    
    private func stcRebateSection(currentCapacity: Double) -> some View {
        let claimedRebate = Binding(
            get: { UserDefaults.standard.bool(forKey: "stc_rebate_claimed") },
            set: { UserDefaults.standard.set($0, forKey: "stc_rebate_claimed") }
        )
        let addedKwh = Binding(
            get: { let s = UserDefaults.standard.double(forKey: "stc_rebate_kwh"); return s > 0 ? s : 0.0 },
            set: { UserDefaults.standard.set($0, forKey: "stc_rebate_kwh") }
        )
        let yearClaimed = Binding(
            get: { let s = UserDefaults.standard.integer(forKey: "stc_rebate_year"); return s >= 2025 ? s : 2025 },
            set: { UserDefaults.standard.set($0, forKey: "stc_rebate_year") }
        )
        
        return VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { UserDefaults.standard.bool(forKey: "stc_rebate_claimed") },
                set: {
                    UserDefaults.standard.set($0, forKey: "stc_rebate_claimed")
                    // Set default year if not already set
                    if $0 && UserDefaults.standard.integer(forKey: "stc_rebate_year") < 2025 {
                        UserDefaults.standard.set(2025, forKey: "stc_rebate_year")
                    }
                }
            )) {
                Text("I've already claimed STC rebate")
            }
            
            if claimedRebate.wrappedValue {
                HStack {
                    Text("Battery added")
                    Spacer()
                    TextField("kWh", value: addedKwh, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 60)
                    Text("kWh").foregroundColor(.secondary)
                }.padding(.leading, 8)
                
                HStack {
                    Text("Year claimed")
                    Spacer()
                    Picker("Year", selection: yearClaimed) {
                        ForEach(2025...2030, id: \.self) { year in Text(String(year)).tag(year) }
                    }.pickerStyle(.menu)
                }.padding(.leading, 8)
            }
            
            Link("About the Cheaper Home Batteries program", destination: URL(string: "https://www.dcceew.gov.au/energy/programs/cheaper-home-batteries")!).font(.caption)
        }
    }
    
    @available(iOS 16.0, *)
    private func expansionChart(_ points: [BatteryExpansionPoint], currentCapacity: Double) -> some View {
        Chart {
            ForEach(points) { point in
                LineMark(x: .value("Capacity", point.capacityKwh), y: .value("Dumb Cost", point.dailyCost), series: .value("Type", "Battery Only"))
                    .foregroundStyle(Color.cyan).lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 3]))
            }
            ForEach(points) { point in
                LineMark(x: .value("Capacity", point.capacityKwh), y: .value("Powston Cost", point.powstonDailyCost), series: .value("Type", "With Powston"))
                    .foregroundStyle(Color.pink).lineStyle(StrokeStyle(lineWidth: 2))
            }
            if let current = points.first(where: { $0.isCurrentCapacity }) {
                PointMark(x: .value("Capacity", current.capacityKwh), y: .value("Cost", current.powstonDailyCost))
                    .foregroundStyle(Color.green).symbolSize(100)
                    .annotation(position: .top) { Text("You").font(.caption2).foregroundColor(.green) }
            }
        }
        .chartXAxisLabel("Battery Capacity (kWh)")
        .chartYAxisLabel("Daily Cost ($)")
    }
    
    // MARK: - Footer
    
    private func footerView(_ result: SavingsBreakdownResult) -> some View {
        VStack(spacing: 8) {
            Button(action: runAnalysis) {
                Label("Refresh Analysis", systemImage: "arrow.clockwise").font(.subheadline)
            }.buttonStyle(.bordered)
            Text("Analysis based on \(result.periodDays) days of meter data").font(.caption).foregroundColor(.secondary)
        }.padding(.top)
    }
    
    // MARK: - Helpers
    
    private func metricView(value: String, unit: String, label: String) -> some View {
        VStack(spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.subheadline.bold())
                if !unit.isEmpty { Text(unit).font(.caption).foregroundColor(.secondary) }
            }
            Text(label).font(.caption2).foregroundColor(.secondary)
        }.frame(maxWidth: .infinity)
    }
    
    private static let currencyFormatter: NumberFormatter = {
        let f = NumberFormatter(); f.numberStyle = .currency; f.currencySymbol = "$"; f.maximumFractionDigits = 2; f.minimumFractionDigits = 2; return f
    }()
    
    private static let currencyRoundedFormatter: NumberFormatter = {
        let f = NumberFormatter(); f.numberStyle = .currency; f.currencySymbol = "$"; f.maximumFractionDigits = 0; f.minimumFractionDigits = 0; return f
    }()
    
    private func formatCurrency(_ value: Double) -> String { Self.currencyFormatter.string(from: NSNumber(value: abs(value))) ?? "$0.00" }
    private func formatCurrencyRounded(_ value: Double) -> String { Self.currencyRoundedFormatter.string(from: NSNumber(value: abs(value))) ?? "$0" }
    
    private func loadCachedOrRun() {
        if let config = config, let cached = analysis.getCachedResult(config: config) { analysis.result = cached }
    }
    
    private func runAnalysis() {
        guard let config = config else { return }
        Task {
            // Refresh data availability before analysis
            await api.refreshLatestCompleteDataDate()
            await analysis.runAnalysis(api: api, config: config)
        }
    }
}

#Preview {
    NavigationStack {
        SavingsBreakdownView().environmentObject(PowstonAPI())
    }
}
