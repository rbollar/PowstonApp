//
//  PowstonWidget.swift
//  PowstonWidget
//
//  Multiple widget styles for Powston energy monitoring
//

import WidgetKit
import SwiftUI

// MARK: - Timeline Entry
struct PowstonEntry: TimelineEntry {
    let date: Date
    let soc: Double
    let action: String
    let buyPrice: Double
    let sellPrice: Double
    let solarKw: Double
    let houseKw: Double
    let gridKw: Double
    let batteryKw: Double
    let buyForecast: [Double]
    let sellForecast: [Double]
    let isError: Bool
    let intervalTime: Date?
    
    var isCharging: Bool { batteryKw < 0 }
    var isExporting: Bool { gridKw < 0 }
    
    static var placeholder: PowstonEntry {
        PowstonEntry(
            date: Date(),
            soc: 75,
            action: "auto",
            buyPrice: 25.5,
            sellPrice: 8.2,
            solarKw: 4.2,
            houseKw: 1.8,
            gridKw: -2.1,
            batteryKw: -0.3,
            buyForecast: [25, 28, 32, 45, 38, 22],
            sellForecast: [8, 10, 15, 28, 20, 5],
            isError: false,
            intervalTime: Date()
        )
    }
    
    static var error: PowstonEntry {
        PowstonEntry(
            date: Date(),
            soc: 0,
            action: "---",
            buyPrice: 0,
            sellPrice: 0,
            solarKw: 0,
            houseKw: 0,
            gridKw: 0,
            batteryKw: 0,
            buyForecast: [],
            sellForecast: [],
            isError: true,
            intervalTime: nil
        )
    }
}

// MARK: - Timeline Provider
struct PowstonProvider: TimelineProvider {
    func placeholder(in context: Context) -> PowstonEntry {
        .placeholder
    }
    
    func getSnapshot(in context: Context, completion: @escaping (PowstonEntry) -> Void) {
        if context.isPreview {
            completion(.placeholder)
        } else {
            Task {
                let entry = await fetchData()
                completion(entry)
            }
        }
    }
    
    func getTimeline(in context: Context, completion: @escaping (Timeline<PowstonEntry>) -> Void) {
        Task {
            let entry = await fetchData()
            let nextUpdate = Calendar.current.date(byAdding: .minute, value: 5, to: Date())!
            let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
            completion(timeline)
        }
    }
    
    private func fetchData() async -> PowstonEntry {
        let defaults = UserDefaults(suiteName: appGroupID)
        
        let apiKey = defaults?.string(forKey: SharedSettingsKey.apiKey) ?? ""
        let baseURL = defaults?.string(forKey: SharedSettingsKey.baseURL) ?? "https://app.powston.com"
        var inverterId = defaults?.integer(forKey: SharedSettingsKey.selectedInverterId) ?? 0
        
        print("🔌 Widget fetchData:")
        print("   appGroupID: \(appGroupID)")
        print("   apiKey: \(apiKey.isEmpty ? "EMPTY" : "\(apiKey.prefix(10))...")")
        print("   baseURL: \(baseURL)")
        print("   inverterId: \(inverterId)")
        
        guard !apiKey.isEmpty else {
            return .error
        }
        
        if inverterId == 0 {
            inverterId = await fetchFirstInverterId(apiKey: apiKey, baseURL: baseURL) ?? 0
        }
        
        guard inverterId > 0 else { return .error }
        
        let urlString = "\(baseURL)/api/inverter_params/\(inverterId)"
        guard let url = URL(string: urlString) else { return .error }
        
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return .error
            }
            
            let decoder = JSONDecoder()
            let inverter = try decoder.decode(WidgetInverterResponse.self, from: data)
            
            return PowstonEntry(
                date: Date(),
                soc: inverter.totalBatterySoc,
                action: inverter.lastAction ?? inverter.action ?? "auto",
                buyPrice: inverter.buyPrice ?? 0,
                sellPrice: inverter.sellPrice ?? 0,
                solarKw: inverter.totalSolarPower / 1000,
                houseKw: inverter.displayHousePower / 1000,
                gridKw: inverter.totalGridPower / 1000,
                batteryKw: inverter.totalBatteryPower / 1000,
                buyForecast: Array((inverter.buyForecast ?? []).prefix(6)),
                sellForecast: Array((inverter.sellForecast ?? []).prefix(6)),
                isError: false,
                intervalTime: inverter.intervalDate
            )
        } catch {
            return .error
        }
    }
    
    private func fetchFirstInverterId(apiKey: String, baseURL: String) async -> Int? {
        guard let url = URL(string: "\(baseURL)/api/inverters") else { return nil }
        
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            
            let decoder = JSONDecoder()
            let inverters = try decoder.decode([WidgetInverter].self, from: data)
            return inverters.first?.id
        } catch {
            return nil
        }
    }
}

// MARK: - Response Models
struct WidgetInverterResponse: Codable {
    let batterySoc: Double?
    let action: String?
    let lastAction: String?
    let buyPrice: Double?
    let sellPrice: Double?
    let solarPower: Double?
    let housePower: Double?
    let gridPower: Double?
    let batteryPower: Double?
    let buyForecast: [Double]?
    let sellForecast: [Double]?
    let intervalTime: String?
    let runtimeParams: WidgetRuntimeParams?
    
    enum CodingKeys: String, CodingKey {
        case batterySoc = "battery_soc"
        case action
        case lastAction = "last_action"
        case buyPrice = "buy_price"
        case sellPrice = "sell_price"
        case solarPower = "solar_power"
        case housePower = "house_power"
        case gridPower = "grid_power"
        case batteryPower = "battery_power"
        case buyForecast = "buy_forecast"
        case sellForecast = "sell_forecast"
        case intervalTime = "interval_time"
        case runtimeParams = "runtime_params"
    }
    
    // Parse interval time to Date
    var intervalDate: Date? {
        guard let intervalTime = intervalTime else { return nil }
        
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        
        if let date = formatter.date(from: intervalTime) {
            return date
        }
        
        // Try without fractional seconds
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: intervalTime)
    }
    
    // Calculate totals from runtime_params if available
    var totalSolarPower: Double {
        guard let params = runtimeParams else { return solarPower ?? 0 }
        var total = params.mainInverter.solarPower ?? 0
        for (_, inv) in params.additionalInverters {
            total += inv.solarPower ?? 0
        }
        return total
    }
    
    var totalHousePower: Double {
        guard let params = runtimeParams else { return housePower ?? 0 }
        var total = params.mainInverter.housePower ?? 0
        for (_, inv) in params.additionalInverters {
            total += inv.housePower ?? 0
        }
        return total
    }
    
    var totalGridPower: Double {
        guard let params = runtimeParams else { return gridPower ?? 0 }
        var total = params.mainInverter.gridPower ?? 0
        for (_, inv) in params.additionalInverters {
            total += inv.gridPower ?? 0
        }
        return total
    }
    
    var totalBatteryPower: Double {
        guard let params = runtimeParams else { return batteryPower ?? 0 }
        var total = params.mainInverter.batteryPower ?? 0
        for (_, inv) in params.additionalInverters {
            total += inv.batteryPower ?? 0
        }
        return total
    }
    
    var totalBatterySoc: Double {
        guard let params = runtimeParams else { return batterySoc ?? 0 }
        var totalCapacity = 0.0
        var totalEnergy = 0.0
        
        if let cap = params.mainInverter.batteryCapacity, let soc = params.mainInverter.batterySoc {
            totalCapacity += Double(cap)
            totalEnergy += Double(cap) * soc / 100
        }
        for (_, inv) in params.additionalInverters {
            if let cap = inv.batteryCapacity, let soc = inv.batterySoc {
                totalCapacity += Double(cap)
                totalEnergy += Double(cap) * soc / 100
            }
        }
        
        return totalCapacity > 0 ? (totalEnergy / totalCapacity) * 100 : (batterySoc ?? 0)
    }
    
    // Energy balance calculation
    var energyImbalance: Double {
        totalSolarPower + totalBatteryPower - totalGridPower - totalHousePower
    }
    
    var hasSignificantImbalance: Bool {
        abs(energyImbalance) > 1000
    }
    
    // Display house power: adjusted for small imbalances
    var displayHousePower: Double {
        if hasSignificantImbalance {
            return totalHousePower
        } else {
            return totalHousePower - energyImbalance
        }
    }
}

// Dynamic coding key for parsing runtime_params
struct WidgetDynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

struct WidgetRuntimeParams: Codable {
    let mainInverter: WidgetInverterData
    var additionalInverters: [String: WidgetInverterData] = [:]
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: WidgetDynamicKey.self)
        
        // Decode main_inverter fields directly (they're at the top level of runtime_params)
        mainInverter = WidgetInverterData(
            solarPower: try? container.decode(Double.self, forKey: WidgetDynamicKey(stringValue: "solar_power")!),
            housePower: try? container.decode(Double.self, forKey: WidgetDynamicKey(stringValue: "house_power")!),
            gridPower: try? container.decode(Double.self, forKey: WidgetDynamicKey(stringValue: "grid_power")!),
            batteryPower: try? container.decode(Double.self, forKey: WidgetDynamicKey(stringValue: "battery_power")!),
            batterySoc: try? container.decode(Double.self, forKey: WidgetDynamicKey(stringValue: "battery_soc")!),
            batteryCapacity: try? container.decode(Int.self, forKey: WidgetDynamicKey(stringValue: "battery_capacity")!)
        )
        
        // Look for nested inverter objects (keyed by serial number)
        var nested: [String: WidgetInverterData] = [:]
        for key in container.allKeys {
            let keyString = key.stringValue
            // Serial numbers typically start with a letter and contain digits
            if keyString.count > 8,
               keyString.first?.isLetter == true,
               keyString.contains(where: { $0.isNumber }) {
                if let nestedData = try? container.decode(WidgetInverterData.self, forKey: key) {
                    nested[keyString] = nestedData
                }
            }
        }
        additionalInverters = nested
    }
    
    func encode(to encoder: Encoder) throws {
        // Not needed for widget
    }
}

struct WidgetInverterData: Codable {
    let solarPower: Double?
    let housePower: Double?
    let gridPower: Double?
    let batteryPower: Double?
    let batterySoc: Double?
    let batteryCapacity: Int?
    
    enum CodingKeys: String, CodingKey {
        case solarPower = "solar_power"
        case housePower = "house_power"
        case gridPower = "grid_power"
        case batteryPower = "battery_power"
        case batterySoc = "battery_soc"
        case batteryCapacity = "battery_capacity"
    }
}

struct WidgetInverter: Codable {
    let id: Int
}

// MARK: - Timezone Helper for Widget

/// Get timezone from shared defaults, falling back to state mapping then Brisbane
func widgetTimezone() -> TimeZone {
    let defaults = UserDefaults(suiteName: appGroupID)
    
    // First try explicit timezone from site
    if let tzIdentifier = defaults?.string(forKey: "site_timezone"),
       !tzIdentifier.isEmpty,
       let tz = TimeZone(identifier: tzIdentifier) {
        return tz
    }
    
    // Fall back to state-based mapping
    if let state = defaults?.string(forKey: "site_state") {
        switch state.uppercased() {
        case "NSW", "ACT":
            return TimeZone(identifier: "Australia/Sydney") ?? .current
        case "VIC":
            return TimeZone(identifier: "Australia/Melbourne") ?? .current
        case "QLD":
            return TimeZone(identifier: "Australia/Brisbane") ?? .current
        case "SA":
            return TimeZone(identifier: "Australia/Adelaide") ?? .current
        case "WA":
            return TimeZone(identifier: "Australia/Perth") ?? .current
        case "TAS":
            return TimeZone(identifier: "Australia/Hobart") ?? .current
        case "NT":
            return TimeZone(identifier: "Australia/Darwin") ?? .current
        default:
            break
        }
    }
    
    // Default to Brisbane (NEM time)
    return TimeZone(identifier: "Australia/Brisbane") ?? .current
}

// MARK: - Shared Helpers
struct WidgetHelpers {
    static func socColor(_ soc: Double) -> Color {
        if soc >= 80 { return .green }
        if soc >= 50 { return .yellow }
        if soc >= 20 { return .orange }
        return .red
    }
    
    static func actionColor(_ action: String) -> Color {
        switch action.lowercased() {
        case "charge", "import": return .green
        case "discharge", "export": return .orange
        case "auto": return .blue
        default: return .secondary
        }
    }
    
    /// Color for price based on magnitude
    static func priceColor(_ cents: Double, isBuy: Bool = true) -> Color {
        if cents < 0 { return .green }        // Negative = they pay you
        if cents >= 500 { return .red }       // ≥$5 = extreme
        if cents >= 100 { return .orange }    // ≥$1 = elevated
        if isBuy && cents > 30 { return .red }  // Buy > 30¢ = expensive
        if !isBuy && cents > 30 { return .green } // Sell > 30¢ = good
        return isBuy ? .blue : .green
    }
    
    /// Format price - shows dollars if >= 100¢
    static func formatPrice(_ cents: Double) -> String {
        if abs(cents) >= 100 {
            return String(format: "$%.2f", cents / 100)
        } else {
            return String(format: "%.1f¢", cents)
        }
    }
    
    /// Compact format for tight spaces - shorter dollar format
    static func formatPriceCompact(_ cents: Double) -> String {
        if abs(cents) >= 1000 {
            // $10+ -> "$12"
            return String(format: "$%.0f", cents / 100)
        } else if abs(cents) >= 100 {
            // $1-$9.99 -> "$1.23"
            return String(format: "$%.2f", cents / 100)
        } else {
            return String(format: "%.1f¢", cents)
        }
    }
    
    /// Whether price is extreme enough to warrant special attention
    static func isExtremePrice(_ cents: Double) -> Bool {
        abs(cents) >= 100
    }
    
    /// Ultra-compact format for accessory widgets - integers only
    static func formatPriceAccessory(_ cents: Double) -> String {
        if abs(cents) >= 100 {
            // $1+ -> "$1" or "$12"
            return String(format: "$%.0f", cents / 100)
        } else {
            // Under $1 -> "25¢"
            return String(format: "%.0f¢", cents)
        }
    }
    
    static func displayAction(_ action: String) -> String {
        let lower = action.lowercased()
        if lower.contains("export") { return "Export" }
        if lower.contains("import") { return "Import" }
        if lower.contains("discharge") { return "Discharge" }
        if lower.contains("charge") { return "Charge" }
        if lower.contains("auto") { return "Auto" }
        return action.capitalized
    }
    
    /// Format AEMO interval time
    static func formatIntervalTime(_ date: Date?) -> String {
        guard let date = date else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        formatter.timeZone = widgetTimezone()  // CHANGED
        return formatter.string(from: date)
    }
}

// MARK: - Error View
struct WidgetErrorView: View {
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundColor(.orange)
            Text("Configure in app")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// ============================================================================
// MARK: - WIDGET 1: Battery Status (SOC Ring + Action)
// ============================================================================

struct BatteryStatusWidgetView: View {
    var entry: PowstonEntry
    @Environment(\.widgetFamily) var family
    
    var body: some View {
        if entry.isError {
            WidgetErrorView()
        } else {
            switch family {
            case .systemSmall:
                smallView
            case .systemMedium:
                mediumView
            default:
                smallView
            }
        }
    }
    
    var smallView: some View {
        VStack(spacing: 6) {
            // SOC Ring with action inside
            ZStack {
                Circle()
                    .stroke(Color.gray.opacity(0.3), lineWidth: 8)
                
                Circle()
                    .trim(from: 0, to: CGFloat(entry.soc) / 100)
                    .stroke(WidgetHelpers.socColor(entry.soc), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                
                VStack(spacing: 2) {
                    Text("\(Int(entry.soc))%")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                    Text(WidgetHelpers.displayAction(entry.action).uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(WidgetHelpers.actionColor(entry.action))
                }
            }
            .frame(width: 80, height: 80)
            
            // Charging/Discharging status
            HStack(spacing: 4) {
                Image(systemName: entry.isCharging ? "bolt.fill" : "arrow.up.circle.fill")
                    .font(.caption2)
                Text(entry.isCharging ? "Charging" : "Discharging")
                    .font(.caption2)
            }
            .foregroundColor(entry.isCharging ? .green : .orange)
            
            // AEMO interval time
            if let intervalTime = entry.intervalTime {
                Text(WidgetHelpers.formatIntervalTime(intervalTime))
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
        }
        .padding(8)
    }
    
    var mediumView: some View {
        HStack(spacing: 20) {
            // SOC Ring
            ZStack {
                Circle()
                    .stroke(Color.gray.opacity(0.3), lineWidth: 10)
                
                Circle()
                    .trim(from: 0, to: CGFloat(entry.soc) / 100)
                    .stroke(WidgetHelpers.socColor(entry.soc), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                
                VStack(spacing: 2) {
                    Text("\(Int(entry.soc))%")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    Text("SOC")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 100, height: 100)
            
            VStack(alignment: .leading, spacing: 8) {
                // Action badge
                Text(WidgetHelpers.displayAction(entry.action).uppercased())
                    .font(.headline)
                    .foregroundColor(WidgetHelpers.actionColor(entry.action))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(WidgetHelpers.actionColor(entry.action).opacity(0.15))
                    .cornerRadius(8)
                
                // Battery power
                HStack(spacing: 4) {
                    Image(systemName: entry.isCharging ? "bolt.fill" : "arrow.up.circle.fill")
                    Text(String(format: "%.1f kW", abs(entry.batteryKw)))
                        .font(.subheadline)
                }
                .foregroundColor(entry.isCharging ? .green : .orange)
                
                // Prices with smart formatting
                HStack(spacing: 12) {
                    Label(WidgetHelpers.formatPrice(entry.buyPrice), systemImage: "arrow.down.circle")
                        .font(.caption)
                        .foregroundColor(WidgetHelpers.priceColor(entry.buyPrice, isBuy: true))
                    Label(WidgetHelpers.formatPrice(entry.sellPrice), systemImage: "arrow.up.circle")
                        .font(.caption)
                        .foregroundColor(WidgetHelpers.priceColor(entry.sellPrice, isBuy: false))
                }
                
                // AEMO interval time
                if let intervalTime = entry.intervalTime {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.caption2)
                        Text(WidgetHelpers.formatIntervalTime(intervalTime))
                            .font(.caption2)
                    }
                    .foregroundColor(.secondary)
                }
            }
            
            Spacer()
        }
        .padding()
    }
}

struct BatteryStatusWidget: Widget {
    let kind: String = "BatteryStatusWidget"
    
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PowstonProvider()) { entry in
            BatteryStatusWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Battery Status")
        .description("SOC level and current action")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// ============================================================================
// MARK: - WIDGET 2: Power Flows
// ============================================================================

struct PowerFlowsWidgetView: View {
    var entry: PowstonEntry
    @Environment(\.widgetFamily) var family
    
    var body: some View {
        if entry.isError {
            WidgetErrorView()
        } else {
            switch family {
            case .systemSmall:
                smallView
            case .systemMedium:
                mediumView
            default:
                smallView
            }
        }
    }
    
    var smallView: some View {
        VStack(spacing: 6) {
            // 2x2 grid
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                PowerFlowCell(icon: "sun.max.fill", value: entry.solarKw, label: "Solar", color: .yellow)
                PowerFlowCell(icon: "house.fill", value: entry.houseKw, label: "Home", color: .purple)
                PowerFlowCell(icon: "bolt.fill", value: abs(entry.gridKw), label: entry.isExporting ? "Export" : "Import", color: entry.isExporting ? .green : .blue)
                PowerFlowCell(icon: "battery.100.bolt", value: abs(entry.batteryKw), label: entry.isCharging ? "Charge" : "Discharge", color: entry.isCharging ? .green : .orange)
            }
            
            // AEMO interval time
            if let intervalTime = entry.intervalTime {
                Text(WidgetHelpers.formatIntervalTime(intervalTime))
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
        }
        .padding(10)
    }
    
    var mediumView: some View {
        VStack(spacing: 4) {
            HStack(spacing: 16) {
                PowerFlowCellLarge(icon: "sun.max.fill", value: entry.solarKw, label: "Solar", color: .yellow)
                PowerFlowCellLarge(icon: "house.fill", value: entry.houseKw, label: "Home", color: .purple)
                PowerFlowCellLarge(icon: "bolt.fill", value: abs(entry.gridKw), label: entry.isExporting ? "Export" : "Import", color: entry.isExporting ? .green : .blue)
                PowerFlowCellLarge(icon: "battery.100.bolt", value: abs(entry.batteryKw), label: entry.isCharging ? "Charge" : "Dchg", color: entry.isCharging ? .green : .orange)
            }
            
            // AEMO interval time
            if let intervalTime = entry.intervalTime {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.caption2)
                    Text(WidgetHelpers.formatIntervalTime(intervalTime))
                        .font(.caption2)
                }
                .foregroundColor(.secondary)
            }
        }
        .padding()
    }
}

struct PowerFlowCell: View {
    let icon: String
    let value: Double
    let label: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundColor(color)
            Text(String(format: "%.1f", value))
                .font(.system(size: 14, weight: .semibold, design: .rounded))
            Text(label)
                .font(.system(size: 8))
                .foregroundColor(.secondary)
        }
    }
}

struct PowerFlowCellLarge: View {
    let icon: String
    let value: Double
    let label: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(color.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .foregroundColor(color)
            }
            Text(String(format: "%.1f", value))
                .font(.system(size: 18, weight: .semibold, design: .rounded))
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct PowerFlowsWidget: Widget {
    let kind: String = "PowerFlowsWidget"
    
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PowstonProvider()) { entry in
            PowerFlowsWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Power Flows")
        .description("Solar, home, grid, and battery power")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// ============================================================================
// MARK: - WIDGET 3: Prices
// ============================================================================

struct PricesWidgetView: View {
    var entry: PowstonEntry
    @Environment(\.widgetFamily) var family
    
    var body: some View {
        if entry.isError {
            WidgetErrorView()
        } else {
            switch family {
            case .systemSmall:
                smallView
            case .systemMedium:
                mediumView
            default:
                smallView
            }
        }
    }
    
    var smallView: some View {
        VStack(spacing: 8) {
            // Current prices - adaptive sizing
            HStack(spacing: 12) {
                VStack(spacing: 2) {
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.blue)
                        Text("Buy")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                    Text(WidgetHelpers.formatPriceCompact(entry.buyPrice))
                        .font(.system(size: WidgetHelpers.isExtremePrice(entry.buyPrice) ? 14 : 16, weight: .semibold, design: .rounded))
                        .foregroundColor(WidgetHelpers.priceColor(entry.buyPrice, isBuy: true))
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                }
                
                VStack(spacing: 2) {
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.green)
                        Text("Sell")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                    Text(WidgetHelpers.formatPriceCompact(entry.sellPrice))
                        .font(.system(size: WidgetHelpers.isExtremePrice(entry.sellPrice) ? 14 : 16, weight: .semibold, design: .rounded))
                        .foregroundColor(WidgetHelpers.priceColor(entry.sellPrice, isBuy: false))
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                }
            }
            
            // Mini forecast chart
            if !entry.buyForecast.isEmpty {
                VStack(spacing: 2) {
                    Text("Next 6 Hours")
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                    MiniPriceChart(buyForecast: entry.buyForecast, sellForecast: entry.sellForecast)
                        .frame(height: 35)
                }
            }
            
            // AEMO interval time
            if let intervalTime = entry.intervalTime {
                Text(WidgetHelpers.formatIntervalTime(intervalTime))
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
        }
        .padding(10)
    }
    
    var mediumView: some View {
        HStack(spacing: 16) {
            // Current prices
            VStack(spacing: 8) {
                HStack(spacing: 16) {
                    VStack(spacing: 4) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down.circle.fill")
                                .foregroundColor(.blue)
                            Text("Buy")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Text(WidgetHelpers.formatPrice(entry.buyPrice))
                            .font(.system(size: WidgetHelpers.isExtremePrice(entry.buyPrice) ? 20 : 24, weight: .bold, design: .rounded))
                            .foregroundColor(WidgetHelpers.priceColor(entry.buyPrice, isBuy: true))
                            .minimumScaleFactor(0.7)
                            .lineLimit(1)
                    }
                    
                    VStack(spacing: 4) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.circle.fill")
                                .foregroundColor(.green)
                            Text("Sell")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Text(WidgetHelpers.formatPrice(entry.sellPrice))
                            .font(.system(size: WidgetHelpers.isExtremePrice(entry.sellPrice) ? 20 : 24, weight: .bold, design: .rounded))
                            .foregroundColor(WidgetHelpers.priceColor(entry.sellPrice, isBuy: false))
                            .minimumScaleFactor(0.7)
                            .lineLimit(1)
                    }
                }
                
                // AEMO interval time
                if let intervalTime = entry.intervalTime {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.caption2)
                        Text(WidgetHelpers.formatIntervalTime(intervalTime))
                            .font(.caption2)
                    }
                    .foregroundColor(.secondary)
                }
            }
            
            // Forecast chart
            if !entry.buyForecast.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Next 6 Hours")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    MiniPriceChart(buyForecast: entry.buyForecast, sellForecast: entry.sellForecast)
                        .frame(height: 50)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding()
    }
}

struct MiniPriceChart: View {
    let buyForecast: [Double]
    let sellForecast: [Double]
    
    var body: some View {
        GeometryReader { geo in
            let allPrices = buyForecast + sellForecast
            let minPrice = allPrices.min() ?? 0
            let maxPrice = allPrices.max() ?? 100
            let range = max(maxPrice - minPrice, 1)
            
            ZStack {
                // Buy line (blue)
                Path { path in
                    guard !buyForecast.isEmpty else { return }
                    let stepX = geo.size.width / CGFloat(buyForecast.count - 1)
                    
                    for (index, price) in buyForecast.enumerated() {
                        let x = CGFloat(index) * stepX
                        let y = geo.size.height - (CGFloat(price - minPrice) / CGFloat(range)) * geo.size.height
                        
                        if index == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                }
                .stroke(Color.blue, lineWidth: 2)
                
                // Sell line (green)
                Path { path in
                    guard !sellForecast.isEmpty else { return }
                    let stepX = geo.size.width / CGFloat(sellForecast.count - 1)
                    
                    for (index, price) in sellForecast.enumerated() {
                        let x = CGFloat(index) * stepX
                        let y = geo.size.height - (CGFloat(price - minPrice) / CGFloat(range)) * geo.size.height
                        
                        if index == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                }
                .stroke(Color.green, lineWidth: 2)
            }
        }
    }
}

struct PricesWidget: Widget {
    let kind: String = "PricesWidget"
    
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PowstonProvider()) { entry in
            PricesWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Energy Prices")
        .description("Current buy/sell prices and forecast")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// ============================================================================
// MARK: - WIDGET 4: Quick Glance (Accessory/Lock Screen)
// ============================================================================

struct QuickGlanceWidgetView: View {
    var entry: PowstonEntry
    @Environment(\.widgetFamily) var family
    
    var body: some View {
        if entry.isError {
            Image(systemName: "exclamationmark.triangle")
        } else {
            switch family {
            case .accessoryCircular:
                circularView
            case .accessoryRectangular:
                rectangularView
            case .accessoryInline:
                inlineView
            default:
                circularView
            }
        }
    }
    
    var circularView: some View {
        Gauge(value: entry.soc, in: 0...100) {
            Text("SOC")
        } currentValueLabel: {
            Text("\(Int(entry.soc))")
                .font(.system(size: 14, weight: .bold))
        }
        .gaugeStyle(.accessoryCircular)
    }
    
    var rectangularView: some View {
        HStack(spacing: 8) {
            // SOC
            Gauge(value: entry.soc, in: 0...100) {
                Text("")
            } currentValueLabel: {
                Text("\(Int(entry.soc))%")
                    .font(.caption2)
            }
            .gaugeStyle(.accessoryCircular)
            .scaleEffect(0.8)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(WidgetHelpers.displayAction(entry.action).uppercased())
                    .font(.caption.bold())
                HStack(spacing: 8) {
                    Text("B:\(WidgetHelpers.formatPriceAccessory(entry.buyPrice))")
                        .font(.caption2)
                    Text("S:\(WidgetHelpers.formatPriceAccessory(entry.sellPrice))")
                        .font(.caption2)
                }
            }
        }
    }
    
    var inlineView: some View {
        Text("⚡ \(Int(entry.soc))% | \(WidgetHelpers.displayAction(entry.action))")
    }
}

struct QuickGlanceWidget: Widget {
    let kind: String = "QuickGlanceWidget"
    
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PowstonProvider()) { entry in
            QuickGlanceWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Quick Glance")
        .description("SOC and action for lock screen")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

// ============================================================================
// MARK: - Widget Bundle
// ============================================================================

@main
struct PowstonWidgetBundle: WidgetBundle {
    var body: some Widget {
        BatteryStatusWidget()
        PowerFlowsWidget()
        PricesWidget()
        QuickGlanceWidget()
        PowstonLiveActivity()
    }
}
