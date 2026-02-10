//
//  WeatherWidget.swift
//  Powston
//

import SwiftUI

struct WeatherWidget: View {
    @StateObject private var weather = WeatherService.shared
    let latitude: Double
    let longitude: Double
    @State private var selectedHour: HourlyWeather?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: "cloud.sun.fill")
                    .foregroundColor(.orange)
                    .accessibilityHidden(true)
                Text("Solar Forecast")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                if weather.isLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                        .accessibilityLabel("Loading")
                }
            }
            .accessibilityAddTraits(.isHeader)
            
            if let error = weather.error, !error.contains("cancelled") {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                        .accessibilityHidden(true)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .accessibilityLabel("Weather error: \(error)")
            } else if weather.hourlyForecast.isEmpty && !weather.isLoading {
                HStack {
                    Text("Loading weather...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button(action: {
                        Task {
                            await weather.fetchWeather(latitude: latitude, longitude: longitude)
                        }
                    }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                    }
                    .accessibilityLabel("Retry loading weather")
                }
            } else if !weather.hourlyForecast.isEmpty {
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
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Temperature: \(Int(current.temperature)) degrees")
                        
                        // Cloud cover
                        HStack(spacing: 4) {
                            Image(systemName: current.cloudIcon)
                                .foregroundColor(.gray)
                                .font(.caption)
                            Text("\(current.cloudCover)%")
                                .font(.subheadline)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Cloud cover: \(current.cloudCover) percent")
                        
                        // Solar radiation
                        HStack(spacing: 4) {
                            Image(systemName: "sun.max.fill")
                                .foregroundColor(.yellow)
                                .font(.caption)
                            Text("\(Int(current.totalRadiation)) W/m²")
                                .font(.subheadline)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Solar radiation: \(Int(current.totalRadiation)) watts per square meter")
                    }
                    .padding(.bottom, 4)
                }
                
                // Selected hour detail
                if let selected = selectedHour {
                    HStack(spacing: 16) {
                        Image(systemName: "sun.max.fill")
                            .foregroundColor(.yellow)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(formatHourFull(selected.time))
                                .font(.caption)
                                .fontWeight(.medium)
                            Text("\(Int(selected.totalRadiation)) W/m² solar radiation")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Text("\(Int(selected.cloudCover))% cloud")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Button(action: { selectedHour = nil }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .accessibilityLabel("Dismiss")
                    }
                    .padding(8)
                    .background(Color.yellow.opacity(0.1))
                    .cornerRadius(8)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(formatHourFull(selected.time)): \(Int(selected.totalRadiation)) watts per square meter, \(Int(selected.cloudCover)) percent cloud cover")
                }
                
                // Next 6 hours forecast
                let hours = weather.nextHours(6)
                HStack(spacing: 0) {
                    ForEach(Array(hours.enumerated()), id: \.element.id) { index, hour in
                        WeatherHourCell(weather: hour, isSelected: selectedHour?.id == hour.id)
                            .frame(maxWidth: .infinity)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 15)
                        .onChanged { value in
                            // Only respond to horizontal drags - let vertical pass through for scrolling
                            let horizontalDistance = abs(value.translation.width)
                            let verticalDistance = abs(value.translation.height)
                            guard horizontalDistance > verticalDistance * 1.5 else { return }
                            
                            let totalWidth = UIScreen.main.bounds.width - 32
                            let cellWidth = totalWidth / CGFloat(hours.count)
                            let index = Int(value.location.x / cellWidth)
                            if index >= 0 && index < hours.count {
                                let hour = hours[index]
                                if selectedHour?.id != hour.id {
                                    selectedHour = hour
                                }
                            }
                        }
                )
                .accessibilityLabel("Hourly forecast. Swipe to select hours.")
            }
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(12)
        .onAppear {
            if weather.hourlyForecast.isEmpty && !weather.isLoading {
                Task {
                    await weather.fetchWeather(latitude: latitude, longitude: longitude)
                }
            }
        }
    }
    
    func formatHourFull(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE ha"  // "Monday 2pm"
        formatter.timeZone = powstonTimezone()
        return formatter.string(from: date)
    }
}

struct WeatherHourCell: View {
    let weather: HourlyWeather
    var isSelected: Bool = false
    
    var body: some View {
        VStack(spacing: 6) {
            // Time
            Text(formatHour(weather.time))
                .font(.caption2)
                .foregroundColor(isSelected ? .primary : .secondary)
            
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
        .padding(.vertical, 4)
        .background(isSelected ? Color.yellow.opacity(0.2) : Color.clear)
        .cornerRadius(8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(formatHour(weather.time)): \(Int(weather.temperature)) degrees, \(Int(weather.cloudCover)) percent cloud, \(Int(weather.totalRadiation)) watts per square meter")
    }
    
    var iconColor: Color {
        if weather.cloudCover < 20 { return .yellow }
        if weather.cloudCover < 50 { return .orange }
        return .gray
    }
    
    func formatHour(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "ha"  // "7PM" format
        formatter.timeZone = powstonTimezone()
        return formatter.string(from: date).lowercased()
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
