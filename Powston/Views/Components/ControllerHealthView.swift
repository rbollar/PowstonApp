//
//  ControllerHealthView.swift
//  Powston
//
//  Displays controller health, site monitors, and communication devices

import SwiftUI

struct ControllerHealthView: View {
    let site: Site
    @EnvironmentObject var api: PowstonAPI
    
    @State private var siteMonitors: [SiteMonitor] = []
    @State private var communicationDevices: [CommunicationDevice] = []
    @State private var diagnoses: [(inverter: Inverter, diagnosis: RuntimeDiagnosis)] = []
    @State private var isLoading = true
    @State private var error: String?
    
    var body: some View {
        List {
            if isLoading {
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                            .padding()
                        Spacer()
                    }
                }
            } else if let error = error {
                Section {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text(error)
                            .foregroundColor(.secondary)
                    }
                }
            } else {
                // Site Monitors (Powston Controllers)
                if !siteMonitors.isEmpty {
                    Section {
                        ForEach(siteMonitors) { monitor in
                            SiteMonitorCard(monitor: monitor, api: api)
                        }
                    } header: {
                        Text("Powston Controllers")
                    } footer: {
                        Text("ESP32-based controllers that communicate with your inverters via Modbus TCP.")
                    }
                }
                
                // Communication Devices (WiNet-S modules)
                if !communicationDevices.isEmpty {
                    Section {
                        ForEach(communicationDevices) { device in
                            CommunicationDeviceCard(device: device)
                        }
                    } header: {
                        Text("Communication Modules")
                    } footer: {
                        Text("Inverter communication modules that connect to your local network.")
                    }
                }
                
                // Powston's own runtime-data diagnosis per inverter
                if !diagnoses.isEmpty {
                    Section {
                        ForEach(diagnoses, id: \.inverter.id) { entry in
                            RuntimeDiagnosisCard(inverter: entry.inverter, diagnosis: entry.diagnosis)
                        }
                    } header: {
                        Text("Data Diagnosis")
                    } footer: {
                        Text("Powston's check of whether live data is arriving from each inverter.")
                    }
                }

                // Empty state
                if siteMonitors.isEmpty && communicationDevices.isEmpty && diagnoses.isEmpty {
                    Section {
                        HStack {
                            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                                .foregroundColor(.secondary)
                            Text("No controllers or communication devices found for this site.")
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Controller Health")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await loadData()
        }
        .task {
            await loadData()
        }
    }
    
    private func loadData() async {
        isLoading = true
        error = nil
        
        async let monitorsTask = api.fetchSiteMonitors(siteId: site.id)
        async let devicesTask = api.fetchCommunicationDevices(siteId: site.id)
        
        let (monitors, devices) = await (monitorsTask, devicesTask)

        var loadedDiagnoses: [(inverter: Inverter, diagnosis: RuntimeDiagnosis)] = []
        for inverter in api.inverters where inverter.siteId == site.id {
            if let diagnosis = await api.fetchRuntimeDiagnosis(inverterId: inverter.id) {
                loadedDiagnoses.append((inverter, diagnosis))
            }
        }
        let diagnosisResults = loadedDiagnoses
        
        await MainActor.run {
            self.siteMonitors = monitors
            self.communicationDevices = devices
            self.diagnoses = diagnosisResults
            self.isLoading = false
            
            if monitors.isEmpty && devices.isEmpty {
                // Not an error, just no devices
            }
        }
    }
}

// MARK: - Site Monitor Card
struct SiteMonitorCard: View {
    let monitor: SiteMonitor
    let api: PowstonAPI
    
    @State private var controllerHealth: ControllerHealth?
    @State private var isLoadingHealth = false
    @State private var diagnosticReport: DiagnosticReport?
    @State private var isRunningDiagnostics = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header with status
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(monitor.productName ?? "Controller")
                        .font(.headline)
                    Text(monitor.serialNumber)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // Health status indicator
                healthStatusBadge
            }
            
            Divider()
            
            // Details grid
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 8) {
                DetailRow(label: "MAC Address", value: monitor.formattedMacAddress)
                DetailRow(label: "IP Address", value: monitor.ipAddress ?? "–")
                DetailRow(label: "Firmware", value: firmwareDisplay)
                DetailRow(label: "Monitor Type", value: monitor.monitorType ?? "–")
                
                if let temp = monitor.temperature {
                    DetailRow(
                        label: "Temperature",
                        value: String(format: "%.1f°C", temp),
                        valueColor: temperatureColor(temp)
                    )
                }
                
                if let uptime = monitor.uptimeString {
                    DetailRow(label: "Uptime", value: uptime)
                }
                
                if let heap = monitor.heapMemoryKB {
                    DetailRow(label: "Free Memory", value: "\(heap) KB")
                }
                
                if let modbusIp = monitor.modbusTcpIp {
                    DetailRow(label: "Inverter IP", value: modbusIp)
                }
            }
            
            // Modbus connection info
            if let modbusType = monitor.modbusType {
                HStack(spacing: 4) {
                    Image(systemName: "network")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("\(modbusType) • Port \(monitor.modbusTcpPort ?? 502) • Device ID \(monitor.modbusSlaveId ?? 1)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            // MARK: - Network Diagnostics Section
            Divider()
            
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Local Network Test")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    Button {
                        Task { await runDiagnostics() }
                    } label: {
                        HStack(spacing: 4) {
                            if isRunningDiagnostics {
                                ProgressView()
                                    .scaleEffect(0.7)
                            } else {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                    .font(.caption)
                            }
                            Text(isRunningDiagnostics ? "Testing..." : "Test")
                                .font(.caption)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isRunningDiagnostics)
                }
                
                if let report = diagnosticReport {
                    diagnosticResultsView(report)
                } else {
                    Text("Tap Test to check reachability from your device")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .task {
            await loadControllerHealth()
        }
    }
    
    // MARK: - Diagnostic Results View
    @ViewBuilder
    private func diagnosticResultsView(_ report: DiagnosticReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Individual results
            HStack(spacing: 12) {
                if let controller = report.controllerResult {
                    resultBadge(controller)
                }
                if let modbus = report.modbusResult {
                    resultBadge(modbus)
                }
                if let portal = report.portalResult, portal.success {
                    resultBadge(portal)
                }
            }
            
            // Timestamp
            Text("Tested \(report.timestamp.formatted(date: .omitted, time: .shortened))")
                .font(.caption2)
                .foregroundColor(.secondary)
            
            // Help text if nothing reachable
            if !report.isOnLocalNetwork {
                HStack(spacing: 4) {
                    Image(systemName: "info.circle")
                        .font(.caption2)
                    Text("Ensure you're on the same network as your inverters")
                        .font(.caption2)
                }
                .foregroundColor(.orange)
            }
        }
    }
    
    @ViewBuilder
    private func resultBadge(_ result: NetworkTestResult) -> some View {
        HStack(spacing: 3) {
            Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.caption2)
            Text(result.testType.rawValue)
                .font(.caption2)
            if let ms = result.latencyMs {
                Text("\(ms)ms")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .foregroundColor(result.success ? .green : .red)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(result.success ? Color.green.opacity(0.1) : Color.red.opacity(0.1))
        .cornerRadius(6)
    }
    
    private func runDiagnostics() async {
        isRunningDiagnostics = true
        
        let report = await NetworkDiagnosticService.shared.runDiagnostics(
            controllerIP: monitor.ipAddress,
            inverterIP: monitor.modbusTcpIp,
            modbusPort: monitor.modbusTcpPort ?? 502
        )
        
        diagnosticReport = report
        isRunningDiagnostics = false
    }
    
    private var healthStatusBadge: some View {
        Group {
            if isLoadingHealth {
                ProgressView()
                    .scaleEffect(0.7)
            } else if monitor.isHealthy {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                    Text("Online")
                        .font(.caption)
                        .foregroundColor(.green)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.green.opacity(0.1))
                .cornerRadius(8)
            } else {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 8, height: 8)
                    Text(monitor.healthStatus)
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(8)
            }
        }
    }
    
    private var firmwareDisplay: String {
        if monitor.hasPendingUpdate {
            return "\(monitor.firmwareVersion ?? "–") → \(monitor.pendingFirmwareVersion ?? "–")"
        }
        return monitor.firmwareVersion ?? "–"
    }
    
    private func temperatureColor(_ temp: Double) -> Color {
        if temp >= 70 { return .red }
        if temp >= 60 { return .orange }
        return .primary
    }
    
    private func loadControllerHealth() async {
        isLoadingHealth = true
        controllerHealth = await api.fetchControllerHealth(macAddress: monitor.macAddress)
        isLoadingHealth = false
    }
}

// MARK: - Communication Device Card
struct CommunicationDeviceCard: View {
    let device: CommunicationDevice
    
    private var gridConnectionDateString: String {
        guard let connDate = device.gridConnectionDate else { return "–" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: connDate)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.deviceName ?? device.productName ?? "Communication Module")
                        .font(.headline)
                    Text(device.serialNumber)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // Status badge
                if device.isOnline {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                        Text("Online")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(8)
                } else {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.gray)
                            .frame(width: 8, height: 8)
                        Text("Unknown")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(8)
                }
            }
            
            Divider()
            
            // Details
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 8) {
                DetailRow(label: "Model", value: device.modelCode ?? device.productName ?? "–")
                DetailRow(label: "Manufacturer", value: device.manufacturer ?? "–")
                DetailRow(label: "Type", value: device.typeName ?? "–")
                DetailRow(label: "Connected", value: gridConnectionDateString)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Detail Row Helper
struct RuntimeDiagnosisCard: View {
    let inverter: Inverter
    let diagnosis: RuntimeDiagnosis

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "stethoscope")
                    .foregroundColor(.blue)
                Text(inverter.productName)
                    .font(.headline)
                Spacer()
                Text(inverter.serialNumber)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Text(diagnosis.verdictLabel)
                .font(.subheadline.weight(.medium))

            if let headline = diagnosis.headline {
                Text(headline)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if let rows = diagnosis.runtimeData?.rowsLast30Min {
                DetailRow(label: "Data rows in last 30 min", value: "\(rows)")
            }

            if let steps = diagnosis.nextSteps, !steps.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Next steps")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    ForEach(steps, id: \.self) { step in
                        Text("• \(step)")
                            .font(.caption)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct DetailRow: View {
    let label: String
    let value: String
    var valueColor: Color = .primary
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(value)
                .font(.caption)
                .foregroundColor(valueColor)
                .lineLimit(1)
        }
    }
}

// Preview removed - Site initializer varies by project configuration
