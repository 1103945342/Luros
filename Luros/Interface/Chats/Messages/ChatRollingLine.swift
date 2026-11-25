import UIKit

/// One line of text that rolls as it is replaced: the newest words of a
/// thought the model is still writing, drawn where a reader looks for them.
///
/// Running, only the end of the text is read — the newest words are what a
/// reader wants of a run still thinking, and reading a whole thought on every
/// token copies all of it. A change that lands while the previous roll is
/// still travelling replaces it at once, so the line never shows two texts at
/// once, and rolls are kept to `rollInterval`: a stream arrives faster than a
/// line can be read.
final class ChatRollingLine: UIView {
    /// The text this line draws, whole or already shortened by its owner.
    var text: String? {
        didSet { update() }
    }

    /// Whether more of the text is still being written: then the end of it is
    /// drawn and each change rolls, else the text is drawn once and still.
    var running = true {
        didSet { update() }
    }

    var font: UIFont = .preferredFont(forTextStyle: .subheadline) {
        didSet { label.font = font }
    }

    var textColor: UIColor = .tertiaryLabel {
        didSet { label.textColor = textColor }
    }

    /// The most the label is given: a thought runs to thousands of characters,
    /// and only the end of it is ever on a line.
    static let maximumLength = 200
    /// How often a roll may start.
    static let rollInterval: TimeInterval = 0.25
    /// How long one takes.
    private static let rollDuration: TimeInterval = 0.2

    var lineHeight: CGFloat { ceil(font.lineHeight) }

    /// What is drawn now, as VoiceOver reads it.
    private(set) var shownText: String?

    private let clip = UIView()
    private let label = UILabel()
    private var lastRoll = Date.distantPast

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        isUserInteractionEnabled = false
        clip.clipsToBounds = true
        addSubview(clip)
        label.font = font
        label.textColor = textColor
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingHead
        clip.addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(frame:)")
    }

    /// The start of `text` on one line of white space. Only the end is read:
    /// splitting a whole thought on every tick copies all of it.
    static func tail(of text: String) -> String {
        let end = text.suffix(maximumLength * 2)
        let line = end.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let truncated = line.count > maximumLength || text.utf8.count > end.utf8.count
        guard truncated else { return line }
        return "…" + String(line.suffix(maximumLength))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        clip.frame = bounds
        label.frame = CGRect(x: 0, y: 0, width: max(bounds.width, 1), height: lineHeight)
    }

    private func update() {
        let next = running ? text.map(Self.tail) : text
        label.lineBreakMode = running ? .byTruncatingHead : .byTruncatingTail
        guard next != shownText else { return }
        let previous = shownText
        shownText = next
        let rolls = running && previous != nil && window != nil
            && !UIAccessibility.isReduceMotionEnabled
            && Date().timeIntervalSince(lastRoll) >= Self.rollInterval
        guard rolls, let previous else {
            label.text = next
            return
        }
        lastRoll = Date()
        let line = max(bounds.height, lineHeight)
        // A roll still in flight leaves its copy behind; it goes now.
        for view in clip.subviews where view !== label {
            view.removeFromSuperview()
        }
        let leaving = UILabel()
        leaving.font = font
        leaving.textColor = textColor
        leaving.numberOfLines = 1
        leaving.lineBreakMode = running ? .byTruncatingHead : .byTruncatingTail
        leaving.text = previous
        leaving.frame = CGRect(x: 0, y: 0, width: max(bounds.width, 1), height: line)
        clip.insertSubview(leaving, belowSubview: label)
        label.text = next
        label.transform = CGAffineTransform(translationX: 0, y: line)
        UIView.animate(withDuration: Self.rollDuration, delay: 0, options: [.curveEaseOut]) {
            leaving.transform = CGAffineTransform(translationX: 0, y: -line)
            leaving.alpha = 0
            self.label.transform = .identity
        } completion: { _ in
            leaving.removeFromSuperview()
        }
    }
}