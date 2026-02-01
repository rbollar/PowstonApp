//
//  PriceForecastService.swift
//  Powston
//
//  Generates plain English price forecasts using Foundation Models
//  with deterministic fallback. Analyzes up to 24 periods (12 hours)
//  of buy/sell price data along with peak times and solar conditions.
//

import Foundation
import SwiftUI
import FoundationModels

// MARK: - Output Structure

struct PriceForecastSummary: Equatable {
    let headline: String          // "Cheap morning, peak this afternoon"
    let outlook: String           // 2-3 sentences max
    let bestBuyWindow: String?    // "6-8am (avg 3¢)" or nil
    let bestSellWindow: String?   // "5-7pm (avg 22¢)" or nil
    let advisory: String?         // Urgent action tip, or nil
    let usedAI: Bool
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
    
    private let systemInstructions = """
    You write brief energy price forecasts for battery system owners. Like a weather forecast — short and useful.
    
    YOUR JOB: Help them know when to buy and sell power today.
    
    STYLE:
    - Max 2-3 sentences for outlook
    - Lead with the most actionable insight
    - Use times like "6am", "this afternoon", not "06:00"
    - Be conversational, not technical
    
    PRICE CONTEXT (Australian cents/kWh):
    - Buy: <0¢ amazing (getting paid!), 0-5¢ cheap, 5-10¢ moderate, >10¢ expensive, >20¢ peak
    - Sell: <5¢ not worth it, 5-10¢ borderline, 10-20¢ good, >20¢ great, >50¢ spike
    
    WHAT TO MENTION (if relevant):
    - Best time to buy (cheapest window)
    - Best time to sell (highest prices)
    - Peak period warning
    - Negative price opportunity (rare, exciting!)
    - Price spikes
    
    WHAT TO SKIP:
    - Don't list every period
    - Don't use jargon like "arbitrage", "tariff", "shoulder"
    - Don't be overly precise with cents unless notable
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
              !buyForecast.isEmpty else {
            return nil
        }
        
        // Try FM first if enabled and available
        if #available(iOS 26.0, macOS 26.0, *), shouldUseAI {
            do {
                return try await forecastWithFoundationModels(data: data, buyForecast: buyForecast, sellForecast: sellForecast)
            } catch {
                // Fall through to deterministic
            }
        }
        
        // Deterministic fallback
        return buildDeterministicForecast(data: data, buyForecast: buyForecast, sellForecast: sellForecast)
    }
    
    // MARK: - Foundation Models
    
    @available(iOS 26.0, macOS 26.0, *)
    private func forecastWithFoundationModels(data: InverterResponse, buyForecast: [Double], sellForecast: [Double]) async throws -> PriceForecastSummary {
        let prompt = buildFMPrompt(data: data, buyForecast: buyForecast, sellForecast: sellForecast)
        
        let session = LanguageModelSession(instructions: systemInstructions)
        let response = try await session.respond(to: prompt, generating: GenerablePriceForecast.self)
        
        return PriceForecastSummary(
            headline: response.content.headline,
            outlook: response.content.outlook,
            bestBuyWindow: response.content.bestBuyWindow.isEmpty ? nil : response.content.bestBuyWindow,
            bestSellWindow: response.content.bestSellWindow.isEmpty ? nil : response.content.bestSellWindow,
            advisory: response.content.advisory.isEmpty ? nil : response.content.advisory,
            usedAI: true
        )
    }
    
    private func buildFMPrompt(data: InverterResponse, buyForecast: [Double], sellForecast: [Double]) -> String {
        let timeFormatter = DateFormatter()
        timeFormatter.timeStyle = .short
        timeFormatter.dateStyle = .none
        timeFormatter.timeZone = powstonTimezone()
        
        let hours = buyForecast.count / 2
        
        var prompt = """
        Write a brief price forecast for the next \(hours) hours.
        
        CURRENT: Buy \(String(format: "%.1f", data.buyPrice ?? 0))¢, Sell \(String(format: "%.1f", data.sellPrice ?? 0))¢
        Battery: \(Int(data.batterySoc ?? 0))%
        
        PRICE FORECAST:
        """
        
        // Show key periods (every 2-3 periods, plus notable ones)
        let count = min(buyForecast.count, sellForecast.count)
        for i in 0..<count {
            let buy = buyForecast[i]
            let sell = sellForecast[i]
            let isNotable = buy < 0 || buy > 20 || sell > 20
            
            if i % 3 == 0 || isNotable {
                if let time = data.absoluteTimeForPeriod(i) {
                    prompt += "\n\(timeFormatter.string(from: time)): Buy \(String(format: "%.1f", buy))¢, Sell \(String(format: "%.1f", sell))¢"
                    if buy < 0 { prompt += " ⚡NEGATIVE" }
                    if sell > 40 { prompt += " 🔥SPIKE" }
                }
            }
        }
        
        // Peak period
        if let peakStart = data.peakStartHour, let peakEnd = data.peakEndHour,
           peakStart > 0, let startDate = data.forecastStartDate {
            if let peakStartTime = Calendar.current.date(byAdding: .second, value: Int(peakStart * 3600), to: startDate),
               let peakEndTime = Calendar.current.date(byAdding: .second, value: Int(peakEnd * 3600), to: startDate) {
                prompt += "\n\nPEAK PERIOD: \(timeFormatter.string(from: peakStartTime)) - \(timeFormatter.string(from: peakEndTime))"
            }
        }
        
        // Analysis
        let avgBuy = buyForecast.reduce(0, +) / Double(buyForecast.count)
        let avgSell = sellForecast.reduce(0, +) / Double(sellForecast.count)
        let minBuy = buyForecast.min() ?? 0
        let maxSell = sellForecast.max() ?? 0
        let minBuyIdx = buyForecast.firstIndex(of: minBuy) ?? 0
        let maxSellIdx = sellForecast.firstIndex(of: maxSell) ?? 0
        
        prompt += "\n\nANALYSIS:"
        prompt += "\n- Average buy: \(String(format: "%.1f", avgBuy))¢, Average sell: \(String(format: "%.1f", avgSell))¢"
        
        if let time = data.absoluteTimeForPeriod(minBuyIdx) {
            prompt += "\n- Cheapest buy: \(timeFormatter.string(from: time)) at \(String(format: "%.1f", minBuy))¢"
        }
        if let time = data.absoluteTimeForPeriod(maxSellIdx) {
            prompt += "\n- Best sell: \(timeFormatter.string(from: time)) at \(String(format: "%.1f", maxSell))¢"
        }
        
        if buyForecast.contains(where: { $0 < 0 }) {
            prompt += "\n- ⚡ NEGATIVE PRICES available — getting paid to charge!"
        }
        
        prompt += """
        
        
        Generate a forecast:
        - headline: 5-8 words summarizing the period
        - outlook: 2-3 sentences. What matters? When to act?
        - bestBuyWindow: Brief (e.g., "6-8am (3¢)") or empty string if nothing notable
        - bestSellWindow: Brief (e.g., "5-7pm (22¢)") or empty string if nothing notable
        - advisory: One urgent tip if needed, or empty string
        
        Respond in \(userLanguage).
        """
        
        return prompt
    }
    
    // MARK: - Deterministic Fallback
    
    private func buildDeterministicForecast(data: InverterResponse, buyForecast: [Double], sellForecast: [Double]) -> PriceForecastSummary {
        let timeFormatter = DateFormatter()
        timeFormatter.timeStyle = .short
        timeFormatter.dateStyle = .none
        timeFormatter.timeZone = powstonTimezone()
        
        let avgBuy = buyForecast.reduce(0, +) / Double(buyForecast.count)
        let avgSell = sellForecast.reduce(0, +) / Double(sellForecast.count)
        let minBuy = buyForecast.min() ?? 0
        let maxSell = sellForecast.max() ?? 0
        let minBuyIdx = buyForecast.firstIndex(of: minBuy) ?? 0
        let maxSellIdx = sellForecast.firstIndex(of: maxSell) ?? 0
        let hasNegative = buyForecast.contains { $0 < 0 }
        let hasSpike = sellForecast.contains { $0 > 50 } || buyForecast.contains { $0 > 50 }
        
        // Headline
        var headline = ""
        if hasNegative {
            headline = "Negative prices — free power!"
        } else if hasSpike {
            headline = "Price spike detected"
        } else if minBuy < 5 && maxSell > 15 {
            headline = "Good spread — cheap buy, high sell"
        } else if minBuy < 5 {
            headline = "Cheap rates available"
        } else if maxSell > 20 {
            headline = "Good sell prices coming"
        } else if avgBuy > 15 {
            headline = "Expensive period ahead"
        } else {
            headline = "Moderate prices today"
        }
        
        // Outlook
        var outlookParts: [String] = []
        
        if hasNegative {
            outlookParts.append("You're getting paid to charge!")
        }
        
        if minBuy < 5, let time = data.absoluteTimeForPeriod(minBuyIdx) {
            outlookParts.append("Cheapest buy at \(timeFormatter.string(from: time)) (\(String(format: "%.1f", minBuy))¢).")
        }
        
        if maxSell > 10, let time = data.absoluteTimeForPeriod(maxSellIdx) {
            outlookParts.append("Best sell at \(timeFormatter.string(from: time)) (\(String(format: "%.1f", maxSell))¢).")
        }
        
        if let peakStart = data.peakStartHour, peakStart > 0, let startDate = data.forecastStartDate,
           let peakTime = Calendar.current.date(byAdding: .second, value: Int(peakStart * 3600), to: startDate) {
            outlookParts.append("Peak pricing starts \(timeFormatter.string(from: peakTime)).")
        }
        
        let outlook = outlookParts.isEmpty ? "Prices are relatively stable." : outlookParts.prefix(3).joined(separator: " ")
        
        // Best windows
        var bestBuyWindow: String? = nil
        var bestSellWindow: String? = nil
        
        if minBuy < avgBuy - 2, let time = data.absoluteTimeForPeriod(minBuyIdx) {
            bestBuyWindow = "\(timeFormatter.string(from: time)) (\(String(format: "%.0f", minBuy))¢)"
        }
        
        if maxSell > avgSell + 2 && maxSell > 8, let time = data.absoluteTimeForPeriod(maxSellIdx) {
            bestSellWindow = "\(timeFormatter.string(from: time)) (\(String(format: "%.0f", maxSell))¢)"
        }
        
        // Advisory
        var advisory: String? = nil
        let soc = data.batterySoc ?? 0
        
        if hasNegative && soc < 80 {
            advisory = "Charge now while prices are negative"
        } else if let peakStart = data.peakStartHour, peakStart > 0 && peakStart < 2, soc < 50 {
            advisory = "Peak starting soon — avoid buying"
        } else if hasSpike && maxSell > 40, let time = data.absoluteTimeForPeriod(maxSellIdx) {
            advisory = "Spike at \(timeFormatter.string(from: time)) — consider selling"
        }
        
        return PriceForecastSummary(
            headline: headline,
            outlook: outlook,
            bestBuyWindow: bestBuyWindow,
            bestSellWindow: bestSellWindow,
            advisory: advisory,
            usedAI: false
        )
    }
}

// MARK: - FM Generable Output

@available(iOS 26.0, macOS 26.0, *)
@Generable
struct GenerablePriceForecast {
    /// 5-8 word headline. E.g., "Cheap morning, peak this afternoon"
    let headline: String
    /// 2-3 sentence outlook. What matters? When to act?
    let outlook: String
    /// Best buy window, brief. E.g., "6-8am (3¢)" or empty string if nothing notable
    let bestBuyWindow: String
    /// Best sell window, brief. E.g., "5-7pm (22¢)" or empty string if nothing notable
    let bestSellWindow: String
    /// One urgent action tip if needed, or empty string
    let advisory: String
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
