import GRDB

extension ActionRecord: FetchableRecord, PersistableRecord {
    static let databaseTableName = "action_records"
    
    enum DBColumns: String, ColumnExpression {
        case id
        case inverterId = "inverter_id"
        case siteId = "site_id"
        case intervalTime = "interval_time"
        case action
        case buyPrice = "buy_price"
        case sellPrice = "sell_price"
        case energyImport = "energy_import"
        case energyExport = "energy_export"
        case batterySoc = "battery_soc"
        case pvPower = "pv_power"
        case gridPower = "grid_power"
        case batteryPower = "battery_power"
        case housePower = "house_power"
        case reason
        case isFinalized = "is_finalized"
        case createdAt = "created_at"
    }
}
