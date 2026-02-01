import GRDB

extension SyncMetadata: FetchableRecord, PersistableRecord {
    static let databaseTableName = "sync_metadata"
    
    enum DBColumns: String, ColumnExpression {
        case rowId = "id"
        case entityType = "entity_type"
        case siteId = "site_id"
        case inverterId = "inverter_id"
        case lastSyncTime = "last_sync_time"
        case lastRecordTime = "last_record_time"
        case recordCount = "record_count"
    }
    
    func encode(to container: inout PersistenceContainer) {
        container[DBColumns.rowId] = rowId
        container[DBColumns.entityType] = entityType
        container[DBColumns.siteId] = siteId
        container[DBColumns.inverterId] = inverterId
        container[DBColumns.lastSyncTime] = lastSyncTime
        container[DBColumns.lastRecordTime] = lastRecordTime
        container[DBColumns.recordCount] = recordCount
    }
}
