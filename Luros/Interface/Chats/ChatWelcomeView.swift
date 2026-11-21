import UIKit

/// The page's opening: a line in the middle of a conversation that has none.
///
/// The sentence is laid out whole and its ink arrives a character at a time.
/// A label whose text grew would re-wrap and slide the line with every
/// character typed; with the layout fixed, only the colour moves.
///
/// It takes no touch and is one element to VoiceOver, which reads the whole
/// sentence even while it is still being written.
final class ChatWelcomeView: UIView {
    /// The lines the page may open with, one picked per new conversation so
    /// two of them do not begin with the same words.
    static var lines: [String] {
        [
            String(localized: "Hello, is there anything I can help you with?"),
            String(localized: "What would you like to do right now?"),
        ]
    }

    /// How long one character takes to arrive, and how many characters of
    /// progress a character takes to fade in: 1.5 makes the newest pair or so
    /// trail behind, which is what reads as ink arriving rather than as a
    /// line of lamps switching on.
    private static let secondsPerCharacter = 0.028
    private static let fadeCharacters = 1.5

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
    private var full: NSAttributedString?
    private var ranges: [NSRange] = []
    private var reveal: CADisplayLink?
    private var started: CFTimeInterval = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        label.numberOfLines = 0
        label.textAlignment = .center
        label.adjustsFontForContentSizeCategory = true
        label.font = Self.font
        label.textColor = Self.ink
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
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
        reveal?.invalidate()
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil {
            stop()
        }
    }

    // MARK: - Writing

    /// Begins a new page: another line, written in again.
    @objc dynamic func play() {
        stop()
        let line = Self.lines.randomElement() ?? ""
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
        // The label is the element: a sentence on a plain view would never
        // be read.
        label.accessibilityLabel = line

        // One range a drawn character, in UTF-16 offsets, so the colouring
        // walks what is drawn rather than what is stored.
        ranges = []
        var offset = 0
        for character in line {
            let length = character.utf16.count
            ranges.append(NSRange(location: offset, length: length))
            offset += length
        }

        // No writing-in for a reader who asked for less motion, or who is
        // listening rather than looking: the sentence is simply there.
        guard !UIAccessibility.isReduceMotionEnabled,
              !UIAccessibility.isVoiceOverRunning
        else {
            label.attributedText = full
            return
        }
        render(0)
        started = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        reveal = link
    }

    /// Stops the writing where it is: the sentence stays as far as it got.
    @objc dynamic func stop() {
        reveal?.invalidate()
        reveal = nil
        if let full {
            label.attributedText = full
        }
    }

    @objc dynamic private func tick() {
        let progress = (CACurrentMediaTime() - started) / Self.secondsPerCharacter
        render(progress)
        if progress >= Double(ranges.count) + Self.fadeCharacters {
            stop()
        }
    }

    @objc dynamic private func render(_ progress: Double) {
        guard let full else { return }
        let shown = NSMutableAttributedString(attributedString: full)
        for (index, range) in ranges.enumerated() {
            let faded = max(0, min(1, (progress - Double(index)) / Self.fadeCharacters))
            shown.addAttribute(
                .foregroundColor,
                value: Self.ink.withAlphaComponent(Self.inkAlpha * faded),
                range: range,
            )
        }
        label.attributedText = shown
    }
}
