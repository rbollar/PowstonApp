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
    
    private let baseURL = "https://api.open-meteo.com/v1/forecast"
    
    func fetchWeather(latitude: Double, longitude: Double) async {
        await MainActor.run {
            isLoading = true
            error = nil
        }
        
        let urlString = "\(baseURL)?latitude=\(latitude)&longitude=\(longitude)&hourly=temperature_2m,cloudcover,direct_radiation,diffuse_radiation&timezone=Australia%2FBrisbane&forecast_days=2"
        
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
            await MainActor.run {
                self.error = error.localizedDescription
                self.isLoading = false
            }
        }
    }
    
    private func parseHourlyData(_ data: OpenMeteoResponse.HourlyData) -> [HourlyWeather] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        
        var forecast: [HourlyWeather] = []
        
        for i in 0..<data.time.count {
            // Parse time like "2025-12-27T00:00"
            let timeString = data.time[i]
            guard let date = formatter.date(from: timeString + ":00") else { continue }
            
            let weather = HourlyWeather(
                time: date,
                temperature: data.temperature_2m[i],
                cloudCover: data.cloudcover[i],
                directRadiation: data.direct_radiation[i],
                diffuseRadiation: data.diffuse_radiation[i]
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
}
