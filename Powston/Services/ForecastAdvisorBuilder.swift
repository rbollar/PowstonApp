//
//  ForecastAdvisorBuilder.swift
//  Powston
//
//  Builds structured input for Foundation Models to generate natural language
//  explanations of current state and upcoming opportunities (forward-looking analysis)
//

import Foundation

// MARK: - Input Structure for Foundation Models

struct ForecastAdvisorInput: Codable {
    // Current state
    let currentSoc: Double
    let currentAction: String             // "auto", "charge", "discharge", "curtail"
    let currentReason: String?            // Raw reason from controller
    
    // Current prices (in ¢/kWh)
    let currentBuyPrice: Double
    let currentSellPrice: Double
    let currentRrp: Double
    
    // System capacity
    let batteryCapacityKWh: Double
    let availableExportKwh: Double        // SOC above floor
    let availableImportKwh: Double        // Capacity minus current SOC
    let inverterCapacityKw: Double
    
    // Live generation/consumption (in kW)
    let solarKw: Double
    let houseKw: Double
    let gridKw: Double                    // Positive = import, negative = export
    let batteryKw: Double                 // Positive = discharge, negative = charge
    
    // Forecast timeline (next 6-12 hours)
    let forecastPeriods: [ForecastPeriodInfo]
    
    // Detected opportunities
    let upcomingSpikes: [PriceSpikeInfo]
    let upcomingCheapPeriods: [CheapPeriodInfo]
    let upcomingNegativePeriods: [NegativePeriodInfo]
    
    // Controller thresholds (for explanation)
    let floorSoc: Double?
    let peakStartHour: Int
    let peakEndHour: Int
    let currentHour: Int
    
    // Time context
    let isInPeakPeriod: Bool
    let minutesToPeakStart: Int?
    let minutesToPeakEnd: Int?
    let sunriseTime: String?
    let sunsetTime: String?
    
    // Alert context (if triggered by notification)
    let alertType: String?                // "highSell", "lowBuy", "negative", "spike", "peakStarting"
    let alertThreshold: Double?
    
    // Weather context (optional)
    let weatherCondition: String?
    let expectedSolarKwh: Double?         // Forecast generation for rest of day
}

struct ForecastPeriodInfo: Codable {
    let startTime: String                 // ISO8601 or "HH:mm" format
    let hoursFromNow: Double
    let forecastBuyPrice: Double
    let forecastSellPrice: Double
    let periodType: String                // "peak", "shoulder", "offpeak", "overnight"
    let isSpike: Bool
    let isCheap: Bool
    let isNegative: Bool
}

struct PriceSpikeInfo: Codable {
    let expectedTime: String
    let hoursFromNow: Double
    let forecastPrice: Double
    let estimatedDurationMinutes: Int
    let requiredSocToMaximize: Double     // What SOC you'd need
    let currentSocGap: Double             // How far short you are (negative = have excess)
    let potentialRevenueDollars: Double   // If you export at full rate
}

struct CheapPeriodInfo: Codable {
    let startTime: String
    let endTime: String
    let hoursFromNow: Double
    let forecastPrice: Double
    let chargeOpportunityKwh: Double      // How much you could import
    let estimatedCostDollars: Double      // Cost to fully charge during this window
}

struct NegativePeriodInfo: Codable {
    let expectedTime: String
    let hoursFromNow: Double
    let forecastPrice: Double             // Negative value = paid to charge
    let potentialEarningsDollars: Double  // How much you'd earn by importing
}

// MARK: - Builder

class ForecastAdvisorBuilder {
    
    private let inverterResponse: InverterResponse
    private let site: Site?
    private let floorSoc: Double?
    
    // Alert context (set if building for a notification)
    private var alertType: String?
    private var alertThreshold: Double?
    
    // Weather context
    private var weatherCondition: String?
    private var expectedSolarKwh: Double?
    
    // Thresholds for opportunity detection
    private let spikeThresholdCents: Double = 25.0     // Sell price above this = spike
    private let cheapThresholdCents: Double = 5.0      // Buy price below this = cheap
    private let ultraCheapThresholdCents: Double = 2.0 // Very cheap
    
    init(
        inverterResponse: InverterResponse,
        site: Site? = nil,
        floorSoc: Double? = nil
    ) {
        self.inverterResponse = inverterResponse
        self.site = site
        self.floorSoc = floorSoc
    }
    
    func withAlert(type: String, threshold: Double) -> Self {
        self.alertType = type
        self.alertThreshold = threshold
        return self
    }
    
    func withWeather(condition: String?, expectedSolarKwh: Double?) -> Self {
        self.weatherCondition = condition
        self.expectedSolarKwh = expectedSolarKwh
        return self
    }
    
    // MARK: - Build
    
    func build() -> ForecastAdvisorInput {
        let soc = inverterResponse.batterySoc ?? 0
        let batteryCapacityKWh = Double(inverterResponse.totalBatteryCapacity ?? site?.installedBattery ?? 0) / 1000.0
        let inverterKw = Double(site?.inverterPower ?? 20000) / 1000.0
        let floor = floorSoc ?? Double(site?.minSoc ?? 20)
        
        // Calculate available capacity
        let availableExport = max(0, (soc - floor) / 100.0 * batteryCapacityKWh)
        let availableImport = max(0, (100 - soc) / 100.0 * batteryCapacityKWh)
        
        // Current power values (convert to kW)
        let solarKw = (inverterResponse.totalSolarPower ?? 0) / 1000.0
        let houseKw = (inverterResponse.totalHousePower ?? 0) / 1000.0
        let gridKw = (inverterResponse.totalGridPower ?? 0) / 1000.0
        let batteryKw = (inverterResponse.totalBatteryPower ?? 0) / 1000.0
        
        // Peak period detection
        let peakStart = UserDefaults.standard.double(forKey: "peak_start_hour")
        let peakEnd = UserDefaults.standard.double(forKey: "peak_end_hour")
        let peakStartHour = peakStart > 0 ? Int(peakStart) : 16
        let peakEndHour = peakEnd > 0 ? Int(peakEnd) : 21
        let currentHour = inverterResponse.currentHour ?? Calendar.current.component(.hour, from: Date())
        
        let isInPeak = currentHour >= peakStartHour && currentHour < peakEndHour
        let minutesToPeakStart = isInPeak ? nil : calculateMinutesUntil(hour: peakStartHour)
        let minutesToPeakEnd = isInPeak ? calculateMinutesUntil(hour: peakEndHour) : nil
        
        // Build forecast periods
        let forecastPeriods = buildForecastPeriods(
            peakStartHour: peakStartHour,
            peakEndHour: peakEndHour
        )
        
        // Detect opportunities
        let spikes = detectSpikes(
            forecastPeriods: forecastPeriods,
            currentSoc: soc,
            floorSoc: floor,
            batteryCapacityKWh: batteryCapacityKWh,
            inverterKw: inverterKw
        )
        
        let cheapPeriods = detectCheapPeriods(
            forecastPeriods: forecastPeriods,
            currentSoc: soc,
            batteryCapacityKWh: batteryCapacityKWh,
            inverterKw: inverterKw
        )
        
        let negativePeriods = detectNegativePeriods(
            forecastPeriods: forecastPeriods,
            currentSoc: soc,
            batteryCapacityKWh: batteryCapacityKWh,
            inverterKw: inverterKw
        )
        
        return ForecastAdvisorInput(
            currentSoc: soc,
            currentAction: inverterResponse.action ?? "auto",
            currentReason: inverterResponse.reason,
            
            currentBuyPrice: inverterResponse.buyPrice ?? 0,
            currentSellPrice: inverterResponse.sellPrice ?? 0,
            currentRrp: (inverterResponse.rrp ?? 0) / 10,  // Convert to ¢/kWh
            
            batteryCapacityKWh: batteryCapacityKWh,
            availableExportKwh: availableExport,
            availableImportKwh: availableImport,
            inverterCapacityKw: inverterKw,
            
            solarKw: solarKw,
            houseKw: houseKw,
            gridKw: gridKw,
            batteryKw: batteryKw,
            
            forecastPeriods: forecastPeriods,
            
            upcomingSpikes: spikes,
            upcomingCheapPeriods: cheapPeriods,
            upcomingNegativePeriods: negativePeriods,
            
            floorSoc: floor,
            peakStartHour: peakStartHour,
            peakEndHour: peakEndHour,
            currentHour: currentHour,
            
            isInPeakPeriod: isInPeak,
            minutesToPeakStart: minutesToPeakStart,
            minutesToPeakEnd: minutesToPeakEnd,
            sunriseTime: inverterResponse.sunrise,
            sunsetTime: inverterResponse.sunset,
            
            alertType: alertType,
            alertThreshold: alertThreshold,
            
            weatherCondition: weatherCondition,
            expectedSolarKwh: expectedSolarKwh
        )
    }
    
    // MARK: - Forecast Period Building
    
    private func buildForecastPeriods(peakStartHour: Int, peakEndHour: Int) -> [ForecastPeriodInfo] {
        guard let buyForecast = inverterResponse.buyForecast,
              let sellForecast = inverterResponse.sellForecast else {
            return []
        }
        
        var periods: [ForecastPeriodInfo] = []
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = powstonTimezone()

        let calendar = Calendar.current

        // Each period is 30 minutes
        let periodCount = min(buyForecast.count, sellForecast.count, 24)  // Max 12 hours
        
        for i in 0..<periodCount {
            guard let periodStart = inverterResponse.absoluteTimeForPeriod(i) else { continue }
            
            // Skip past periods
            if periodStart < now { continue }
            
            let hoursFromNow = periodStart.timeIntervalSince(now) / 3600
            if hoursFromNow > 12 { break }  // Only show next 12 hours
            
            let buyPrice = buyForecast[i]
            let sellPrice = sellForecast[i]
            
            let hour = calendar.component(.hour, from: periodStart)
            let periodType = determinePeriodType(hour: hour, peakStart: peakStartHour, peakEnd: peakEndHour)
            
            let isSpike = sellPrice >= spikeThresholdCents
            let isCheap = buyPrice <= cheapThresholdCents
            let isNegative = buyPrice < 0
            
            periods.append(ForecastPeriodInfo(
                startTime: formatter.string(from: periodStart),
                hoursFromNow: (hoursFromNow * 10).rounded() / 10,  // Round to 1 decimal
                forecastBuyPrice: buyPrice,
                forecastSellPrice: sellPrice,
                periodType: periodType,
                isSpike: isSpike,
                isCheap: isCheap,
                isNegative: isNegative
            ))
        }
        
        return periods
    }
    
    private func determinePeriodType(hour: Int, peakStart: Int, peakEnd: Int) -> String {
        if hour >= peakStart && hour < peakEnd {
            return "peak"
        } else if hour >= 22 || hour < 6 {
            return "overnight"
        } else if hour >= 6 && hour < 10 {
            return "morning"
        } else {
            return "shoulder"
        }
    }
    
    // MARK: - Opportunity Detection
    
    private func detectSpikes(
        forecastPeriods: [ForecastPeriodInfo],
        currentSoc: Double,
        floorSoc: Double,
        batteryCapacityKWh: Double,
        inverterKw: Double
    ) -> [PriceSpikeInfo] {
        
        var spikes: [PriceSpikeInfo] = []
        var i = 0
        
        while i < forecastPeriods.count {
            let period = forecastPeriods[i]
            
            if period.isSpike {
                // Find duration (consecutive spike periods)
                var durationMinutes = 30
                var j = i + 1
                while j < forecastPeriods.count && forecastPeriods[j].isSpike {
                    durationMinutes += 30
                    j += 1
                }
                
                // Calculate what SOC we'd need to export full rate for duration
                let exportKwhNeeded = inverterKw * (Double(durationMinutes) / 60.0)
                let requiredSoc = floorSoc + (exportKwhNeeded / batteryCapacityKWh * 100)
                let socGap = requiredSoc - currentSoc
                
                // Estimate potential revenue
                let availableExport = max(0, (currentSoc - floorSoc) / 100 * batteryCapacityKWh)
                let exportableKwh = min(availableExport, exportKwhNeeded)
                let potentialRevenue = exportableKwh * period.forecastSellPrice / 100
                
                spikes.append(PriceSpikeInfo(
                    expectedTime: period.startTime,
                    hoursFromNow: period.hoursFromNow,
                    forecastPrice: period.forecastSellPrice,
                    estimatedDurationMinutes: durationMinutes,
                    requiredSocToMaximize: min(100, requiredSoc),
                    currentSocGap: socGap,
                    potentialRevenueDollars: (potentialRevenue * 100).rounded() / 100
                ))
                
                i = j  // Skip past this spike cluster
            } else {
                i += 1
            }
        }
        
        return spikes
    }
    
    private func detectCheapPeriods(
        forecastPeriods: [ForecastPeriodInfo],
        currentSoc: Double,
        batteryCapacityKWh: Double,
        inverterKw: Double
    ) -> [CheapPeriodInfo] {
        
        var cheapPeriods: [CheapPeriodInfo] = []
        var i = 0
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        
        while i < forecastPeriods.count {
            let period = forecastPeriods[i]
            
            if period.isCheap && !period.isNegative {
                let startTime = period.startTime
                var endTime = period.startTime
                var durationMinutes = 30
                var totalPrice = period.forecastBuyPrice
                
                // Find end of cheap period
                var j = i + 1
                while j < forecastPeriods.count && forecastPeriods[j].isCheap && !forecastPeriods[j].isNegative {
                    endTime = forecastPeriods[j].startTime
                    durationMinutes += 30
                    totalPrice += forecastPeriods[j].forecastBuyPrice
                    j += 1
                }
                
                let avgPrice = totalPrice / Double(j - i)
                let chargeOpportunity = min(
                    (100 - currentSoc) / 100 * batteryCapacityKWh,
                    inverterKw * (Double(durationMinutes) / 60)
                )
                let estimatedCost = chargeOpportunity * avgPrice / 100
                
                cheapPeriods.append(CheapPeriodInfo(
                    startTime: startTime,
                    endTime: endTime,
                    hoursFromNow: period.hoursFromNow,
                    forecastPrice: avgPrice,
                    chargeOpportunityKwh: (chargeOpportunity * 10).rounded() / 10,
                    estimatedCostDollars: (estimatedCost * 100).rounded() / 100
                ))
                
                i = j
            } else {
                i += 1
            }
        }
        
        return cheapPeriods
    }
    
    private func detectNegativePeriods(
        forecastPeriods: [ForecastPeriodInfo],
        currentSoc: Double,
        batteryCapacityKWh: Double,
        inverterKw: Double
    ) -> [NegativePeriodInfo] {
        
        var negativePeriods: [NegativePeriodInfo] = []
        
        for period in forecastPeriods where period.isNegative {
            // You get PAID to import during negative prices
            let importCapacity = min(
                (100 - currentSoc) / 100 * batteryCapacityKWh,
                inverterKw * 0.5  // 30 min period
            )
            let potentialEarnings = importCapacity * abs(period.forecastBuyPrice) / 100
            
            negativePeriods.append(NegativePeriodInfo(
                expectedTime: period.startTime,
                hoursFromNow: period.hoursFromNow,
                forecastPrice: period.forecastBuyPrice,
                potentialEarningsDollars: (potentialEarnings * 100).rounded() / 100
            ))
        }
        
        return negativePeriods
    }
    
    // MARK: - Helpers
    
    private func calculateMinutesUntil(hour: Int) -> Int {
        let calendar = Calendar.current
        let now = Date()
        let currentHour = calendar.component(.hour, from: now)
        let currentMinute = calendar.component(.minute, from: now)
        
        var hoursUntil = hour - currentHour
        if hoursUntil <= 0 {
            hoursUntil += 24  // Tomorrow
        }
        
        return hoursUntil * 60 - currentMinute
    }
}

// MARK: - Convenience Extensions

extension ForecastAdvisorInput {
    
    /// Whether there's an immediate opportunity (within 1 hour)
    var hasImmediateOpportunity: Bool {
        let immediateSpike = upcomingSpikes.first { $0.hoursFromNow <= 1 }
        let immediateNegative = upcomingNegativePeriods.first { $0.hoursFromNow <= 1 }
        return immediateSpike != nil || immediateNegative != nil
    }
    
    /// Best upcoming spike
    var bestUpcomingSpike: PriceSpikeInfo? {
        upcomingSpikes.max(by: { $0.forecastPrice < $1.forecastPrice })
    }
    
    /// Most urgent action hint
    var urgentActionHint: String? {
        // Negative prices are most urgent - you get PAID
        if let neg = upcomingNegativePeriods.first, neg.hoursFromNow <= 2 {
            return "Negative price at \(neg.expectedTime) — you'll be paid \(String(format: "%.1f", abs(neg.forecastPrice)))¢/kWh to charge"
        }
        
        // High spike coming and SOC is low
        if let spike = upcomingSpikes.first, spike.hoursFromNow <= 2 && spike.currentSocGap > 10 {
            return "Spike at \(spike.expectedTime) (\(String(format: "%.0f", spike.forecastPrice))¢) — need \(Int(spike.currentSocGap))% more SOC to maximize"
        }
        
        // Peak starting soon
        if let minToStart = minutesToPeakStart, minToStart <= 60 && minToStart > 0 {
            return "Peak period starts in \(minToStart) minutes — preserve battery"
        }
        
        return nil
    }
    
    /// Current action explained simply
    var simpleActionExplanation: String {
        switch currentAction.lowercased() {
        case "charge", "import":
            if currentBuyPrice < 0 {
                return "Charging — getting paid \(String(format: "%.1f", abs(currentBuyPrice)))¢/kWh"
            } else {
                return "Charging at \(String(format: "%.1f", currentBuyPrice))¢/kWh"
            }
        case "discharge", "export":
            return "Exporting at \(String(format: "%.1f", currentSellPrice))¢/kWh"
        case "curtail":
            return "Curtailing to limit grid export"
        case "auto":
            if gridKw < -0.5 {
                return "Solar exporting surplus to grid"
            } else if batteryKw < -0.5 {
                return "Solar charging battery"
            } else {
                return "Balanced — solar covering load"
            }
        default:
            return "Operating normally"
        }
    }
    
    /// Formatted current power flow
    var powerFlowSummary: String {
        var parts: [String] = []
        
        if solarKw > 0.1 {
            parts.append("☀️ \(String(format: "%.1f", solarKw))kW solar")
        }
        if houseKw > 0.1 {
            parts.append("🏠 \(String(format: "%.1f", houseKw))kW load")
        }
        if abs(gridKw) > 0.1 {
            let direction = gridKw > 0 ? "importing" : "exporting"
            parts.append("⚡ \(String(format: "%.1f", abs(gridKw)))kW \(direction)")
        }
        
        return parts.joined(separator: " • ")
    }
}
