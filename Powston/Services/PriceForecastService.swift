//
//  PriceForecastService.swift
//  Powston
//
//  Generates plain English price forecasts using Foundation Models
//  with deterministic fallback. Uses hybrid architecture: deterministic
//  engine computes all facts, AI layer provides natural language.
//

import Foundation
import SwiftUI
import FoundationModels
import Combine

// MARK: - Output Structure

struct PriceForecastSummary: Equatable {
    // AI-generated prose
    let headline: String              // "Cheap rates late morning, 5¢ spread"
    let outlook: String               // 1-2 sentences
    
    // Deterministic facts (computed, not AI-generated)
    let bestBuyTime: String?          // "11:10am"
    let bestBuyPrice: Double?         // 1.8
    let bestPeakTime: String?         // "5:45pm"
    let bestPeakPrice: Double?        // 7.2
    let spread: Double?               // 5.4
    
    // Conditional alerts (nil = hidden in UI)
    let peakWarning: String?          // "Currently in peak hours" (only during peak)
    let spikeAlert: String?           // "Hits your 25¢ alert at 5:45pm"
    let leastBadOption: String?       // "All rates >10¢ — least bad: 2am (12¢)"
    
    // AI-generated contextual (empty string from AI = nil here)
    let socAdvisory: String?          // "Battery at 28% — charge before peak"
    let weatherImpact: String?        // "Cloudy — reduced solar expected"
    
    let usedAI: Bool
}

// MARK: - Forecast Mode

enum ForecastMode: String {
    case overnight   // peak_end → sunrise
    case amPeak      // sunrise → am_peak_end (detected from price drop)
    case prePeak     // am_peak_end → peak_start
    case peak        // peak_start → peak_end
    case postPeak    // peak_end → sunset (brief transitional)
    
    var description: String {
        switch self {
        case .overnight: return "overnight"
        case .amPeak: return "AM peak"
        case .prePeak: return "pre-peak"
        case .peak: return "peak"
        case .postPeak: return "post-peak"
        }
    }
}

// MARK: - SOC Status

enum SOCStatus: String {
    case sufficient  // Will comfortably reach target
    case marginal    // Will be tight (5-15% at target)
    case critical    // Won't make it without charging
    
    var description: String {
        switch self {
        case .sufficient: return "sufficient"
        case .marginal: return "marginal"
        case .critical: return "critical"
        }
    }
}

// MARK: - Price Analysis (Deterministic)

struct PriceAnalysis {
    let mode: ForecastMode
    let currentTime: Date
    let timeOfDay: String
    
    // Time windows
    let sunrise: Date
    let sunset: Date
    let amPeakEnd: Date
    let peakStart: Date
    let peakEnd: Date
    
    // Best opportunities (excluding peak for buy)
    let bestBuyTime: Date?
    let bestBuyPrice: Double?
    
    let bestPeakPrice: Double?
    let bestPeakTime: Date?
    let spread: Double?
    let spreadQuality: String?
    
    // Fallbacks
    let leastBadBuyTime: Date?
    let leastBadBuyPrice: Double?
    let hasGoodBuyWindow: Bool
    
    // Alerts
    let spikeAlertTime: Date?
    let spikeAlertPrice: Double?
    let userSpikeThreshold: Double?
    
    // Context
    let currentBuyPrice: Double
    let currentSellPrice: Double
    let batterySoc: Double
    let socStatus: SOCStatus
    let survivalTarget: Date
    
    // Weather
    let cloudCover: Int
    let weatherDescription: String
    let weatherAffectsSolar: Bool
    
    // Negative prices
    let hasNegativePrices: Bool
    let negativePriceTime: Date?
}

// MARK: - Service

@MainActor
class PriceForecastService: ObservableObject {
    
    static let shared = PriceForecastService()
    
    @Published var isAvailable = false
    @AppStorage("enableAppleIntelligence") private var enableAppleIntelligence: Bool = true
    
    var shouldUseAI: Bool {
        enableAppleIntelligence && isAvailable
    }
    
    /// User's spike threshold from notification settings (0 = not set)
    private var userSpikeThreshold: Double {
        UserDefaults.standard.double(forKey: "sell_above_threshold")
    }
    
    private lazy var timeFormatter: DateFormatter = {
        let tf = DateFormatter()
        tf.timeStyle = .short
        tf.dateStyle = .none
        tf.timeZone = powstonTimezone()
        return tf
    }()
    
    private let systemInstructions = """
    You are a concise energy trading advisor. Generate a headline and outlook for price forecasts.

    CRITICAL RULES:
    - You are a SPEECHWRITER, not an analyst. All facts are provided to you.
    - NEVER invent times or prices. Only reference values marked with ✅ in the prompt.
    - NEVER say "buy low, sell high", "sell during peak", or any variation.
    - NEVER mention battery SOC, survival times, or battery status.
    - SPREAD = peak price MINUS buy price. Only mention if ≥10¢.
    - The OUTLOOK must add value, NOT repeat the headline.

    HEADLINE (5-10 words):
    - Focus on the buy opportunity and time
    - Only mention spread if ≥10¢
    - Examples:
      ✓ "Cheap rates late morning"
      ✓ "Negative prices at noon"
      ✓ "Great spread today — 28¢ margin" (only if spread ≥10¢)
      ✓ "Buy at 11:30am while rates are low"

    OUTLOOK (1 sentence):
    - Must ADD NEW INFO not in headline
    - If spread <10¢: mention "limited resale margin" or focus on self-use
    - If spread ≥10¢: can mention the arbitrage opportunity
    - Examples:
      ✓ "Good time to top up before peak." (simple, no repeat)
      ✓ "Limited resale margin — charge for overnight use."
      ✓ "Strong arbitrage window with 15¢ spread."

    BAD PATTERNS:
    ✗ Headline: "Buy at 11:30am for 5¢ spread" + Outlook: "Buy at 11:30am at 1.8¢ for 5¢ spread" (repeats)
    ✗ Mentioning spread when it's <10¢
    ✗ "Battery critical" or any SOC mention

    SOC/WEATHER: Always return empty string. Handled elsewhere.
    """
    
    private var userLanguage: String {
        Locale.current.language.languageCode?.identifier ?? "en"
    }
    
    init() {
        if #available(iOS 26.0, macOS 26.0, *) {
            Task {
                await checkFoundationModelsAvailability()
            }
        }
    }
    
    @available(iOS 26.0, macOS 26.0, *)
    private func checkFoundationModelsAvailability() async {
        do {
            let session = LanguageModelSession()
            _ = try await session.respond(to: "test")
            await MainActor.run {
                self.isAvailable = true
            }
        } catch {
            await MainActor.run { self.isAvailable = false }
        }
    }
    
    // MARK: - Main Entry Point
    
    func forecast(from data: InverterResponse) async -> PriceForecastSummary? {
        guard let buyForecast = data.buyForecast,
              let sellForecast = data.sellForecast,
              !buyForecast.isEmpty,
              !sellForecast.isEmpty else {
            return nil
        }
        
        // Build deterministic analysis first
        let analysis = buildAnalysis(data: data, buyForecast: buyForecast, sellForecast: sellForecast)
        
        // Try AI for prose if enabled and available
        if #available(iOS 26.0, macOS 26.0, *), shouldUseAI {
            do {
                return try await forecastWithAI(analysis: analysis)
            } catch {
                // Fall through to deterministic
            }
        }
        
        // Deterministic fallback
        return buildDeterministicSummary(analysis: analysis)
    }
    
    // MARK: - Analysis Builder
    
    private func buildAnalysis(data: InverterResponse, buyForecast: [Double], sellForecast: [Double]) -> PriceAnalysis {
        let now = Date()
        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()
        
        // Parse sunrise/sunset from data or use defaults
        let sunrise = parseSunrise(from: data, calendar: calendar, now: now)
        let sunset = parseSunset(from: data, calendar: calendar, now: now)
        
        // Get peak times from user settings
        let (peakStart, peakEnd) = parsePeakTimes(from: data, calendar: calendar, now: now)
        
        // Detect AM peak end from price data
        let amPeakEnd = detectAMPeakEnd(buyForecast: buyForecast, data: data, sunrise: sunrise)
        
        // Detect current mode
        let mode = detectMode(now: now, sunrise: sunrise, sunset: sunset, amPeakEnd: amPeakEnd, peakStart: peakStart, peakEnd: peakEnd)
        
        // Time of day string
        let timeOfDay = timeOfDayString(now: now, peakStart: peakStart, peakEnd: peakEnd, calendar: calendar)
        
        // Find best buy OUTSIDE peak
        var bestBuyTime: Date? = nil
        var bestBuyPrice: Double? = nil
        var leastBadBuyTime: Date? = nil
        var leastBadBuyPrice: Double? = nil
        var hasNegativePrices = false
        var negativePriceTime: Date? = nil
        
        for (i, price) in buyForecast.enumerated() {
            guard let time = data.absoluteTimeForPeriod(i), time > now else { continue }
            
            let isDuringPeak = time >= peakStart && time < peakEnd
            
            // Track negative prices
            if price < 0 && !hasNegativePrices {
                hasNegativePrices = true
                negativePriceTime = time
            }
            
            // Best buy must be outside peak
            if !isDuringPeak {
                if bestBuyPrice == nil || price < bestBuyPrice! {
                    bestBuyPrice = price
                    bestBuyTime = time
                }
            }
            
            // Track least bad regardless of peak (for fallback)
            if leastBadBuyPrice == nil || price < leastBadBuyPrice! {
                leastBadBuyPrice = price
                leastBadBuyTime = time
            }
        }
        
        let hasGoodBuyWindow = (bestBuyPrice ?? 100) < 10
        
        // Find best sell DURING peak
        var bestPeakPrice: Double? = nil
        var bestPeakTime: Date? = nil
        
        for (i, price) in sellForecast.enumerated() {
            guard let time = data.absoluteTimeForPeriod(i), time > now else { continue }
            
            let isDuringPeak = time >= peakStart && time < peakEnd
            if isDuringPeak {
                if bestPeakPrice == nil || price > bestPeakPrice! {
                    bestPeakPrice = price
                    bestPeakTime = time
                }
            }
        }
        
        // Calculate spread
        var spread: Double? = nil
        var spreadQualityStr: String? = nil
        if let buy = bestBuyPrice, let peak = bestPeakPrice {
            spread = peak - buy
            spreadQualityStr = spreadQuality(spread!)
        }
        
        // Check for spike alert
        let spikeThreshold = userSpikeThreshold
        var spikeAlertTime: Date? = nil
        var spikeAlertPrice: Double? = nil
        
        if spikeThreshold > 0 {
            for (i, price) in sellForecast.enumerated() {
                guard let time = data.absoluteTimeForPeriod(i), time > now else { continue }
                if price >= spikeThreshold {
                    spikeAlertTime = time
                    spikeAlertPrice = price
                    break  // First occurrence
                }
            }
        }
        
        // SOC and survival target
        let batterySoc = data.batterySoc ?? 50
        let survivalTarget: Date
        switch mode {
        case .overnight, .amPeak:
            survivalTarget = amPeakEnd
        case .prePeak:
            survivalTarget = peakStart
        case .peak, .postPeak:
            survivalTarget = peakEnd
        }
        
        let socStatus = detectSOCStatus(currentSoc: batterySoc, mode: mode, survivalTarget: survivalTarget, now: now)
        
        // Weather - average cloud cover over next 6 hours
        let weather = WeatherService.shared
        let relevantHours = min(6, weather.hourlyForecast.count)
        let cloudCover: Int
        if relevantHours > 0 {
            cloudCover = weather.hourlyForecast.prefix(relevantHours).map { $0.cloudCover }.reduce(0, +) / relevantHours
        } else {
            cloudCover = 0
        }
        let weatherDescription: String
        if cloudCover < 20 {
            weatherDescription = "Clear"
        } else if cloudCover < 50 {
            weatherDescription = "Partly cloudy"
        } else if cloudCover < 80 {
            weatherDescription = "Cloudy"
        } else {
            weatherDescription = "Overcast"
        }
        
        return PriceAnalysis(
            mode: mode,
            currentTime: now,
            timeOfDay: timeOfDay,
            sunrise: sunrise,
            sunset: sunset,
            amPeakEnd: amPeakEnd,
            peakStart: peakStart,
            peakEnd: peakEnd,
            bestBuyTime: bestBuyTime,
            bestBuyPrice: bestBuyPrice,
            bestPeakPrice: bestPeakPrice,
            bestPeakTime: bestPeakTime,
            spread: spread,
            spreadQuality: spreadQualityStr,
            leastBadBuyTime: leastBadBuyTime,
            leastBadBuyPrice: leastBadBuyPrice,
            hasGoodBuyWindow: hasGoodBuyWindow,
            spikeAlertTime: spikeAlertTime,
            spikeAlertPrice: spikeAlertPrice,
            userSpikeThreshold: spikeThreshold > 0 ? spikeThreshold : nil,
            currentBuyPrice: data.buyPrice ?? 0,
            currentSellPrice: data.sellPrice ?? 0,
            batterySoc: batterySoc,
            socStatus: socStatus,
            survivalTarget: survivalTarget,
            cloudCover: cloudCover,
            weatherDescription: weatherDescription,
            weatherAffectsSolar: cloudCover > 70,
            hasNegativePrices: hasNegativePrices,
            negativePriceTime: negativePriceTime
        )
    }
    
    // MARK: - Time Parsing Helpers
    
    private func parseSunrise(from data: InverterResponse, calendar: Calendar, now: Date) -> Date {
        if let sunriseStr = data.sunrise {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: sunriseStr) {
                return date
            }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: sunriseStr) {
                return date
            }
        }
        // Default: 5:30 AM
        return calendar.date(bySettingHour: 5, minute: 30, second: 0, of: now) ?? now
    }
    
    private func parseSunset(from data: InverterResponse, calendar: Calendar, now: Date) -> Date {
        if let sunsetStr = data.sunset {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: sunsetStr) {
                return date
            }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: sunsetStr) {
                return date
            }
        }
        // Default: 6:30 PM
        return calendar.date(bySettingHour: 18, minute: 30, second: 0, of: now) ?? now
    }
    
    private func parsePeakTimes(from data: InverterResponse, calendar: Calendar, now: Date) -> (start: Date, end: Date) {
        var peakStartDate: Date
        var peakEndDate: Date
        
        if let peakStartHour = data.peakStartHour, let peakEndHour = data.peakEndHour,
           peakStartHour > 0, let startDate = data.forecastStartDate {
            peakStartDate = startDate.addingTimeInterval(peakStartHour * 3600)
            peakEndDate = startDate.addingTimeInterval(peakEndHour * 3600)
        } else {
            // Defaults: 4pm - 9pm
            peakStartDate = calendar.date(bySettingHour: 16, minute: 0, second: 0, of: now) ?? now
            peakEndDate = calendar.date(bySettingHour: 21, minute: 0, second: 0, of: now) ?? now
        }
        
        return (peakStartDate, peakEndDate)
    }
    
    // MARK: - AM Peak Detection
    
    private func detectAMPeakEnd(buyForecast: [Double], data: InverterResponse, sunrise: Date) -> Date {
        let fourHoursAfterSunrise = sunrise.addingTimeInterval(4 * 3600)
        
        var morningPeriods: [(time: Date, price: Double)] = []
        for (i, price) in buyForecast.enumerated() {
            if let time = data.absoluteTimeForPeriod(i),
               time >= sunrise && time < fourHoursAfterSunrise {
                morningPeriods.append((time, price))
            }
        }
        
        guard !morningPeriods.isEmpty else {
            // No data — fallback to sunrise + 2 hours
            return sunrise.addingTimeInterval(2 * 3600)
        }
        
        let morningHigh = morningPeriods.map(\.price).max() ?? 0
        let dropThreshold = morningHigh * 0.7  // 30% drop
        
        for period in morningPeriods {
            // First period that drops 30% from morning high
            if period.price < dropThreshold {
                return period.time
            }
            // Or falls below 10¢
            if period.price < 10 {
                return period.time
            }
        }
        
        // No clear drop — use end of 4-hour window
        return fourHoursAfterSunrise
    }
    
    // MARK: - Mode Detection
    
    private func detectMode(now: Date, sunrise: Date, sunset: Date, amPeakEnd: Date, peakStart: Date, peakEnd: Date) -> ForecastMode {
        // During peak
        if now >= peakStart && now < peakEnd {
            return .peak
        }
        
        // After peak, before midnight or before sunrise = overnight
        if now >= peakEnd && now < sunrise.addingTimeInterval(24 * 3600) {
            // Check if we're past sunset (true overnight) or just post-peak
            if now >= sunset || now < sunrise {
                return .overnight
            }
            return .postPeak
        }
        
        // Before sunrise = overnight
        if now < sunrise {
            return .overnight
        }
        
        // Between sunrise and AM peak end
        if now >= sunrise && now < amPeakEnd {
            return .amPeak
        }
        
        // Between AM peak end and peak start
        if now >= amPeakEnd && now < peakStart {
            return .prePeak
        }
        
        return .prePeak  // Default fallback
    }
    
    // MARK: - Time of Day String
    
    private func timeOfDayString(now: Date, peakStart: Date, peakEnd: Date, calendar: Calendar) -> String {
        // Check if currently in peak
        if now >= peakStart && now < peakEnd {
            return "peak"
        }
        
        let hour = calendar.component(.hour, from: now)
        
        switch hour {
        case 5..<9:
            return "morning"
        case 9..<12:
            return "late morning"
        case 12..<16:
            return "afternoon"
        case 21..<24, 0..<5:
            return "overnight"
        default:
            return "evening"
        }
    }
    
    // MARK: - SOC Status Detection
    
    private func detectSOCStatus(currentSoc: Double, mode: ForecastMode, survivalTarget: Date, now: Date) -> SOCStatus {
        let hoursToTarget = max(0, survivalTarget.timeIntervalSince(now) / 3600)
        let estimatedDrain = hoursToTarget * 4  // ~4% per hour average
        let estimatedSocAtTarget = currentSoc - estimatedDrain
        
        if estimatedSocAtTarget > 15 {
            return .sufficient
        } else if estimatedSocAtTarget > 5 {
            return .marginal
        } else {
            return .critical
        }
    }
    
    // MARK: - Spread Quality
    
    private func spreadQuality(_ spread: Double) -> String? {
        if spread < 3 {
            return nil
        } else if spread < 10 {
            return "decent"
        } else if spread < 25 {
            return "good"
        } else {
            return "excellent"
        }
    }
    
    // MARK: - Foundation Models
    
    @available(iOS 26.0, macOS 26.0, *)
    private func forecastWithAI(analysis: PriceAnalysis) async throws -> PriceForecastSummary {
        let prompt = buildFMPrompt(analysis: analysis)
        let session = LanguageModelSession(instructions: systemInstructions)
        let response = try await session.respond(to: prompt, generating: GenerablePriceForecast.self)
        
        // Compute deterministic SOC advisory (don't trust AI)
        var socAdvisory: String? = nil
        if analysis.mode == .amPeak && (analysis.socStatus == .marginal || analysis.socStatus == .critical) {
            socAdvisory = "Battery low — limited capacity"
        } else if analysis.socStatus == .marginal {
            socAdvisory = "Battery may be tight — consider charging if good rate available."
        } else if analysis.socStatus == .critical {
            socAdvisory = "Battery low — charge before peak if possible."
        }
        
        // Compute deterministic weather (don't trust AI)
        var weatherImpact: String? = nil
        if analysis.weatherAffectsSolar {
            weatherImpact = "\(analysis.weatherDescription) — reduced solar expected."
        }
        
        return PriceForecastSummary(
            headline: response.content.headline,
            outlook: response.content.outlook,
            bestBuyTime: analysis.bestBuyTime.map { timeFormatter.string(from: $0) },
            bestBuyPrice: analysis.bestBuyPrice,
            bestPeakTime: analysis.bestPeakTime.map { timeFormatter.string(from: $0) },
            bestPeakPrice: analysis.bestPeakPrice,
            spread: analysis.spread,
            peakWarning: analysis.mode == .peak ? "Currently in peak hours" : nil,
            spikeAlert: analysis.spikeAlertTime.map { time in
                "Hits your \(String(format: "%.0f", analysis.userSpikeThreshold!))¢ alert at \(timeFormatter.string(from: time))"
            },
            leastBadOption: analysis.hasGoodBuyWindow ? nil :
                "All rates >10¢ — least bad: \(timeFormatter.string(from: analysis.leastBadBuyTime!)) (\(String(format: "%.0f", analysis.leastBadBuyPrice!))¢)",
            socAdvisory: socAdvisory,
            weatherImpact: weatherImpact,
            usedAI: true
        )
    }
    
    private func buildFMPrompt(analysis: PriceAnalysis) -> String {
        let tf = timeFormatter
        
        // Calculate actual spread from best buy/peak prices
        let actualSpread: Double? = {
            if let buy = analysis.bestBuyPrice, let peak = analysis.bestPeakPrice {
                return peak - buy
            }
            return nil
        }()
        let spreadIsGood = (actualSpread ?? 0) >= 10
        
        var prompt = """
        Energy price forecast.

        CURRENT STATUS:
        - Time: \(tf.string(from: analysis.currentTime)) (\(analysis.timeOfDay))
        - Mode: \(analysis.mode.description)

        ✅ VERIFIED FACTS:
        """
        
        // Negative prices
        if analysis.hasNegativePrices, let time = analysis.negativePriceTime {
            prompt += "\n- ⚡ NEGATIVE PRICES at \(tf.string(from: time)) — get paid to charge!"
        }
        
        // Best buy
        if analysis.hasGoodBuyWindow, let time = analysis.bestBuyTime, let price = analysis.bestBuyPrice {
            prompt += "\n- BEST BUY: \(tf.string(from: time)) at \(String(format: "%.1f", price))¢"
        } else if let time = analysis.leastBadBuyTime, let price = analysis.leastBadBuyPrice {
            prompt += "\n- NO GOOD BUY WINDOW (all >10¢)"
            prompt += "\n- LEAST BAD: \(tf.string(from: time)) at \(String(format: "%.1f", price))¢"
        }
        
        // Spread - only include if good (≥10¢)
        if let spread = actualSpread {
            if spreadIsGood {
                prompt += "\n- SPREAD: \(String(format: "%.1f", spread))¢ — GOOD, mention in headline"
            } else {
                prompt += "\n- SPREAD: \(String(format: "%.1f", spread))¢ — LOW, do NOT mention in headline. Say 'limited resale margin' in outlook."
            }
        }
        
        // Task
        prompt += """
        

        TASK:
        Generate headline and outlook. Outlook must ADD VALUE, not repeat headline.
        
        headline: 5-10 words. Focus on buy time. Only mention spread if ≥10¢.
        outlook: 1 sentence that adds NEW info. If spread <10¢, mention "limited resale margin" or focus on self-use.
        socAdvisory: empty string
        weatherImpact: empty string
        
        Respond in \(userLanguage).
        """
        
        return prompt
    }
    
    // MARK: - Deterministic Fallback
    
    private func buildDeterministicSummary(analysis: PriceAnalysis) -> PriceForecastSummary {
        let tf = timeFormatter
        
        // Calculate actual spread
        let actualSpread: Double? = {
            if let buy = analysis.bestBuyPrice, let peak = analysis.bestPeakPrice {
                return peak - buy
            }
            return nil
        }()
        let spreadIsGood = (actualSpread ?? 0) >= 10
        
        // Build headline - only mention spread if ≥10¢
        var headline: String
        if analysis.hasNegativePrices {
            headline = "Negative prices — get paid to charge"
        } else if let spread = actualSpread, spread >= 25 {
            headline = "Great spread today — \(Int(spread))¢ margin"
        } else if let spread = actualSpread, spread >= 10, let time = analysis.bestBuyTime {
            headline = "Buy at \(tf.string(from: time)) for \(Int(spread))¢ spread"
        } else if analysis.spikeAlertTime != nil, let threshold = analysis.userSpikeThreshold {
            headline = "Price spike hits your \(Int(threshold))¢ alert"
        } else if analysis.hasGoodBuyWindow, let price = analysis.bestBuyPrice, let time = analysis.bestBuyTime {
            // No spread in headline if <10¢
            if price < 3 {
                headline = "Ultra-cheap rates at \(tf.string(from: time))"
            } else if price < 8 {
                headline = "Cheap rates at \(tf.string(from: time))"
            } else {
                headline = "Buy at \(tf.string(from: time)) (\(String(format: "%.0f", price))¢)"
            }
        } else if !analysis.hasGoodBuyWindow {
            headline = "No good buy window today"
        } else {
            headline = "Moderate prices ahead"
        }
        
        // Build outlook - must add value, not repeat headline
        var outlook: String
        if analysis.hasNegativePrices, let time = analysis.negativePriceTime {
            outlook = "Free electricity at \(tf.string(from: time))."
        } else if !analysis.hasGoodBuyWindow, let time = analysis.leastBadBuyTime, let price = analysis.leastBadBuyPrice {
            outlook = "Least bad option: \(tf.string(from: time)) at \(String(format: "%.0f", price))¢."
        } else if spreadIsGood, let spread = actualSpread {
            outlook = "Good arbitrage window with \(Int(spread))¢ spread."
        } else if actualSpread != nil {
            outlook = "Limited resale margin — charge for self-use."
        } else {
            outlook = "Good time to top up before peak."
        }
        
        // SOC advisory
        var socAdvisory: String? = nil
        if analysis.mode == .amPeak && (analysis.socStatus == .marginal || analysis.socStatus == .critical) {
            socAdvisory = "Battery low — limited capacity"
        } else if analysis.socStatus == .marginal {
            socAdvisory = "Battery may be tight — consider charging if good rate available."
        } else if analysis.socStatus == .critical {
            socAdvisory = "Battery low — charge before peak if possible."
        }
        
        // Weather
        var weatherImpact: String? = nil
        if analysis.weatherAffectsSolar {
            weatherImpact = "\(analysis.weatherDescription) — reduced solar expected."
        }
        
        return PriceForecastSummary(
            headline: headline,
            outlook: outlook,
            bestBuyTime: analysis.bestBuyTime.map { tf.string(from: $0) },
            bestBuyPrice: analysis.bestBuyPrice,
            bestPeakTime: analysis.bestPeakTime.map { tf.string(from: $0) },
            bestPeakPrice: analysis.bestPeakPrice,
            spread: actualSpread,  // Use recalculated spread
            peakWarning: analysis.mode == .peak ? "Currently in peak hours" : nil,
            spikeAlert: analysis.spikeAlertTime.map { time in
                "Hits your \(String(format: "%.0f", analysis.userSpikeThreshold!))¢ alert at \(tf.string(from: time))"
            },
            leastBadOption: analysis.hasGoodBuyWindow ? nil :
                "All rates >10¢ — least bad: \(tf.string(from: analysis.leastBadBuyTime!)) (\(String(format: "%.0f", analysis.leastBadBuyPrice!))¢)",
            socAdvisory: socAdvisory,
            weatherImpact: weatherImpact,
            usedAI: false
        )
    }
}

// MARK: - FM Generable Output

@available(iOS 26.0, macOS 26.0, *)
@Generable
struct GenerablePriceForecast {
    /// 5-10 words. Focus on buy time. Only mention spread if ≥10¢. Do NOT mention battery.
    let headline: String
    
    /// 1 sentence that ADDS VALUE (not repeat headline). If spread <10¢, say "limited resale margin".
    let outlook: String
    
    /// Always empty string — handled by deterministic code.
    let socAdvisory: String
    
    /// Always empty string — handled by deterministic code.
    let weatherImpact: String
}

// MARK: - SwiftUI Environment

private struct PriceForecastServiceKey: EnvironmentKey {
    static let defaultValue = PriceForecastService.shared
}

extension EnvironmentValues {
    var priceForecastService: PriceForecastService {
        get { self[PriceForecastServiceKey.self] }
        set { self[PriceForecastServiceKey.self] = newValue }
    }
}
