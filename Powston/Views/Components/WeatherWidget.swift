//
//  WeatherWidget.swift
//  Powston
//

import SwiftUI

struct WeatherWidget: View {
    @StateObject private var weather = WeatherService.shared
    let latitude: Double
    let longitude: Double
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: "cloud.sun.fill")
                    .foregroundColor(.orange)
                Text("Solar Forecast")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                if weather.isLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                }
            }
            
            if let error = weather.error {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else if weather.hourlyForecast.isEmpty {
                Text("Loading weather...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                // Current conditions
                if let current = weather.currentWeather {
                    HStack(spacing: 16) {
                        // Temperature
                        HStack(spacing: 4) {
                            Image(systemName: "thermometer")
                                .foregroundColor(.red)
                                .font(.caption)
                            Text("\(Int(current.temperature))°")
                                .font(.subheadline)
                                .fontWeight(.medium)
                        }
                        
                        // Cloud cover
                        HStack(spacing: 4) {
                            Image(systemName: current.cloudIcon)
                                .foregroundColor(.gray)
                                .font(.caption)
                            Text("\(current.cloudCover)%")
                                .font(.subheadline)
                        }
                        
                        // Solar radiation
                        HStack(spacing: 4) {
                            Image(systemName: "sun.max.fill")
                                .foregroundColor(.yellow)
                                .font(.caption)
                            Text("\(Int(current.totalRadiation)) W/m²")
                                .font(.subheadline)
                        }
                    }
                    .padding(.bottom, 4)
                }
                
                // Next 6 hours forecast
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(weather.nextHours(6)) { hour in
                            WeatherHourCell(weather: hour)
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(12)
        .task {
            if weather.hourlyForecast.isEmpty {
                await weather.fetchWeather(latitude: latitude, longitude: longitude)
            }
        }
    }
}

struct WeatherHourCell: View {
    let weather: HourlyWeather
    
    var body: some View {
        VStack(spacing: 6) {
            // Time
            Text(formatHour(weather.time))
                .font(.caption2)
                .foregroundColor(.secondary)
            
            // Cloud icon
            Image(systemName: weather.cloudIcon)
                .font(.title3)
                .foregroundColor(iconColor)
            
            // Radiation indicator (simplified)
            RadiationBar(value: weather.totalRadiation, max: 800)
                .frame(width: 30, height: 4)
            
            // Temperature
            Text("\(Int(weather.temperature))°")
                .font(.caption)
                .fontWeight(.medium)
        }
        .frame(width: 50)
    }
    
    var iconColor: Color {
        if weather.cloudCover < 20 { return .yellow }
        if weather.cloudCover < 50 { return .orange }
        return .gray
    }
    
    func formatHour(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        formatter.timeZone = powstonTimezone()
        return formatter.string(from: date)
    }
}

struct RadiationBar: View {
    let value: Double
    let max: Double
    
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.gray.opacity(0.3))
                
                RoundedRectangle(cornerRadius: 2)
                    .fill(barColor)
                    .frame(width: geo.size.width * min(value / max, 1.0))
            }
        }
    }
    
    var barColor: Color {
        let ratio = value / max
        if ratio > 0.6 { return .yellow }
        if ratio > 0.3 { return .orange }
        return .gray
    }
}
