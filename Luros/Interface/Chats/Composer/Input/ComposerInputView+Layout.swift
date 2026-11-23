// Lakr233's Inhouse Code, from FlowDown.
// I CAN DO WHAT I WANT.

import UIKit

extension ComposerInputView {
    func textLayoutHeight(_ input: CGFloat) -> CGFloat {
        var finalHeight = input
        finalHeight = max(font.lineHeight, finalHeight)
        finalHeight = min(finalHeight, maxTextEditorHeight)
        return ceil(finalHeight)
    }

    /// How tall the text would be were the band as wide as it is: what tells
    /// the band its text has outgrown it.
    ///
    /// Counted rather than guessed from line breaks: a long paragraph wraps
    /// without one, and a band that measured by newlines would show Expand only
    /// once the reader pressed return.
    private func measuredTextHeight() -> CGFloat {
        let width = textView.bounds.width
        guard width > 0, let text = textView.text, !text.isEmpty else { return font.lineHeight }
        let measured = TextMeasurement.shared.measureSize(
            of: NSAttributedString(
                string: text,
                attributes: [.font: font],
            ),
            usingWidth: width,
        ).height
        return ceil(max(measured, font.lineHeight))
    }

    /// One line's worth of room inside the band, either side of the text.
    private var textRoomHeight: CGFloat {
        maxTextEditorHeight - inset.top - inset.bottom
    }

    func switchToRequiredStatus() {
        assert(Thread.isMainThread)
        // The band no longer has three shapes to choose between — the text
        // takes the whole row whatever the state — but a caller setting the
        // text twice still asks for a layout, and the height it publishes
        // follows.
        setNeedsLayout()
    }

    /// The width the text wraps in, as the next layout pass will compute it:
    /// the wand's room comes out of the text's side while it is shown. The
    /// height the band keeps is measured for this same width, so the two never
    /// disagree about which line the text ends on.
    var textLayoutWidth: CGFloat {
        guard bounds.width > 0 else { return textView.frame.width }
        let toolsShown = hasContent && !isBusy
        let rewriteRoom = toolsShown ? ComposerMetrics.Send.diameter + iconSpacing : 0
        return max(0, bounds.width - inset.left - inset.right - rewriteRoom)
    }

    /// A text view that scrolled to its caret while the band was shorter keeps
    /// that offset once the room arrives, and the text sits above a blank
    /// stretch where it now fits whole. It starts at the top instead.
    func scrollTextToTopIfItFits() {
        guard textView.contentSize.height <= textView.bounds.height else { return }
        if textView.contentOffset.y != 0 {
            textView.contentOffset = .zero
        }
    }

    /// Where the text starts: the band's own inset, and the text sits against
    /// the top rather than centred, so a growing draft grows downward and the
    /// first line stays where the reader left it.
    private func textFrame(width: CGFloat) -> CGRect {
        let height = textLayoutHeight(textHeight.value)
        return CGRect(
            x: inset.left,
            y: inset.top,
            width: max(0, width),
            height: height,
        )
    }

    /// The wand at the band's trailing corner, visible when there is something
    /// to rewrite and no run to interrupt.
    private func placeRewriteButton() {
        let showsRewrite = hasContent && !isBusy
        rewriteButton.alpha = showsRewrite ? 1 : 0
        rewriteButton.isUserInteractionEnabled = showsRewrite

        let rewriteSize = ComposerMetrics.Send.diameter
        let x = bounds.width - inset.right - rewriteSize
        rewriteButton.frame = CGRect(
            x: x,
            y: max(0, inset.top - 4),
            width: rewriteSize,
            height: rewriteSize,
        )
    }

    /// One shape, whatever the state: the text takes the band's row, and the
    /// wand sits at the trailing corner when there is something to rewrite.
    func layoutTextBand() {
        // The text takes the band's row, the wand its trailing corner:
        // `textLayoutWidth` is how much of that row is the text's, the very
        // figure its height was measured with.
        let frame = textFrame(width: textLayoutWidth)
        textView.frame = frame
        scrollTextToTopIfItFits()
        // The tip rolls with a transform on it, and a view carrying one has no
        // frame to set: its bounds and centre are what a layout pass may write.
        placeholderLabel.bounds = CGRect(origin: .zero, size: frame.size)
        placeholderLabel.center = CGPoint(x: frame.midX, y: frame.midY)
        placeRewriteButton()
    }

    func updateOverflowState() {
        // No-op: expand button removed, overflow state no longer tracked
    }
}
