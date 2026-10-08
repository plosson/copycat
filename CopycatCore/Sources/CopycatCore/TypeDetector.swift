import Foundation
import UniformTypeIdentifiers

/// Works out a downloaded file's type and a safe file name. Pure functions.
public enum TypeDetector {
    /// Types recognised by their magic bytes. A hint, Content-Type or extension
    /// claiming one of these is ignored when the bytes do not match.
    static let sniffable: [UTType] = [.gif, .png, .jpeg, .webP, .mpeg4Movie, .quickTimeMovie]

    static let maxNameCharacters = 120
    static let maxNameBytes = 240

    public static func sniff(_ head: Data) -> UTType? {
        let bytes = [UInt8](head.prefix(16))
        func has(_ signature: [UInt8], at offset: Int) -> Bool {
            bytes.count >= offset + signature.count
                && Array(bytes[offset..<offset + signature.count]) == signature
        }
        func has(_ ascii: String, at offset: Int) -> Bool { has(Array(ascii.utf8), at: offset) }

        if has("GIF87a", at: 0) || has("GIF89a", at: 0) { return .gif }
        if has([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], at: 0) { return .png }
        if has([0xFF, 0xD8, 0xFF], at: 0) { return .jpeg }
        if has("RIFF", at: 0) && has("WEBP", at: 8) { return .webP }
        if has("ftyp", at: 4) { return has("qt  ", at: 8) ? .quickTimeMovie : .mpeg4Movie }
        return nil
    }

    public static func detectType(head: Data, hint: String?, contentType: String?, url: URL) -> UTType {
        if let sniffed = sniff(head) { return sniffed }
        let ext = url.pathExtension
        let candidates = [
            mimeType(hint),
            mimeType(contentType),
            ext.isEmpty ? nil : UTType(filenameExtension: ext),
        ]
        for case let type? in candidates
        where !type.isDynamic && !sniffable.contains(where: { type.conforms(to: $0) }) {
            return type
        }
        return .data
    }

    public static func fileName(hint: String?, url: URL, type: UTType, now: Date = Date()) -> String {
        let ext = type.preferredFilenameExtension ?? "bin"
        let base = [hint, url.lastPathComponent]
            .compactMap { $0.map(cleanBase) }
            .first { !$0.isEmpty } ?? defaultBase(now)
        var capped = String(base.prefix(maxNameCharacters - ext.count - 1))
        while capped.utf8.count > maxNameBytes - ext.utf8.count - 1 { capped.removeLast() }
        return "\(capped).\(ext)"
    }

    static func cleanBase(_ raw: String) -> String {
        let kept = raw.unicodeScalars.filter { scalar in
            !"/\\:".unicodeScalars.contains(scalar) && !CharacterSet.controlCharacters.contains(scalar)
        }
        var name = String(String.UnicodeScalarView(kept))
        while name.hasPrefix(".") { name.removeFirst() }
        name = (name as NSString).deletingPathExtension
        return name.trimmingCharacters(in: .whitespaces)
    }

    static func defaultBase(_ now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "copycat-\(formatter.string(from: now))"
    }

    static func mimeType(_ value: String?) -> UTType? {
        guard let essence = value?.split(separator: ";").first?
            .trimmingCharacters(in: .whitespaces).lowercased(), !essence.isEmpty
        else { return nil }
        return UTType(mimeType: essence)
    }
}
