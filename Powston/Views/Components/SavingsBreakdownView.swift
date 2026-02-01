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
            // Summary Card
            summaryCard(result)
            
            // Savings Waterfall
            savingsWaterfallCard(result)
            
            // Solar Value
            solarValueCard(result)
            
            // Battery Value
            batteryValueCard(result)
            
            // Powston Value
            powstonValueCard(result)
            
            // Flat Rate Comparison
            flatRateCard(result)
            
            // Battery Expansion
            expansionCard(result)
            
            // Footer
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
            
            HStack(spacing: 20) {
                VStack(spacing: 4) {
                    Text(formatCurrency(result.totalSavings))
                        .font(.title.bold())
                        .foregroundColor(.green)
                    Text("Total Saved")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                VStack(spacing: 4) {
                    Text(formatCurrency(result.dailyAvgSavings))
                        .font(.title2.bold())
                        .foregroundColor(.green)
                    Text("Per Day")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                VStack(spacing: 4) {
                    Text(formatCurrency(result.gridOnlyCost))
                        .font(.title2.bold())
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
            Text("Savings Breakdown")
                .font(.headline)
            
            VStack(spacing: 8) {
                waterfallRow(
                    icon: "powerplug.fill",
                    color: .gray,
                    label: "Grid only baseline",
                    value: result.gridOnlyCost,
                    isCost: true
                )
                
                waterfallRow(
                    icon: "sun.max.fill",
                    color: .yellow,
                    label: result.solarSavings >= 0 ? "Solar savings" : "Solar cost",
                    value: result.solarSavings,
                    isCost: false
                )
                
                waterfallRow(
                    icon: "battery.100percent",
                    color: .green,
                    label: "Battery savings",
                    value: result.batterySavings,
                    isCost: false
                )
                
                waterfallRow(
                    icon: "brain.head.profile",
                    color: .purple,
                    label: result.powstonSavings >= 0 ? "Powston savings" : "Powston cost",
                    value: result.powstonSavings,
                    isCost: false
                )
                
                Divider()
                
                HStack {
                    Image(systemName: result.actualCost <= 0 ? "checkmark.circle.fill" : "dollarsign.circle.fill")
                        .foregroundColor(result.actualCost <= 0 ? .green : .orange)
                        .frame(width: 24)
                    Text(result.actualCost <= 0 ? "Actual benefit" : "Actual cost")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Spacer()
                    Text(formatCurrency(result.actualCost))
                        .font(.subheadline.monospacedDigit())
                        .fontWeight(.medium)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    private func waterfallRow(icon: String, color: Color, label: String, value: Double, isCost: Bool) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 24)
            Text(label)
                .font(.subheadline)
            Spacer()
            if isCost {
                Text(formatCurrency(value))
                    .font(.subheadline.monospacedDigit())
                    .foregroundColor(.secondary)
            } else {
                Text(formatSavings(value))
                    .font(.subheadline.monospacedDigit())
                    .foregroundColor(value >= 0 ? .green : .red)
            }
        }
    }
    
    // MARK: - Solar Value Card
    
    private func solarValueCard(_ result: SavingsBreakdownResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "sun.max.fill")
                    .foregroundColor(.yellow)
                Text("Solar Value")
                    .font(.headline)
                Spacer()
                Text(formatSavings(result.solarSavings))
                    .font(.headline)
                    .foregroundColor(result.solarSavings >= 0 ? .green : .red)
            }
            
            Divider()
            
            HStack(spacing: 20) {
                metricView(
                    value: String(format: "%.0f", result.totalPvGenerationKwh),
                    unit: "kWh",
                    label: "Generated"
                )
                
                metricView(
                    value: String(format: "%.0f%%", result.selfConsumptionPercent),
                    unit: "",
                    label: "Self-consumed"
                )
                
                metricView(
                    value: String(format: "%.1f¢", result.avgExportPrice),
                    unit: "",
                    label: "Avg export rate"
                )
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
                Image(systemName: "battery.100percent")
                    .foregroundColor(.green)
                Text("Battery Value")
                    .font(.headline)
                Spacer()
                Text(formatSavings(result.batterySavings))
                    .font(.headline)
                    .foregroundColor(.green)
            }
            
            Divider()
            
            HStack(spacing: 20) {
                metricView(
                    value: String(format: "%.0f", result.currentBatteryCapacity),
                    unit: "kWh",
                    label: "Capacity"
                )
                
                metricView(
                    value: String(format: "%.0f%%", result.batteryUtilizationPercent),
                    unit: "",
                    label: "Utilization"
                )
                
                metricView(
                    value: String(format: "$%.2f", result.batterySavings / 60),
                    unit: "/day",
                    label: "Avg savings"
                )
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
                Image(systemName: "brain.head.profile")
                    .foregroundColor(.purple)
                Text("Powston Optimization")
                    .font(.headline)
                Spacer()
                Text(formatSavings(result.powstonSavings))
                    .font(.headline)
                    .foregroundColor(result.powstonSavings >= 0 ? .green : .red)
            }
            
            Divider()
            
            if result.powstonSavings >= 0 {
                Text("Powston's intelligent trading beat a simple self-consumption strategy by \(formatCurrency(result.powstonSavings)) over 60 days.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                Text("A simple self-consumption strategy would have saved \(formatCurrency(abs(result.powstonSavings))) more over 60 days. This can happen when price forecasts don't match actual prices.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            HStack(spacing: 20) {
                metricView(
                    value: String(format: "$%.2f", result.dailyAvgPowstonValue),
                    unit: "/day",
                    label: result.powstonSavings >= 0 ? "Avg benefit" : "Avg cost"
                )
                
                metricView(
                    value: String(format: "%.1f¢", result.avgImportPrice),
                    unit: "",
                    label: "Avg buy rate"
                )
                
                metricView(
                    value: String(format: "%.1f¢", result.avgExportPrice),
                    unit: "",
                    label: "Avg sell rate"
                )
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    // MARK: - Flat Rate Card
    
    private func flatRateCard(_ result: SavingsBreakdownResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "equal.circle.fill")
                    .foregroundColor(.blue)
                Text("Flat Rate Comparison")
                    .font(.headline)
                Spacer()
            }
            
            Divider()
            
            HStack {
                Text("At \(Int(result.flatBuyRate))¢ buy / \(Int(result.flatSellRate))¢ sell:")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                Text(formatCurrency(result.flatRateCost))
                    .font(.subheadline.monospacedDigit())
            }
            
            if result.flatRateSavings > 0.01 {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("You beat flat rate by \(formatCurrency(result.flatRateSavings))")
                        .font(.subheadline)
                        .foregroundColor(.green)
                }
            } else if result.flatRateSavings < -0.01 {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("Flat rate would save \(formatCurrency(abs(result.flatRateSavings)))")
                        .font(.subheadline)
                        .foregroundColor(.orange)
                }
            }
            
            Text("Adjust comparison rates in Settings → Leaderboard")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    // MARK: - Expansion Card
    
    private func expansionCard(_ result: SavingsBreakdownResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "plus.circle.fill")
                    .foregroundColor(.cyan)
                Text("Battery Expansion Analysis")
                    .font(.headline)
                Spacer()
            }
            
            Divider()
            
            Text("Diminishing returns curve based on your actual usage patterns:")
                .font(.caption)
                .foregroundColor(.secondary)
            
            // Chart
            if #available(iOS 16.0, *) {
                expansionChart(result.expansionAnalysis, currentCapacity: result.currentBatteryCapacity)
                    .frame(height: 200)
            }
            
            // Table of key points
            VStack(spacing: 8) {
                HStack {
                    Text("Capacity")
                        .font(.caption)
                        .fontWeight(.medium)
                        .frame(width: 70, alignment: .leading)
                    Text("Daily Cost")
                        .font(.caption)
                        .fontWeight(.medium)
                        .frame(width: 80, alignment: .trailing)
                    Text("Marginal")
                        .font(.caption)
                        .fontWeight(.medium)
                        .frame(width: 70, alignment: .trailing)
                    Text("$/kWh/day")
                        .font(.caption)
                        .fontWeight(.medium)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .foregroundColor(.secondary)
                
                ForEach(result.expansionAnalysis.filter { point in
                    point.capacityKwh.truncatingRemainder(dividingBy: 50) == 0 || point.isCurrentCapacity
                }) { point in
                    HStack {
                        HStack(spacing: 4) {
                            if point.isCurrentCapacity {
                                Image(systemName: "arrow.right")
                                    .font(.caption2)
                                    .foregroundColor(.green)
                            }
                            Text("\(Int(point.capacityKwh)) kWh")
                                .font(.caption.monospacedDigit())
                        }
                        .frame(width: 70, alignment: .leading)
                        .foregroundColor(point.isCurrentCapacity ? .green : .primary)
                        
                        Text(formatCurrency(point.dailyCost))
                            .font(.caption.monospacedDigit())
                            .frame(width: 80, alignment: .trailing)
                        
                        Text(point.marginalSavings > 0 ? "-\(formatCurrency(point.marginalSavings / 60))" : "—")
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.green)
                            .frame(width: 70, alignment: .trailing)
                        
                        Text(point.savingsPerAddedKwh > 0.001 ? String(format: "%.2f¢", point.savingsPerAddedKwh * 100) : "—")
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
            
            Text("Marginal savings decrease as capacity increases — the first kWh saves more than the last.")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 4)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    @available(iOS 16.0, *)
    private func expansionChart(_ points: [BatteryExpansionPoint], currentCapacity: Double) -> some View {
        Chart {
            ForEach(points) { point in
                LineMark(
                    x: .value("Capacity", point.capacityKwh),
                    y: .value("Daily Cost", point.dailyCost)
                )
                .foregroundStyle(Color.cyan)
                
                if point.isCurrentCapacity {
                    PointMark(
                        x: .value("Capacity", point.capacityKwh),
                        y: .value("Daily Cost", point.dailyCost)
                    )
                    .foregroundStyle(Color.green)
                    .symbolSize(100)
                    .annotation(position: .top) {
                        Text("You")
                            .font(.caption2)
                            .foregroundColor(.green)
                    }
                }
            }
        }
        .chartXAxisLabel("Battery Capacity (kWh)")
        .chartYAxisLabel("Daily Cost ($)")
    }
    
    // MARK: - Footer
    
    private func footerView(_ result: SavingsBreakdownResult) -> some View {
        VStack(spacing: 8) {
            Button(action: runAnalysis) {
                Label("Refresh Analysis", systemImage: "arrow.clockwise")
                    .font(.subheadline)
            }
            .buttonStyle(.bordered)
            
            Text("Analysis based on \(result.periodDays) days of meter data")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.top)
    }
    
    // MARK: - Helpers
    
    private func metricView(value: String, unit: String, label: String) -> some View {
        VStack(spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.subheadline.bold())
                if !unit.isEmpty {
                    Text(unit)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
    
    private func formatCurrency(_ value: Double) -> String {
        String(format: "$%.2f", abs(value))
    }
    
    private func formatSavings(_ value: Double) -> String {
        if value >= 0 {
            return String(format: "-$%.2f", value)
        } else {
            return String(format: "+$%.2f", abs(value))
        }
    }
    
    private func loadCachedOrRun() {
        if let config = config, let cached = analysis.getCachedResult(config: config) {
            analysis.result = cached
        }
    }
    
    private func runAnalysis() {
        guard let config = config else { return }
        Task {
            await analysis.runAnalysis(api: api, config: config)
        }
    }
}

#Preview {
    NavigationStack {
        SavingsBreakdownView()
            .environmentObject(PowstonAPI())
    }
}