//
//  ManualOverrideView.swift
//  Powston
//

import SwiftUI

struct ManualOverrideView: View {
    @EnvironmentObject var api: PowstonAPI
    @State private var selectedMode: OverrideMode = .auto
    @State private var duration: Int = 60
    @State private var useTimeRange = false
    @State private var startTime = Date()
    @State private var endTime = Date().addingTimeInterval(3600)
    @State private var exportLimit = false
    @State private var addPriceConstraints = false
    @State private var addSocConstraints = false
    @State private var minBuyPrice: Double = 0
    @State private var maxBuyPrice: Double = 50
    @State private var minSellPrice: Double = 0
    @State private var maxSellPrice: Double = 50
    @State private var minSoc: Double = 10
    @State private var maxSoc: Double = 100
    @State private var notes: String = ""
    @State private var acceptedResponsibility = false
    @State private var showingConfirmation = false
    @State private var showingResult = false
    @State private var resultMessage = ""
    @State private var isSubmitting = false
    
    var body: some View {
        NavigationStack {
            Form {
                // Active Override Banner
                if let d = api.data, d.reason.lowercased().hasPrefix("manual") {
                    Section {
                        HStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                .font(.title2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Manual Override Active")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.orange)
                                Text(d.reason)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button("Cancel") {
                                selectedMode = .auto
                                duration = 1
                                Task { await applyOverride() }
                            }
                            .font(.subheadline)
                            .foregroundColor(.red)
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowBackground(Color.orange.opacity(0.1))
                }
                
                // Mode Selection
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Select Mode")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(.secondary)
                        
                        HStack(spacing: 12) {
                            ModeButton(mode: .auto, isSelected: selectedMode == .auto, action: { selectedMode = .auto })
                            ModeButton(mode: .autoCurtail, isSelected: selectedMode == .autoCurtail, action: { selectedMode = .autoCurtail })
                        }
                        
                        HStack(spacing: 12) {
                            ModeButton(mode: .charge, isSelected: selectedMode == .charge, action: { selectedMode = .charge })
                            ModeButton(mode: .discharge, isSelected: selectedMode == .discharge, action: { selectedMode = .discharge })
                        }
                        
                        HStack(spacing: 12) {
                            ModeButton(mode: .import, isSelected: selectedMode == .import, action: { selectedMode = .import })
                            ModeButton(mode: .export, isSelected: selectedMode == .export, action: { selectedMode = .export })
                        }
                    }
                    .padding(.vertical, 8)
                    
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .foregroundColor(.blue)
                            .font(.subheadline)
                        Text(selectedMode.description)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Mode")
                }
                
                // Export Limit Toggle
                if selectedMode != .auto {
                    Section {
                        Toggle(isOn: $exportLimit) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Export Limit")
                                    .font(.subheadline)
                                Text("Prevent exporting to grid, only meet site load")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                
                // Duration / Time Range
                if selectedMode != .auto {
                    Section {
                        Picker("Timing", selection: $useTimeRange) {
                            Text("Duration").tag(false)
                            Text("Time Range").tag(true)
                        }
                        .pickerStyle(.segmented)
                        
                        if useTimeRange {
                            DatePicker("Start", selection: $startTime)
                            DatePicker("End", selection: $endTime)
                        } else {
                            VStack(spacing: 16) {
                                VStack(spacing: 4) {
                                    Text(formatDurationLong(duration))
                                        .font(.title2)
                                        .fontWeight(.semibold)
                                        .foregroundColor(.blue)
                                    
                                    Text("Until \(formatEndTime(duration))")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.blue.opacity(0.08))
                                .cornerRadius(12)
                                
                                HStack(spacing: 8) {
                                    ForEach([5, 15, 30], id: \.self) { mins in
                                        DurationChip(label: "\(mins)m", isSelected: duration == mins, action: { duration = mins })
                                    }
                                    ForEach([1, 2, 4, 8, 12], id: \.self) { hours in
                                        DurationChip(label: "\(hours)h", isSelected: duration == hours * 60, action: { duration = hours * 60 })
                                    }
                                }
                                
                                Stepper("Custom: \(duration) minutes", value: $duration, in: 5...720, step: 5)
                                    .font(.subheadline)
                            }
                            .padding(.vertical, 8)
                        }
                    } header: {
                        Text("Duration")
                    }
                }
                
                // Price Constraints
                if selectedMode != .auto {
                    Section {
                        Toggle("Add Price Constraints", isOn: $addPriceConstraints)
                        
                        if addPriceConstraints {
                            VStack(alignment: .leading, spacing: 16) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Buy Price Range")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    HStack {
                                        Text("Min: \(Int(minBuyPrice))¢")
                                            .font(.subheadline)
                                            .frame(width: 80, alignment: .leading)
                                        Slider(value: $minBuyPrice, in: -20...100, step: 1)
                                    }
                                    HStack {
                                        Text("Max: \(Int(maxBuyPrice))¢")
                                            .font(.subheadline)
                                            .frame(width: 80, alignment: .leading)
                                        Slider(value: $maxBuyPrice, in: 0...150, step: 1)
                                    }
                                }
                                
                                Divider()
                                
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Sell Price Range")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    HStack {
                                        Text("Min: \(Int(minSellPrice))¢")
                                            .font(.subheadline)
                                            .frame(width: 80, alignment: .leading)
                                        Slider(value: $minSellPrice, in: -20...100, step: 1)
                                    }
                                    HStack {
                                        Text("Max: \(Int(maxSellPrice))¢")
                                            .font(.subheadline)
                                            .frame(width: 80, alignment: .leading)
                                        Slider(value: $maxSellPrice, in: 0...150, step: 1)
                                    }
                                }
                            }
                            .padding(.vertical, 8)
                        }
                    } header: {
                        Text("Price Constraints")
                    } footer: {
                        if addPriceConstraints {
                            Text("Override will only apply when prices are within these ranges")
                        }
                    }
                }
                
                // SOC Constraints
                if selectedMode != .auto {
                    Section {
                        Toggle("Add Battery SOC Constraints", isOn: $addSocConstraints)
                        
                        if addSocConstraints {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Text("Min SOC: \(Int(minSoc))%")
                                        .font(.subheadline)
                                        .frame(width: 100, alignment: .leading)
                                    Slider(value: $minSoc, in: 5...95, step: 5)
                                }
                                HStack {
                                    Text("Max SOC: \(Int(maxSoc))%")
                                        .font(.subheadline)
                                        .frame(width: 100, alignment: .leading)
                                    Slider(value: $maxSoc, in: 10...100, step: 5)
                                }
                                
                                if minSoc >= maxSoc {
                                    HStack {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .foregroundColor(.red)
                                        Text("Min must be less than Max")
                                            .font(.caption)
                                            .foregroundColor(.red)
                                    }
                                }
                            }
                            .padding(.vertical, 8)
                        }
                    } header: {
                        Text("SOC Constraints")
                    }
                }
                
                // Notes
                if selectedMode != .auto {
                    Section("Reason (Optional)") {
                        TextField("e.g., Testing pool heater...", text: $notes, axis: .vertical)
                            .lineLimit(2...4)
                    }
                }
                
                // Confirmation
                if selectedMode != .auto {
                    Section {
                        Toggle(isOn: $acceptedResponsibility) {
                            Text("I understand this overrides automatic control and accept responsibility for any costs or profits this may generate.")
                                .font(.caption)
                        }
                        .toggleStyle(CheckboxToggleStyle())
                    }
                }
                
                // Apply Button
                Section {
                    Button(action: { showingConfirmation = true }) {
                        HStack {
                            Spacer()
                            if isSubmitting {
                                ProgressView()
                                    .tint(.white)
                                    .padding(.trailing, 8)
                            }
                            Text(selectedMode == .auto ? "Return to Auto" : "Apply Override")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                    .disabled(!canSubmit)
                    .foregroundColor(.white)
                    .listRowBackground(
                        canSubmit
                            ? (selectedMode == .auto ? Color.blue : Color.green)
                            : Color.gray.opacity(0.4)
                    )
                }
            }
            .navigationTitle("Manual Override")
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog(
                selectedMode == .auto ? "Return to Auto?" : "Apply Override?",
                isPresented: $showingConfirmation,
                titleVisibility: .visible
            ) {
                Button(selectedMode == .auto ? "Return to Auto" : "Apply \(selectedMode.displayName)", role: selectedMode == .auto ? .none : .destructive) {
                    Task { await applyOverride() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                if selectedMode == .auto {
                    Text("This will return control to the optimization script.")
                } else {
                    Text("This will apply \(selectedMode.displayName) mode for \(formatDurationLong(duration)) on \(api.inverters.count) inverter(s).")
                }
            }
            .alert("Override Result", isPresented: $showingResult) {
                Button("OK") {}
            } message: {
                Text(resultMessage)
            }
        }
    }
    
    var canSubmit: Bool {
        if selectedMode == .auto { return true }
        if !acceptedResponsibility { return false }
        if addSocConstraints && minSoc >= maxSoc { return false }
        if api.selectedInverterId == 0 && api.inverters.isEmpty { return false }
        return true
    }
    
    func formatDurationLong(_ minutes: Int) -> String {
        if minutes < 60 {
            return "\(minutes) minutes"
        } else if minutes == 60 {
            return "1 hour"
        } else if minutes % 60 == 0 {
            return "\(minutes / 60) hours"
        } else {
            let hours = minutes / 60
            let mins = minutes % 60
            return "\(hours)h \(mins)m"
        }
    }
    
    func formatEndTime(_ minutes: Int) -> String {
        let endDate = Date().addingTimeInterval(Double(minutes) * 60)
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.timeZone = powstonTimezone()
        return formatter.string(from: endDate)
    }
    
    func applyOverride() async {
        isSubmitting = true
        var successCount = 0, failCount = 0
        
        let inverterIds: [Int]
        if api.inverters.isEmpty {
            inverterIds = api.selectedInverterId != 0 ? [api.selectedInverterId] : []
        } else {
            inverterIds = api.inverters.map { $0.id }
        }
        
        for inverterId in inverterIds {
            let success = await api.setManualOverride(
                inverterId: inverterId,
                mode: selectedMode.apiValue,
                minutes: selectedMode == .auto ? 1 : duration,
                notes: notes.isEmpty ? nil : notes,
                minSoc: addSocConstraints ? Int(minSoc) : nil,
                maxSoc: addSocConstraints ? Int(maxSoc) : nil,
                minBuyPrice: addPriceConstraints ? minBuyPrice : nil,
                maxBuyPrice: addPriceConstraints ? maxBuyPrice : nil,
                minSellPrice: addPriceConstraints ? minSellPrice : nil,
                maxSellPrice: addPriceConstraints ? maxSellPrice : nil,
                exportLimit: exportLimit,
                startTime: useTimeRange ? startTime : nil,
                endTime: useTimeRange ? endTime : nil
            )
            
            if success {
                successCount += 1
            } else {
                failCount += 1
            }
        }
        
        isSubmitting = false
        
        if failCount == 0 {
            resultMessage = "✅ \(selectedMode == .auto ? "Returned to auto" : "Override applied") on \(successCount) inverter(s)"
            await api.fetchData()
        } else {
            resultMessage = "⚠️ Success: \(successCount), Failed: \(failCount)"
        }
        
        showingResult = true
    }
}
