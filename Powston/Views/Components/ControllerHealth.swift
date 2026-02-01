//
//  ControllerHealth.swift
//  Powston
//
//  Model for controller health status from /api/controller_health/{mac}

import Foundation

struct ControllerHealth: Codable {
    let status: String?
    let site: Bool?
    let inverter: Bool?
    let clientTime: String?
    let externalIp: String?
    let temperature: Double?
    let inverterBrand: String?
    let productName: String?
    let siteNetwork: String?
    let firmwareVersion: String?
    let siteStatus: ControllerSiteStatus?
    
    enum CodingKeys: String, CodingKey {
        case status
        case site
        case inverter
        case clientTime = "client_time"
        case externalIp = "external_ip"
        case temperature
        case inverterBrand = "inverter_brand"
        case productName = "product_name"
        case siteNetwork = "site_network"
        case firmwareVersion = "firmware_version"
        case siteStatus = "site_status"
    }
    
    // MARK: - Computed Properties
    
    /// Parse client time to Date
    var clientDate: Date? {
        guard let timeString = clientTime else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
        return formatter.date(from: timeString)
    }
    
    /// Time since client responded
    var timeSinceResponse: TimeInterval? {
        guard let date = clientDate else { return nil }
        return Date().timeIntervalSince(date)
    }
    
    /// Is healthy (responded within 10 minutes)?
    var isHealthy: Bool {
        guard let elapsed = timeSinceResponse else { return false }
        return elapsed < 600
    }
    
    /// Health status string
    var healthStatusString: String {
        guard let elapsed = timeSinceResponse else { return "Unknown" }
        if elapsed < 60 {
            return "Online"
        } else if elapsed < 600 {
            return "Online (\(Int(elapsed / 60))m ago)"
        } else {
            return "Stale (\(Int(elapsed / 60))m ago)"
        }
    }
    
    /// Temperature in Celsius (API returns raw value)
    var temperatureCelsius: Double? {
        temperature
    }
    
    /// Temperature status
    var temperatureStatus: TemperatureStatus {
        guard let temp = temperature else { return .unknown }
        if temp >= 70 { return .critical }
        if temp >= 60 { return .warning }
        return .normal
    }
    
    enum TemperatureStatus {
        case normal, warning, critical, unknown
    }
    
    /// Overall status is success
    var isSuccess: Bool {
        status?.lowercased() == "success"
    }
    
    /// Both site and inverter connections are good
    var isFullyConnected: Bool {
        (site ?? false) && (inverter ?? false)
    }
}

// MARK: - Controller Site Status
struct ControllerSiteStatus: Codable {
    let nmi: Bool?
    let nmiReporting: Bool?
    let nmiActual: Bool?
    let hasInverter: Bool?
    let inverterControlled: Bool?
    let tariffs: Bool?
    let userCode: Bool?
    let userCodeEnabled: Bool?
    let recentData: Bool?
    let inverterBatteryCapacity: Int?
    let hasSiteMonitor: Bool?
    let siteMonitorConfigured: Bool?
    let siteMonitorOnline: Bool?
    let siteMonitorInverter: Bool?
    let recentModbusData: Bool?
    let siteMonitorTime: Int?
    let siteMonitorLocal: Bool?
    let trainingRuns: [TrainingRun]?
    
    enum CodingKeys: String, CodingKey {
        case nmi
        case nmiReporting = "nmi_reporting"
        case nmiActual = "nmi_actual"
        case hasInverter = "has_inverter"
        case inverterControlled = "inverter_controlled"
        case tariffs
        case userCode = "user_code"
        case userCodeEnabled = "user_code_enabled"
        case recentData = "recent_data"
        case inverterBatteryCapacity = "inverter_battery_capacity"
        case hasSiteMonitor = "has_site_monitor"
        case siteMonitorConfigured = "site_monitor_configured"
        case siteMonitorOnline = "site_monitor_online"
        case siteMonitorInverter = "site_monitor_inverter"
        case recentModbusData = "recent_modbus_data"
        case siteMonitorTime = "site_monitor_time"
        case siteMonitorLocal = "site_monitor_local"
        case trainingRuns = "training_runs"
    }
    
    /// Battery capacity in kWh
    var batteryCapacityKWh: Double? {
        guard let capacity = inverterBatteryCapacity else { return nil }
        return Double(capacity) / 1000.0
    }
    
    /// Site monitor last response time
    var siteMonitorDate: Date? {
        guard let timestamp = siteMonitorTime else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(timestamp))
    }
}

// MARK: - Training Run
struct TrainingRun: Codable, Identifiable {
    let id: Int
    let meterBill: Double?
    let bill: Double?
    let startDate: String?
    let endDate: String?
    let startedAt: String?
    let finishedAt: String?
    let createdAt: String?
    
    enum CodingKeys: String, CodingKey {
        case id
        case meterBill = "meter_bill"
        case bill
        case startDate = "start_date"
        case endDate = "end_date"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case createdAt = "created_at"
    }
    
    /// Savings from this training run
    var savings: Double? {
        guard let meter = meterBill, let actual = bill else { return nil }
        return meter - actual
    }
    
    /// Savings percentage
    var savingsPercent: Double? {
        guard let meter = meterBill, let actual = bill, meter > 0 else { return nil }
        return ((meter - actual) / meter) * 100
    }
    
    /// Date range string
    var dateRangeString: String? {
        guard let start = startDate, let end = endDate else { return nil }
        // Parse and format dates
        let inputFormatter = ISO8601DateFormatter()
        inputFormatter.formatOptions = [.withFullDate]
        
        let outputFormatter = DateFormatter()
        outputFormatter.dateStyle = .medium
        outputFormatter.timeStyle = .none
        
        if let startDate = inputFormatter.date(from: start),
           let endDate = inputFormatter.date(from: end) {
            return "\(outputFormatter.string(from: startDate)) - \(outputFormatter.string(from: endDate))"
        }
        return "\(start) - \(end)"
    }
}
