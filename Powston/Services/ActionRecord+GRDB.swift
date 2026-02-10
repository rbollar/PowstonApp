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
        case earnings
        case costs
        case batterySoc = "battery_soc"
        case pvPower = "pv_power"
        case gridPower = "grid_power"
        case batteryPower = "battery_power"
        case housePower = "house_power"
        case reason
        case isFinalized = "is_finalized"
        case createdAt = "created_at"
        case valuesJson = "values_json"
    }

    func encode(to container: inout PersistenceContainer) {
        container[DBColumns.id] = id
        container[DBColumns.inverterId] = inverterId
        container[DBColumns.siteId] = siteId
        container[DBColumns.intervalTime] = intervalTime
        container[DBColumns.action] = action
        container[DBColumns.buyPrice] = buyPrice
        container[DBColumns.sellPrice] = sellPrice
        container[DBColumns.energyImport] = energyImport
        container[DBColumns.energyExport] = energyExport
        container[DBColumns.earnings] = earnings
        container[DBColumns.costs] = costs
        container[DBColumns.batterySoc] = batterySoc
        container[DBColumns.pvPower] = pvPower
        container[DBColumns.gridPower] = gridPower
        container[DBColumns.batteryPower] = batteryPower
        container[DBColumns.housePower] = housePower
        container[DBColumns.reason] = reason
        container[DBColumns.isFinalized] = isFinalized
        container[DBColumns.createdAt] = createdAt
        container[DBColumns.valuesJson] = valuesJson
    }
}
