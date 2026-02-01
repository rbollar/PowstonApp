//
//  Charts.swift
//  Powston
//

import SwiftUI

// MARK: - SOC Chart
struct SOCChart: View {
    let records: [MeterRecord]
    @Binding var selectedRecord: MeterRecord?
    
    var body: some View {
        GeometryReader { geometry in
            let sortedRecords = records.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
            let width = geometry.size.width - 40
            let height = geometry.size.height - 30
            let stepWidth = sortedRecords.count > 1 ? width / CGFloat(sortedRecords.count - 1) : width
            
            ZStack(alignment: .topLeading) {
                // Y-axis labels
                ForEach([0, 25, 50, 75, 100], id: \.self) { pct in
                    let y = height - (CGFloat(pct) / 100 * height)
                    
                    Path { path in
                        path.move(to: CGPoint(x: 30, y: y))
                        path.addLine(to: CGPoint(x: width + 30, y: y))
                    }
                    .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                    
                    Text("\(pct)%")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .position(x: 15, y: y)
                }
                
                // SOC line
                Path { path in
                    for (index, record) in sortedRecords.enumerated() {
                        let soc = record.startBatterySoc ?? 0
                        let x = CGFloat(index) * stepWidth + 30
                        let y = height - (CGFloat(soc) / 100 * height)
                        
                        if index == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                }
                .stroke(
                    LinearGradient(
                        colors: [.green, .yellow, .orange, .red],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 2
                )
                
                // SOC gradient fill
                Path { path in
                    for (index, record) in sortedRecords.enumerated() {
                        let soc = record.startBatterySoc ?? 0
                        let x = CGFloat(index) * stepWidth + 30
                        let y = height - (CGFloat(soc) / 100 * height)
                        
                        if index == 0 {
                            path.move(to: CGPoint(x: x, y: height))
                            path.addLine(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                    path.addLine(to: CGPoint(x: CGFloat(sortedRecords.count - 1) * stepWidth + 30, y: height))
                    path.closeSubpath()
                }
                .fill(
                    LinearGradient(
                        colors: [Color.green.opacity(0.3), Color.green.opacity(0.05)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                
                // Touch overlay
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let x = value.location.x - 30
                                let index = Int(round(x / stepWidth))
                                if index >= 0 && index < sortedRecords.count {
                                    selectedRecord = sortedRecords[index]
                                }
                            }
                    )
                
                // Time labels
                Group {
                    let timeFormatter: DateFormatter = {
                        let f = DateFormatter()
                        f.timeZone = powstonTimezone()
                        f.timeStyle = .short
                        return f
                    }()

                    if sortedRecords.count > 1 {
                        Text(timeFormatter.string(from: sortedRecords.first?.brisbaneDate ?? Date()))
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                            .position(x: 45, y: height + 15)
                        
                        Text(timeFormatter.string(from: sortedRecords.last?.brisbaneDate ?? Date()))
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                            .position(x: width + 15, y: height + 15)
                    }
                }
            }
        }
    }
}

// MARK: - Grid Flow Chart
struct GridFlowChart: View {
    let records: [MeterRecord]
    @Binding var selectedRecord: MeterRecord?
    
    var body: some View {
        GeometryReader { geometry in
            let sortedRecords = records.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
            let width = geometry.size.width - 40
            let height = geometry.size.height - 20
            let barWidth = sortedRecords.count > 0 ? max(1, width / CGFloat(sortedRecords.count)) : 1
            
            let maxImport = sortedRecords.compactMap { $0.energyImport }.max() ?? 1
            let maxExport = sortedRecords.compactMap { $0.energyExport }.max() ?? 1
            let maxValue = max(maxImport, maxExport, 0.1)
            
            ZStack(alignment: .topLeading) {
                Path { path in
                    path.move(to: CGPoint(x: 30, y: height / 2))
                    path.addLine(to: CGPoint(x: width + 30, y: height / 2))
                }
                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                
                ForEach(Array(sortedRecords.enumerated()), id: \.element.id) { index, record in
                    let x = CGFloat(index) * barWidth + 30
                    let importVal = record.energyImport ?? 0
                    let exportVal = record.energyExport ?? 0
                    
                    if importVal > 0 {
                        let barHeight = CGFloat(importVal / maxValue) * (height / 2)
                        Rectangle()
                            .fill(Color.blue.opacity(0.7))
                            .frame(width: max(1, barWidth - 1), height: barHeight)
                            .position(x: x + barWidth / 2, y: height / 2 + barHeight / 2)
                    }
                    
                    if exportVal > 0 {
                        let barHeight = CGFloat(exportVal / maxValue) * (height / 2)
                        Rectangle()
                            .fill(Color.orange.opacity(0.7))
                            .frame(width: max(1, barWidth - 1), height: barHeight)
                            .position(x: x + barWidth / 2, y: height / 2 - barHeight / 2)
                    }
                }
                
                Text("Export ↑")
                    .font(.system(size: 8))
                    .foregroundColor(.orange)
                    .position(x: 15, y: height / 4)
                
                Text("Import ↓")
                    .font(.system(size: 8))
                    .foregroundColor(.blue)
                    .position(x: 15, y: height * 3 / 4)
            }
        }
    }
}

// MARK: - Combined Forecast Chart
struct CombinedForecastChart: View {
    let buyValues: [Double]
    let sellValues: [Double]
    let sunriseHour: Double?
    let sunsetHour: Double?
    let peakStartHour: Double?
    let peakEndHour: Double?
    let data: InverterResponse
    @Binding var selectedPeriod: Int?
    
    var body: some View {
        GeometryReader { geometry in
            let allValues = buyValues + sellValues
            let maxValue = allValues.max() ?? 1
            let minValue = allValues.min() ?? 0
            let range = maxValue - minValue
            
            let leftMargin: CGFloat = 35
            let rightMargin: CGFloat = 10
            let topMargin: CGFloat = 10
            let bottomMargin: CGFloat = 30
            
            let width = geometry.size.width - leftMargin - rightMargin
            let height = geometry.size.height - topMargin - bottomMargin
            let stepWidth = width / CGFloat(max(buyValues.count - 1, 1))
            
            ZStack(alignment: .topLeading) {
                Text("Price (¢/kWh)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .rotationEffect(.degrees(-90))
                    .offset(x: -10, y: height / 2)
                
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
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.red.opacity(0.6))
                            .offset(x: (startX + endX) / 2 - 15, y: 4)
                    }
                    
                    // Grid lines
                    ForEach(0..<5) { i in
                        let y = height * CGFloat(i) / 4
                        let value = maxValue - (range * CGFloat(i) / 4)
                        
                        Path { path in
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: width, y: y))
                        }
                        .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                        
                        Text(String(format: "%.0f", value))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .offset(x: -28, y: y - 8)
                    }
                    
                    // X-axis hour markers
                    ForEach(Array(stride(from: 0, through: 24, by: 3)), id: \.self) { hour in
                        if hour < buyValues.count / 2 {
                            let x = CGFloat(hour * 2) * stepWidth
                            
                            Path { path in
                                path.move(to: CGPoint(x: x, y: height))
                                path.addLine(to: CGPoint(x: x, y: height + 5))
                            }
                            .stroke(Color.gray.opacity(0.4), lineWidth: 1)
                            
                            if let absTime = data.absoluteTimeForPeriod(hour * 2) {
                                Text(formatTimeShort(absTime))
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                                    .offset(x: x - 12, y: height + 8)
                            }
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
                    
                    // Sell price gradient
                    Path { path in
                        for (index, value) in sellValues.enumerated() {
                            let x = CGFloat(index) * stepWidth
                            let normalizedValue = range > 0 ? (value - minValue) / range : 0.5
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
                            let normalizedValue = range > 0 ? (value - minValue) / range : 0.5
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
                            let normalizedValue = range > 0 ? (value - minValue) / range : 0.5
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
                            let normalizedValue = range > 0 ? (value - minValue) / range : 0.5
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
                        
                        let buyNormalizedValue = range > 0 ? (buyValues[period] - minValue) / range : 0.5
                        let buyY = height - (CGFloat(buyNormalizedValue) * height)
                        Circle()
                            .fill(Color.blue)
                            .frame(width: 8, height: 8)
                            .offset(x: x - 4, y: buyY - 4)
                        
                        Circle()
                            .stroke(Color.white, lineWidth: 2)
                            .frame(width: 8, height: 8)
                            .offset(x: x - 4, y: buyY - 4)
                        
                        let sellNormalizedValue = range > 0 ? (sellValues[period] - minValue) / range : 0.5
                        let sellY = height - (CGFloat(sellNormalizedValue) * height)
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                            .offset(x: x - 4, y: sellY - 4)
                        
                        Circle()
                            .stroke(Color.white, lineWidth: 2)
                            .frame(width: 8, height: 8)
                            .offset(x: x - 4, y: sellY - 4)
                    }
                    
                    // Tap overlay
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
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
