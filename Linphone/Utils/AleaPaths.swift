/*
 * ALEA: data paths that work without App Group (Simulator / unsigned debug).
 */
import Foundation

enum AleaPaths {
    static var appGroupId: String {
        (Bundle.main.object(forInfoDictionaryKey: "APP_GROUP_NAME") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
            ?? "group.org.linphone.phone.msgNotification"
    }

    static var sharedContainerAvailable: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) != nil
    }

    /// Root directory for linphone data/logs (app group if available, else app Library).
    static func dataDirectory() -> URL {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) {
            return url
        }
        let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("alea-linphone", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func preferencesDirectory() -> URL {
        let url = dataDirectory().appendingPathComponent("Library/Preferences/linphone", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
