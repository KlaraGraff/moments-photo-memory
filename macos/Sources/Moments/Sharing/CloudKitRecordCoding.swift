import CloudKit
import Foundation
import MomentsCore

/// `SyncRecord` <-> `CKRecord`. Only fields `SyncSchema` lists are written;
/// a field that became nil is cleared on the server too. References are
/// stored as plain ID strings (the sync layer repairs links itself), and a
/// preview travels as a `CKAsset` file.
enum CloudKitRecordCoding {
    /// Builds the record to save. `systemFields` is the server's archived
    /// bookkeeping from the last save or fetch, so the save quotes the change
    /// tag CloudKit expects; without it the record is new.
    static func ckRecord(
        from record: SyncRecord,
        recordName: String,
        zoneID: CKRecordZone.ID,
        systemFields: Data?,
        assetFile: (SyncAssetRef) -> URL?
    ) -> CKRecord {
        let ckRecord = systemFields.flatMap(decodeSystemFields)
            ?? CKRecord(recordType: record.type.rawValue, recordID: CKRecord.ID(recordName: recordName, zoneID: zoneID))
        for field in record.type.spec.fields {
            ckRecord[field.name] = value(record.fields[field.name], assetFile: assetFile)
        }
        ckRecord[SyncSchema.idField] = record.fields[SyncSchema.idField]?.stringValue as NSString?
        return ckRecord
    }

    private static func value(_ value: SyncValue?, assetFile: (SyncAssetRef) -> URL?) -> (any CKRecordValueProtocol)? {
        guard let value else { return nil }
        switch value {
        case .string(let string), .reference(let string): return string as NSString
        case .int(let int): return NSNumber(value: Int64(int))
        case .double(let double): return NSNumber(value: double)
        case .bool(let bool): return NSNumber(value: bool)
        case .date(let date): return date as NSDate
        case .data(let data): return data as NSData
        case .asset(let asset): return assetFile(asset).map { CKAsset(fileURL: $0) }
        }
    }

    /// Reads a fetched record. Unknown record types return nil; unknown or
    /// mistyped fields are dropped. A preview's file is handed to
    /// `storeAsset`, which returns its checksum and size.
    static func syncRecord(from ckRecord: CKRecord, storeAsset: (URL) -> SyncAssetRef?) -> SyncRecord? {
        guard let type = SyncRecordType(rawValue: ckRecord.recordType) else { return nil }
        var record = SyncRecord(type: type, id: ckRecord.recordID.recordName)
        for field in type.spec.fields {
            guard let raw = ckRecord[field.name] else { continue }
            switch field.kind {
            case .string: if let string = raw as? String { record.fields[field.name] = .string(string) }
            case .reference: if let string = raw as? String { record.fields[field.name] = .reference(string) }
            case .int: if let number = raw as? NSNumber { record.fields[field.name] = .int(number.intValue) }
            case .double: if let number = raw as? NSNumber { record.fields[field.name] = .double(number.doubleValue) }
            case .bool: if let number = raw as? NSNumber { record.fields[field.name] = .bool(number.boolValue) }
            case .date: if let date = raw as? Date { record.fields[field.name] = .date(date) }
            case .data: if let data = raw as? Data { record.fields[field.name] = .data(data) }
            case .asset:
                if let asset = raw as? CKAsset, let url = asset.fileURL, let ref = storeAsset(url) {
                    record.fields[field.name] = .asset(ref)
                }
            }
        }
        if let id = ckRecord[SyncSchema.idField] as? String {
            record.fields[SyncSchema.idField] = .string(id)
        }
        return record
    }

    static func encodeSystemFields(_ record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    static func decodeSystemFields(_ data: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }
}
