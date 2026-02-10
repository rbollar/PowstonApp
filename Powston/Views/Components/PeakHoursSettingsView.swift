//
//  PeakHoursSettingsView.swift
//  Powston
//

import SwiftUI

struct PeakHoursSettingsView: View {
    @AppStorage("peak_start_hour") private var peakStartHour: Double = 16.0
    @AppStorage("peak_end_hour") private var peakEndHour: Double = 21.0
    @AppStorage("peak_enabled") private var peakEnabled: Bool = false
    
    var body: some View {
        Form {
            Section {
                Toggle("Enable Peak Period Markers", isOn: $peakEnabled)
            } footer: {
                Text("Highlights peak pricing periods on charts to help visualize high-cost windows")
            }
            
            if peakEnabled {
                Section("Peak Window") {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Start")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(formatHour(peakStartHour))
                                    .font(.headline)
                                    .monospacedDigit()
                            }
                            Slider(value: $peakStartHour, in: 0...23.75, step: 0.25)
                                .accessibilityLabel("Peak start time")
                                .accessibilityValue(formatHour(peakStartHour))
                        }
                        
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("End")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(formatHour(peakEndHour))
                                    .font(.headline)
                                    .monospacedDigit()
                            }
                            Slider(value: $peakEndHour, in: 0...23.75, step: 0.25)
                                .accessibilityLabel("Peak end time")
                                .accessibilityValue(formatHour(peakEndHour))
                        }
                    }
                    .padding(.vertical, 4)
                }
                
                if peakStartHour >= peakEndHour {
                    Section {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("Peak start must be before peak end")
                                .font(.subheadline)
                                .foregroundColor(.orange)
                        }
                    }
                }
                
                Section {
                    HStack {
                        Image(systemName: "info.circle")
                            .foregroundColor(.blue)
                        Text("Peak periods are shown as shaded regions on price charts")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Peak Hours")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    func formatHour(_ hour: Double) -> String {
        let tz = powstonTimezone()
        var cal = Calendar.current
        cal.timeZone = tz
        let startOfDay = cal.startOfDay(for: Date())
        guard let date = cal.date(byAdding: .hour, value: Int(hour), to: startOfDay),
              let dateWithMinutes = cal.date(byAdding: .minute, value: Int((hour - Double(Int(hour))) * 60), to: date) else {
            return String(format: "%02d:%02d", Int(hour), Int((hour - Double(Int(hour))) * 60))
        }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        formatter.timeZone = tz
        return formatter.string(from: dateWithMinutes)
    }
}

// MARK: - Summary Helper
extension PeakHoursSettingsView {
    /// Returns a summary string for display in parent settings view
    static func summary(enabled: Bool, startHour: Double, endHour: Double) -> String {
        guard enabled else { return "Off" }
        let startH = Int(startHour)
        let endH = Int(endHour)
        let startSuffix = startH >= 12 ? "pm" : "am"
        let endSuffix = endH >= 12 ? "pm" : "am"
        let startDisplay = startH > 12 ? startH - 12 : (startH == 0 ? 12 : startH)
        let endDisplay = endH > 12 ? endH - 12 : (endH == 0 ? 12 : endH)
        return "\(startDisplay)\(startSuffix)–\(endDisplay)\(endSuffix)"
    }
}

#Preview {
    NavigationStack {
        PeakHoursSettingsView()
    }
}
