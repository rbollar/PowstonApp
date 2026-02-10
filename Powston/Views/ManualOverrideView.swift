//
//  ManualOverrideView.swift
//  Powston
//

import SwiftUI

struct ManualOverrideView: View {
    @EnvironmentObject var api: PowstonAPI
    @State private var selectedMode: OverrideMode?
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
    
    @State private var isCancelling = false
    @State private var verificationTask: Task<Void, Never>?
    @State private var scrollToTop = false

    // Map active override action to OverrideMode
    func modeFromAction(_ action: String) -> OverrideMode? {
        let lower = action.lowercased()
        if lower.contains("discharge") { return .discharge }
        if lower.contains("charge") { return .charge }
        if lower.contains("export") { return .export }
        if lower.contains("import") { return .import }
        if lower.contains("curtail") { return .autoCurtail }
        if lower.contains("auto") { return .auto }
        return nil
    }
    
    // Inverters for current site only
    var siteInverters: [Inverter] {
        guard let selectedInverter = api.inverters.first(where: { $0.id == api.selectedInverterId }) else {
            return api.inverters
        }
        return api.inverters.filter { $0.siteId == selectedInverter.siteId }
    }
    
    var currentSiteName: String {
        guard let selectedInverter = api.inverters.first(where: { $0.id == api.selectedInverterId }),
              let site = api.sites.first(where: { $0.id == selectedInverter.siteId }) else {
            return "Current Site"
        }
        return site.displayName ?? site.name
    }

    
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                Form {
                    // Currently Active Override(s)
                    if !api.currentOverrides.isEmpty {
                        Section {
                            ForEach(api.currentOverrides) { action in
                                OverrideRowView(
                                    action: action,
                                    type: .active,
                                    isCancelling: isCancelling,
                                    onCancel: { await cancelSingleOverride(action) }
                                )
                            }
                        } header: {
                            Label("Active Now", systemImage: "bolt.fill")
                                .foregroundColor(.orange)
                        }
                        .listRowBackground(Color.orange.opacity(0.1))
                    }
                    
                    // Scheduled Override(s)
                    if !api.scheduledOverrides.isEmpty {
                        Section {
                            ForEach(api.scheduledOverrides) { action in
                                OverrideRowView(
                                    action: action,
                                    type: .scheduled,
                                    isCancelling: isCancelling,
                                    onCancel: { await cancelSingleOverride(action) }
                                )
                            }
                        } header: {
                            Label("Scheduled", systemImage: "clock.fill")
                                .foregroundColor(.blue)
                        }
                        .listRowBackground(Color.blue.opacity(0.05))
                    }
                
                // Pending Override Banner
                if !api.pendingOverrides.isEmpty {
                    Section {
                        ForEach(api.pendingOverrides) { pending in
                            HStack(spacing: 12) {
                                ProgressView()
                                    .controlSize(.small)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Override Pending")
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                        .foregroundColor(.blue)
                                    Text("\(pending.mode.capitalized) • \(pending.elapsedTime)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text("\(pending.inverterIds.count) inverter(s) • Verifying...")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 4)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Override pending: \(pending.mode), \(pending.inverterIds.count) inverters, \(pending.elapsedTime) elapsed, verifying")
                        }
                        Text("Waiting for confirmation. This may take up to 5 minutes.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .listRowBackground(Color.blue.opacity(0.1))
                    .id("pendingSection")
                }
                
                // All form sections - disabled while pending
                Group {
                    // Site/Inverter Info
                    Section {
                        HStack {
                            Image(systemName: "building.2")
                                .foregroundColor(.blue)
                            Text(currentSiteName)
                            Spacer()
                            Text("\(siteInverters.count) inverter\(siteInverters.count == 1 ? "" : "s")")
                                .foregroundColor(.secondary)
                        }
                    } header: {
                        Text("Applying To")
                    }
                
                // Mode Selection
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                                            // Auto - centered at 1.5x width of paired buttons
                                            GeometryReader { geo in

                                                    let pairedButtonWidth = (geo.size.width - 12) / 2
                                                    let autoWidth = pairedButtonWidth * 1.5
                                                    HStack {
                                                        Spacer()
                                                        ModeButton(mode: .auto, isSelected: selectedMode == .auto, action: { selectedMode = .auto })
                                                            .frame(width: autoWidth)
                                                        Spacer()
                                                    }
                                                }
                                                .frame(height: 60)
                                                .padding(.bottom, 14)
                                                
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
                        Text(selectedMode?.description ?? "Select a mode above to see its description.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Mode")
                }
                
                // Export Limit Toggle
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
                
                // Duration / Time Range
                Section {
                    Picker("Timing", selection: $useTimeRange) {
                        Text("Duration").tag(false)
                        Text("Time Range").tag(true)
                    }
                    .pickerStyle(.segmented)
                    
                    if useTimeRange {
                        DatePicker(
                            "Start",
                            selection: $startTime,
                            in: Date()...,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                        .onChange(of: startTime) { _, newValue in
                            if endTime <= newValue {
                                endTime = newValue.addingTimeInterval(300)
                            }
                        }
                        
                        DatePicker(
                            "End",
                            selection: $endTime,
                            in: startTime.addingTimeInterval(60)...,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                        
                        // Show duration
                        let durationMins = Int(endTime.timeIntervalSince(startTime) / 60)
                        HStack {
                            Text("Duration")
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(formatDurationLong(durationMins))
                                .foregroundColor(.blue)
                        }
                        .font(.caption)
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
                
                // Price Constraints
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
                
                // SOC Constraints
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
                
                // Notes - use TextEditor for better performance
                Section("Reason (Optional)") {
                    TextEditor(text: $notes)
                        .frame(minHeight: 60, maxHeight: 100)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .overlay(
                            Group {
                                if notes.isEmpty {
                                    Text("e.g., Testing pool heater...")
                                        .foregroundColor(.secondary.opacity(0.5))
                                        .padding(.top, 8)
                                        .padding(.leading, 4)
                                        .allowsHitTesting(false)
                                }
                            },
                            alignment: .topLeading
                        )
                }
                
                // Confirmation
                Section {
                    Toggle(isOn: $acceptedResponsibility) {
                        Text("I understand this overrides automatic control and accept responsibility for any costs or profits this may generate.")
                            .font(.caption)
                    }
                    .toggleStyle(CheckboxToggleStyle())
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
                            Text("Apply Override")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                    .disabled(!canSubmit)
                    .foregroundColor(.white)
                    .listRowBackground(
                        canSubmit
                            ? Color.green
                            : Color.gray.opacity(0.4)
                    )
                }
                
                // Limitations disclosure
                Section {
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 12) {
                            LimitationRow(
                                icon: "calendar.badge.clock",
                                text: "You can have multiple scheduled overrides, but overlapping times will cancel the existing one."
                            )
                            LimitationRow(
                                icon: "square.stack.3d.up",
                                text: "All inverters at a site receive the same manual action."
                            )
                            LimitationRow(
                                icon: "clock.badge.exclamationmark",
                                text: "Overrides take effect on the next AEMO 5-minute cycle."
                            )
                            LimitationRow(
                                icon: "arrow.clockwise",
                                text: "Status updates in this app may be delayed up to 5 minutes."
                            )
                        }
                        .padding(.vertical, 8)
                    } label: {
                        HStack {
                            Image(systemName: "info.circle")
                                .foregroundColor(.secondary)
                            Text("Limitations & Tips")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                } // End Group
                .disabled(api.hasPendingOverride)
            }
            .navigationTitle("Manual Override")
            .navigationBarTitleDisplayMode(.inline)
            .alert(
                hasOverlap ? "Override Conflict" : "Apply Override?",
                isPresented: $showingConfirmation
            ) {
                Button(hasOverlap ? "Replace & Apply" : "Apply", role: .destructive) {
                    Task { await applyOverride() }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                if hasOverlap {
                    let conflicts = overlappingOverrides.map { "\($0.action.capitalized) (\($0.formattedTimeRange))" }.joined(separator: ", ")
                    Text("This will cancel conflicting override(s): \(conflicts)\n\nThen apply \(selectedMode?.displayName ?? "selected") mode on \(siteInverters.count) inverter(s).")
                } else {
                    Text("Apply \(selectedMode?.displayName ?? "selected") mode for \(useTimeRange ? "the selected time range" : formatDurationLong(duration)) on \(siteInverters.count) inverter(s)?")
                }
            }
            .alert("Override Result", isPresented: $showingResult) {
                Button("OK") {}
            } message: {
                Text(resultMessage)
            }
            .task {
                await api.refreshActiveOverrides()
                clearStalePending()
                await clearStaleLiveActivity()

                // Debug
                print("📋 Scheduled overrides: \(api.scheduledOverrides.count)")
                for override in api.scheduledOverrides {
                    print("   - \(override.action) \(override.formattedTimeRange) inv:\(override.inverterId)")
                }
                print("📋 Current overrides: \(api.currentOverrides.count)")
                for override in api.currentOverrides {
                    print("   - \(override.action) \(override.formattedTimeRange) inv:\(override.inverterId)")
                }
                print("📋 All override actions: \(api.allOverrideActions.count)")
            }
            .refreshable {
                await api.refreshActiveOverrides()
                clearStalePending()
                await clearStaleLiveActivity()
            }
            .onDisappear {
                verificationTask?.cancel()
            }
            .onAppear {
                // Set initial mode from active override if any
                if selectedMode == nil, let firstActive = api.activeOverrides.first {
                    selectedMode = modeFromAction(firstActive.action)
                }
            }
            .onChange(of: api.pendingOverrides.count) { oldCount, newCount in
                if newCount > oldCount {
                    withAnimation {
                        proxy.scrollTo("pendingSection", anchor: .top)
                    }
                }
            }
            } // End ScrollViewReader
        } // End NavigationStack
    } // End body
    
    func clearStalePending() {
        // Remove pending overrides if we now have active overrides for those inverters
        let activeInverterIds = Set(api.activeOverrides.map { $0.inverterId })
        api.pendingOverrides.removeAll { pending in
            // If all inverters in this pending now have active overrides, clear it
            pending.inverterIds.allSatisfy { activeInverterIds.contains($0) }
        }
    }

    func cancelAllOverrides() async {
        isCancelling = true
        var successCount = 0
        var failCount = 0
        
        // Cancel all active and scheduled overrides for this site
        for action in api.activeOverrides {
            let success = await api.endManualAction(actionId: action.id)
            if success {
                successCount += 1
            } else {
                failCount += 1
            }
        }
        
        isCancelling = false
        
        // End Live Activity
        await LiveActivityManager.shared.endAsCancelled()
        
        if failCount == 0 {
            resultMessage = "✅ Cancelled \(successCount) override(s)"
        } else {
            resultMessage = "⚠️ Cancelled: \(successCount), Failed: \(failCount)"
        }
        
        await api.refreshActiveOverrides()
        await api.fetchData()
        showingResult = true
    }
    
    func cancelSingleOverride(_ action: ManualAction) async {
        isCancelling = true
        let (successCount, failCount) = await api.cancelOverrideGroup(action)
        isCancelling = false
        
        // End Live Activity
        await LiveActivityManager.shared.endAsCancelled()
        
        if failCount == 0 {
            resultMessage = "✅ Cancelled \(action.action.capitalized) override (\(successCount) inverter\(successCount == 1 ? "" : "s"))"
        } else {
            resultMessage = "⚠️ Cancelled: \(successCount), Failed: \(failCount)"
        }
        
        await api.refreshActiveOverrides()
        await api.fetchData()
        showingResult = true
    }
    
    // Find overrides that would conflict with the proposed time range
    var overlappingOverrides: [ManualAction] {
        let proposedStart: Date
        let proposedEnd: Date
        
        if useTimeRange {
            proposedStart = startTime
            proposedEnd = endTime
        } else {
            proposedStart = Date()
            proposedEnd = Date().addingTimeInterval(Double(duration) * 60)
        }
        
        return api.findOverlappingOverrides(start: proposedStart, end: proposedEnd)
    }
    
    var hasOverlap: Bool {
        !overlappingOverrides.isEmpty
    }
    
    var canSubmit: Bool {
        if api.hasPendingOverride { return false }
        if selectedMode == nil { return false }
        if !acceptedResponsibility { return false }
        if addSocConstraints && minSoc >= maxSoc { return false }
        if siteInverters.isEmpty { return false }
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
        // Block in demo mode
        if api.isDemoMode {
            resultMessage = "⚠️ Overrides not available in Demo Mode\n\nConnect your Powston account to control your inverter."
            showingResult = true
            return
        }
        
        isSubmitting = true
        
        guard let mode = selectedMode else {
            isSubmitting = false
            resultMessage = "❌ No mode selected"
            showingResult = true
            return
        }
        
        let inverterIds = siteInverters.map { $0.id }
        let targetMode = mode.apiValue
        
        guard !inverterIds.isEmpty else {
            isSubmitting = false
            resultMessage = "❌ No inverters found for current site"
            showingResult = true
            return
        }
        
        // Cancel any conflicting overrides first
        if hasOverlap {
            for conflict in overlappingOverrides {
                _ = await api.endManualAction(actionId: conflict.id)
            }
            // Brief delay to let cancellations process
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
        }
        
        // Create pending override for UI feedback
        let pending = PendingOverride(
            mode: targetMode,
            inverterIds: inverterIds,
            startedAt: Date()
        )
        api.pendingOverrides.append(pending)
        
        // Start Live Activity
        LiveActivityManager.shared.startPendingOverride(
            activityId: pending.id.uuidString,
            mode: targetMode,
            inverterCount: inverterIds.count,
            siteName: currentSiteName,
            endTime: useTimeRange ? endTime : Date().addingTimeInterval(Double(duration) * 60),
            startTime: useTimeRange ? startTime : nil
        )
        
        // Fire requests without waiting (fire-and-forget)
        for inverterId in inverterIds {
            let apiRef = api
            let modeValue = mode.apiValue
            let durationValue = duration
            let notesValue = notes.isEmpty ? nil : notes
            let minSocValue = addSocConstraints ? Int(minSoc) : nil
            let maxSocValue = addSocConstraints ? Int(maxSoc) : nil
            let minBuyPriceValue = addPriceConstraints ? minBuyPrice : nil
            let maxBuyPriceValue = addPriceConstraints ? maxBuyPrice : nil
            let minSellPriceValue = addPriceConstraints ? minSellPrice : nil
            let maxSellPriceValue = addPriceConstraints ? maxSellPrice : nil
            let exportLimitValue = exportLimit
            let useTimeRangeValue = useTimeRange
            let startTimeValue = startTime
            let endTimeValue = endTime
            
            Task.detached {
                _ = await apiRef.setManualOverride(
                    inverterId: inverterId,
                    mode: modeValue,
                    minutes: durationValue,
                    notes: notesValue,
                    minSoc: minSocValue,
                    maxSoc: maxSocValue,
                    minBuyPrice: minBuyPriceValue,
                    maxBuyPrice: maxBuyPriceValue,
                    minSellPrice: minSellPriceValue,
                    maxSellPrice: maxSellPriceValue,
                    exportLimit: exportLimitValue,
                    startTime: useTimeRangeValue ? startTimeValue : nil,
                    endTime: useTimeRangeValue ? endTimeValue : nil
                )
            }
        }
        
        isSubmitting = false
        
        // Start background verification polling
        startVerificationPolling(pendingId: pending.id, targetMode: targetMode, inverterIds: inverterIds)
    }
    
    func startVerificationPolling(pendingId: UUID, targetMode: String, inverterIds: [Int]) {
        verificationTask?.cancel()
        
        let expectedStartTime = useTimeRange ? startTime : Date()
        
        verificationTask = Task { @MainActor in
            for _ in 1...30 {
                guard !Task.isCancelled else { return }
                
                try? await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
                
                guard !Task.isCancelled else { return }
                
                await api.refreshActiveOverrides()
                
                // Find actions matching our expected mode and approximate start time
                let matchingActions = api.allOverrideActions.filter { action in
                    action.action.lowercased() == targetMode.lowercased() &&
                    action.startDate != nil &&
                    abs(action.startDate!.timeIntervalSince(expectedStartTime)) < 120 // Within 2 min
                }
                
                let confirmedCount = matchingActions.count
                let allConfirmed = confirmedCount >= inverterIds.count
                
                print("🔍 Verification check:")
                print("   Pending ID: \(pendingId)")
                print("   Expected mode: \(targetMode)")
                print("   Expected inverter count: \(inverterIds.count)")
                print("   Matching action count: \(confirmedCount)")
                print("   allConfirmed: \(allConfirmed)")
                
                if allConfirmed {
                    // Only remove THIS pending override
                    api.pendingOverrides.removeAll { $0.id == pendingId }
                    
                    // Update Live Activity based on whether it's scheduled or active
                    let isScheduled = matchingActions.first?.isScheduled ?? false
                    if isScheduled, let scheduled = matchingActions.first,
                       let start = scheduled.startDate, let end = scheduled.endDate {
                        await LiveActivityManager.shared.updateToScheduled(startTime: start, endTime: end)
                    } else if let active = matchingActions.first, let end = active.endDate {
                        await LiveActivityManager.shared.updateToActive(endTime: end, startTime: active.startDate)
                    }
                    
                    resultMessage = isScheduled
                        ? "✅ Override scheduled on \(inverterIds.count) inverter(s)"
                        : "✅ Override confirmed on \(inverterIds.count) inverter(s)"
                    showingResult = true
                    await api.fetchData()
                    return
                }
            }
            
            // Timeout - couldn't confirm after 5 minutes
            api.pendingOverrides.removeAll { $0.id == pendingId }
            
            await LiveActivityManager.shared.endAsCancelled()
            
            resultMessage = "❌ Override not confirmed after 5 minutes. Please check the system status and try again."
            showingResult = true
        }
    }
    func clearStaleLiveActivity() async {
        // If there's an active Live Activity but no active/scheduled/pending overrides, end it
        let hasOverrides = !api.currentOverrides.isEmpty ||
                           !api.scheduledOverrides.isEmpty ||
                           !api.pendingOverrides.isEmpty
        
        if !hasOverrides {
            await LiveActivityManager.shared.endAsCompleted()
        }
    }
}

// MARK: - Override Row View
struct OverrideRowView: View {
    @EnvironmentObject var api: PowstonAPI
    let action: ManualAction
    let type: OverrideType
    let isCancelling: Bool
    let onCancel: () async -> Void
    
    var inverterCount: Int {
        api.getOverrideGroup(matching: action).count
    }
    
    enum OverrideType {
        case active
        case scheduled
        
        var icon: String {
            switch self {
            case .active: return "bolt.fill"
            case .scheduled: return "clock.fill"
            }
        }
        
        var color: Color {
            switch self {
            case .active: return .orange
            case .scheduled: return .blue
            }
        }
        
        var accessibilityPrefix: String {
            switch self {
            case .active: return "Active override"
            case .scheduled: return "Scheduled override"
            }
        }
    }
    
    var accessibilityDescription: String {
        var desc = "\(type.accessibilityPrefix): \(action.action)"
        if inverterCount > 1 {
            desc += ", \(inverterCount) inverters"
        }
        if action.exportLimit == true {
            desc += ", export limited"
        }
        desc += ". \(action.formattedTimeRange)"
        if type == .active {
            desc += ". \(action.formattedRemainingTime)"
        } else {
            desc += ". Starts \(action.formattedStartsIn)"
        }
        return desc
    }
    
    var body: some View {
        HStack(spacing: 12) {
            // Status icon
            Image(systemName: type.icon)
                .foregroundColor(type.color)
                .font(.title3)
                .frame(width: 28)
                .accessibilityHidden(true)
            
            // Details
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(action.action.capitalized)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    
                    if inverterCount > 1 {
                        Text("• \(inverterCount) inverters")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    
                    if action.exportLimit == true {
                        Text("• Export Limited")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                
                Text(action.formattedTimeRange)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                if type == .active {
                    Text(action.formattedRemainingTime)
                        .font(.caption2)
                        .foregroundColor(type.color)
                } else {
                    Text("Starts \(action.formattedStartsIn)")
                        .font(.caption2)
                        .foregroundColor(type.color)
                }
                
                if let notes = action.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            
            Spacer()
            
            // Cancel button
            Button {
                Task { await onCancel() }
            } label: {
                if isCancelling {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.red.opacity(0.7))
                        .font(.title3)
                }
            }
            .buttonStyle(.plain)
            .disabled(isCancelling)
            .accessibilityLabel("Cancel override")
            .accessibilityHint("Double tap to cancel this \(action.action) override")
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }
}

// MARK: - Limitation Row
struct LimitationRow: View {
    let icon: String
    let text: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.orange)
                .frame(width: 20)
            Text(text)
                .font(.subheadline)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
