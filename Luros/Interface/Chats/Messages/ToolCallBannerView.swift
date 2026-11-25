import UIKit

/// One line under a running summary, at the reading width, between hairlines
/// on a faint grey ground that runs the row's whole width: what the turn is
/// doing now.
///
/// A call leads with the symbol of the tool it made (`ToolSymbol`), then the
/// reason the agent gave for it, and the lines it added and removed at the
/// trailing end — kept out of the truncating text so a long reason never eats
/// them. A thought the model is still writing leads with the thought's own
/// symbol and rolls the newest of it (`ChatRollingLine`): the same line, the
/// current activity either way.
///
/// A new call, or a call's counts coming in, fades in, at once under Reduce
/// Motion. The full record stays in the trace the summary opens.
final class ToolCallBannerView: UIView {
    /// What the line says now.
    enum Content: Equatable {
        /// A call, and which one: `token` tells two calls worded the same
        /// apart, so the line redraws for the second.
        case call(ToolCallBanner, token: Int)
        /// A thought still being written, as much of it as the line shows.
        case thought(String)
    }

    static let height: CGFloat = 32
    static let iconSize: CGFloat = 15
    private static let iconSpacing: CGFloat = 8
    /// Between the call's words and its counts.
    private static let figuresSpacing: CGFloat = 8

    private let icon = UIImageView()
    private let reasonLabel = UILabel()
    private let figuresLabel = UILabel()
    private let thought = ChatRollingLine()
    /// The grey ground and its hairlines, drawn past the view's own edges
    /// to the row's: the line keeps the reading width, its ground does not.
    private let ground = UIView()
    private let topRule = UIView()
    private let bottomRule = UIView()
    private var shownContent: Content?

    /// How far the ground reaches past each side, set by the row.
    @objc dynamic var groundBleed = UIEdgeInsets.zero {
        didSet {
            if groundBleed != oldValue {
                setNeedsLayout()
            }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        ground.backgroundColor = UIColor.systemGray.withAlphaComponent(0.05)
        addSubview(ground)
        for rule in [topRule, bottomRule] {
            rule.backgroundColor = .separator
            ground.addSubview(rule)
        }
        icon.contentMode = .scaleAspectFit
        icon.tintColor = .secondaryLabel
        icon.isAccessibilityElement = false
        addSubview(icon)
        reasonLabel.numberOfLines = 1
        reasonLabel.lineBreakMode = .byTruncatingTail
        addSubview(reasonLabel)
        figuresLabel.numberOfLines = 1
        figuresLabel.setContentHuggingPriority(.required, for: .horizontal)
        figuresLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(figuresLabel)
        thought.font = .preferredFont(forTextStyle: .footnote)
        thought.textColor = .secondaryLabel
        thought.isHidden = true
        addSubview(thought)
        isAccessibilityElement = true
        accessibilityTraits = .staticText
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(frame:)")
    }

    /// `animated`: the same summary showing its next activity.
    func show(_ content: Content, animated: Bool) {
        guard content != shownContent else { return }
        let previous = shownContent
        shownContent = content
        reasonLabel.layer.removeAllAnimations()
        reasonLabel.font = .preferredFont(forTextStyle: .footnote)
        figuresLabel.font = .monospacedDigitSystemFont(ofSize: reasonLabel.font.pointSize, weight: .medium)
        switch content {
        case let .call(banner, _):
            thought.isHidden = true
            thought.text = nil
            reasonLabel.isHidden = false
            figuresLabel.isHidden = false
            icon.image = UIImage(systemName: ToolSymbol.name(for: banner.tool))
            reasonLabel.attributedText = Self.reasonLine(banner.reason, font: reasonLabel.font)
            let figures = Self.figuresLine(banner.change, font: figuresLabel.font)
            figuresLabel.attributedText = figures
            figuresLabel.isHidden = figures == nil
            accessibilityLabel = banner.reason
            accessibilityValue = Self.spokenCounts(banner.change)
        case let .thought(text):
            reasonLabel.isHidden = true
            reasonLabel.attributedText = nil
            figuresLabel.isHidden = true
            figuresLabel.attributedText = nil
            thought.isHidden = false
            thought.running = true
            thought.text = text
            icon.image = UIImage(systemName: "brain.head.profile")
            accessibilityLabel = String(localized: "Thoughts")
            accessibilityValue = thought.shownText
        }
        guard animated, previous != nil, window != nil,
              !UIAccessibility.isReduceMotionEnabled else { return }
        let fadeIn = CATransition()
        fadeIn.type = .fade
        fadeIn.duration = 0.2
        let changing: UIView = thought.isHidden ? reasonLabel : thought
        changing.layer.add(fadeIn, forKey: "content")
    }

    @objc dynamic func reset() {
        shownContent = nil
        reasonLabel.layer.removeAllAnimations()
        reasonLabel.attributedText = nil
        reasonLabel.isHidden = false
        figuresLabel.attributedText = nil
        figuresLabel.isHidden = true
        thought.text = nil
        thought.isHidden = true
        icon.image = nil
        accessibilityLabel = nil
        accessibilityValue = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let rule = 1 / max(traitCollection.displayScale, 1)
        ground.frame = bounds.inset(
            by: UIEdgeInsets(top: 0, left: -groundBleed.left, bottom: 0, right: -groundBleed.right),
        )
        topRule.frame = CGRect(x: 0, y: 0, width: ground.bounds.width, height: rule)
        bottomRule.frame = CGRect(x: 0, y: ground.bounds.height - rule, width: ground.bounds.width, height: rule)

        // The symbol leads, whichever side the text runs from, and what the
        // call changed stays at the other end of the words.
        let padding = ChatMessageRow.horizontalPadding
        let rightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft
        icon.frame = CGRect(
            x: rightToLeft ? bounds.width - padding - Self.iconSize : padding,
            y: ((bounds.height - Self.iconSize) / 2).rounded(),
            width: Self.iconSize,
            height: Self.iconSize,
        )
        let textStart = padding + Self.iconSize + Self.iconSpacing
        let textWidth = max(1, bounds.width - textStart - padding)
        let textArea = CGRect(x: rightToLeft ? padding : textStart, y: 0, width: textWidth, height: bounds.height)
        let figuresWidth = figuresLabel.isHidden ? 0 : ceil(figuresLabel.intrinsicContentSize.width)
        let gap = figuresWidth > 0 ? Self.figuresSpacing : 0
        let reasonsWidth = max(1, textArea.width - figuresWidth - gap)
        if rightToLeft {
            figuresLabel.frame = CGRect(x: textArea.minX, y: 0, width: figuresWidth, height: textArea.height)
            reasonLabel.frame = CGRect(
                x: textArea.minX + figuresWidth + gap, y: 0, width: reasonsWidth, height: textArea.height,
            )
        } else {
            figuresLabel.frame = CGRect(
                x: textArea.maxX - figuresWidth, y: 0, width: figuresWidth, height: textArea.height,
            )
            reasonLabel.frame = CGRect(x: textArea.minX, y: 0, width: reasonsWidth, height: textArea.height)
        }
        let line = thought.lineHeight
        thought.frame = CGRect(x: textArea.minX, y: ((bounds.height - line) / 2).rounded(), width: textArea.width, height: line)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory,
              case let .call(banner, _)? = shownContent else { return }
        reasonLabel.font = .preferredFont(forTextStyle: .footnote)
        figuresLabel.font = .monospacedDigitSystemFont(ofSize: reasonLabel.font.pointSize, weight: .medium)
        reasonLabel.attributedText = Self.reasonLine(banner.reason, font: reasonLabel.font)
        figuresLabel.attributedText = Self.figuresLine(banner.change, font: figuresLabel.font)
        setNeedsLayout()
    }

    /// The reason the agent gave the call, on one line: each run of white
    /// space, line breaks included, as one space. The file it touched is not
    /// named here — the trace the summary opens has it.
    private static func reasonLine(_ reason: String, font: UIFont) -> NSAttributedString {
        let line = reason.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return NSAttributedString(string: line, attributes: [.font: font, .foregroundColor: UIColor.secondaryLabel])
    }

    /// "+12 −3", the lines a file tool added and removed; nil for a call that
    /// touched no file.
    private static func figuresLine(_ change: ToolCallBanner.LineChange?, font: UIFont) -> NSAttributedString? {
        guard let change else { return nil }
        let figures = NSMutableAttributedString()
        figures.append(NSAttributedString(
            string: "+\(change.added)",
            attributes: [.font: font, .foregroundColor: UIColor.systemGreen],
        ))
        figures.append(NSAttributedString(
            string: " −\(change.removed)",
            attributes: [.font: font, .foregroundColor: UIColor.systemRed],
        ))
        return figures
    }

    /// The counts in words: "12 lines added and 3 lines removed".
    private static func spokenCounts(_ change: ToolCallBanner.LineChange?) -> String? {
        guard let change else { return nil }
        let added = change.added == 1
            ? String(localized: "1 line added")
            : String(localized: "\(change.added) lines added")
        let removed = change.removed == 1
            ? String(localized: "1 line removed")
            : String(localized: "\(change.removed) lines removed")
        return ListFormatter.localizedString(byJoining: [added, removed])
    }
}