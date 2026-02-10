//
//  WeatherService.swift
//  Powston
//

import Foundation
import Combine

// MARK: - Weather Response Model
struct OpenMeteoResponse: Codable {
    let latitude: Double
    let longitude: Double
    let timezone: String
    let hourly: HourlyData
    
    struct HourlyData: Codable {
        let time: [String]
        let temperature_2m: [Double]
        let cloudcover: [Int]
        let direct_radiation: [Double]
        let diffuse_radiation: [Double]
    }
}

struct HourlyWeather: Identifiable {
    let id = UUID()
    let time: Date
    let temperature: Double
    let cloudCover: Int
    let directRadiation: Double
    let diffuseRadiation: Double
    
    var totalRadiation: Double {
        directRadiation + diffuseRadiation
    }
    
    var solarPotential: String {
        if totalRadiation > 600 { return "Excellent" }
        if totalRadiation > 400 { return "Good" }
        if totalRadiation > 200 { return "Fair" }
        if totalRadiation > 0 { return "Low" }
        return "None"
    }
    
    var cloudIcon: String {
        if cloudCover < 20 { return "sun.max.fill" }
        if cloudCover < 50 { return "cloud.sun.fill" }
        if cloudCover < 80 { return "cloud.fill" }
        return "smoke.fill"
    }
    
    var cloudDescription: String {
        if cloudCover < 20 { return "Clear" }
        if cloudCover < 50 { return "Partly Cloudy" }
        if cloudCover < 80 { return "Cloudy" }
        return "Overcast"
    }
}

// MARK: - Weather Service
class WeatherService: ObservableObject {
    static let shared = WeatherService()
    
    @Published var hourlyForecast: [HourlyWeather] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var lastFetchTime: Date?
    
    private let forecastBaseURL = "https://api.open-meteo.com/v1/forecast"
    private let archiveBaseURL = "https://archive-api.open-meteo.com/v1/archive"
    
    // Cache for historical weather to avoid repeated fetches
    private var historicalCache: [String: [HourlyWeather]] = [:]
    
    func fetchWeather(latitude: Double, longitude: Double) async {
        await MainActor.run {
            isLoading = true
            error = nil
        }
        
        let urlString = "\(forecastBaseURL)?latitude=\(latitude)&longitude=\(longitude)&hourly=temperature_2m,cloudcover,direct_radiation,diffuse_radiation&timezone=Australia%2FBrisbane&forecast_days=2"
        
        guard let url = URL(string: urlString) else {
            await MainActor.run {
                error = "Invalid URL"
                isLoading = false
            }
            return
        }
        
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                await MainActor.run {
                    error = "Weather API error"
                    isLoading = false
                }
                return
            }
            
            let decoded = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
            let forecast = parseHourlyData(decoded.hourly)
            
            await MainActor.run {
                self.hourlyForecast = forecast
                self.lastFetchTime = Date()
                self.isLoading = false
            }
            
        } catch {
            // Don't show "cancelled" as an error - it's normal when view disappears
            if Task.isCancelled || error.localizedDescription.contains("cancelled") {
                await MainActor.run {
                    self.isLoading = false
                }
            } else {
                await MainActor.run {
                    self.error = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }
    
    /// Fetch historical weather for a specific date using Open-Meteo Archive API
    /// - Parameters:
    ///   - latitude: Site latitude
    ///   - longitude: Site longitude
    ///   - date: The historical date to fetch
    /// - Returns: Array of hourly weather data for that day, or nil on error
    func fetchHistoricalWeather(latitude: Double, longitude: Double, date: Date) async -> [HourlyWeather]? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = powstonTimezone()
        let dateString = formatter.string(from: date)
        
        // Check cache first
        let cacheKey = "\(latitude),\(longitude),\(dateString)"
        if let cached = historicalCache[cacheKey] {
            print("🌤️ Weather cache hit for \(dateString)")
            return cached
        }
        
        // Check if date is in the future or today (archive doesn't have it)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) || date > Date() {
            print("🌤️ Date \(dateString) is today or future, skipping archive fetch")
            return nil
        }
        
        // Archive API needs start_date and end_date
        let urlString = "\(archiveBaseURL)?latitude=\(latitude)&longitude=\(longitude)&start_date=\(dateString)&end_date=\(dateString)&hourly=temperature_2m,cloudcover,direct_radiation,diffuse_radiation&timezone=Australia%2FBrisbane"
        
        guard let url = URL(string: urlString) else {
            print("❌ Invalid archive weather URL")
            return nil
        }
        
        do {
            print("🌤️ Fetching historical weather for \(dateString)")
            let (data, response) = try await URLSession.shared.data(from: url)
            
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                print("❌ Archive weather API error: \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                return nil
            }
            
            let decoded = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
            let weather = parseHourlyData(decoded.hourly)
            
            // Cache the result
            historicalCache[cacheKey] = weather
            print("🌤️ Historical weather: \(weather.count) hours")
            
            return weather
            
        } catch {
            if !Task.isCancelled {
                print("❌ Archive weather error: \(error.localizedDescription)")
            }
            return nil
        }
    }
    
    private func parseHourlyData(_ data: OpenMeteoResponse.HourlyData) -> [HourlyWeather] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        formatter.timeZone = powstonTimezone()  // Open-Meteo returns Brisbane local time
        
        var forecast: [HourlyWeather] = []
        
        for i in 0..<data.time.count {
            // Parse time like "2025-12-27T00:00" as Brisbane local time
            let timeString = data.time[i]
            guard let date = formatter.date(from: timeString) else { continue }
            
            // Handle optional arrays gracefully
            let cloudCover = i < data.cloudcover.count ? data.cloudcover[i] : 0
            let directRad = i < data.direct_radiation.count ? data.direct_radiation[i] : 0
            let diffuseRad = i < data.diffuse_radiation.count ? data.diffuse_radiation[i] : 0
            
            let weather = HourlyWeather(
                time: date,
                temperature: data.temperature_2m[i],
                cloudCover: cloudCover,
                directRadiation: directRad,
                diffuseRadiation: diffuseRad
            )
            forecast.append(weather)
        }
        
        return forecast
    }
    
    // Get forecast for next N hours from now
    func nextHours(_ count: Int) -> [HourlyWeather] {
        let now = Date()
        return hourlyForecast
            .filter { $0.time > now }
            .prefix(count)
            .map { $0 }
    }
    
    // Get current hour's weather
    var currentWeather: HourlyWeather? {
        let now = Date()
        let calendar = Calendar.current
        let currentHour = calendar.component(.hour, from: now)
        
        return hourlyForecast.first { weather in
            let weatherHour = calendar.component(.hour, from: weather.time)
            let weatherDay = calendar.component(.day, from: weather.time)
            let nowDay = calendar.component(.day, from: now)
            return weatherHour == currentHour && weatherDay == nowDay
        }
    }
    
    // Get solar radiation values aligned with 30-min price forecast periods
    // Returns array of total radiation (W/m²) for each period
    func solarForecastForPricePeriods(startDate: Date, periodCount: Int) -> [Double] {
        var result: [Double] = []
        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()
        
        for period in 0..<periodCount {
            // Each period is 30 minutes
            let periodStart = calendar.date(byAdding: .minute, value: period * 30, to: startDate) ?? startDate
            let periodHour = calendar.component(.hour, from: periodStart)
            let periodDay = calendar.component(.day, from: periodStart)
            
            // Find matching hourly weather data
            if let weather = hourlyForecast.first(where: { w in
                let wHour = calendar.component(.hour, from: w.time)
                let wDay = calendar.component(.day, from: w.time)
                return wHour == periodHour && wDay == periodDay
            }) {
                result.append(weather.totalRadiation)
            } else {
                result.append(0)
            }
        }
        
        return result
    }
    
    /// Clear the historical weather cache
    func clearCache() {
        historicalCache.removeAll()
    }
}
