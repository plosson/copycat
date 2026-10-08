import AppKit
import UniformTypeIdentifiers

/// Puts a downloaded file on the clipboard in the formats apps read.
public struct PasteboardWriter {
    /// Types that also get their raw bytes on the clipboard, next to the file URL.
    static let dataTypes: [UTType] = [.gif, .png, .jpeg, .webP]

    let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    /// Reads everything it needs before touching the clipboard, so a failure leaves the clipboard as it was.
    public func write(fileURL: URL, type: UTType) throws {
        let item = NSPasteboardItem()
        if Self.dataTypes.contains(type) {
            let data = try Data(contentsOf: fileURL)
            item.setData(data, forType: NSPasteboard.PasteboardType(type.identifier))
        } else if !FileManager.default.fileExists(atPath: fileURL.path) {
            throw CocoaError(.fileNoSuchFile)
        }
        item.setString(fileURL.absoluteString, forType: .fileURL)
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { throw CocoaError(.fileWriteUnknown) }
    }
}
