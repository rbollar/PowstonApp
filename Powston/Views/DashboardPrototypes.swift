//
//  DashboardPrototypes.swift
//  Powston
//
//  Three prototype concepts for the dashboard

import SwiftUI

// MARK: - Prototype 1: Energy Flow House Diagram
struct EnergyFlowHouseView: View {
    let solarKw: Double
    let homeKw: Double
    let batteryKw: Double
    let batterySoc: Double
    let gridKw: Double
    let temperature: Double?
    let weatherIcon: String
    
    var batteryStatus: String {
        if batteryKw > 0.1 { return "Charging" }
        else if batteryKw < -0.1 { return "Discharging" }
        else { return "Idle" }
    }
    
    var batteryColor: Color {
        if batteryKw > 0.1 { return .green }
        else if batteryKw < -0.1 { return .orange }
        else { return .gray }
    }
    
    var gridStatus: String {
        if gridKw > 0.1 { return "Importing" }
        else if gridKw < -0.1 { return "Exporting" }
        else { return "Idle" }
    }
    
    var gridColor: Color {
        if gridKw > 0.1 { return .blue }
        else if gridKw < -0.1 { return .green }
        else { return .gray }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Weather badge top-left
            HStack {
                HStack(spacing: 4) {
                    Image(systemName: weatherIcon)
                        .foregroundColor(.yellow)
                    if let temp = temperature {
                        Text("\(Int(temp))°C")
                            .font(.caption)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.3))
                .cornerRadius(8)
                Spacer()
            }
            .padding(.horizontal)
            
            // Main house diagram
            ZStack {
                // House shape background
                HouseShape()
                    .fill(Color.gray.opacity(0.1))
                    .frame(width: 280, height: 220)
                
                HouseShape()
                    .stroke(Color.gray.opacity(0.3), lineWidth: 2)
                    .frame(width: 280, height: 220)
                
                // Solar on roof
                VStack(spacing: 2) {
                    Image(systemName: "sun.max.fill")
                        .font(.title2)
                        .foregroundColor(.yellow)
                    Text(String(format: "%.1f kW", solarKw))
                        .font(.headline)
                        .fontWeight(.bold)
                    Text("SOLAR")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .offset(x: -50, y: -70)
                
                // Home consumption on roof
                VStack(spacing: 2) {
                    Image(systemName: "house.fill")
                        .font(.title2)
                        .foregroundColor(.purple)
                    Text(String(format: "%.1f kW", homeKw))
                        .font(.headline)
                        .fontWeight(.bold)
                    Text("HOME")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .offset(x: 50, y: -70)
                
                // Battery bottom-left
                VStack(spacing: 2) {
                    BatteryIcon(soc: batterySoc, isCharging: batteryKw > 0.1)
                        .frame(width: 30, height: 20)
                    Text(String(format: "%.1f kW · %.0f%%", abs(batteryKw), batterySoc))
                        .font(.caption)
                        .fontWeight(.semibold)
                    Text(batteryStatus)
                        .font(.caption2)
                        .foregroundColor(batteryColor)
                }
                .offset(x: -60, y: 60)
                
                // Grid bottom-right
                VStack(spacing: 2) {
                    Image(systemName: "bolt.fill")
                        .font(.title2)
                        .foregroundColor(gridColor)
                    Text(String(format: "%.1f kW", abs(gridKw)))
                        .font(.caption)
                        .fontWeight(.semibold)
                    Text("GRID")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    if gridKw != 0 {
                        Text(gridStatus)
                            .font(.caption2)
                            .foregroundColor(gridColor)
                    }
                }
                .offset(x: 60, y: 60)
                
                // Flow arrows
                if solarKw > 0.1 {
                    FlowArrow(from: CGPoint(x: -30, y: -40), to: CGPoint(x: 0, y: 20), color: .yellow)
                }
                if gridKw > 0.1 {
                    FlowArrow(from: CGPoint(x: 80, y: 40), to: CGPoint(x: 20, y: 20), color: .blue)
                }
                if gridKw < -0.1 {
                    FlowArrow(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 80, y: 40), color: .green)
                }
            }
            .frame(height: 260)
        }
        .padding()
        .background(Color.gray.opacity(0.05))
        .cornerRadius(16)
    }
}

// MARK: - Prototype 2: Block Timeline (David's concept)
struct BlockTimelineView: View {
    let blocks: [TimeBlock]
    
    struct TimeBlock: Identifiable {
        let id = UUID()
        let time: String
        let solarKw: Double
        let homeKw: Double
        let gridKw: Double
        let batterySoc: Double
        let isCurrent: Bool
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent Activity")
                    .font(.headline)
                Spacer()
                Text("5-min intervals")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            HStack(spacing: 8) {
                ForEach(blocks) { block in
                    VStack(spacing: 6) {
                        Text(block.time)
                            .font(.caption2)
                            .foregroundColor(block.isCurrent ? .primary : .secondary)
                        
                        VStack(spacing: 4) {
                            // Solar
                            HStack(spacing: 2) {
                                Image(systemName: "sun.max.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(.yellow)
                                Text(String(format: "%.1f", block.solarKw))
                                    .font(.system(size: 11, design: .monospaced))
                            }
                            
                            // Home
                            HStack(spacing: 2) {
                                Image(systemName: "house.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(.purple)
                                Text(String(format: "%.1f", block.homeKw))
                                    .font(.system(size: 11, design: .monospaced))
                            }
                            
                            // Grid
                            HStack(spacing: 2) {
                                Image(systemName: "bolt.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(block.gridKw > 0 ? .blue : .green)
                                Text(String(format: "%.1f", abs(block.gridKw)))
                                    .font(.system(size: 11, design: .monospaced))
                            }
                            
                            // Battery SOC bar
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color.gray.opacity(0.3))
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color.green)
                                        .frame(width: geo.size.width * block.batterySoc / 100)
                                }
                            }
                            .frame(height: 6)
                            
                            Text("\(Int(block.batterySoc))%")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        }
                        .padding(8)
                        .background(block.isCurrent ? Color.blue.opacity(0.1) : Color.gray.opacity(0.05))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(block.isCurrent ? Color.blue : Color.clear, lineWidth: 2)
                        )
                    }
                }
            }
            
            Text("← older | current →")
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding()
        .background(Color.gray.opacity(0.05))
        .cornerRadius(16)
    }
}

// MARK: - Prototype 3: Three Sections (Now / Next / Opportunity)
struct ThreeSectionsView: View {
    // Now
    let currentAction: String
    let batterySoc: Double
    let solarKw: Double
    let homeKw: Double
    let gridKw: Double
    
    // Next
    let solarForecast: [(hour: Int, kw: Double)]
    
    // Opportunity
    let nextSpike: (time: String, price: Double)?
    let potentialEarnings: Double?
    
    var body: some View {
        VStack(spacing: 16) {
            // SECTION 1: NOW
            VStack(alignment: .leading, spacing: 8) {
                Label("NOW", systemImage: "clock.fill")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.blue)
                
                HStack(spacing: 16) {
                    // Action badge
                    VStack(spacing: 4) {
                        Text(currentAction.uppercased())
                            .font(.title3)
                            .fontWeight(.bold)
                            .foregroundColor(actionColor(currentAction))
                        Text("Powston")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .frame(width: 80)
                    
                    Divider()
                        .frame(height: 50)
                    
                    // Current stats
                    HStack(spacing: 12) {
                        MiniStat(icon: "sun.max.fill", value: String(format: "%.1f", solarKw), unit: "kW", color: .yellow)
                        MiniStat(icon: "house.fill", value: String(format: "%.1f", homeKw), unit: "kW", color: .purple)
                        MiniStat(icon: "bolt.fill", value: String(format: "%.1f", abs(gridKw)), unit: "kW", color: gridKw > 0 ? .blue : .green)
                        
                        // Battery
                        VStack(spacing: 2) {
                            ZStack {
                                Circle()
                                    .stroke(Color.gray.opacity(0.3), lineWidth: 4)
                                    .frame(width: 36, height: 36)
                                Circle()
                                    .trim(from: 0, to: batterySoc / 100)
                                    .stroke(Color.green, lineWidth: 4)
                                    .frame(width: 36, height: 36)
                                    .rotationEffect(.degrees(-90))
                                Text("\(Int(batterySoc))")
                                    .font(.system(size: 11, weight: .bold))
                            }
                            Text("SOC")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .padding()
            .background(Color.blue.opacity(0.05))
            .cornerRadius(12)
            
            // SECTION 2: NEXT (Solar Forecast)
            VStack(alignment: .leading, spacing: 8) {
                Label("NEXT", systemImage: "sun.horizon.fill")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.orange)
                
                HStack(spacing: 4) {
                    ForEach(solarForecast.prefix(6), id: \.hour) { forecast in
                        VStack(spacing: 4) {
                            Text("\(forecast.hour):00")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                            
                            // Bar
                            let maxKw = solarForecast.map(\.kw).max() ?? 1
                            let height = CGFloat(forecast.kw / maxKw) * 40
                            
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.yellow.opacity(forecast.kw > 0 ? 0.8 : 0.2))
                                .frame(width: 24, height: max(height, 4))
                            
                            Text(String(format: "%.0f", forecast.kw))
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                
                Text("kW solar generation forecast")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color.orange.opacity(0.05))
            .cornerRadius(12)
            
            // SECTION 3: OPPORTUNITY
            VStack(alignment: .leading, spacing: 8) {
                Label("OPPORTUNITY", systemImage: "dollarsign.circle.fill")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.green)
                
                if let spike = nextSpike {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Next price spike")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text(spike.time)
                                    .font(.title2)
                                    .fontWeight(.bold)
                                Text(String(format: "%.0f¢/kWh", spike.price))
                                    .font(.subheadline)
                                    .foregroundColor(.green)
                            }
                        }
                        
                        Spacer()
                        
                        if let earnings = potentialEarnings {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("Potential")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(String(format: "+$%.2f", earnings))
                                    .font(.title3)
                                    .fontWeight(.bold)
                                    .foregroundColor(.green)
                            }
                        }
                        
                        Button(action: {}) {
                            Image(systemName: "arrow.right.circle.fill")
                                .font(.title)
                                .foregroundColor(.green)
                        }
                    }
                } else {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("No significant price spikes in the next 6 hours")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding()
            .background(Color.green.opacity(0.05))
            .cornerRadius(12)
        }
    }
    
    struct MiniStat: View {
        let icon: String
        let value: String
        let unit: String
        let color: Color
        
        var body: some View {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(color)
                Text(value)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                Text(unit)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
        }
    }
    
    func actionColor(_ action: String) -> Color {
        switch action.lowercased() {
        case "import": return .blue
        case "export": return .green
        case "auto": return .purple
        default: return .gray
        }
    }
}

// MARK: - Supporting Views

struct HouseShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        
        // Roof peak
        path.move(to: CGPoint(x: w * 0.5, y: 0))
        path.addLine(to: CGPoint(x: w, y: h * 0.35))
        path.addLine(to: CGPoint(x: w, y: h))
        path.addLine(to: CGPoint(x: 0, y: h))
        path.addLine(to: CGPoint(x: 0, y: h * 0.35))
        path.closeSubpath()
        
        return path
    }
}

struct BatteryIcon: View {
    let soc: Double
    let isCharging: Bool
    
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Battery outline
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Color.gray, lineWidth: 1.5)
                
                // Fill
                RoundedRectangle(cornerRadius: 2)
                    .fill(soc > 20 ? Color.green : Color.red)
                    .frame(width: geo.size.width * soc / 100)
                    .padding(2)
                
                // Charging bolt
                if isCharging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                
                // Terminal
                Rectangle()
                    .fill(Color.gray)
                    .frame(width: 3, height: geo.size.height * 0.4)
                    .offset(x: geo.size.width - 1)
            }
        }
    }
}

struct FlowArrow: View {
    let from: CGPoint
    let to: CGPoint
    let color: Color
    
    @State private var phase: CGFloat = 0
    
    var body: some View {
        Path { path in
            path.move(to: from)
            path.addLine(to: to)
        }
        .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [8, 4], dashPhase: phase))
        .onAppear {
            withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                phase = -12
            }
        }
    }
}

// MARK: - Preview Container
struct DashboardPrototypesPreview: View {
    @State private var selectedPrototype = 0
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Picker("Prototype", selection: $selectedPrototype) {
                        Text("House").tag(0)
                        Text("Timeline").tag(1)
                        Text("Sections").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    
                    switch selectedPrototype {
                    case 0:
                        EnergyFlowHouseView(
                            solarKw: 1.2,
                            homeKw: 1.4,
                            batteryKw: -0.2,
                            batterySoc: 84.9,
                            gridKw: 0,
                            temperature: 16,
                            weatherIcon: "cloud.sun.fill"
                        )
                        .padding(.horizontal)
                        
                    case 1:
                        BlockTimelineView(blocks: [
                            .init(time: "8:35", solarKw: 0.8, homeKw: 1.2, gridKw: 0.2, batterySoc: 78, isCurrent: false),
                            .init(time: "8:40", solarKw: 1.0, homeKw: 1.3, gridKw: 0.1, batterySoc: 80, isCurrent: false),
                            .init(time: "8:45", solarKw: 1.2, homeKw: 1.4, gridKw: 0.0, batterySoc: 83, isCurrent: false),
                            .init(time: "8:50", solarKw: 1.4, homeKw: 1.4, gridKw: -0.1, batterySoc: 85, isCurrent: true)
                        ])
                        .padding(.horizontal)
                        
                    case 2:
                        ThreeSectionsView(
                            currentAction: "auto",
                            batterySoc: 84.9,
                            solarKw: 1.2,
                            homeKw: 1.4,
                            gridKw: 0,
                            solarForecast: [
                                (9, 2.1), (10, 3.5), (11, 4.2), (12, 4.8), (13, 4.5), (14, 3.8)
                            ],
                            nextSpike: (time: "4:30 PM", price: 52),
                            potentialEarnings: 8.40
                        )
                        .padding(.horizontal)
                        
                    default:
                        EmptyView()
                    }
                    
                    Spacer()
                }
                .padding(.top)
            }
            .navigationTitle("Dashboard Prototypes")
        }
    }
}

#Preview("All Prototypes") {
    DashboardPrototypesPreview()
}

#Preview("House View") {
    EnergyFlowHouseView(
        solarKw: 1.2,
        homeKw: 1.4,
        batteryKw: -0.2,
        batterySoc: 84.9,
        gridKw: 0,
        temperature: 16,
        weatherIcon: "cloud.sun.fill"
    )
    .padding()
}

#Preview("Timeline View") {
    BlockTimelineView(blocks: [
        .init(time: "8:35", solarKw: 0.8, homeKw: 1.2, gridKw: 0.2, batterySoc: 78, isCurrent: false),
        .init(time: "8:40", solarKw: 1.0, homeKw: 1.3, gridKw: 0.1, batterySoc: 80, isCurrent: false),
        .init(time: "8:45", solarKw: 1.2, homeKw: 1.4, gridKw: 0.0, batterySoc: 83, isCurrent: false),
        .init(time: "8:50", solarKw: 1.4, homeKw: 1.4, gridKw: -0.1, batterySoc: 85, isCurrent: true)
    ])
    .padding()
}

#Preview("Three Sections") {
    ThreeSectionsView(
        currentAction: "auto",
        batterySoc: 84.9,
        solarKw: 1.2,
        homeKw: 1.4,
        gridKw: 0,
        solarForecast: [
            (9, 2.1), (10, 3.5), (11, 4.2), (12, 4.8), (13, 4.5), (14, 3.8)
        ],
        nextSpike: (time: "4:30 PM", price: 52),
        potentialEarnings: 8.40
    )
    .padding()
}
