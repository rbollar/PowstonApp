import GRDB

extension AnalysisCacheEntry: FetchableRecord, PersistableRecord {
    static let databaseTableName = "analysis_cache"
    
    enum DBColumns: String, ColumnExpression {
        case rowId = "id"
        case siteId = "site_id"
        case analysisType = "analysis_type"
        case parametersHash = "parameters_hash"
        case resultJson = "result_json"
        case computedAt = "computed_at"
        case validUntil = "valid_until"
    }
    
    func encode(to container: inout PersistenceContainer) {
        container[DBColumns.rowId] = rowId
        container[DBColumns.siteId] = siteId
        container[DBColumns.analysisType] = analysisType
        container[DBColumns.parametersHash] = parametersHash
        container[DBColumns.resultJson] = resultJson
        container[DBColumns.computedAt] = computedAt
        container[DBColumns.validUntil] = validUntil
    }
}
