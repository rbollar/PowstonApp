//
//  MapViews.swift
//  Powston
//

import SwiftUI
import MapKit

// MARK: - Site Detail View
struct SiteDetailView: View {
    let site: Site
    @EnvironmentObject var api: PowstonAPI
    @State private var position: MapCameraPosition
    
    // Editable fields
    @State private var editedDisplayName: String = ""
    @State private var editedPvoutputApiKey: String = ""
    @State private var isEditingDisplayName = false
    @State private var isEditingPvoutputApiKey = false
    
    // Alerts and sheets
    @State private var showHAWarning = false
    @State private var showMqttInfo = false
    @State private var showPvoutputInfo = false
    @State private var showSaveError = false
    @State private var saveErrorMessage = ""
    @State private var isSaving = false
    
    init(site: Site) {
        self.site = site
        _position = State(initialValue: .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: site.latitude ?? -26.5,
                longitude: site.longitude ?? 153.0
            ),
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )))
        _editedDisplayName = State(initialValue: site.displayName ?? site.name)
        _editedPvoutputApiKey = State(initialValue: site.pvoutputApiKey ?? "")
    }
    
    var siteInverters: [Inverter] {
        api.inverters.filter { $0.siteId == site.id }
    }
    
    var hasDisplayNameChanged: Bool {
        editedDisplayName != (site.displayName ?? site.name) && !editedDisplayName.isEmpty
    }
    
    var hasPvoutputApiKeyChanged: Bool {
        editedPvoutputApiKey != (site.pvoutputApiKey ?? "")
    }
    
    var body: some View {
        List {
            // Map Section
            if site.latitude != nil && site.longitude != nil {
                Section {
                    Map(position: $position) {
                        Marker(site.displayName ?? site.name, coordinate: CLLocationCoordinate2D(
                            latitude: site.latitude!,
                            longitude: site.longitude!
                        ))
                        .tint(.green)
                    }
                    .frame(height: 180)
                    .cornerRadius(12)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }
            
            // Site Info Section
            Section("Site Information") {
                // Editable Display Name
                HStack {
                    Text("Name")
                        .foregroundColor(.secondary)
                    Spacer()
                    if isEditingDisplayName {
                        TextField("Display Name", text: $editedDisplayName)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 180)
                            .multilineTextAlignment(.trailing)
                        Button("Done") {
                            if hasDisplayNameChanged {
                                if site.haPublish == true {
                                    showHAWarning = true
                                } else {
                                    saveDisplayName()
                                }
                            } else {
                                isEditingDisplayName = false
                            }
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                    } else {
                        Text(site.displayName ?? site.name)
                        Button(action: { isEditingDisplayName = true }) {
                            Image(systemName: "pencil")
                                .font(.caption)
                                .foregroundColor(.blue)
                        }
                        .buttonStyle(.plain)
                    }
                }
                
                InfoRow(label: "State", value: site.state ?? "–")
                InfoRow(label: "Network", value: (site.network ?? "–").capitalized)
                if let location = site.location {
                    InfoRow(label: "Address", value: location)
                }
                if let timezone = site.timezone {
                    InfoRow(label: "Timezone", value: timezone)
                }
                if let brand = site.brand {
                    InfoRow(label: "Brand", value: brand)
                }
            }
            
            // Capacity Section
            Section("System Capacity") {
                if let solar = site.installedSolar {
                    InfoRow(label: "Solar", value: formatPower(solar), color: .yellow)
                }
                if let battery = site.installedBattery {
                    InfoRow(label: "Battery", value: formatEnergy(battery), color: .green)
                }
//                if let gridLimit = site.gridPowerLimit {
//                    InfoRow(label: "Grid Export Limit", value: formatPower(gridLimit), color: .blue)
//                }
                if let inverterPower = site.inverterPower {
                    InfoRow(label: "Inverter Power", value: formatPower(inverterPower), color: .orange)
                }
            }
            
            // Tariffs Section
            Section("Tariffs") {
                if let tariff = site.tariff {
                    InfoRow(label: "Import Tariff", value: tariff)
                }
                if let exportTariff = site.exportTariff {
                    InfoRow(label: "Export Tariff", value: exportTariff)
                }
                
                // Retailer detection
                if let retailer = site.retailerName {
                    InfoRow(label: "Retailer", value: retailer, color: site.isLocalVoltsSite ? .purple : .orange)
                }
            }
            
            // Status Section
            Section("Status") {
                HStack {
                    Text("Controlled")
                    Spacer()
                    Image(systemName: site.controlled == true ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundColor(site.controlled == true ? .green : .secondary)
                }
                HStack {
                    Text("Home Assistant")
                    Spacer()
                    Image(systemName: site.haPublish == true ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundColor(site.haPublish == true ? .green : .secondary)
                }
                if site.pvoutputSiteId != nil {
                    HStack {
                        Text("PVOutput")
                        Spacer()
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    }
                }
                HStack {
                    Text("Read Only")
                    Spacer()
                    Image(systemName: site.readOnly == true ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundColor(site.readOnly == true ? .orange : .secondary)
                }
            }
            
            // Credentials Section
            Section {
                // MQTT credentials with info button
                if site.mqttUser != nil || site.mqttPassword != nil {
                    HStack {
                        Text("MQTT")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Button(action: { showMqttInfo = true }) {
                            Image(systemName: "info.circle")
                                .font(.caption)
                                .foregroundColor(.blue)
                        }
                        .buttonStyle(.plain)
                        Spacer()
                    }
                    
                    if let mqttUser = site.mqttUser {
                        InfoRow(label: "User", value: mqttUser)
                    }
                    if let mqttPassword = site.mqttPassword {
                        MaskedCredentialRow(label: "Password", value: mqttPassword)
                    }
                }
                
                // PVOutput credentials with info button
                if site.pvoutputSiteId != nil || site.pvoutputApiKey != nil || !editedPvoutputApiKey.isEmpty {
                    if site.mqttUser != nil || site.mqttPassword != nil {
                        Divider()
                    }
                    
                    HStack {
                        Text("PVOutput")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Button(action: { showPvoutputInfo = true }) {
                            Image(systemName: "info.circle")
                                .font(.caption)
                                .foregroundColor(.blue)
                        }
                        .buttonStyle(.plain)
                        Spacer()
                    }
                    
                    if let siteId = site.pvoutputSiteId {
                        InfoRow(label: "Site ID", value: "\(siteId)")
                    }
                    
                    // Editable PVOutput API Key
                    EditableCredentialRow(
                        label: "API Key",
                        value: $editedPvoutputApiKey,
                        isEditing: $isEditingPvoutputApiKey,
                        hasChanged: hasPvoutputApiKeyChanged,
                        isSaving: isSaving,
                        onSave: savePvoutputApiKey
                    )
                }
            } header: {
                Text("Credentials")
            } footer: {
                if site.mqttUser != nil {
                    Text("MQTT credentials are read-only. PVOutput API key can be edited.")
                        .font(.caption)
                }
            }
            
            // Inverters Section
            if !siteInverters.isEmpty {
                Section("Inverters (\(siteInverters.count))") {
                    ForEach(siteInverters) { inverter in
                        InverterDetailCard(inverter: inverter)
                    }
                }
            }
            
            // Control Link
            Section {
                NavigationLink(destination: ManualOverrideView()) {
                    HStack {
                        Image(systemName: "slider.horizontal.3")
                            .foregroundColor(.blue)
                        Text("Manual Control")
                    }
                }
            }
        }
        .navigationTitle(site.displayName ?? site.name)
        .navigationBarTitleDisplayMode(.inline)
        .alert("Home Assistant Warning", isPresented: $showHAWarning) {
            Button("Cancel", role: .cancel) { }
            Button("Rename Anyway") { saveDisplayName() }
        } message: {
            Text("This site has Home Assistant integration enabled. Renaming may require reconfiguring your Home Assistant setup to match the new name.")
        }
        .alert("Save Error", isPresented: $showSaveError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(saveErrorMessage)
        }
        .sheet(isPresented: $showMqttInfo) {
            MqttInfoSheet()
        }
        .sheet(isPresented: $showPvoutputInfo) {
            PvoutputInfoSheet()
        }
    }
    
    func saveDisplayName() {
        guard hasDisplayNameChanged else {
            isEditingDisplayName = false
            return
        }
        
        isSaving = true
        Task {
            let result = await api.updateSite(siteId: site.id, displayName: editedDisplayName)
            await MainActor.run {
                isSaving = false
                switch result {
                case .success:
                    isEditingDisplayName = false
                case .failure(let error):
                    saveErrorMessage = error.localizedDescription
                    showSaveError = true
                }
            }
        }
    }
    
    func savePvoutputApiKey() {
        guard hasPvoutputApiKeyChanged else {
            isEditingPvoutputApiKey = false
            return
        }
        
        isSaving = true
        Task {
            let result = await api.updateSite(siteId: site.id, pvoutputApiKey: editedPvoutputApiKey)
            await MainActor.run {
                isSaving = false
                switch result {
                case .success:
                    isEditingPvoutputApiKey = false
                case .failure(let error):
                    saveErrorMessage = error.localizedDescription
                    showSaveError = true
                }
            }
        }
    }
    
    func formatPower(_ watts: Int) -> String {
        if watts >= 1000 {
            return String(format: "%.1f kW", Double(watts) / 1000)
        }
        return "\(watts) W"
    }
    
    func formatEnergy(_ wattHours: Int) -> String {
        if wattHours >= 1000 {
            return String(format: "%.1f kWh", Double(wattHours) / 1000)
        }
        return "\(wattHours) Wh"
    }
}

// MARK: - Editable Credential Row
struct EditableCredentialRow: View {
    let label: String
    @Binding var value: String
    @Binding var isEditing: Bool
    let hasChanged: Bool
    let isSaving: Bool
    let onSave: () -> Void
    
    @State private var isRevealed = false
    
    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            
            if isEditing {
                if isRevealed {
                    TextField("", text: $value)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: 160)
                        .multilineTextAlignment(.trailing)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                } else {
                    SecureField("", text: $value)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 160)
                        .multilineTextAlignment(.trailing)
                }
                
                Button(action: { isRevealed.toggle() }) {
                    Image(systemName: isRevealed ? "eye.slash" : "eye")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                
                if isSaving {
                    ProgressView()
                        .scaleEffect(0.7)
                } else {
                    Button("Save") { onSave() }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .disabled(!hasChanged)
                }
            } else {
                if value.isEmpty {
                    Text("Not set")
                        .foregroundColor(.secondary)
                        .italic()
                } else if isRevealed {
                    Text(value)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                } else {
                    Text(String(repeating: "•", count: min(value.count, 16)))
                        .foregroundColor(.secondary)
                }
                
                if !value.isEmpty {
                    Button(action: { isRevealed.toggle() }) {
                        Image(systemName: isRevealed ? "eye.slash" : "eye")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                
                Button(action: { isEditing = true }) {
                    Image(systemName: "pencil")
                        .font(.caption)
                        .foregroundColor(.blue)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - MQTT Info Sheet
struct MqttInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("MQTT Integration")
                        .font(.title2)
                        .fontWeight(.bold)
                    
                    Text("MQTT (Message Queuing Telemetry Transport) allows Powston to publish your solar system data to Home Assistant or other smart home platforms.")
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Real-time data updates", systemImage: "bolt.fill")
                        Label("Home Assistant integration", systemImage: "house.fill")
                        Label("Custom automations", systemImage: "gearshape.2.fill")
                    }
                    .foregroundColor(.secondary)
                    
                    Divider()
                    
                    Text("Setup Guide")
                        .font(.headline)
                    
                    Text("Use these credentials to configure the MQTT integration in Home Assistant. The broker address and port are provided in the Powston documentation.")
                    
                    Link(destination: URL(string: "https://powston.com.au/blog/using-powston-in-home-assistant")!) {
                        HStack {
                            Image(systemName: "book.fill")
                            Text("View Setup Guide")
                            Spacer()
                            Image(systemName: "arrow.up.right")
                        }
                        .padding()
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(10)
                    }
                }
                .padding()
            }
            .navigationTitle("MQTT")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - PVOutput Info Sheet
struct PvoutputInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("PVOutput Integration")
                        .font(.title2)
                        .fontWeight(.bold)
                    
                    Text("PVOutput.org is a free service for sharing and comparing photovoltaic solar panel output data.")
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Track generation history", systemImage: "chart.line.uptrend.xyaxis")
                        Label("Compare with neighbors", systemImage: "person.2.fill")
                        Label("Public or private data", systemImage: "lock.shield.fill")
                        Label("Detailed analytics", systemImage: "chart.bar.fill")
                    }
                    .foregroundColor(.secondary)
                    
                    Divider()
                    
                    Text("API Key")
                        .font(.headline)
                    
                    Text("Your PVOutput API key allows Powston to upload your generation data automatically. You can find or generate your API key in your PVOutput account settings.")
                    
                    Link(destination: URL(string: "https://pvoutput.org")!) {
                        HStack {
                            Image(systemName: "sun.max.fill")
                            Text("Visit PVOutput.org")
                            Spacer()
                            Image(systemName: "arrow.up.right")
                        }
                        .padding()
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(10)
                    }
                }
                .padding()
            }
            .navigationTitle("PVOutput")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Inverter Detail Card (with View Code button)
struct InverterDetailCard: View {
    @EnvironmentObject var api: PowstonAPI
    let inverter: Inverter
    @State private var showingCode = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: inverter.id == api.selectedInverterId ? "bolt.circle.fill" : "bolt.circle")
                    .foregroundColor(inverter.id == api.selectedInverterId ? .green : .orange)
                Text("\(inverter.manufacturer) \(inverter.productName)")
                    .fontWeight(.medium)
                Spacer()
                if inverter.id == api.selectedInverterId {
                    Text("Active")
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }
            
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Serial:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(inverter.serialNumber)
                        .font(.caption.monospaced())
                }
                
                HStack(spacing: 16) {
                    if let battery = inverter.batteryCapacity, battery > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "battery.100")
                                .font(.caption)
                                .foregroundColor(.green)
                            Text(formatEnergy(battery))
                                .font(.caption)
                        }
                    }
                    if let pv = inverter.pvCapacity, pv > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "sun.max.fill")
                                .font(.caption)
                                .foregroundColor(.yellow)
                            Text(formatPower(pv))
                                .font(.caption)
                        }
                    }
                    if let phases = inverter.phases {
                        HStack(spacing: 4) {
                            Image(systemName: "waveform")
                                .font(.caption)
                                .foregroundColor(.blue)
                            Text("\(phases)φ")
                                .font(.caption)
                        }
                    }
                }
            }
            
            // View Code Button
            Button {
                showingCode = true
            } label: {
                Label("View User Code", systemImage: "doc.text")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.top, 4)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            if inverter.id != api.selectedInverterId {
                api.selectedInverterId = inverter.id
                Task { await api.fetchData() }
            }
        }
        .fullScreenCover(isPresented: $showingCode) {
            UserCodeView(inverterId: inverter.id, inverterName: inverter.productName)
        }
    }
    
    func formatPower(_ watts: Int) -> String {
        if watts >= 1000 {
            return String(format: "%.1f kW", Double(watts) / 1000)
        }
        return "\(watts) W"
    }
    
    func formatEnergy(_ wattHours: Int) -> String {
        if wattHours >= 1000 {
            return String(format: "%.1f kWh", Double(wattHours) / 1000)
        }
        return "\(wattHours) Wh"
    }
}

// MARK: - User Code View (Full Screen)
struct UserCodeView: View {
    @EnvironmentObject var api: PowstonAPI
    @Environment(\.dismiss) var dismiss
    
    let inverterId: Int
    let inverterName: String
    
    @State private var code: String?
    @State private var isLoading = true
    @State private var error: String?
    @State private var copied = false
    
    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    VStack(spacing: 16) {
                        ProgressView()
                        Text("Loading user code...")
                            .foregroundColor(.secondary)
                    }
                } else if let error = error {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundColor(.orange)
                        Text(error)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        
                        Button("Retry") {
                            Task { await loadCode() }
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding()
                } else if let code = code {
                    ScrollView([.horizontal, .vertical]) {
                        Text(code)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .padding()
                    }
                    .background(Color(.systemBackground))
                } else {
                    Text("No code available")
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Inverter \(String(inverterId))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                }
                
                if code != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            UIPasteboard.general.string = code
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                copied = false
                            }
                        } label: {
                            Label(copied ? "Copied!" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                    }
                }
            }
        }
        .task {
            await loadCode()
        }
        .onAppear {
            OrientationManager.shared.allowLandscape()
        }
        .onDisappear {
            OrientationManager.shared.lockToPortrait()
        }
    }
    
    func loadCode() async {
        isLoading = true
        error = nil
        
        if let fetchedCode = await api.fetchCurrentUserCode(inverterId: inverterId) {
            code = fetchedCode
        } else {
            error = "Failed to load user code for inverter \(inverterId)"
        }
        
        isLoading = false
    }
}

// MARK: - Info Row Helper
struct InfoRow: View {
    let label: String
    let value: String
    var color: Color = .primary
    
    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .foregroundColor(color)
        }
    }
}

// MARK: - Masked Credential Row (read-only, hidden by default)
struct MaskedCredentialRow: View {
    let label: String
    let value: String
    @State private var isRevealed = false
    
    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            if isRevealed {
                Text(value)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            } else {
                Text(String(repeating: "•", count: min(value.count, 16)))
                    .foregroundColor(.secondary)
            }
            Button(action: { isRevealed.toggle() }) {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - All Sites Map View
struct AllSitesMapView: View {
    let sites: [Site]
    @State private var position: MapCameraPosition
    @State private var selectedSite: Site?
    
    init(sites: [Site]) {
        self.sites = sites
        
        let validSites = sites.filter { $0.latitude != nil && $0.longitude != nil }
        
        if validSites.isEmpty {
            _position = State(initialValue: .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: -25.0, longitude: 135.0),
                span: MKCoordinateSpan(latitudeDelta: 30, longitudeDelta: 30)
            )))
        } else if validSites.count == 1 {
            _position = State(initialValue: .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(
                    latitude: validSites[0].latitude!,
                    longitude: validSites[0].longitude!
                ),
                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
            )))
        } else {
            let lats = validSites.compactMap { $0.latitude }
            let lons = validSites.compactMap { $0.longitude }
            
            let minLat = lats.min()!, maxLat = lats.max()!
            let minLon = lons.min()!, maxLon = lons.max()!
            
            let centerLat = (minLat + maxLat) / 2
            let centerLon = (minLon + maxLon) / 2
            let spanLat = (maxLat - minLat) * 1.5 + 0.1
            let spanLon = (maxLon - minLon) * 1.5 + 0.1
            
            _position = State(initialValue: .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon),
                span: MKCoordinateSpan(latitudeDelta: max(spanLat, 0.05), longitudeDelta: max(spanLon, 0.05))
            )))
        }
    }
    
    var body: some View {
        ZStack(alignment: .bottom) {
            Map(position: $position) {
                ForEach(sites.filter { $0.latitude != nil && $0.longitude != nil }) { site in
                    Annotation(site.displayName ?? site.name, coordinate: CLLocationCoordinate2D(
                        latitude: site.latitude!,
                        longitude: site.longitude!
                    )) {
                        SiteMapPin(site: site, isSelected: selectedSite?.id == site.id)
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    if selectedSite?.id == site.id {
                                        selectedSite = nil
                                    } else {
                                        selectedSite = site
                                    }
                                }
                            }
                    }
                }
            }
            .ignoresSafeArea(edges: .top)
            
            if let site = selectedSite {
                SiteInfoCard(site: site, onClose: { selectedSite = nil })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding()
            }
            
            if selectedSite == nil {
                VStack {
                    Spacer()
                    SitesLegend(sites: sites)
                        .padding()
                }
            }
        }
        .navigationTitle("All Sites")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button(action: fitAllSites) {
                        Label("Fit All Sites", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                    Divider()
                    ForEach(sites.filter { $0.latitude != nil }) { site in
                        Button(action: { zoomToSite(site) }) {
                            Label(site.displayName ?? site.name, systemImage: "mappin")
                        }
                    }
                } label: {
                    Image(systemName: "location.magnifyingglass")
                }
            }
        }
    }
    
    func fitAllSites() {
        let validSites = sites.filter { $0.latitude != nil && $0.longitude != nil }
        guard !validSites.isEmpty else { return }
        
        let lats = validSites.compactMap { $0.latitude }
        let lons = validSites.compactMap { $0.longitude }
        
        let minLat = lats.min()!, maxLat = lats.max()!
        let minLon = lons.min()!, maxLon = lons.max()!
        
        let centerLat = (minLat + maxLat) / 2
        let centerLon = (minLon + maxLon) / 2
        let spanLat = (maxLat - minLat) * 1.5 + 0.1
        let spanLon = (maxLon - minLon) * 1.5 + 0.1
        
        withAnimation {
            position = .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon),
                span: MKCoordinateSpan(latitudeDelta: max(spanLat, 0.05), longitudeDelta: max(spanLon, 0.05))
            ))
        }
    }
    
    func zoomToSite(_ site: Site) {
        guard let lat = site.latitude, let lon = site.longitude else { return }
        withAnimation {
            position = .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
            ))
            selectedSite = site
        }
    }
}

// MARK: - Site Map Pin
struct SiteMapPin: View {
    let site: Site
    let isSelected: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(brandColor.opacity(0.2))
                    .frame(width: isSelected ? 50 : 40, height: isSelected ? 50 : 40)
                
                Circle()
                    .fill(brandColor)
                    .frame(width: isSelected ? 36 : 28, height: isSelected ? 36 : 28)
                    .shadow(color: .black.opacity(0.2), radius: 3)
                
                Image(systemName: brandIcon)
                    .font(isSelected ? .body : .caption)
                    .foregroundColor(.white)
            }
            
            Triangle()
                .fill(brandColor)
                .frame(width: 12, height: 8)
                .offset(y: -2)
            
            if isSelected {
                Text(site.displayName ?? site.name)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(.systemBackground))
                    .cornerRadius(4)
                    .shadow(color: .black.opacity(0.1), radius: 2)
                    .offset(y: 4)
            }
        }
    }
    
    var brandColor: Color {
        switch site.brand?.uppercased() {
        case "SUNGROW": return .orange
        case "GOODWE": return .blue
        case "FRONIUS": return .red
        case "TESLA": return .gray
        case "ENPHASE": return .orange
        case "SOLAREDGE": return .green
        case "DEYE": return .purple
        default: return .green
        }
    }
    
    var brandIcon: String {
        switch site.brand?.uppercased() {
        case "SUNGROW": return "sun.max.fill"
        case "TESLA": return "bolt.fill"
        default: return "bolt.fill"
        }
    }
}

// MARK: - Site Info Card
struct SiteInfoCard: View {
    let site: Site
    let onClose: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(site.displayName ?? site.name)
                        .font(.headline)
                    Text(site.location ?? site.state ?? "–")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                
                Spacer()
                
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
            }
            
            Divider()
            
            HStack(spacing: 16) {
                StatPill(icon: "bolt.fill", label: site.brand ?? "Unknown", color: .orange)
                StatPill(icon: "network", label: (site.network ?? "–").capitalized, color: .blue)
                StatPill(icon: retailerIcon, label: detectedRetailer, color: .green)
            }
            
            HStack(spacing: 20) {
                if let solar = site.installedSolar {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Solar")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(formatPower(solar))
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(.yellow)
                    }
                }
                
                if let battery = site.installedBattery {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Battery")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(formatEnergy(battery))
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(.green)
                    }
                }
                
//                if let gridLimit = site.gridPowerLimit {
//                    VStack(alignment: .leading, spacing: 2) {
//                        Text("Grid Limit")
//                            .font(.caption2)
//                            .foregroundColor(.secondary)
//                        Text(formatPower(gridLimit))
//                            .font(.subheadline)
//                            .fontWeight(.semibold)
//                            .foregroundColor(.blue)
//                    }
//                }
                
                Spacer()
            }
            
            HStack(spacing: 12) {
                if site.controlled == true {
                    StatusBadge(text: "Controlled", color: .green)
                }
                if site.haPublish == true {
                    StatusBadge(text: "HA", color: .blue)
                }
                if site.pvoutputSiteId != nil {
                    StatusBadge(text: "PVOutput", color: .orange)
                }
                Spacer()
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.15), radius: 10)
    }
    
    var detectedRetailer: String {
        site.retailerName ?? "Unknown"
    }
    
    var retailerIcon: String {
        if site.isLocalVoltsSite {
            return "bolt.circle"
        } else if site.retailerName != nil {
            return "leaf.circle"
        } else {
            return "questionmark.circle"
        }
    }
    
    func formatPower(_ watts: Int) -> String {
        if watts >= 1000 {
            return String(format: "%.1f kW", Double(watts) / 1000)
        }
        return "\(watts) W"
    }
    
    func formatEnergy(_ wattHours: Int) -> String {
        if wattHours >= 1000 {
            return String(format: "%.1f kWh", Double(wattHours) / 1000)
        }
        return "\(wattHours) Wh"
    }
}

// MARK: - Sites Legend
struct SitesLegend: View {
    let sites: [Site]
    
    var body: some View {
        HStack(spacing: 12) {
            let brands = Dictionary(grouping: sites, by: { $0.brand ?? "Unknown" })
            
            ForEach(Array(brands.keys.sorted()), id: \.self) { brand in
                HStack(spacing: 4) {
                    Circle()
                        .fill(brandColor(brand))
                        .frame(width: 10, height: 10)
                    Text("\(brand): \(brands[brand]?.count ?? 0)")
                        .font(.caption2)
                }
            }
            
            Spacer()
            
            Text("\(sites.count) sites")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .cornerRadius(10)
    }
    
    func brandColor(_ brand: String) -> Color {
        switch brand.uppercased() {
        case "SUNGROW": return .orange
        case "GOODWE": return .blue
        case "FRONIUS": return .red
        case "TESLA": return .gray
        case "ENPHASE": return .orange
        case "SOLAREDGE": return .green
        case "DEYE": return .purple
        default: return .green
        }
    }
}
