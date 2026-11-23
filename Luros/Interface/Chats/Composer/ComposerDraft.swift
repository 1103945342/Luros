// Lakr233's Inhouse Code, from FlowDown.
// I CAN DO WHAT THE FUCK I WANT.

import Foundation

/// What a conversation has typed and attached but not sent; saved with its ChatRecord.
struct ComposerDraft: Codable, Sendable {
    var id = UUID()
    var text = ""
    var attachments: [ComposerAttachment] = []
}

struct ComposerAttachment: Identifiable, Hashable, Codable, Sendable {
    var id = UUID()
    var name: String
    var data = Data() // Inline attachments in older drafts, and pasted text/photos.
    var text: String?
    var isImage = false
    /// A UUID, never an external path, resolves a disk-backed draft attachment.
    var storedFile: UUID?
    var storedBytes: Int?
    var mimeType: String?
    var shareBatch: UUID?

    var byteCount: Int { storedBytes ?? data.count }
}
