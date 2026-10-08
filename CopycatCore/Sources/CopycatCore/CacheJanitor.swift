import Foundation

/// Keeps the download cache small: the newest folders only, none older than a day.
public enum CacheJanitor {
    public static func prune(_ directory: URL, keep: Int = 20, maxAge: TimeInterval = 86_400, now: Date = Date()) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }

        let folders = entries.compactMap { url -> (URL, Date)? in
            // Only folders Copycat created (named with a UUID) are ever deleted.
            guard UUID(uuidString: url.lastPathComponent) != nil,
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isDirectory == true
            else { return nil }
            return (url, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.1 > $1.1 }

        for (index, (url, date)) in folders.enumerated()
        where index >= keep || now.timeIntervalSince(date) > maxAge {
            try? fm.removeItem(at: url)
        }
    }
}
