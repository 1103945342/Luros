// Lakr233's Inhouse Code, from FlowDown.
// I CAN DO WHAT THE FUCK I WANT.

import UIKit

extension ComposerInputView {
    /// The text view, with a hardware keyboard's return keys: return sends
    /// (or breaks the line, by `ComposerBehavior`), ⌘ return sends, ⌥ return
    /// breaks the line. A pasted image, or a long paste, goes to the
    /// composer instead of the text.
    class TextEditorView: UITextView {
        init() {
            super.init(frame: .zero, textContainer: nil)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("Use init()")
        }

        override var keyCommands: [UIKeyCommand]? {
            [
                UIKeyCommand(input: "\r", modifierFlags: .alternate, action: #selector(insertNewLine)),
                UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(returnPressed)),
                UIKeyCommand(input: "\r", modifierFlags: .command, action: #selector(commandReturnPressed)),
            ]
        }

        @objc dynamic var onReturnKeyPressed: () -> Void = {}
        @objc dynamic var onCommandReturnKeyPressed: () -> Void = {}
        @objc dynamic var onImagePasted: (UIImage) -> Void = { _ in }

        override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
            if action == #selector(paste(_:)) {
                // no need to check the pasteboard: reading it asks the user
                return true
            }
            return super.canPerformAction(action, withSender: sender)
        }

        override func paste(_ sender: Any?) {
            if let image = UIPasteboard.general.image {
                onImagePasted(image)
                return
            }
            if ComposerBehavior.pasteLargeTextContentAsFile,
               let text = UIPasteboard.general.string,
               text.count > ComposerBehavior.longPasteThreshold
            {
                var superView: UIView? = self
                while superView != nil, !(superView is ComposerInputView) {
                    superView = superView?.superview
                }
                guard let editor = superView as? ComposerInputView else { return }
                editor.delegate?.onComposerInputPastingLargeTextAsDocument(content: text)
                return
            }
            super.paste(sender)
        }

        @objc dynamic private func insertNewLine() {
            insertText("\n")
        }

        @objc dynamic private func returnPressed() {
            onReturnKeyPressed()
        }

        @objc dynamic private func commandReturnPressed() {
            onCommandReturnKeyPressed()
        }
    }
}

extension ComposerInputView: UITextViewDelegate {
    @objc dynamic func textViewDidBeginEditing(_ textView: UITextView) {
        delegate?.onComposerInputBeginEditing()
        updateTextHeight()
        delegate?.onComposerInputTextChanged(text: textView.text)
        switchToRequiredStatus()
    }

    @objc dynamic func textViewDidEndEditing(_ textView: UITextView) {
        clearAttributedText()
        updateTextHeight()
        delegate?.onComposerInputTextChanged(text: textView.text)
        delegate?.onComposerInputEndEditing()
        switchToRequiredStatus()
    }

    @objc dynamic func textViewDidChange(_ textView: UITextView) {
        updatePlaceholderAlpha()
        scheduleTextHeightUpdate()
        updateOverflowState()
        delegate?.onComposerInputTextChanged(text: textView.text)
        switchToRequiredStatus()
    }

    @objc dynamic func textView(
        _ textView: UITextView,
        editMenuForTextIn _: NSRange,
        suggestedActions: [UIMenuElement],
    ) -> UIMenu? {
        let pasteboard = UIPasteboard.general
        let canPasteAttachment = pasteboard.hasStrings

        let actions: [UIAction] = [
            UIAction(title: String(localized: "Insert New Line")) { _ in
                textView.insertText("\n")
            },
            UIAction(
                title: String(localized: "Paste as Attachment"),
                attributes: canPasteAttachment ? [] : [.disabled],
            ) { [weak self] _ in
                self?.delegate?.onComposerInputPasteAsAttachmentTapped()
            },
            UIAction(title: String(localized: "More")) { [weak self] _ in
                self?.delegate?.onComposerInputMoreButtonTapped()
            },
        ]
        return UIMenu(children: suggestedActions + actions)
    }

    @objc dynamic func textView(_ textView: UITextView, shouldChangeTextIn _: NSRange, replacementText text: String) -> Bool {
        if text == "\n", !ComposerBehavior.useConfirmationOnSend {
            textView.resignFirstResponder()
            delegate?.onComposerInputSubmitButtonTapped()
            return false
        }
        return true
    }

    /// Shows or hides the tip with the text, and only when that changed: a roll
    /// animates the label's own alpha, and a layout pass that wrote it again
    /// would cut the animation short.
    @objc dynamic func updatePlaceholderAlpha() {
        setPlaceholderVisible(textView.text.isEmpty)
    }

    /// The band's height follows the text: measured here, in the column the
    /// next layout will give it, so the two never disagree about which line
    /// the text ends on. A paste can add a dozen lines at once, and measured
    /// against a column wider than the text ends up in, the band stops short
    /// and the last lines are hidden past its bottom.
    @objc dynamic func updateTextHeight() {
        let width = textLayoutWidth
        let attrText = textView.attributedText ?? .init()
        // An empty draft is one line whatever the column is; any other text
        // waits for the first layout pass to say how wide that column is.
        guard width > 0 || attrText.length == 0 else { return }
        textMeasuredWidth = width
        let measured = width > 0
            ? TextMeasurement.shared.measureSize(of: attrText, usingWidth: width).height
            : 0
        let decision = ceil(max(measured, font.lineHeight))
        doWithAnimation { self.textHeight.send(decision) } completion: { [weak self] in
            // The spring gave the text view room after the pass that resized
            // it: one more layout at its final size paints what was blank.
            guard let self else { return }
            textView.layoutIfNeeded()
            scrollTextToTopIfItFits()
        }
        updateOverflowState()
    }

    /// What a text change asks for. Not measured from inside
    /// `textViewDidChange`: a layout pass put in the middle of the text view's
    /// own insertion leaves its glyphs laid out for the frame it had when the
    /// insertion began, and the room the band gains under the text stays blank
    /// until something scrolls it. The height is measured on the next turn of
    /// the run loop instead, and however many changes came meanwhile share one
    /// pass.
    @objc dynamic func scheduleTextHeightUpdate() {
        guard !isTextHeightUpdateScheduled else { return }
        isTextHeightUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isTextHeightUpdateScheduled = false
            self.updateTextHeight()
        }
    }

    @objc dynamic func clearAttributedText() {
        let currentText = textView.text
        textView.attributedText = NSAttributedString(
            string: currentText ?? "",
            attributes: [
                .font: UIFont.preferredFont(forTextStyle: .body),
                .foregroundColor: UIColor.label,
            ],
        )
    }
}
