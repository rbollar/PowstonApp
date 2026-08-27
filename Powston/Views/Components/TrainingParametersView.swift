//
//  TrainingParametersView.swift
//  Powston
//
//  View for editing Magic Mode tuning parameters
//

import SwiftUI

struct TrainingParametersView: View {
    @EnvironmentObject var api: PowstonAPI
    @Environment(\.dismiss) var dismiss
    
    let siteId: Int
    let siteName: String
    
    @State private var params = TrainingParameters.empty
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var hasChanges = false
    
    // Editable text fields for manual entry
    @State private var editingField: String? = nil
    @State private var editText = ""
    
    var body: some View {
        NavigationStack {
            List {
                // Warning banner
                Section {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(.blue)
                            .font(.title3)
                        Text("These parameters are suggestions for the AI. They will be used in the next training run and may be overwritten as the system learns optimal values.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                
                // Magic Mode Tunables
                Section {
                    parameterRow(
                        title: "Minimum SOC",
                        value: $params.minSoc,
                        range: 0...100,
                        unit: "%",
                        description: "Minimum battery state of charge (%) to keep in reserve for outages",
                        fieldKey: "minSoc"
                    )
                    
                    parameterRow(
                        title: "C-Rating",
                        value: $params.cRating,
                        range: 1...10,
                        unit: "",
                        description: "How many 30 minute intervals to fully charge/discharge the battery (forecast based)",
                        fieldKey: "cRating"
                    )
                    
                    parameterRow(
                        title: "Overnight SOC Needed",
                        value: $params.batterySocNeeded,
                        range: 0...100,
                        unit: "%",
                        description: "Battery SOC needed for overnight house use",
                        fieldKey: "batterySocNeeded"
                    )
                    
                    parameterRow(
                        title: "AC Overnight SOC",
                        value: $params.batterySocAc,
                        range: 0...100,
                        unit: "%",
                        description: "Battery SOC reserved for AC at night (increases on hot nights over 30°C)",
                        fieldKey: "batterySocAc"
                    )
                    
                    parameterRow(
                        title: "Always Import SOC",
                        value: $params.alwaysImportSoc,
                        range: 0...100,
                        unit: "%",
                        description: "Battery level at which to always import energy (numbers over 20% are for homes with insufficient solar)",
                        fieldKey: "alwaysImportSoc"
                    )
                    
                    parameterRow(
                        title: "Default Export Price",
                        value: $params.defaultExport,
                        range: 0...100,
                        unit: "¢/kWh",
                        description: "Suggested sell price (adjusted by forecast). Not an absolute value but a guide for the AI to start - lower this for more aggressive exporting.",
                        fieldKey: "defaultExport"
                    )
                    
                    parameterRow(
                        title: "Import Factor",
                        value: $params.importFactor,
                        range: 0...200,
                        unit: "%",
                        description: "Multiplier for import decisions. Higher values make the system more willing to import energy.",
                        fieldKey: "importFactor"
                    )
                    
                } header: {
                    Label("Magic Mode Tunables", systemImage: "wand.and.stars")
                }

            }
            .navigationTitle("Tuning Parameters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await saveParameters() }
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text("Save")
                        }
                    }
                    .disabled(isSaving || !hasChanges)
                }
            }
            .overlay {
                if isLoading {
                    ProgressView("Loading parameters...")
                        .padding()
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .alert("Error", isPresented: $showError) {
                Button("OK") { }
            } message: {
                Text(errorMessage)
            }
            .task {
                await loadParameters()
            }
        }
    }
    
    // MARK: - Parameter Row
    
    @ViewBuilder
    private func parameterRow(
        title: String,
        value: Binding<Int?>,
        range: ClosedRange<Int>,
        unit: String,
        description: String,
        fieldKey: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                
                // Tappable value for manual entry
                Button {
                    editingField = fieldKey
                    editText = value.wrappedValue.map { String($0) } ?? ""
                } label: {
                    HStack(spacing: 2) {
                        Text(value.wrappedValue.map { "\($0)" } ?? "—")
                            .font(.headline)
                            .foregroundStyle(.blue)
                        if !unit.isEmpty {
                            Text(unit)
                                .font(.subheadline)
                                .foregroundStyle(.blue)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            
            // Slider
            Slider(
                value: Binding(
                    get: { Double(value.wrappedValue ?? range.lowerBound) },
                    set: { 
                        value.wrappedValue = Int($0)
                        hasChanges = true
                    }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: 1
            )
            .tint(.blue)
            
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .alert("Enter \(title)", isPresented: Binding(
            get: { editingField == fieldKey },
            set: { if !$0 { editingField = nil } }
        )) {
            TextField("Value", text: $editText)
                .keyboardType(.numberPad)
            Button("Cancel", role: .cancel) {
                editingField = nil
            }
            Button("OK") {
                if let newValue = Int(editText) {
                    let clamped = min(max(newValue, range.lowerBound), range.upperBound)
                    value.wrappedValue = clamped
                    hasChanges = true
                }
                editingField = nil
            }
        } message: {
            Text("Enter a value between \(range.lowerBound) and \(range.upperBound)")
        }
    }
    
    // MARK: - Helpers

    private func formatHour(_ hour: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h a"
        var components = DateComponents()
        components.hour = hour
        if let date = Calendar.current.date(from: components) {
            return formatter.string(from: date)
        }
        return "\(hour):00"
    }

    // MARK: - Load/Save

    private func loadParameters() async {
        isLoading = true
        if let loaded = await api.fetchTrainingParameters(siteId: siteId) {
            await MainActor.run {
                params = loaded
                isLoading = false
            }
        } else {
            await MainActor.run {
                // Use defaults if fetch fails
                params = TrainingParameters.empty
                isLoading = false
            }
        }
    }
    
    private func saveParameters() async {
        isSaving = true
        let result = await api.updateTrainingParameters(siteId: siteId, params: params)
        
        await MainActor.run {
            isSaving = false
            switch result {
            case .success:
                hasChanges = false
                dismiss()
            case .failure(let error):
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }
}

#Preview {
    TrainingParametersView(siteId: 65, siteName: "Demo Site")
        .environmentObject(PowstonAPI())
}
