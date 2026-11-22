import UIKit

/// The page's opening: a line in the middle of a conversation that has none,
/// written in with a caret, held for the reader, then taken back and written
/// again as the other line.
///
/// The sentence is laid out whole and revealed by colour, so the line never
/// re-wraps or slides while it is being written; the caret is placed on that
/// fixed layout, at the end of what has been written so far.
///
/// It takes no touch and is one element to VoiceOver, which reads the whole
/// sentence even while it is still being written.
final class ChatWelcomeView: UIView {
    /// The lines the page opens with, in the order they are written: each
    /// cycle takes the next one, so both are seen.
    static var lines: [String] {
        [
            String(localized: "Hello, is there anything I can help you with?"),
            String(localized: "What would you like to do right now?"),
        ]
    }

    /// Writing takes about this long whatever the sentence's length — a long
    /// English line and a short Chinese one arrive at the same pace to the
    /// eye — inside the two limits per character.
    private static let writingSeconds = 1.6
    private static let slowestCharacter = 0.11
    private static let fastestCharacter = 0.035
    /// Taking it back is quicker than writing it: the reader has read it.
    private static let erasingSeconds = 0.7
    private static let quickestErase = 0.018
    /// How long the finished sentence stays before it is taken back, and how
    /// long the page stays empty before the next one starts.
    private static let heldSeconds = 2.4
    private static let emptySeconds = 0.6
    /// A character and a half of fade behind the newest, which is what reads
    /// as ink arriving rather than as a line of lamps switching on.
    private static let fadeCharacters = 1.5
    private static let blinkSeconds = 0.5

    /// The ink's own strength: a greeting is read, not shouted.
    private static let inkAlpha: CGFloat = 0.9

    private static var ink: UIColor {
        UIColor.label.withAlphaComponent(inkAlpha)
    }

    /// Sized so the Chinese line — thirteen characters — stays on one line
    /// inside the page's margins; the English one takes two, which reads fine
    /// centred.
    private static var font: UIFont {
        UIFontMetrics(forTextStyle: .title2).scaledFont(
            for: .systemFont(ofSize: 24, weight: .regular),
            maximumPointSize: 40,
        )
    }

    private let label = UILabel()
    private let caret = UIView()
    private var loop: Task<Void, Never>?
    private var full: NSAttributedString?
    private var ranges: [NSRange] = []
    /// The sentence's own layout, kept with its storage: a layout manager
    /// holds its text storage weakly, and a storage that goes away leaves it
    /// with no glyphs to measure.
    private var textLayout: (storage: NSTextStorage, manager: NSLayoutManager, container: NSTextContainer)?
    private var lineIndex = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        label.numberOfLines = 0
        label.textAlignment = .center
        label.adjustsFontForContentSizeCategory = true
        label.font = Self.font
        label.textColor = Self.ink
        label.isAccessibilityElement = true
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        caret.backgroundColor = Self.ink.withAlphaComponent(0.55)
        caret.layer.cornerRadius = 1
        caret.isAccessibilityElement = false
        caret.isHidden = true
        label.addSubview(caret)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    deinit {
        loop?.cancel()
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil {
            stop()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // A new width lays the sentence out again; the caret is redrawn where
        // it now belongs rather than where the old width put it.
        buildLayout()
        if loop == nil {
            caret.layer.removeAllAnimations()
            caret.isHidden = true
        } else {
            startBlinking()
        }
    }

    // MARK: - Writing

    /// Begins a new page: the first line written in, then the other.
    @objc dynamic func play() {
        stop()
        // No writing-in for a reader who asked for less motion, or who is
        // listening rather than looking: the sentence is simply there.
        guard !UIAccessibility.isReduceMotionEnabled,
              !UIAccessibility.isVoiceOverRunning
        else {
            prepare(Self.lines.first ?? "")
            label.attributedText = full
            caret.isHidden = true
            return
        }
        lineIndex = Int.random(in: 0 ..< max(1, Self.lines.count))
        startBlinking()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, await self.writeThenErase() else { return }
            }
        }
    }

    /// Stops where it is: the sentence stays as far as it got, and stays put.
    @objc dynamic func stop() {
        loop?.cancel()
        loop = nil
        caret.layer.removeAllAnimations()
        caret.isHidden = true
        if let full {
            label.attributedText = full
        }
    }

    /// One sentence written in and taken back. Answers false when the task was
    /// cancelled, so the loop ends instead of writing into another page.
    private func writeThenErase() async -> Bool {
        let lines = Self.lines
        guard !lines.isEmpty else { return false }
        let line = lines[lineIndex % lines.count]
        lineIndex = (lineIndex + 1) % lines.count
        prepare(line)
        if Task.isCancelled { return false }

        let count = ranges.count
        let step = min(Self.slowestCharacter, max(Self.fastestCharacter, Self.writingSeconds / Double(max(count, 1))))
        for written in 0 ... count {
            if Task.isCancelled { return false }
            reveal(written)
            try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
        }
        if Task.isCancelled { return false }
        try? await Task.sleep(nanoseconds: UInt64(Self.heldSeconds * 1_000_000_000))
        if Task.isCancelled { return false }

        let erasing = max(Self.quickestErase, Self.erasingSeconds / Double(max(count, 1)))
        for written in stride(from: count, through: 0, by: -1) {
            if Task.isCancelled { return false }
            reveal(written)
            try? await Task.sleep(nanoseconds: UInt64(erasing * 1_000_000_000))
        }
        if Task.isCancelled { return false }
        try? await Task.sleep(nanoseconds: UInt64(Self.emptySeconds * 1_000_000_000))
        return !Task.isCancelled
    }

    /// Lays out `line` in full and hides all of it, ready to be revealed.
    private func prepare(_ line: String) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = 6
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.font,
            .foregroundColor: Self.ink,
            .paragraphStyle: paragraph,
        ]
        let full = NSAttributedString(string: line, attributes: attributes)
        self.full = full
        label.accessibilityLabel = line
        ranges = []
        var offset = 0
        for character in line {
            let length = character.utf16.count
            ranges.append(NSRange(location: offset, length: length))
            offset += length
        }
        label.attributedText = full
        buildLayout()
        reveal(0)
    }

    /// Shows the first `written` characters, and puts the caret after them.
    private func reveal(_ written: Int) {
        guard let full else { return }
        let shown = NSMutableAttributedString(attributedString: full)
        for (index, range) in ranges.enumerated() {
            let faded = max(0, min(1, (Double(written) - Double(index)) / Self.fadeCharacters))
            shown.addAttribute(
                .foregroundColor,
                value: Self.ink.withAlphaComponent(Self.inkAlpha * faded),
                range: range,
            )
        }
        label.attributedText = shown
        placeCaret(after: min(written, ranges.count))
    }

    // MARK: - The caret and its place on the fixed layout

    private func buildLayout() {
        guard let full, label.bounds.width > 0, label.bounds.height > 0 else {
            textLayout = nil
            return
        }
        let storage = NSTextStorage(attributedString: full)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: label.bounds.size)
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = 0
        container.lineBreakMode = .byWordWrapping
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        textLayout = (storage, manager, container)
    }

    private func placeCaret(after written: Int) {
        guard let layout = textLayout else { return }
        let manager = layout.manager
        let container = layout.container
        let frame: CGRect
        if written == 0 || ranges.isEmpty {
            let fragment = manager.numberOfGlyphs > 0
                ? manager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
                : manager.extraLineFragmentRect
            frame = CGRect(x: fragment.minX, y: fragment.minY, width: 2, height: fragment.height)
        } else {
            // The last character's whole glyph run, so a cluster of several
            // glyphs puts the caret after all of them.
            let characters = ranges[written - 1]
            let glyphs = manager.glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
            let rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
            let line = manager.lineFragmentRect(forGlyphAt: max(NSMaxRange(glyphs) - 1, 0), effectiveRange: nil)
            frame = CGRect(x: rect.maxX, y: line.minY, width: 2, height: line.height)
        }
        // UILabel centres its text block in its bounds; the layout starts at
        // the top, so the caret moves by the same amount the text does.
        let used = manager.usedRect(for: container)
        let offsetY = max(0, (label.bounds.height - used.height) / 2)
        let height = min(frame.height, label.bounds.height)
        caret.isHidden = false
        caret.frame = CGRect(
            x: min(max(frame.minX, 0), max(0, label.bounds.width - 2)),
            y: min(max(offsetY + frame.midY - height / 2, 0), max(0, label.bounds.height - height)),
            width: 2,
            height: height,
        )
    }

    private func startBlinking() {
        caret.alpha = 1
        caret.layer.removeAllAnimations()
        UIView.animate(
            withDuration: Self.blinkSeconds,
            delay: 0,
            options: [.repeat, .autoreverse, .curveLinear, .allowUserInteraction],
        ) {
            self.caret.alpha = 0
        }
    }
}
