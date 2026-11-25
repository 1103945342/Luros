import Foundation

/// The height a message's markdown document takes at a width, kept for as
/// long as its text and width hold.
///
/// Not the question a *step's* height answers (`ChatTraceSteps` keeps those):
/// this is one message's whole document, which the list asks for on every
/// batch of a stream.
///
/// A streaming reply is laid out by the view that draws it, at the pace that
/// view keeps, and the list asks for its height on every batch. Measuring the
/// whole document a second time there — a full parse and layout on the frame's
/// path, paced by nothing — was half of what made a long reply stutter. The
/// row publishes the height it already laid out, and the list reads it back.
@MainActor
enum ChatRowHeights {
    private struct Key: Hashable {
        let id: UUID
        let text: String
        let width: CGFloat
    }

    private static var heights: [Key: CGFloat] = [:]
    /// Past this many the table starts again: it holds a screen's worth of
    /// rows and the few being measured for the next one.
    private static let capacity = 192

    static func height(id: UUID, text: String, width: CGFloat) -> CGFloat? {
        heights[Key(id: id, text: text, width: width)]
    }

    static func store(_ height: CGFloat, id: UUID, text: String, width: CGFloat) {
        guard height.isFinite, height > 0 else { return }
        if heights.count >= capacity {
            heights.removeAll(keepingCapacity: true)
        }
        heights[Key(id: id, text: text, width: width)] = height
    }

    /// The conversation on screen changed: none of it holds.
    static func forget() {
        heights.removeAll(keepingCapacity: true)
    }
}