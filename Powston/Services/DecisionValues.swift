//
//  DecisionValues.swift
//  Powston
//
//  Parsed decision context from inverter action values JSON
//  Used for Decision Efficiency analysis
//

import Foundation

// MARK: - Decision Values (Parsed from values JSON)

struct DecisionValues: Codable, Sendable {
    
    // MARK: - Forecasts (raw, undiscounted - 24 hourly values)
    
    let buyForecast: [Double]?
    let sellForecast: [Double]?
    
    // MARK: - Current Prices
    
    let buyPrice: Double?
    let sellPrice: Double?
    
    // MARK: - Battery State
    
    let batterySoc: Double?
    
    // MARK: - Decision Context (from decisions.decisions[0].values)
    
    let activeFloor: Double?
    let exportBudgetKwh: Double?
    let bestBuyThreshold: Double?
    let bestSellThreshold: Double?
    let isOptimalBuy: Bool?
    let isOptimalSell: Bool?
    let isOvernight: Bool?
    let daytimeDeficitKwh: Double?
    
    // MARK: - Config values
    
    let peakStart: Int?
    let peakEnd: Int?
    
    // MARK: - Coding Keys
    
    enum CodingKeys: String, CodingKey {
        case buyForecast = "buy_forecast"
        case sellForecast = "sell_forecast"
        case buyPrice = "buy_price"
        case sellPrice = "sell_price"
        case batterySoc = "battery_soc"
        case decisions
        case config = "CONFIG"
    }
    
    enum ConfigKeys: String, CodingKey {
        case peakStart = "PEAK_START"
        case peakEnd = "PEAK_END"
    }
    
    // MARK: - Custom Decoding
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        // Top-level forecasts (24 hourly values)
        buyForecast = try container.decodeIfPresent([Double].self, forKey: .buyForecast)
        sellForecast = try container.decodeIfPresent([Double].self, forKey: .sellForecast)
        
        // Current prices
        buyPrice = try container.decodeIfPresent(Double.self, forKey: .buyPrice)
        sellPrice = try container.decodeIfPresent(Double.self, forKey: .sellPrice)
        
        // Battery state
        batterySoc = try container.decodeIfPresent(Double.self, forKey: .batterySoc)
        
        // Parse CONFIG for peak hours
        if let configContainer = try? container.nestedContainer(keyedBy: ConfigKeys.self, forKey: .config) {
            peakStart = try configContainer.decodeIfPresent(Int.self, forKey: .peakStart)
            peakEnd = try configContainer.decodeIfPresent(Int.self, forKey: .peakEnd)
        } else {
            peakStart = nil
            peakEnd = nil
        }
        
        // Parse nested decisions for decision context
        var activeFloorTemp: Double? = nil
        var exportBudgetKwhTemp: Double? = nil
        var bestBuyThresholdTemp: Double? = nil
        var bestSellThresholdTemp: Double? = nil
        var isOptimalBuyTemp: Bool? = nil
        var isOptimalSellTemp: Bool? = nil
        var isOvernightTemp: Bool? = nil
        var daytimeDeficitKwhTemp: Double? = nil
        
        if let decisionsWrapper = try? container.decode(DecisionsWrapper.self, forKey: .decisions) {
            if let appliedDecision = decisionsWrapper.decisions.first(where: { $0.applied == true }) ?? decisionsWrapper.decisions.first {
                activeFloorTemp = appliedDecision.values?.activeFloor
                exportBudgetKwhTemp = appliedDecision.values?.exportBudgetKwh
                bestBuyThresholdTemp = appliedDecision.values?.bestBuyThreshold
                bestSellThresholdTemp = appliedDecision.values?.bestSellThreshold
                isOptimalBuyTemp = appliedDecision.values?.isOptimalBuy
                isOptimalSellTemp = appliedDecision.values?.isOptimalSell
                isOvernightTemp = appliedDecision.values?.isOvernight
                daytimeDeficitKwhTemp = appliedDecision.values?.daytimeDeficitKwh
            }
        }
        
        activeFloor = activeFloorTemp
        exportBudgetKwh = exportBudgetKwhTemp
        bestBuyThreshold = bestBuyThresholdTemp
        bestSellThreshold = bestSellThresholdTemp
        isOptimalBuy = isOptimalBuyTemp
        isOptimalSell = isOptimalSellTemp
        isOvernight = isOvernightTemp
        daytimeDeficitKwh = daytimeDeficitKwhTemp
    }
    
    // MARK: - Encoding
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(buyForecast, forKey: .buyForecast)
        try container.encodeIfPresent(sellForecast, forKey: .sellForecast)
        try container.encodeIfPresent(buyPrice, forKey: .buyPrice)
        try container.encodeIfPresent(sellPrice, forKey: .sellPrice)
        try container.encodeIfPresent(batterySoc, forKey: .batterySoc)
    }
    
    // MARK: - Direct Init (for testing/manual creation)
    
    init(
        buyForecast: [Double]? = nil,
        sellForecast: [Double]? = nil,
        buyPrice: Double? = nil,
        sellPrice: Double? = nil,
        batterySoc: Double? = nil,
        activeFloor: Double? = nil,
        exportBudgetKwh: Double? = nil,
        bestBuyThreshold: Double? = nil,
        bestSellThreshold: Double? = nil,
        isOptimalBuy: Bool? = nil,
        isOptimalSell: Bool? = nil,
        isOvernight: Bool? = nil,
        daytimeDeficitKwh: Double? = nil,
        peakStart: Int? = nil,
        peakEnd: Int? = nil
    ) {
        self.buyForecast = buyForecast
        self.sellForecast = sellForecast
        self.buyPrice = buyPrice
        self.sellPrice = sellPrice
        self.batterySoc = batterySoc
        self.activeFloor = activeFloor
        self.exportBudgetKwh = exportBudgetKwh
        self.bestBuyThreshold = bestBuyThreshold
        self.bestSellThreshold = bestSellThreshold
        self.isOptimalBuy = isOptimalBuy
        self.isOptimalSell = isOptimalSell
        self.isOvernight = isOvernight
        self.daytimeDeficitKwh = daytimeDeficitKwh
        self.peakStart = peakStart
        self.peakEnd = peakEnd
    }
    
    // MARK: - Forecast Helpers
    
    /// Get buy forecast for next N hours from current hour
    func buyForecastWindow(fromHour hour: Int, windowHours: Int = 4) -> [Double] {
        guard let forecast = buyForecast, !forecast.isEmpty else { return [] }
        let startIndex = hour % 24
        var result: [Double] = []
        for i in 0..<windowHours {
            let index = (startIndex + i) % forecast.count
            result.append(forecast[index])
        }
        return result
    }
    
    /// Get sell forecast for next N hours from current hour
    func sellForecastWindow(fromHour hour: Int, windowHours: Int = 4) -> [Double] {
        guard let forecast = sellForecast, !forecast.isEmpty else { return [] }
        let startIndex = hour % 24
        var result: [Double] = []
        for i in 0..<windowHours {
            let index = (startIndex + i) % forecast.count
            result.append(forecast[index])
        }
        return result
    }
    
    /// Best (lowest) buy price in forecast window
    func bestBuyInWindow(fromHour hour: Int, windowHours: Int = 4) -> Double? {
        let window = buyForecastWindow(fromHour: hour, windowHours: windowHours)
        return window.min()
    }
    
    /// Best (highest) sell price in forecast window
    func bestSellInWindow(fromHour hour: Int, windowHours: Int = 4) -> Double? {
        let window = sellForecastWindow(fromHour: hour, windowHours: windowHours)
        return window.max()
    }
}

// MARK: - Nested Decision Structures

private struct DecisionsWrapper: Codable {
    let decisions: [Decision]
}

private struct Decision: Codable {
    let reason: String?
    let wanted: String?
    let priority: Int?
    let applied: Bool?
    let values: DecisionNestedValues?
    let action: String?
}

private struct DecisionNestedValues: Codable {
    let activeFloor: Double?
    let exportBudgetKwh: Double?
    let bestBuyThreshold: Double?
    let bestSellThreshold: Double?
    let isOptimalBuy: Bool?
    let isOptimalSell: Bool?
    let isOvernight: Bool?
    let daytimeDeficitKwh: Double?
    
    enum CodingKeys: String, CodingKey {
        case activeFloor = "active_floor"
        case exportBudgetKwh = "export_budget_kwh"
        case bestBuyThreshold = "best_buy_threshold"
        case bestSellThreshold = "best_sell_threshold"
        case isOptimalBuy = "is_optimal_buy"
        case isOptimalSell = "is_optimal_sell"
        case isOvernight = "is_overnight"
        case daytimeDeficitKwh = "daytime_deficit_kwh"
    }
}

// MARK: - ActionRecord Extension

extension ActionRecord {
    
    /// Parse decision values from stored valuesJson
    var decisionValues: DecisionValues? {
        guard let json = valuesJson,
              let data = json.data(using: .utf8) else {
            return nil
        }
        
        do {
            return try JSONDecoder().decode(DecisionValues.self, from: data)
        } catch {
            // Silent fail - not all records will have valid decision data
            return nil
        }
    }
    
    /// Check if this record has forecast data for efficiency analysis
    var hasForecastData: Bool {
        guard let dv = decisionValues else { return false }
        return dv.buyForecast != nil && dv.sellForecast != nil
    }
}
