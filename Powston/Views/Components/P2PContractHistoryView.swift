//
//  P2PContractHistoryView.swift
//  Powston
//
//  Contract tracking view showing historical and active P2P contracts
//  with performance metrics, fill rate gauges, and tier breakdowns
//

import SwiftUI

// MARK: - Contract History View

struct P2PContractHistoryView: View {
    @EnvironmentObject var api: PowstonAPI
    @State private var contracts: [P2PContract] = []
    @State private var performanceCache: [UUID: P2PContractPerformance] = [:]
    @State private var showNewContract = false
    @State private var editingContract: P2PContract?
    @State private var isLoading = true
    
    var body: some View {
        VStack(spacing: 16) {
            if isLoading {
                ProgressView("Loading contracts...")
                    .padding(.vertical, 40)
            } else if contracts.isEmpty {
                emptyState
            } else {
                contractList
            }
        }
        .sheet(isPresented: $showNewContract) {
            P2PContractEntryView(onSave: { _ in loadContracts() })
        }
        .sheet(item: $editingContract) { contract in
            P2PContractEntryView(
                existingContract: contract,
                onSave: { _ in loadContracts() }
            )
        }
        .onAppear { loadContracts() }
    }
    
    // MARK: - Empty State
    
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text.fill")
                .font(.system(size: 40))
                .foregroundColor(.purple.opacity(0.5))
            
            Text("No Contracts Yet")
                .font(.headline)
            
            Text("Track your P2P trading contracts to monitor fill rates, tier performance, and revenue vs forecast.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            Button(action: { showNewContract = true }) {
                Label("Add Contract", systemImage: "plus.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.purple)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
        }
        .padding()
    }
    
    // MARK: - Contract List
    
    private var contractList: some View {
        VStack(spacing: 16) {
            // Active contract (if any)
            if let active = contracts.first(where: { $0.isActive }) {
                activeContractCard(active)
            }
            
            // Add new contract button
            Button(action: { showNewContract = true }) {
                Label("New Contract", systemImage: "plus.circle.fill")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.purple.opacity(0.15))
                    .foregroundColor(.purple)
                    .cornerRadius(12)
            }
            
            // Past contracts
            let pastContracts = contracts.filter { !$0.isActive }
            if !pastContracts.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Past Contracts")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    
                    ForEach(pastContracts) { contract in
                        pastContractCard(contract)
                    }
                }
            }
        }
    }
    
    // MARK: - Active Contract Card
    
    private func activeContractCard(_ contract: P2PContract) -> some View {
        let perf = performanceCache[contract.id]
        
        return VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: "bolt.circle.fill")
                    .foregroundColor(.green)
                Text("Active Contract")
                    .font(.headline)
                Spacer()
                Button(action: { editingContract = contract }) {
                    Image(systemName: "pencil.circle")
                        .foregroundColor(.secondary)
                }
            }
            
            Divider()
            
            // Contract terms
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(contract.dateRangeString)
                        .font(.subheadline.bold())
                    Text(contract.hoursString + " AEST")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "%.0f kWh", contract.totalVolumeKwh))
                        .font(.subheadline.bold())
                    Text(String(format: "%.1f¢ blended", contract.blendedPriceCents))
                        .font(.caption)
                        .foregroundColor(.purple)
                }
            }
            
            // Tier fill rates
            if let perf = perf {
                Divider()
                tierFillGauges(perf)
                
                Divider()
                performanceSummary(perf)
            } else {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Loading performance...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }
            
            // Renewal info
            if let days = contract.renewalDays {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Renews every \(days) days")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.green.opacity(0.3), lineWidth: 1)
        )
        .cornerRadius(12)
    }
    
    // MARK: - Past Contract Card
    
    private func pastContractCard(_ contract: P2PContract) -> some View {
        let perf = performanceCache[contract.id]
        
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(contract.dateRangeString)
                        .font(.subheadline.bold())
                    Text(contract.hoursString)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                if let perf = perf {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(String(format: "%.0f%%", perf.overallFillRate))
                            .font(.subheadline.bold())
                            .foregroundColor(fillRateColor(perf.overallFillRate))
                        Text("fill rate")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                
                Button(action: { editingContract = contract }) {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            // Compact tier gauges
            if let perf = perf {
                HStack(spacing: 8) {
                    ForEach(perf.tierPerformance) { tierPerf in
                        compactTierGauge(tierPerf)
                    }
                }
                
                HStack {
                    Text(formatCurrency(perf.totalRevenue))
                        .font(.caption.bold())
                        .foregroundColor(.green)
                    Text("of")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(formatCurrency(contract.estimatedRevenue))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("forecast")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    Text("\(perf.counterpartyCount) counterparties")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    // MARK: - Tier Fill Gauges
    
    private func tierFillGauges(_ perf: P2PContractPerformance) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tier Fill Rates")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
            
            ForEach(perf.tierPerformance) { tierPerf in
                tierFillRow(tierPerf)
            }
        }
    }
    
    private func tierFillRow(_ tierPerf: P2PTierPerformance) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text("\(Int(tierPerf.tier.priceCents))¢")
                    .font(.caption.bold())
                    .foregroundColor(.purple)
                    .frame(width: 35, alignment: .leading)
                
                Text("(\(Int(tierPerf.tier.percentage))%)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(width: 35)
                
                // Fill gauge
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(.tertiarySystemBackground))
                            .frame(height: 8)
                        
                        RoundedRectangle(cornerRadius: 3)
                            .fill(fillRateColor(tierPerf.fillRate))
                            .frame(width: max(0, geo.size.width * min(1, tierPerf.fillRate / 100)), height: 8)
                    }
                }
                .frame(height: 8)
                
                Text(String(format: "%.0f%%", tierPerf.fillRate))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(fillRateColor(tierPerf.fillRate))
                    .frame(width: 40, alignment: .trailing)
            }
            
            HStack {
                Spacer()
                    .frame(width: 70)
                Text(String(format: "%.1f / %.1f kWh", tierPerf.matchedKwh, tierPerf.tier.volumeKwh))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
    }
    
    private func compactTierGauge(_ tierPerf: P2PTierPerformance) -> some View {
        VStack(spacing: 2) {
            Text("\(Int(tierPerf.tier.priceCents))¢")
                .font(.caption2.bold())
                .foregroundColor(.purple)
            
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(.tertiarySystemBackground))
                    .frame(height: 6)
                
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(fillRateColor(tierPerf.fillRate))
                        .frame(width: max(0, geo.size.width * min(1, tierPerf.fillRate / 100)), height: 6)
                }
                .frame(height: 6)
            }
            
            Text(String(format: "%.0f%%", tierPerf.fillRate))
                .font(.caption2.monospacedDigit())
                .foregroundColor(fillRateColor(tierPerf.fillRate))
        }
    }
    
    // MARK: - Performance Summary
    
    private func performanceSummary(_ perf: P2PContractPerformance) -> some View {
        VStack(spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Matched")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(String(format: "%.1f kWh", perf.totalMatchedKwh))
                        .font(.subheadline.bold())
                }
                
                Spacer()
                
                VStack(alignment: .center, spacing: 2) {
                    Text("Revenue")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(formatCurrency(perf.totalRevenue))
                        .font(.subheadline.bold())
                        .foregroundColor(.green)
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Fill Rate")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(String(format: "%.0f%%", perf.overallFillRate))
                        .font(.subheadline.bold())
                        .foregroundColor(fillRateColor(perf.overallFillRate))
                }
            }
            
            // Revenue vs forecast
            HStack(spacing: 6) {
                Image(systemName: perf.revenueVsForecast >= 80 ? "checkmark.circle.fill" : "info.circle.fill")
                    .foregroundColor(perf.revenueVsForecast >= 80 ? .green : .orange)
                    .font(.caption)
                Text(String(format: "%.0f%% of $%.2f forecast", perf.revenueVsForecast, perf.contract.estimatedRevenue))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(perf.counterpartyCount) counterparties")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    // MARK: - Helpers
    
    private func fillRateColor(_ rate: Double) -> Color {
        if rate >= 75 { return .green }
        if rate >= 40 { return .orange }
        return .red
    }
    
    private func formatCurrency(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencySymbol = "$"
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? "$0.00"
    }
    
    // MARK: - Data Loading
    
    private func loadContracts() {
        guard let siteId = api.selectedSite?.id else {
            isLoading = false
            return
        }
        
        isLoading = true
        
        contracts = PowstonDataStore.shared.getP2PContracts(siteId: siteId)
        
        // Load performance for each contract
        Task { @MainActor in
            for contract in contracts {
                let perf = PowstonDataStore.shared.getP2PContractPerformance(contract)
                performanceCache[contract.id] = perf
            }
            isLoading = false
        }
    }
}

// MARK: - Preview

#Preview {
    P2PContractHistoryView()
        .environmentObject(PowstonAPI())
}