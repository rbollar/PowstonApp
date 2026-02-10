//
//  P2PContractEntryView.swift
//  Powston
//
//  Manual entry form for P2P trading contracts
//  Supports tiered pricing with auto-calculated volumes
//

import SwiftUI

struct P2PContractEntryView: View {
    @EnvironmentObject var api: PowstonAPI
    @Environment(\.dismiss) var dismiss

    // Edit mode: pass existing contract to edit
    var existingContract: P2PContract?
    var defaultDirection: P2PTradeDirection = .sell
    var onSave: ((P2PContract) -> Void)?

    // Form state
    @State private var direction: P2PTradeDirection = .sell
    @State private var didSetInitialDirection = false
    @State private var startDate = Date()
    @State private var endDate = Date().addingTimeInterval(6 * 86400) // Default 7 days
    @State private var startHour = 17
    @State private var endHour = 20
    @State private var totalVolumeKwh: String = ""
    @State private var isRecurring = true
    @State private var renewalDays: String = "7"
    @State private var notes: String = ""
    @State private var isActive = true
    
    // Tier management (for Sell contracts)
    @State private var tierEntries: [TierEntry] = [
        TierEntry(percentage: "40", priceCents: "20"),
        TierEntry(percentage: "35", priceCents: "25"),
        TierEntry(percentage: "25", priceCents: "30")
    ]

    // Buy contract pricing (simpler - one initial price, optional second)
    @State private var buyPriceCents: String = "8"      // Initial price cap
    @State private var buySecondPriceCents: String = "" // Optional second price for future matching
    
    @State private var showSaveError = false
    @State private var saveErrorMessage = ""
    
    private let hours = Array(0...23)
    
    struct TierEntry: Identifiable {
        let id = UUID()
        var percentage: String
        var priceCents: String
    }
    
    var body: some View {
        NavigationStack {
            Form {
                dateSection
                hoursSection
                volumeSection

                // Different pricing sections for Sell vs Buy
                if direction == .sell {
                    tiersSection
                } else {
                    buyPricingSection
                }

                renewalSection
                notesSection
                
                if existingContract != nil {
                    activeSection
                }
                
                summarySection
            }
            .navigationTitle(existingContract != nil ? "Edit \(direction.displayName) Contract" : "New \(direction.displayName) Contract")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveContract() }
                        .disabled(!isFormValid)
                        .fontWeight(.semibold)
                }
            }
            .alert("Save Error", isPresented: $showSaveError) {
                Button("OK") { }
            } message: {
                Text(saveErrorMessage)
            }
            .onAppear {
                loadExistingContract()
                // Set default direction for new contracts
                if existingContract == nil && !didSetInitialDirection {
                    direction = defaultDirection
                    // Update hours based on direction
                    if defaultDirection == .buy {
                        startHour = 10
                        endHour = 16
                    }
                    didSetInitialDirection = true
                }
            }
        }
    }
    
    // MARK: - Date Section

    private var dateSection: some View {
        Section("Contract Period") {
            DatePicker("Start Date", selection: $startDate, displayedComponents: .date)
            DatePicker("End Date", selection: $endDate, displayedComponents: .date)
            
            if dayCount > 0 {
                HStack {
                    Text("Duration")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(dayCount) day\(dayCount == 1 ? "" : "s")")
                        .foregroundColor(.secondary)
                }
            }
        }
    }
    
    // MARK: - Hours Section
    
    private var hoursSection: some View {
        Section("Trading Hours (AEST)") {
            Picker("Start Hour", selection: $startHour) {
                ForEach(hours, id: \.self) { h in
                    Text(formatHour24(h)).tag(h)
                }
            }
            
            Picker("End Hour", selection: $endHour) {
                ForEach(hours, id: \.self) { h in
                    Text(formatHour24(h)).tag(h)
                }
            }
            
            if endHour > startHour {
                HStack {
                    Text("Window")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(endHour - startHour) hour\(endHour - startHour == 1 ? "" : "s")/day")
                        .foregroundColor(.secondary)
                }
            }
        }
    }
    
    // MARK: - Volume Section
    
    private var volumeSection: some View {
        Section("Total Volume") {
            HStack {
                TextField("Total kWh", text: $totalVolumeKwh)
                    .keyboardType(.decimalPad)
                Text("kWh")
                    .foregroundColor(.secondary)
            }
            
            if let total = Double(totalVolumeKwh), total > 0, dayCount > 0 {
                HStack {
                    Text("Daily")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(String(format: "%.1f kWh/day", total / Double(dayCount)))
                        .foregroundColor(.secondary)
                }
            }
        }
    }
    
    // MARK: - Tiers Section
    
    private var tiersSection: some View {
        Section {
            ForEach($tierEntries) { $entry in
                tierRow(entry: $entry)
            }
            .onDelete { indexSet in
                tierEntries.remove(atOffsets: indexSet)
            }
            
            Button(action: addTier) {
                Label("Add Tier", systemImage: "plus.circle.fill")
            }
            
            // Validation
            if let percentTotal = tierPercentageTotal, abs(percentTotal - 100) > 0.1 {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("Percentages total \(String(format: "%.0f", percentTotal))% — should be 100%")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
        } header: {
            Text("Pricing Tiers")
        } footer: {
            Text("Each tier: percentage of total volume at a fixed price. Lower tiers fill first.")
        }
    }

    // MARK: - Buy Pricing Section

    private var buyPricingSection: some View {
        Section {
            // Initial price cap - matches against existing sell offers
            HStack {
                Text("Price Cap")
                Spacer()
                HStack(spacing: 4) {
                    TextField("¢", text: $buyPriceCents)
                        .keyboardType(.decimalPad)
                        .frame(width: 50)
                        .multilineTextAlignment(.trailing)
                    Text("¢/kWh")
                        .foregroundColor(.secondary)
                }
            }

            // Explanation
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundColor(.orange)
                Text("Matches existing sell offers at or below this price")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Optional second price for future matching
            HStack {
                Text("Second Price")
                Spacer()
                HStack(spacing: 4) {
                    TextField("Optional", text: $buySecondPriceCents)
                        .keyboardType(.decimalPad)
                        .frame(width: 50)
                        .multilineTextAlignment(.trailing)
                    Text("¢/kWh")
                        .foregroundColor(.secondary)
                }
            }

            if !buySecondPriceCents.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "clock")
                        .foregroundColor(.blue)
                    Text("Second price waits for future sell offers")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        } header: {
            Text("Buy Pricing")
        } footer: {
            Text("Enter a price cap to match existing sellers. Add a second price to catch future offers.")
        }
    }

    private func tierRow(entry: Binding<TierEntry>) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                TextField("%", text: entry.percentage)
                    .keyboardType(.decimalPad)
                    .frame(width: 44)
                    .multilineTextAlignment(.trailing)
                Text("%")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
            
            HStack(spacing: 4) {
                TextField("¢", text: entry.priceCents)
                    .keyboardType(.decimalPad)
                    .frame(width: 44)
                    .multilineTextAlignment(.trailing)
                Text("¢/kWh")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
            
            Spacer()
            
            // Show calculated volume
            if let vol = tierVolume(entry.wrappedValue) {
                Text(String(format: "%.1f kWh", vol))
                    .font(.caption)
                    .foregroundColor(.purple)
            }
        }
    }
    
    // MARK: - Renewal Section
    
    private var renewalSection: some View {
        Section("Renewal") {
            Toggle("Auto-renewing", isOn: $isRecurring)
            
            if isRecurring {
                HStack {
                    Text("Every")
                    TextField("Days", text: $renewalDays)
                        .keyboardType(.numberPad)
                        .frame(width: 50)
                        .multilineTextAlignment(.center)
                    Text("days")
                        .foregroundColor(.secondary)
                }
            }
        }
    }
    
    // MARK: - Notes Section
    
    private var notesSection: some View {
        Section("Notes") {
            TextField("Optional notes", text: $notes, axis: .vertical)
                .lineLimit(3...6)
        }
    }
    
    // MARK: - Active Section (edit mode only)
    
    private var activeSection: some View {
        Section {
            Toggle("Active Contract", isOn: $isActive)
        } footer: {
            Text("Only one contract can be active per site. Activating this will deactivate others.")
        }
    }
    
    // MARK: - Summary Section
    
    private var summarySection: some View {
        Section("Summary") {
            if let total = Double(totalVolumeKwh), total > 0 {
                let tiers = buildTiers()
                let amount = tiers.reduce(0) { $0 + $1.estimatedRevenue }
                let blended = total > 0 ? (amount / total) * 100 : 0

                if direction == .sell {
                    // Sell contract summary
                    HStack {
                        Text("Estimated Revenue")
                        Spacer()
                        Text(String(format: "$%.2f", amount))
                            .fontWeight(.semibold)
                            .foregroundColor(.green)
                    }

                    HStack {
                        Text("Blended Price")
                        Spacer()
                        Text(String(format: "%.2f¢/kWh", blended))
                            .foregroundColor(.purple)
                    }

                    if dayCount > 0 {
                        HStack {
                            Text("Daily Revenue")
                            Spacer()
                            Text(String(format: "$%.2f/day", amount / Double(dayCount)))
                                .foregroundColor(.secondary)
                        }
                    }
                } else {
                    // Buy contract summary
                    HStack {
                        Text("Max Cost")
                        Spacer()
                        Text(String(format: "$%.2f", amount))
                            .fontWeight(.semibold)
                            .foregroundColor(.orange)
                    }

                    HStack {
                        Text("Price Cap")
                        Spacer()
                        Text(String(format: "%.2f¢/kWh", blended))
                            .foregroundColor(.orange)
                    }

                    if dayCount > 0 {
                        HStack {
                            Text("Daily Max")
                            Spacer()
                            Text(String(format: "$%.2f/day", amount / Double(dayCount)))
                                .foregroundColor(.secondary)
                        }
                    }

                    // Hedge value note
                    HStack(spacing: 8) {
                        Image(systemName: "shield.checkered")
                            .foregroundColor(.blue)
                        Text("Unfilled volume falls back to spot price")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            } else {
                Text(direction == .sell
                    ? "Enter volume and tier details to see summary"
                    : "Enter volume and price cap to see summary")
                    .foregroundColor(.secondary)
            }
        }
    }
    
    // MARK: - Helpers
    
    private var dayCount: Int {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: startDate, to: endDate).day ?? 0
        return max(1, days + 1)
    }
    
    private var tierPercentageTotal: Double? {
        let total = tierEntries.compactMap { Double($0.percentage) }.reduce(0, +)
        return tierEntries.isEmpty ? nil : total
    }
    
    private func tierVolume(_ entry: TierEntry) -> Double? {
        guard let pct = Double(entry.percentage),
              let total = Double(totalVolumeKwh),
              total > 0 else { return nil }
        return total * pct / 100.0
    }
    
    private var isFormValid: Bool {
        guard let total = Double(totalVolumeKwh), total > 0 else { return false }
        guard endDate >= startDate else { return false }
        guard endHour > startHour else { return false }

        if direction == .sell {
            // Sell contracts need valid tier entries
            guard !tierEntries.isEmpty else { return false }
            for entry in tierEntries {
                guard let pct = Double(entry.percentage), pct > 0,
                      let price = Double(entry.priceCents), price > 0 else {
                    return false
                }
            }
        } else {
            // Buy contracts need at least the initial price
            guard let price = Double(buyPriceCents), price >= 0 else { return false }
        }

        return true
    }

    private func buildTiers() -> [P2PContractTier] {
        guard let total = Double(totalVolumeKwh), total > 0 else { return [] }

        if direction == .sell {
            // Sell: use tier entries
            return tierEntries.compactMap { entry in
                guard let pct = Double(entry.percentage), pct > 0,
                      let price = Double(entry.priceCents), price > 0 else {
                    return nil
                }
                return P2PContractTier(
                    percentage: pct,
                    priceCents: price,
                    volumeKwh: total * pct / 100.0
                )
            }
        } else {
            // Buy: create tiers from buy prices
            var tiers: [P2PContractTier] = []

            if let price1 = Double(buyPriceCents), price1 >= 0 {
                let hasSecond = Double(buySecondPriceCents) != nil && !buySecondPriceCents.isEmpty
                let pct1 = hasSecond ? 50.0 : 100.0  // Split if two prices

                tiers.append(P2PContractTier(
                    percentage: pct1,
                    priceCents: price1,
                    volumeKwh: total * pct1 / 100.0
                ))

                if let price2 = Double(buySecondPriceCents), price2 >= 0 {
                    tiers.append(P2PContractTier(
                        percentage: 50.0,
                        priceCents: price2,
                        volumeKwh: total * 50.0 / 100.0
                    ))
                }
            }

            return tiers
        }
    }
    
    private func addTier() {
        tierEntries.append(TierEntry(percentage: "", priceCents: ""))
    }
    
    private func formatHour24(_ hour: Int) -> String {
        String(format: "%02d:00", hour)
    }
    
    // MARK: - Load Existing
    
    private func loadExistingContract() {
        guard let contract = existingContract else { return }

        direction = contract.direction
        startDate = contract.startDate
        endDate = contract.endDate
        startHour = contract.startHour
        endHour = contract.endHour
        totalVolumeKwh = String(format: "%.2f", contract.totalVolumeKwh)
        isActive = contract.isActive
        notes = contract.notes ?? ""
        
        if let days = contract.renewalDays {
            isRecurring = true
            renewalDays = "\(days)"
        } else {
            isRecurring = false
        }
        
        if contract.direction == .sell {
            // Load sell tiers
            tierEntries = contract.tiers.map { tier in
                TierEntry(
                    percentage: String(format: "%.0f", tier.percentage),
                    priceCents: String(format: "%.0f", tier.priceCents)
                )
            }
        } else {
            // Load buy prices from tiers
            let sortedTiers = contract.tiers.sorted { $0.priceCents < $1.priceCents }
            if let first = sortedTiers.first {
                buyPriceCents = String(format: "%.0f", first.priceCents)
            }
            if sortedTiers.count > 1, let second = sortedTiers.dropFirst().first {
                buySecondPriceCents = String(format: "%.0f", second.priceCents)
            }
        }
    }
    
    // MARK: - Save
    
    private func saveContract() {
        guard let siteId = api.selectedSite?.id else {
            saveErrorMessage = "No site selected"
            showSaveError = true
            return
        }
        
        guard let total = Double(totalVolumeKwh), total > 0 else {
            saveErrorMessage = "Invalid volume"
            showSaveError = true
            return
        }
        
        // Normalize dates to AEST day boundaries
        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()
        let normalizedStart = calendar.startOfDay(for: startDate)
        let normalizedEnd = calendar.startOfDay(for: endDate)
            .addingTimeInterval(86400 - 1)
        
        let contract = P2PContract(
            id: existingContract?.id ?? UUID(),
            siteId: siteId,
            direction: direction,
            startDate: normalizedStart,
            endDate: normalizedEnd,
            startHour: startHour,
            endHour: endHour,
            tiers: buildTiers(),
            totalVolumeKwh: total,
            renewalDays: isRecurring ? Int(renewalDays) : nil,
            isActive: isActive,
            createdAt: existingContract?.createdAt ?? Date(),
            notes: notes.isEmpty ? nil : notes
        )
        
        let success = PowstonDataStore.shared.saveP2PContract(contract)
        
        if success {
            onSave?(contract)
            dismiss()
        } else {
            saveErrorMessage = "Failed to save contract"
            showSaveError = true
        }
    }
}

// MARK: - Preview

#Preview {
    P2PContractEntryView()
        .environmentObject(PowstonAPI())
}
