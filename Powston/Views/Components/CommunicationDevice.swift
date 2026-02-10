//
//  CommunicationDevice.swift
//  Powston
//
//  Model for inverter communication modules (e.g., WiNet-S)

import Foundation

struct CommunicationDevice: Codable, Identifiable {
    let id: Int
    let siteId: Int
    let serialNumber: String
    let manufacturer: String?
    let productName: String?
    let vendorKey: String?
    let metaData: CommunicationDeviceMetaData?
    let createdAt: Date?
    
    enum CodingKeys: String, CodingKey {
        case id
        case siteId = "site_id"
        case serialNumber = "serial_number"
        case manufacturer
        case productName = "product_name"
        case vendorKey = "vendor_key"
        case metaData = "meta_data"
        case createdAt = "created_at"
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        id = try container.decode(Int.self, forKey: .id)
        siteId = try container.decode(Int.self, forKey: .siteId)
        serialNumber = try container.decode(String.self, forKey: .serialNumber)
        manufacturer = try container.decodeIfPresent(String.self, forKey: .manufacturer)
        productName = try container.decodeIfPresent(String.self, forKey: .productName)
        vendorKey = try container.decodeIfPresent(String.self, forKey: .vendorKey)
        metaData = try container.decodeIfPresent(CommunicationDeviceMetaData.self, forKey: .metaData)
        
        // Parse date
        if let dateString = try container.decodeIfPresent(String.self, forKey: .createdAt) {
            let dateFormatter = ISO8601DateFormatter()
            dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            createdAt = dateFormatter.date(from: dateString) ?? ISO8601DateFormatter().date(from: dateString)
        } else {
            createdAt = nil
        }
    }
    
    // MARK: - Computed Properties
    
    /// Device name from metadata (e.g., "ESS 2 Communication Module Right")
    var deviceName: String? {
        metaData?.deviceName
    }
    
    /// Device model code (e.g., "WiNet-S")
    var modelCode: String? {
        metaData?.deviceModelCode
    }
    
    /// Grid connection date
    var gridConnectionDate: Date? {
        guard let dateString = metaData?.gridConnectionDate else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: dateString)
    }
    
    /// Device status (1 = online)
    var isOnline: Bool {
        metaData?.devStatus == "1"
    }
    
    /// Fault status
    var hasFault: Bool {
        guard let status = metaData?.devFaultStatus else { return false }
        return status != 0 && status != 4  // 4 seems to be normal based on sample data
    }
    
    /// Type name (e.g., "Communication module")
    var typeName: String? {
        metaData?.typeName
    }
}

// MARK: - Communication Device MetaData
struct CommunicationDeviceMetaData: Codable {
    let uuid: Int?
    let psId: Int?
    let psKey: String?
    let chnnlId: Int?
    let relTime: String?
    let deviceSn: String?
    let relState: Int?
    let typeName: String?
    let devStatus: String?
    let deviceCode: Int?
    let deviceName: String?
    let deviceType: Int?
    let factoryName: String?
    let deviceModelId: Int?
    let devFaultStatus: Int?
    let deviceModelCode: String?
    let communicationDevSn: String?
    let gridConnectionDate: String?
    
    enum CodingKeys: String, CodingKey {
        case uuid
        case psId = "ps_id"
        case psKey = "ps_key"
        case chnnlId = "chnnl_id"
        case relTime = "rel_time"
        case deviceSn = "device_sn"
        case relState = "rel_state"
        case typeName = "type_name"
        case devStatus = "dev_status"
        case deviceCode = "device_code"
        case deviceName = "device_name"
        case deviceType = "device_type"
        case factoryName = "factory_name"
        case deviceModelId = "device_model_id"
        case devFaultStatus = "dev_fault_status"
        case deviceModelCode = "device_model_code"
        case communicationDevSn = "communication_dev_sn"
        case gridConnectionDate = "grid_connection_date"
    }
}
