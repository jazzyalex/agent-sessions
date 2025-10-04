import Foundation

extension UserDefaults {
    private enum UpdateKeys {
        static let lastCheckAt = "UpdateLastCheckAt"
        static let etag = "UpdateETag"
        static let skippedVersion = "UpdateSkippedVersion"
        static let lastErrorAt = "UpdateLastErrorAt"
        static let errorCount = "UpdateErrorCount"
    }

    var updateLastCheckAt: Date? {
        get { object(forKey: UpdateKeys.lastCheckAt) as? Date }
        set { set(newValue, forKey: UpdateKeys.lastCheckAt) }
    }

    var updateETag: String? {
        get { string(forKey: UpdateKeys.etag) }
        set { set(newValue, forKey: UpdateKeys.etag) }
    }

    var updateSkippedVersion: String? {
        get { string(forKey: UpdateKeys.skippedVersion) }
        set { set(newValue, forKey: UpdateKeys.skippedVersion) }
    }

    var updateLastErrorAt: Date? {
        get { object(forKey: UpdateKeys.lastErrorAt) as? Date }
        set { set(newValue, forKey: UpdateKeys.lastErrorAt) }
    }

    var updateErrorCount: Int {
        get { integer(forKey: UpdateKeys.errorCount) }
        set { set(newValue, forKey: UpdateKeys.errorCount) }
    }
}
