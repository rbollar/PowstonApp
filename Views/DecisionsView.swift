//
//  DecisionsView.swift
//  Powston
//

import SwiftUI

struct DecisionsView: View {
    @EnvironmentObject var api: PowstonAPI
    @State private var selectedHour: Int? = nil
    
    var body: some View {
        NavigationStack {
            if let d = api.data {
                List {
                    Section("Current Decision") {
                        HStack {
                            Text("Action")
                            Spacer()
                            Text(d.action.uppercased())
                                .fontWeight(.bold)
                                .foregroundColor(actionColor(d.action))
                        }
                        HStack {
                            Text("Script")
                            Spacer()
                            Text(d.userCodeName)
                                .font(.caption)
                        }
                    }
                    
                    Section("Reason") {
                        Text(d.reason)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    
                    Section("24h Action Pattern") {
                        VStack(alignment: .leading, spacing: 12) {
                            if let hour = selectedHour, hour < d.actionPattern.count {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Hour")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                        Text(formatHour(hour, data: d))
                                            .font(.subheadline)
                                            .fontWeight(.semibold)
                                    }
                                    
                                    Divider()
                                        .frame(height: 30)
                                    
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Action")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                        Text(d.actionPattern[hour].uppercased())
                                            .font(.subheadline)
                                            .fontWeight(.semibold)
                                            .foregroundColor(actionColor(d.actionPattern[hour]))
                                    }
                                    
                                    Divider()
                                        .frame(height: 30)
                                    
                                    let forecastIndex = hour * 2
                                    if forecastIndex < d.buyForecast.count {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Buy")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                            Text(String(format: "%.1f¢", d.buyForecast[forecastIndex]))
                                                .font(.subheadline)
                                                .foregroundColor(.blue)
                                        }
                                        
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Sell")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                            Text(String(format: "%.1f¢", d.sellForecast[forecastIndex]))
                                                .font(.subheadline)
                                                .foregroundColor(.green)
                                        }
                                    }
                                    
                                    Spacer()
                                    
                                    Button(action: { selectedHour = nil }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .padding(10)
                                .background(actionColor(d.actionPattern[hour]).opacity(0.1))
                                .cornerRadius(8)
                                
                                if hour == d.currentHour {
                                    HStack {
                                        Image(systemName: "clock.fill")
                                            .font(.caption2)
                                        Text("Current hour")
                                            .font(.caption2)
                                    }
                                    .foregroundColor(.secondary)
                                }
                            } else {
                                Text("Tap an hour to see details")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 4) {
                                    ForEach(Array(d.actionPattern.enumerated()), id: \.offset) { i, action in
                                        Button(action: {
                                            withAnimation(.easeInOut(duration: 0.15)) {
                                                if selectedHour == i {
                                                    selectedHour = nil
                                                } else {
                                                    selectedHour = i
                                                }
                                            }
                                        }) {
                                            VStack(spacing: 2) {
                                                RoundedRectangle(cornerRadius: 3)
                                                    .fill(actionColor(action))
                                                    .frame(width: selectedHour == i ? 16 : 12, height: selectedHour == i ? 32 : 24)
                                                    .opacity(i == d.currentHour ? 1 : (selectedHour == i ? 0.9 : 0.4))
                                                    .overlay(
                                                        RoundedRectangle(cornerRadius: 3)
                                                            .stroke(selectedHour == i ? Color.primary : Color.clear, lineWidth: 2)
                                                    )
                                                Text("\(i)")
                                                    .font(.system(size: selectedHour == i ? 9 : 8))
                                                    .foregroundColor(selectedHour == i ? .primary : .secondary)
                                            }
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.vertical, 8)
                            }
                            
                            HStack(spacing: 16) {
                                LegendDot(color: .blue, label: "Import")
                                LegendDot(color: .green, label: "Export")
                                LegendDot(color: .yellow, label: "Charge")
                                LegendDot(color: .gray, label: "Auto/Hold")
                            }
                            .font(.caption2)
                        }
                    }
                }
                .navigationTitle(api.isDemoMode ? "Decisions (Demo)" : "Decisions")
            } else {
                VStack {
                    Text("No data")
                        .foregroundColor(.secondary)
                }
                .navigationTitle(api.isDemoMode ? "Decisions (Demo)" : "Decisions")
            }
        }
    }
    
    func actionColor(_ action: String) -> Color {
        switch action.lowercased() {
        case "import": return .blue
        case "export": return .green
        case "charge": return .yellow
        case "hold": return .gray
        default: return .gray
        }
    }
    
    func formatHour(_ hour: Int, data: InverterResponse) -> String {
        let displayHour = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour)
        let ampm = hour < 12 ? "AM" : "PM"
        return "\(displayHour):00 \(ampm)"
    }
}
