//
//  Charts.swift
//  Powston
//

import SwiftUI

// MARK: - Shared Scrub Info for History Charts
struct HistoryScrubInfo: Equatable {
    let time: Date
    let soc: Double?
    let gridImport: Double?
    let gridExport: Double?
    let gridW: Double?
    let batteryW: Double?
    let solarW: Double?
    let loadW: Double?
    let earnings: Double?
    let costs: Double?
    
    static func from(_ record: MeterRecord) -> HistoryScrubInfo {
        HistoryScrubInfo(
            time: record.brisbaneDate ?? Date(),
            soc: record.startBatterySoc,
            gridImport: record.energyImport,
            gridExport: record.energyExport,
            gridW: record.gridW,
            batteryW: record.batteryW,
            solarW: record.ppvGeneration,
            loadW: record.houseConsumption,
            earnings: record.earnings,
            costs: record.costs
        )
    }
}

// MARK: - Scrub Detail Card (larger, more readable)
struct ScrubDetailCard: View {
    let info: HistoryScrubInfo
    
    var body: some View {
        VStack(spacing: 12) {
            // Time header
            HStack {
                Image(systemName: "clock")
                    .foregroundColor(.blue)
                Text(formatTime(info.time))
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                
                // Earnings/Costs
                if let earn = info.earnings, earn > 0 {
                    Text(String(format: "+%.2f¢", earn))
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.green)
                }
                if let cost = info.costs, cost > 0 {
                    Text(String(format: "-%.2f¢", cost))
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.red)
                }
            }
            
            Divider()
            
            // Stats grid
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 8) {
                if let soc = info.soc {
                    ScrubStat(label: "SOC", value: "\(Int(soc))%", color: .green)
                }
                
                // Prefer separate import/export fields when available
                // Convert kWh to Wh for display consistency
                if let imp = info.gridImport, imp > 0 {
                    ScrubStat(label: "Import", value: String(format: "%.0f Wh", imp * 1000), color: .blue)
                } else if let exp = info.gridExport, exp > 0 {
                    ScrubStat(label: "Export", value: String(format: "%.0f Wh", exp * 1000), color: .orange)
                } else if let gridW = info.gridW, gridW != 0 {
                    // Fallback to instantaneous watts if no kWh data
                    // Positive = export, negative = import
                    if gridW < 0 {
                        ScrubStat(label: "Import", value: String(format: "%.0fW", abs(gridW)), color: .blue)
                    } else {
                        ScrubStat(label: "Export", value: String(format: "%.0fW", gridW), color: .orange)
                    }
                }
                
                if let batteryW = info.batteryW {
                    let label = batteryW < 0 ? "Charging" : "Discharge"
                    let color: Color = batteryW < 0 ? .green : .purple
                    ScrubStat(label: label, value: String(format: "%.0fW", abs(batteryW)), color: color)
                }
                
                if let solarW = info.solarW, solarW > 0 {
                    ScrubStat(label: "Solar", value: String(format: "%.0fW", solarW), color: .yellow)
                }
                
                if let loadW = info.loadW, loadW > 0 {
                    ScrubStat(label: "Load", value: String(format: "%.0fW", loadW), color: .orange)
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.1), radius: 4)
    }
    
    func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = powstonTimezone()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

struct ScrubStat: View {
    let label: String
    let value: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(color)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - SOC Chart (Canvas-based for performance)
struct SOCChart: View {
    let records: [MeterRecord]  // Expects pre-sorted records
    @Binding var selectedRecord: MeterRecord?
    var scrubIndex: Int?
    var onScrub: ((Int?) -> Void)?
    
    var body: some View {
        let count = records.count
        
        GeometryReader { geo in
            let w = geo.size.width - 40
            // Use bar-style spacing (n divisions) to sync with GridFlowChart
            let barW = count > 0 ? w / CGFloat(count) : w
            
            Canvas { context, size in
                let width = size.width - 40
                let height = size.height - 30
                guard count > 0 else { return }
                let bw = width / CGFloat(count)
                
                // Grid lines
                for pct in [0, 25, 50, 75, 100] {
                    let y = height - (CGFloat(pct) / 100 * height)
                    var path = Path()
                    path.move(to: CGPoint(x: 30, y: y))
                    path.addLine(to: CGPoint(x: width + 30, y: y))
                    context.stroke(path, with: .color(.gray.opacity(0.2)), lineWidth: 1)
                }
                
                // Build paths once - use center of each bar slot
                var fillPath = Path()
                var linePath = Path()
                
                for (i, record) in records.enumerated() {
                    let soc = record.startBatterySoc ?? 0
                    let x = CGFloat(i) * bw + 30 + bw / 2  // Center of bar slot
                    let y = height - (CGFloat(soc) / 100 * height)
                    
                    if i == 0 {
                        fillPath.move(to: CGPoint(x: x, y: height))
                        fillPath.addLine(to: CGPoint(x: x, y: y))
                        linePath.move(to: CGPoint(x: x, y: y))
                    } else {
                        fillPath.addLine(to: CGPoint(x: x, y: y))
                        linePath.addLine(to: CGPoint(x: x, y: y))
                    }
                }
                if count > 0 {
                    let lastX = CGFloat(count - 1) * bw + 30 + bw / 2
                    fillPath.addLine(to: CGPoint(x: lastX, y: height))
                }
                fillPath.closeSubpath()
                
                context.fill(fillPath, with: .linearGradient(
                    Gradient(colors: [Color.green.opacity(0.3), Color.green.opacity(0.05)]),
                    startPoint: .zero, endPoint: CGPoint(x: 0, y: height)
                ))
                context.stroke(linePath, with: .linearGradient(
                    Gradient(colors: [.green, .yellow, .orange, .red]),
                    startPoint: .zero, endPoint: CGPoint(x: 0, y: height)
                ), lineWidth: 2)
                
                // Scrub indicator - centered in bar slot like GridFlowChart
                if let idx = scrubIndex, idx < count {
                    let x = CGFloat(idx) * bw + 30 + bw / 2
                    var scrubPath = Path()
                    scrubPath.move(to: CGPoint(x: x, y: 0))
                    scrubPath.addLine(to: CGPoint(x: x, y: height))
                    context.stroke(scrubPath, with: .color(.white.opacity(0.8)), lineWidth: 1)
                    
                    let soc = records[idx].startBatterySoc ?? 0
                    let y = height - (CGFloat(soc) / 100 * height)
                    context.fill(Circle().path(in: CGRect(x: x - 5, y: y - 5, width: 10, height: 10)), with: .color(.green))
                }
            }
            .drawingGroup(opaque: false)
            .overlay(alignment: .leading) {
                VStack {
                    Text("100%").font(.system(size: 9)).foregroundColor(.secondary)
                    Spacer()
                    Text("50%").font(.system(size: 9)).foregroundColor(.secondary)
                    Spacer()
                    Text("0%").font(.system(size: 9)).foregroundColor(.secondary)
                }
                .frame(width: 28)
                .padding(.bottom, 30)
            }
            .overlay(alignment: .bottom) {
                HStack {
                    if let first = records.first?.brisbaneDate {
                        Text(formatTimeShort(first)).font(.caption2).foregroundColor(.secondary)
                    }
                    Spacer()
                    if let last = records.last?.brisbaneDate {
                        Text(formatTimeShort(last)).font(.caption2).foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 30)
                .padding(.bottom, 4)
            }
            .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 10)
                                .onChanged { value in
                                    let x = value.location.x - 30
                                    guard w > 0, count > 0 else { return }
                                    let idx = Int(x / barW)
                                    let clamped = max(0, min(count - 1, idx))
                                    onScrub?(clamped)
                                    selectedRecord = records[clamped]
                                }
                                .onEnded { _ in onScrub?(nil) }
                        )
        }
    }
    
    func formatTimeShort(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = powstonTimezone()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Grid Flow Chart (Canvas-based for performance)
struct GridFlowChart: View {
    let records: [MeterRecord]  // Expects pre-sorted records
    @Binding var selectedRecord: MeterRecord?
    var scrubIndex: Int?
    var onScrub: ((Int?) -> Void)?
    
    var body: some View {
        let count = records.count
        let maxImport = records.compactMap { $0.energyImport }.max() ?? 1
        let maxExport = records.compactMap { $0.energyExport }.max() ?? 1
        let maxValue = max(maxImport, maxExport, 0.1)
        
        GeometryReader { geo in
            let w = geo.size.width - 40
            let bw = count > 0 ? max(1, w / CGFloat(count)) : w
            
            Canvas { context, size in
                let width = size.width - 40
                let height = size.height - 20
                guard count > 0 else { return }
                let barW = max(1, width / CGFloat(count))
                
                // Center line
                var centerPath = Path()
                centerPath.move(to: CGPoint(x: 30, y: height / 2))
                centerPath.addLine(to: CGPoint(x: width + 30, y: height / 2))
                context.stroke(centerPath, with: .color(.gray.opacity(0.3)), lineWidth: 1)
                
                // Bars - Import above zero (consuming from grid), Export below zero (sending to grid)
                for (i, record) in records.enumerated() {
                    let x = CGFloat(i) * barW + 30
                    let importVal = record.energyImport ?? 0
                    let exportVal = record.energyExport ?? 0
                    
                    if importVal > 0 {
                        let barH = CGFloat(importVal / maxValue) * (height / 2)
                        context.fill(Path(CGRect(x: x, y: height / 2 - barH, width: max(1, barW - 1), height: barH)), with: .color(.blue.opacity(0.7)))
                    }
                    if exportVal > 0 {
                        let barH = CGFloat(exportVal / maxValue) * (height / 2)
                        context.fill(Path(CGRect(x: x, y: height / 2, width: max(1, barW - 1), height: barH)), with: .color(.orange.opacity(0.7)))
                    }
                }
                
                // Scrub indicator
                if let idx = scrubIndex, idx < count {
                    let x = CGFloat(idx) * barW + 30 + barW / 2
                    var scrubPath = Path()
                    scrubPath.move(to: CGPoint(x: x, y: 0))
                    scrubPath.addLine(to: CGPoint(x: x, y: height))
                    context.stroke(scrubPath, with: .color(.white.opacity(0.8)), lineWidth: 1)
                }
            }
            .drawingGroup(opaque: false)
            .overlay(alignment: .leading) {
                VStack {
                    Text("Import ↑").font(.caption2).foregroundColor(.blue)
                    Spacer()
                    Text("Export ↓").font(.caption2).foregroundColor(.orange)
                }
                .frame(width: 28)
                .padding(.vertical, 10)
            }
            .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 10)
                                .onChanged { value in
                                    let x = value.location.x - 30
                                    guard w > 0, count > 0 else { return }
                                    let idx = Int(x / bw)
                                    let clamped = max(0, min(count - 1, idx))
                                    onScrub?(clamped)
                                    selectedRecord = records[clamped]
                                }
                                .onEnded { _ in onScrub?(nil) }
                        )
        }
    }
}

// MARK: - Combined Forecast Chart
struct CombinedForecastChart: View {
    let buyValues: [Double]
    let sellValues: [Double]
    let solarValues: [Double]
    let sunriseHour: Double?
    let sunsetHour: Double?
    let peakStartHour: Double?
    let peakEndHour: Double?
    let data: InverterResponse
    @Binding var selectedPeriod: Int?
    
    var body: some View {
        GeometryReader { geometry in
            let allPriceValues = buyValues + sellValues
            let maxPriceValue = allPriceValues.max() ?? 1
            let minPriceValue = allPriceValues.min() ?? 0
            let priceRange = maxPriceValue - minPriceValue
            
            let maxSolarValue = max(solarValues.max() ?? 1, 100) // At least 100 W/m² scale
            
            let leftMargin: CGFloat = 35
            let rightMargin: CGFloat = 45  // More space for solar axis
            let topMargin: CGFloat = 10
            let bottomMargin: CGFloat = 30
            
            let width = geometry.size.width - leftMargin - rightMargin
            let height = geometry.size.height - topMargin - bottomMargin
            let stepWidth = width / CGFloat(max(buyValues.count - 1, 1))
            
            ZStack(alignment: .topLeading) {
                // Left Y-axis label (Price)
                Text("Price (¢/kWh)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .rotationEffect(.degrees(-90))
                    .offset(x: -10, y: height / 2)
                
                // Right Y-axis label (Solar)
                Text("Solar (W/m²)")
                    .font(.caption2)
                    .foregroundColor(.yellow.opacity(0.8))
                    .rotationEffect(.degrees(90))
                    .offset(x: geometry.size.width - 15, y: height / 2)
                
                ZStack(alignment: .topLeading) {
                    // Peak period background
                    if let peakStart = peakStartHour, let peakEnd = peakEndHour {
                        let startX = CGFloat(peakStart * 2) * stepWidth
                        let endX = CGFloat(peakEnd * 2) * stepWidth
                        
                        Rectangle()
                            .fill(Color.red.opacity(0.08))
                            .frame(width: max(0, endX - startX), height: height)
                            .offset(x: startX)
                        
                        Path { path in
                            path.move(to: CGPoint(x: startX, y: 0))
                            path.addLine(to: CGPoint(x: startX, y: height))
                        }
                        .stroke(Color.red.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4, 2]))
                        
                        Path { path in
                            path.move(to: CGPoint(x: endX, y: 0))
                            path.addLine(to: CGPoint(x: endX, y: height))
                        }
                        .stroke(Color.red.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4, 2]))
                        
                        Text("PEAK")
                            .font(.caption2.weight(.bold))
                            .foregroundColor(.red.opacity(0.6))
                            .offset(x: (startX + endX) / 2 - 15, y: 4)
                    }
                    
                    // Grid lines
                    ForEach(0..<5) { i in
                        let y = height * CGFloat(i) / 4
                        let value = maxPriceValue - (priceRange * CGFloat(i) / 4)
                        
                        Path { path in
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: width, y: y))
                        }
                        .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                        
                        // Price labels (left)
                        Text(String(format: "%.0f", value))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .offset(x: -25, y: y - 6)
                        
                        // Solar labels (right)
                        let solarValue = maxSolarValue * (1.0 - Double(i) / 4.0)
                        Text(String(format: "%.0f", solarValue))
                            .font(.caption2)
                            .foregroundColor(.yellow.opacity(0.7))
                            .offset(x: width + 5, y: y - 6)
                    }
                    
                    // Time labels
                    let labelInterval = max(1, buyValues.count / 6)
                    ForEach(Array(stride(from: 0, to: buyValues.count, by: labelInterval)), id: \.self) { i in
                        let x = CGFloat(i) * stepWidth
                        if let absTime = data.absoluteTimeForPeriod(i) {
                            Text(formatTimeShort(absTime))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .offset(x: x - 15, y: height + 8)
                        }
                    }
                    
                    // Sunrise marker
                    if let sunrise = sunriseHour, sunrise >= 0 && sunrise <= 24 {
                        let x = CGFloat(sunrise * 2) * stepWidth
                        Path { path in
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: x, y: height))
                        }
                        .stroke(Color.orange.opacity(0.5), style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                        
                        Image(systemName: "sunrise.fill")
                            .font(.caption2)
                            .foregroundColor(.orange)
                            .offset(x: x - 8, y: -8)
                    }
                    
                    // Sunset marker
                    if let sunset = sunsetHour, sunset >= 0 && sunset <= 24 {
                        let x = CGFloat(sunset * 2) * stepWidth
                        Path { path in
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: x, y: height))
                        }
                        .stroke(Color.orange.opacity(0.5), style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                        
                        Image(systemName: "sunset.fill")
                            .font(.caption2)
                            .foregroundColor(.orange)
                            .offset(x: x - 8, y: -8)
                    }
                    
                    // Solar radiation bars (behind price lines)
                    if !solarValues.isEmpty {
                        let barWidth = stepWidth * 2  // Each bar covers 1 hour (2 x 30-min periods)
                        ForEach(Array(stride(from: 0, to: solarValues.count, by: 2)), id: \.self) { index in
                            let value = solarValues[index]
                            if value > 0 {
                                let x = CGFloat(index) * stepWidth
                                let normalizedValue = value / maxSolarValue
                                let barHeight = CGFloat(normalizedValue) * height
                                
                                Rectangle()
                                    .fill(
                                        LinearGradient(
                                            colors: [Color.yellow.opacity(0.5), Color.yellow.opacity(0.2)],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                    )
                                    .frame(width: barWidth - 2, height: barHeight)
                                    .position(x: x, y: height - barHeight / 2)
                            }
                        }
                    }
                    
                    // Sell price gradient
                    Path { path in
                        for (index, value) in sellValues.enumerated() {
                            let x = CGFloat(index) * stepWidth
                            let normalizedValue = priceRange > 0 ? (value - minPriceValue) / priceRange : 0.5
                            let y = height - (CGFloat(normalizedValue) * height)
                            
                            if index == 0 {
                                path.move(to: CGPoint(x: x, y: height))
                                path.addLine(to: CGPoint(x: x, y: y))
                            } else {
                                path.addLine(to: CGPoint(x: x, y: y))
                            }
                        }
                        path.addLine(to: CGPoint(x: width, y: height))
                        path.closeSubpath()
                    }
                    .fill(
                        LinearGradient(
                            colors: [Color.green.opacity(0.2), Color.green.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    
                    // Buy price gradient
                    Path { path in
                        for (index, value) in buyValues.enumerated() {
                            let x = CGFloat(index) * stepWidth
                            let normalizedValue = priceRange > 0 ? (value - minPriceValue) / priceRange : 0.5
                            let y = height - (CGFloat(normalizedValue) * height)
                            
                            if index == 0 {
                                path.move(to: CGPoint(x: x, y: height))
                                path.addLine(to: CGPoint(x: x, y: y))
                            } else {
                                path.addLine(to: CGPoint(x: x, y: y))
                            }
                        }
                        path.addLine(to: CGPoint(x: width, y: height))
                        path.closeSubpath()
                    }
                    .fill(
                        LinearGradient(
                            colors: [Color.blue.opacity(0.2), Color.blue.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    
                    // Sell price line
                    Path { path in
                        for (index, value) in sellValues.enumerated() {
                            let x = CGFloat(index) * stepWidth
                            let normalizedValue = priceRange > 0 ? (value - minPriceValue) / priceRange : 0.5
                            let y = height - (CGFloat(normalizedValue) * height)
                            
                            if index == 0 {
                                path.move(to: CGPoint(x: x, y: y))
                            } else {
                                path.addLine(to: CGPoint(x: x, y: y))
                            }
                        }
                    }
                    .stroke(Color.green, lineWidth: 2.5)
                    
                    // Buy price line
                    Path { path in
                        for (index, value) in buyValues.enumerated() {
                            let x = CGFloat(index) * stepWidth
                            let normalizedValue = priceRange > 0 ? (value - minPriceValue) / priceRange : 0.5
                            let y = height - (CGFloat(normalizedValue) * height)
                            
                            if index == 0 {
                                path.move(to: CGPoint(x: x, y: y))
                            } else {
                                path.addLine(to: CGPoint(x: x, y: y))
                            }
                        }
                    }
                    .stroke(Color.blue, lineWidth: 2.5)
                    
                    // Selected period indicator
                    if let period = selectedPeriod, period < buyValues.count {
                        let x = CGFloat(period) * stepWidth
                        
                        Path { path in
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: x, y: height))
                        }
                        .stroke(Color.primary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        
                        let buyNormalizedValue = priceRange > 0 ? (buyValues[period] - minPriceValue) / priceRange : 0.5
                        let buyY = height - (CGFloat(buyNormalizedValue) * height)
                        Circle()
                            .fill(Color.blue)
                            .frame(width: 8, height: 8)
                            .offset(x: x - 4, y: buyY - 4)
                        
                        Circle()
                            .stroke(Color.white, lineWidth: 2)
                            .frame(width: 8, height: 8)
                            .offset(x: x - 4, y: buyY - 4)
                        
                        let sellNormalizedValue = priceRange > 0 ? (sellValues[period] - minPriceValue) / priceRange : 0.5
                        let sellY = height - (CGFloat(sellNormalizedValue) * height)
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                            .offset(x: x - 4, y: sellY - 4)
                        
                        Circle()
                            .stroke(Color.white, lineWidth: 2)
                            .frame(width: 8, height: 8)
                            .offset(x: x - 4, y: sellY - 4)
                        
                        // Solar indicator
                        if period < solarValues.count && solarValues[period] > 0 {
                            let solarNormalized = solarValues[period] / maxSolarValue
                            let solarY = height - (CGFloat(solarNormalized) * height)
                            Circle()
                                .fill(Color.yellow)
                                .frame(width: 8, height: 8)
                                .offset(x: x - 4, y: solarY - 4)
                            
                            Circle()
                                .stroke(Color.white, lineWidth: 2)
                                .frame(width: 8, height: 8)
                                .offset(x: x - 4, y: solarY - 4)
                        }
                    }
                    
                    // Tap overlay
                                        Color.clear
                                            .contentShape(Rectangle())
                                            .gesture(
                                                DragGesture(minimumDistance: 10)
                                                    .onChanged { value in
                                                        let x = value.location.x
                                                        let period = Int(round(x / stepWidth))
                                                        if period >= 0 && period < buyValues.count {
                                                            selectedPeriod = period
                                                        }
                                                    }
                                            )
                }
                .offset(x: leftMargin, y: topMargin)
                
                Text("Time")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .offset(x: geometry.size.width / 2 - 10, y: geometry.size.height - 10)
            }
        }
    }
    
    private func formatTimeShort(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        formatter.timeZone = powstonTimezone()
        let timeString = formatter.string(from: date)
        return timeString.replacingOccurrences(of: " ", with: "")
    }
}
