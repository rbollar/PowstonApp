//
//  SiteMonitor.swift
//  Powston
//
//  Model for Powston controller/site monitor hardware

import Foundation

struct SiteMonitor: Codable, Identifiable {
    let id: Int
    let siteId: Int
    let inverterId: Int
    let serialNumber: String
    let macAddress: String
    let ipAddress: String?
    let firmwareVersion: String?
    let pendingFirmwareVersion: String?
    let manufacturer: String?
    let productName: String?
    let monitorType: String?
    let modbusType: String?
    let modbusSlaveId: Int?
    let modbusTimeout: Int?
    let modbusTcpIp: String?
    let modbusTcpPort: Int?
    let mqttUser: String?
    let lastBootAt: Date?
    let createdAt: Date?
    let config: SiteMonitorConfig?
    
    enum CodingKeys: String, CodingKey {
        case id
        case siteId = "site_id"
        case inverterId = "inverter_id"
        case serialNumber = "serial_number"
        case macAddress = "mac_address"
        case ipAddress = "ip_address"
        case firmwareVersion = "firmware_version"
        case pendingFirmwareVersion = "pending_firmware_version"
        case manufacturer
        case productName = "product_name"
        case monitorType = "monitor_type"
        case modbusType = "modbus_type"
        case modbusSlaveId = "modbus_slave_id"
        case modbusTimeout = "modbus_timeout"
        case modbusTcpIp = "modbus_tcp_ip"
        case modbusTcpPort = "modbus_tcp_port"
        case mqttUser = "mqtt_user"
        case lastBootAt = "last_boot_at"
        case createdAt = "created_at"
        case config
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        id = try container.decode(Int.self, forKey: .id)
        siteId = try container.decode(Int.self, forKey: .siteId)
        inverterId = try container.decode(Int.self, forKey: .inverterId)
        serialNumber = try container.decode(String.self, forKey: .serialNumber)
        macAddress = try container.decode(String.self, forKey: .macAddress)
        ipAddress = try container.decodeIfPresent(String.self, forKey: .ipAddress)
        firmwareVersion = try container.decodeIfPresent(String.self, forKey: .firmwareVersion)
        pendingFirmwareVersion = try container.decodeIfPresent(String.self, forKey: .pendingFirmwareVersion)
        manufacturer = try container.decodeIfPresent(String.self, forKey: .manufacturer)
        productName = try container.decodeIfPresent(String.self, forKey: .productName)
        monitorType = try container.decodeIfPresent(String.self, forKey: .monitorType)
        modbusType = try container.decodeIfPresent(String.self, forKey: .modbusType)
        modbusSlaveId = try container.decodeIfPresent(Int.self, forKey: .modbusSlaveId)
        modbusTimeout = try container.decodeIfPresent(Int.self, forKey: .modbusTimeout)
        modbusTcpIp = try container.decodeIfPresent(String.self, forKey: .modbusTcpIp)
        modbusTcpPort = try container.decodeIfPresent(Int.self, forKey: .modbusTcpPort)
        mqttUser = try container.decodeIfPresent(String.self, forKey: .mqttUser)
        config = try container.decodeIfPresent(SiteMonitorConfig.self, forKey: .config)
        
        // Parse dates with ISO8601
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        
        if let dateString = try container.decodeIfPresent(String.self, forKey: .lastBootAt) {
            lastBootAt = dateFormatter.date(from: dateString) ?? ISO8601DateFormatter().date(from: dateString)
        } else {
            lastBootAt = nil
        }
        
        if let dateString = try container.decodeIfPresent(String.self, forKey: .createdAt) {
            createdAt = dateFormatter.date(from: dateString) ?? ISO8601DateFormatter().date(from: dateString)
        } else {
            createdAt = nil
        }
    }
    
    // MARK: - Computed Properties
    
    /// MAC address formatted with colons (e.g., "88:13:BF:6E:B6:B0")
    var formattedMacAddress: String {
        guard macAddress.count == 12 else { return macAddress }
        var result = ""
        for (index, char) in macAddress.enumerated() {
            if index > 0 && index % 2 == 0 {
                result += ":"
            }
            result += String(char)
        }
        return result
    }
    
    /// Temperature from config in Celsius
    var temperature: Double? {
        config?.temperature
    }
    
    /// Temperature status for UI coloring
    var temperatureStatus: TemperatureStatus {
        guard let temp = temperature else { return .unknown }
        if temp >= 70 { return .critical }
        if temp >= 60 { return .warning }
        return .normal
    }
    
    enum TemperatureStatus {
        case normal, warning, critical, unknown
        
        var color: String {
            switch self {
            case .normal: return "green"
            case .warning: return "orange"
            case .critical: return "red"
            case .unknown: return "gray"
            }
        }
    }
    
    /// Time since last boot
    var uptimeString: String? {
        guard let bootTime = lastBootAt else { return nil }
        let interval = Date().timeIntervalSince(bootTime)
        
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        
        if hours >= 24 {
            let days = hours / 24
            let remainingHours = hours % 24
            return "\(days)d \(remainingHours)h"
        } else if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }
    
    /// Client time from config (Unix timestamp)
    var clientTime: Date? {
        guard let timestamp = config?.clientTime else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(timestamp))
    }
    
    /// Time since last response (for health check)
    var timeSinceResponse: TimeInterval? {
        guard let clientDate = clientTime else { return nil }
        return Date().timeIntervalSince(clientDate)
    }
    
    /// Is controller healthy (responded within 10 minutes)?
    var isHealthy: Bool {
        guard let elapsed = timeSinceResponse else { return false }
        return elapsed < 600 // 10 minutes
    }
    
    /// Health status string
    var healthStatus: String {
        guard let elapsed = timeSinceResponse else { return "Unknown" }
        if elapsed < 60 {
            return "Online"
        } else if elapsed < 600 {
            let minutes = Int(elapsed / 60)
            return "Online (\(minutes)m ago)"
        } else {
            let minutes = Int(elapsed / 60)
            return "Stale (\(minutes)m ago)"
        }
    }
    
    /// Heap memory from config (in KB)
    var heapMemoryKB: Int? {
        guard let heap = config?.heap else { return nil }
        return heap / 1024
    }
    
    /// Has pending firmware update
    var hasPendingUpdate: Bool {
        guard let current = firmwareVersion, let pending = pendingFirmwareVersion else { return false }
        return current != pending
    }
}

// MARK: - Site Monitor Config (nested config object)
struct SiteMonitorConfig: Codable {
    let temperature: Double?
    let heap: Int?
    let clientTime: Int?
    let externalIp: String?
    let wifiRssi: String?
    let wifiSsid: String?
    let wifiStatus: Int?
    let ethIpAddress: String?
    let wifiIpAddress: String?
    let boardVoltage: String?
    let loopInterval: String?
    let readInterval: String?
    let watchdogStatus: Int?
    let modbusInUse: Bool?
    let modbusProxyPort: String?
    let modbusMaxClients: String?
    let modbusCacheDuration: String?
    let modbusClientTimeout: String?
    
    enum CodingKeys: String, CodingKey {
        case temperature
        case heap
        case clientTime = "client_time"
        case externalIp = "external_ip"
        case wifiRssi = "wifi_rssi"
        case wifiSsid = "wifi_ssid"
        case wifiStatus = "wifi_status"
        case ethIpAddress = "eth_ip_address"
        case wifiIpAddress = "wifi_ip_address"
        case boardVoltage = "board_voltage"
        case loopInterval = "loop_interval"
        case readInterval = "read_interval"
        case watchdogStatus = "watchdog_status"
        case modbusInUse = "modbus_in_use"
        case modbusProxyPort = "modbus_proxy_port"
        case modbusMaxClients = "modbus_max_clients"
        case modbusCacheDuration = "modbus_cache_duration"
        case modbusClientTimeout = "modbus_client_timeout"
    }
}
