//
//  HistoryView.swift
//  Powston
//

import SwiftUI

struct HistoryView: View {
    @EnvironmentObject var api: PowstonAPI
    @State private var records: [MeterRecord] = []
    @State private var isLoading = false
    @State private var selectedRecord: MeterRecord?
    
    var totalEarnings: Double {
        records.compactMap { $0.earnings }.reduce(0, +) / 100.0
    }

    var totalCosts: Double {
        records.compactMap { $0.costs }.reduce(0, +) / 100.0
    }
    
    var totalImport: Double {
        records.compactMap { $0.energyImport }.reduce(0, +)
    }
    
    var totalExport: Double {
        records.compactMap { $0.energyExport }.reduce(0, +)
    }
    
    var netProfit: Double {
        totalEarnings - totalCosts
    }
    
    var timeRange: String {
        guard let oldest = records.last?.brisbaneDate,
              let newest = records.first?.brisbaneDate else { return "—" }
        
        let formatter = DateFormatter()
        formatter.timeZone = powstonTimezone()
        
        let calendar = Calendar.current
        
        if calendar.isDate(oldest, inSameDayAs: newest) {
            formatter.dateFormat = "MMMM d, yyyy"
            return formatter.string(from: oldest)
        } else {
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            return "\(formatter.string(from: oldest)) – \(formatter.string(from: newest))"
        }
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                if isLoading {
                    ProgressView("Loading history...")
                        .padding(.top, 100)
                } else if records.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 50))
                            .foregroundColor(.secondary)
                        Text("No history available")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        if api.selectedInverterId == 0 {
                            Text("Select an inverter in Settings")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.top, 100)
                } else {
                    VStack(spacing: 20) {
                        // Time range header
                        HStack {
                            Image(systemName: "calendar")
                                .foregroundColor(.secondary)
                            Text(timeRange)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(records.count) intervals")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal)
                        .padding(.top, 8)
                        
                        // Summary Cards
                        HStack(spacing: 12) {
                            SummaryCard(
                                title: "Earnings",
                                value: String(format: "$%.2f", totalEarnings),
                                icon: "arrow.up.circle.fill",
                                color: .green
                            )
                            SummaryCard(
                                title: "Costs",
                                value: String(format: "$%.2f", totalCosts),
                                icon: "arrow.down.circle.fill",
                                color: .red
                            )
                            SummaryCard(
                                title: "Net",
                                value: String(format: "%@$%.2f", netProfit >= 0 ? "+" : "", abs(netProfit)),
                                icon: netProfit >= 0 ? "plus.circle.fill" : "minus.circle.fill",
                                color: netProfit >= 0 ? .green : .red
                            )
                        }
                        .padding(.horizontal)
                        
                        // Energy Summary
                        HStack(spacing: 12) {
                            EnergySummaryCard(
                                title: "Imported",
                                value: String(format: "%.2f kWh", totalImport),
                                color: .blue
                            )
                            EnergySummaryCard(
                                title: "Exported",
                                value: String(format: "%.2f kWh", totalExport),
                                color: .orange
                            )
                        }
                        .padding(.horizontal)
                        
                        // SOC Chart
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Battery SOC")
                                .font(.headline)
                                .padding(.horizontal)
                            
                            SOCChart(records: records, selectedRecord: $selectedRecord)
                                .frame(height: 200)
                                .padding(.horizontal, 8)
                        }
                        .padding(.vertical, 8)
                        .background(Color.gray.opacity(0.05))
                        .cornerRadius(12)
                        .padding(.horizontal)
                        
                        // Grid Flow Chart
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Grid Flow")
                                    .font(.headline)
                                Spacer()
                                HStack(spacing: 12) {
                                    HStack(spacing: 4) {
                                        Circle().fill(Color.blue).frame(width: 8, height: 8)
                                        Text("Import").font(.caption2)
                                    }
                                    HStack(spacing: 4) {
                                        Circle().fill(Color.orange).frame(width: 8, height: 8)
                                        Text("Export").font(.caption2)
                                    }
                                }
                                .foregroundColor(.secondary)
                            }
                            .padding(.horizontal)
                            
                            GridFlowChart(records: records, selectedRecord: $selectedRecord)
                                .frame(height: 150)
                                .padding(.horizontal, 8)
                        }
                        .padding(.vertical, 8)
                        .background(Color.gray.opacity(0.05))
                        .cornerRadius(12)
                        .padding(.horizontal)
                        
                        // Selected record detail
                        if let record = selectedRecord {
                            RecordDetailCard(record: record)
                                .padding(.horizontal)
                        }
                        
                        Spacer(minLength: 20)
                    }
                }
            }
            .background(Color.gray.opacity(0.02))
            .navigationTitle(api.isDemoMode ? "History (Demo)" : "History")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button(action: { Task { await loadHistory() } }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                }
            }
            .task {
                if records.isEmpty {
                    await loadHistory()
                }
            }
        }
    }
    
    func loadHistory() async {
        isLoading = true
        records = await api.fetchMeterRecords()
        isLoading = false
    }
}

// MARK: - Record Detail Card
struct RecordDetailCard: View {
    let record: MeterRecord
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "clock")
                    .foregroundColor(.blue)
                Text(formatTime(record.brisbaneDate))
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
            }
            
            Divider()
            
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 12) {
                DetailStat(label: "SOC", value: String(format: "%.1f%%", record.startBatterySoc ?? 0), color: .green)
                DetailStat(label: "Grid", value: String(format: "%.0fW", record.gridW ?? 0), color: .blue)
                DetailStat(label: "Battery", value: String(format: "%.0fW", record.batteryW ?? 0), color: .purple)
                DetailStat(label: "Solar", value: String(format: "%.0fW", record.ppvGeneration ?? 0), color: .yellow)
                DetailStat(label: "Load", value: String(format: "%.0fW", record.houseConsumption ?? 0), color: .orange)
                DetailStat(label: "RRP", value: String(format: "$%.0f", record.rrp ?? 0), color: .gray)
            }
            
            HStack(spacing: 16) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.circle.fill")
                        .foregroundColor(.green)
                        .font(.caption)
                    Text(String(format: "+$%.4f", record.earnings ?? 0))
                        .font(.caption)
                        .foregroundColor(.green)
                }
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundColor(.red)
                        .font(.caption)
                    Text(String(format: "-$%.4f", record.costs ?? 0))
                        .font(.caption)
                        .foregroundColor(.red)
                }
                Spacer()
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.1), radius: 4)
    }
    
    func formatTime(_ date: Date?) -> String {
        guard let date = date else { return "—" }
        let formatter = DateFormatter()
        formatter.timeZone = powstonTimezone()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
}
