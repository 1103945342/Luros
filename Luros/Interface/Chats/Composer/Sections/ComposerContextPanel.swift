import UIKit

/// How full the conversation's context is, opened from the ring beside the model
/// row: the bar the agent's own compaction threshold is marked on, what is used
/// against what the model holds, and a button to compact now.
///
/// The layout is aimini's `ContextInfoPanel`, read as points: no title band, a
/// capsule bar with the threshold ticked on it, three lines at the left and one
/// capsule action at the right. The figure is the last request's own input token
/// count, the one the provider reported, not a total for the conversation: a
/// total grows without ever falling when a compaction happens, and says nothing
/// about the room left.
final class ComposerContextPanel: ComposerPanel {
    /// Where the agent compacts on its own: kwwk's `AgentAutoCompactOptions`
    /// default, which Luros does not override. The tick on the bar and the
    /// sentence under it both read this one figure.
    /// What the reader set in Settings ▸ Chat: the share at which a
    /// conversation compacts itself, shown here as a percentage.
    static var compactionThresholdPercent: Int {
        Int((Preferences.compressionThreshold * 100).rounded())
    }

    private static let barHeight: CGFloat = 8
    private static let quotaBarHeight: CGFloat = 6
    private static let refreshButtonSize: CGFloat = 28

    private let track = UIView()
    private let fill = UIView()
    private let thresholdTick = UIView()
    private let usedLabel = UILabel()
    private let limitLabel = UILabel()
    private let thresholdLabel = UILabel()
    private let compactButton = UIButton(type: .system)

    private let quotaDivider = UIView()
    private let quotaTrack = UIView()
    private let quotaFill = UIView()
    private let quotaTitleLabel = UILabel()
    private let quotaDetailLabel = UILabel()
    private let quotaRefreshButton = UIButton(type: .system)

    private var usedTokens = 0
    private var limitTokens = 0
    private var compactEnabled = true
    private var isCompacting = false
    private var quotaDisplay: QuotaFormatting.ComposerQuotaDisplay?

    /// The height last handed to the composer, so a body measured against a
    /// width it did not have yet is corrected once, not on every pass.
    private var publishedHeight: CGFloat = 0

    /// Asked for when the button is tapped.
    var onCompact: (() -> Void)?
    var onRefreshQuota: (() -> Void)?

    override func initializeViews() {
        super.initializeViews()

        setHeaderless()

        track.layer.cornerRadius = Self.barHeight / 2
        track.layer.cornerCurve = .continuous
        track.backgroundColor = UIColor.separator.withAlphaComponent(0.4)
        track.clipsToBounds = true
        body.addSubview(track)

        fill.layer.cornerRadius = Self.barHeight / 2
        fill.layer.cornerCurve = .continuous
        track.addSubview(fill)

        // The threshold, as a hairline standing on the bar rather than a
        // sentence about it: how close the fill is to compacting is read at a
        // glance, which is the reason to open this at all.
        thresholdTick.backgroundColor = UIColor.label.withAlphaComponent(0.55)
        track.addSubview(thresholdTick)

        usedLabel.font = Self.font(.footnote, weight: .semibold)
        usedLabel.textColor = .label
        usedLabel.adjustsFontForContentSizeCategory = true
        usedLabel.numberOfLines = 0
        body.addSubview(usedLabel)

        for label in [limitLabel, thresholdLabel] {
            label.font = .preferredFont(forTextStyle: .caption2)
            label.textColor = .secondaryLabel
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
            body.addSubview(label)
        }

        var configuration = UIButton.Configuration.filled()
        configuration.cornerStyle = .capsule
        configuration.image = Self.boltImage
        configuration.imagePadding = ComposerMetrics.Spacing.xs
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 6,
            leading: ComposerMetrics.Spacing.md,
            bottom: 6,
            trailing: ComposerMetrics.Spacing.md,
        )
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = ComposerContextPanel.font(.caption1, weight: .semibold)
            return outgoing
        }
        compactButton.configuration = configuration
        compactButton.addTarget(self, action: #selector(compactTapped), for: .primaryActionTriggered)
        body.addSubview(compactButton)

        quotaDivider.backgroundColor = UIColor.separator.withAlphaComponent(0.35)
        body.addSubview(quotaDivider)

        quotaTrack.layer.cornerRadius = Self.quotaBarHeight / 2
        quotaTrack.layer.cornerCurve = .continuous
        quotaTrack.backgroundColor = UIColor.separator.withAlphaComponent(0.4)
        quotaTrack.clipsToBounds = true
        body.addSubview(quotaTrack)

        quotaFill.layer.cornerRadius = Self.quotaBarHeight / 2
        quotaFill.layer.cornerCurve = .continuous
        quotaTrack.addSubview(quotaFill)

        quotaTitleLabel.font = Self.font(.footnote, weight: .semibold)
        quotaTitleLabel.textColor = .label
        quotaTitleLabel.adjustsFontForContentSizeCategory = true
        quotaTitleLabel.numberOfLines = 0
        body.addSubview(quotaTitleLabel)

        quotaDetailLabel.font = .preferredFont(forTextStyle: .caption2)
        quotaDetailLabel.textColor = .secondaryLabel
        quotaDetailLabel.adjustsFontForContentSizeCategory = true
        quotaDetailLabel.numberOfLines = 0
        body.addSubview(quotaDetailLabel)

        quotaRefreshButton.setImage(
            UIImage(systemName: "arrow.clockwise")?.withConfiguration(
                UIImage.SymbolConfiguration(pointSize: 13, weight: .medium),
            ),
            for: .normal,
        )
        quotaRefreshButton.tintColor = .secondaryLabel
        quotaRefreshButton.accessibilityLabel = String(localized: "Refresh Quota")
        quotaRefreshButton.addTarget(self, action: #selector(luros_refreshQuotaTapped), for: .primaryActionTriggered)
        body.addSubview(quotaRefreshButton)

        updateText()
        updateQuotaViews()
    }

    override var preferredHeight: CGFloat {
        // Measured against the body's own width once it has one; the composer
        // hands the panel its width right after the height it asks for, and
        // `layoutSubviews` corrects the answer when the guess was wrong.
        let base = ComposerMetrics.Spacing.sm
            + Self.barHeight
            + ComposerMetrics.Spacing.sm
            + rowHeight(for: measuredWidth)
            + ComposerMetrics.Spacing.sm
        return base + quotaSectionHeight(for: measuredWidth)
    }

    func set(
        usedTokens: Int,
        limitTokens: Int,
        compactable: Bool,
        compacting: Bool,
    ) {
        self.usedTokens = usedTokens
        self.limitTokens = limitTokens
        compactEnabled = compactable
        isCompacting = compacting
        updateText()
        setNeedsLayout()
        // A folded panel publishes nothing. The composer lays out whatever has
        // a height, so a figure arriving while it is folded must not put the
        // card back over a body it is not showing.
        if isExpanded, !isSuppressed {
            publishedHeight = preferredHeight
            heightPublisher.send(publishedHeight)
        }
    }

    func setProviderQuota(_ display: QuotaFormatting.ComposerQuotaDisplay?) {
        quotaDisplay = display
        updateQuotaViews()
        setNeedsLayout()
        if isExpanded, !isSuppressed {
            publishedHeight = preferredHeight
            heightPublisher.send(publishedHeight)
        }
    }

    private var fraction: Double? {
        guard limitTokens > 0 else { return nil }
        return min(1, max(0, Double(usedTokens) / Double(limitTokens)))
    }

    /// The width the body will have: its own once the composer has placed the
    /// panel, and before that the screen's less the panel's own insets.
    private var measuredWidth: CGFloat {
        if body.bounds.width > 0 { return body.bounds.width }
        return max(0, UIScreen.main.bounds.width - ComposerMetrics.Spacing.md * 4)
    }

    private func rowHeight(for width: CGFloat) -> CGFloat {
        let button = compactButton.intrinsicContentSize
        let text = textColumnHeight(for: width - button.width - ComposerMetrics.Spacing.sm)
        return max(button.height, text)
    }

    private func textColumnHeight(for width: CGFloat) -> CGFloat {
        [usedLabel, limitLabel, thresholdLabel].reduce(0) { total, label in
            total + label.sizeThatFits(
                CGSize(width: max(0, width), height: .greatestFiniteMagnitude),
            ).height
        }
    }

    private func updateText() {
        let ratio = fraction
        let threshold = Double(Self.compactionThresholdPercent) / 100

        usedLabel.text = String(localized: "\(Self.tokenText(usedTokens)) tokens used")
        if let ratio {
            limitLabel.text = String(
                localized: "Limit \(Self.tokenText(limitTokens)) (\(Int((ratio * 100).rounded()))%)",
            )
        } else {
            limitLabel.text = String(localized: "Context limit unknown")
        }
        thresholdLabel.text = String(localized: "Auto-compacts at \(Self.compactionThresholdPercent)%")

        let level: UIColor = if ratio == nil {
            .tertiaryLabel
        } else if let ratio, ratio >= 1 {
            .systemRed
        } else if let ratio, ratio >= threshold {
            .systemOrange
        } else {
            .systemGreen
        }
        fill.backgroundColor = level

        updateButton()
    }

    /// The action's three states: ready, busy, and not this conversation's to
    /// take — the same shape each time, so the panel does not jump.
    private func updateButton() {
        guard var configuration = compactButton.configuration else { return }
        let enabled = compactEnabled && !isCompacting

        configuration.showsActivityIndicator = isCompacting
        configuration.image = isCompacting ? nil : Self.boltImage
        configuration.title = isCompacting
            ? String(localized: "Compressing context")
            : String(localized: "Compact Now")
        // The fill is the window's tint, which on a monochrome accent is the
        // text's own colour: white in the dark. So is the title, unless it
        // asks the accent what sits on it.
        configuration.baseBackgroundColor = enabled ? .tintColor : UIColor.tertiarySystemFill
        configuration.baseForegroundColor = enabled ? AppAccent.foreground(glass: .white) : .secondaryLabel
        compactButton.configuration = configuration
        compactButton.isUserInteractionEnabled = enabled
        compactButton.accessibilityLabel = isCompacting
            ? String(localized: "Compressing context")
            : String(localized: "Compact This Conversation Now")
        compactButton.accessibilityTraits = enabled ? .button : [.button, .notEnabled]
    }

    private static var boltImage: UIImage? {
        UIImage(
            systemName: "bolt.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold),
        )
    }

    /// A text style's own size and scaling, at another weight: the system has
    /// no one-call answer for this, and a descriptor keeps Dynamic Type.
    private static func font(_ style: UIFont.TextStyle, weight: UIFont.Weight) -> UIFont {
        let base = UIFont.preferredFont(forTextStyle: style)
        let descriptor = base.fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: weight],
        ])
        return UIFont(descriptor: descriptor, size: 0)
    }

    private static func tokenText(_ tokens: Int) -> String {
        // aimini's `formatTokenCount`: one decimal in the thousands and above,
        // so a window reads "200.0k" rather than seven digits.
        switch tokens {
        case 1_000_000_000...:
            String(format: "%.1fB", Double(tokens) / 1_000_000_000)
        case 1_000_000...:
            String(format: "%.1fM", Double(tokens) / 1_000_000)
        case 1_000...:
            String(format: "%.1fk", Double(tokens) / 1_000)
        default:
            String(tokens)
        }
    }

    @objc private func compactTapped() {
        guard compactEnabled, !isCompacting else { return }
        onCompact?()
    }

    @objc(luros_refreshQuotaTapped) private dynamic func luros_refreshQuotaTapped() {
        onRefreshQuota?()
    }

    @objc(luros_updateQuotaViews) private dynamic func updateQuotaViews() {
        let shown = quotaDisplay != nil
        for view in [quotaDivider, quotaTitleLabel, quotaDetailLabel, quotaRefreshButton] {
            view.isHidden = !shown
        }
        guard let quotaDisplay else {
            quotaTrack.isHidden = true
            return
        }
        quotaTitleLabel.text = quotaDisplay.headline
        quotaDetailLabel.text = quotaDisplay.detail
        if let pct = quotaDisplay.usedPercent {
            quotaTrack.isHidden = false
            let ratio = NSDecimalNumber(decimal: pct).doubleValue / 100.0
            let color: UIColor = if quotaDisplay.isExhausted || ratio >= 0.95 {
                .systemRed
            } else if ratio >= 0.75 {
                .systemOrange
            } else {
                .systemGreen
            }
            quotaFill.backgroundColor = color
        } else {
            quotaTrack.isHidden = true
        }
    }

    private func quotaSectionHeight(for width: CGFloat) -> CGFloat {
        guard let quotaDisplay else { return 0 }
        let textWidth = max(0, width - Self.refreshButtonSize - ComposerMetrics.Spacing.sm)
        let titleH = quotaTitleLabel.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height
        let detailH = quotaDetailLabel.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height
        let textH = max(Self.refreshButtonSize, titleH + detailH)
        let barH: CGFloat = quotaDisplay.usedPercent != nil ? (Self.quotaBarHeight + ComposerMetrics.Spacing.xs) : 0
        return 1 + ComposerMetrics.Spacing.sm + barH + textH + ComposerMetrics.Spacing.sm
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let width = body.bounds.width
        let ratio = fraction ?? 0
        let threshold = CGFloat(Self.compactionThresholdPercent) / 100

        track.frame = CGRect(x: 0, y: 0, width: width, height: Self.barHeight)
        fill.frame = CGRect(x: 0, y: 0, width: width * ratio, height: Self.barHeight)
        thresholdTick.frame = directionalFrame(CGRect(
            x: min(max(0, width - 2), width * threshold - 1),
            y: 0,
            width: 2,
            height: Self.barHeight,
        ))

        let buttonSize = compactButton.intrinsicContentSize
        let row = max(buttonSize.height, textColumnHeight(for: width - buttonSize.width - ComposerMetrics.Spacing.sm))
        let rowTop = track.frame.maxY + ComposerMetrics.Spacing.sm

        var y = rowTop
        let textWidth = max(0, width - buttonSize.width - ComposerMetrics.Spacing.sm)
        for label in [usedLabel, limitLabel, thresholdLabel] {
            let height = label.sizeThatFits(
                CGSize(width: textWidth, height: .greatestFiniteMagnitude),
            ).height
            label.frame = CGRect(x: 0, y: y, width: textWidth, height: height)
            y = label.frame.maxY
        }

        compactButton.frame = directionalFrame(CGRect(
            x: width - buttonSize.width,
            y: rowTop + (row - buttonSize.height) / 2,
            width: buttonSize.width,
            height: buttonSize.height,
        ))

        var totalBottom = rowTop + row + ComposerMetrics.Spacing.sm
        if let quotaDisplay {
            quotaDivider.frame = CGRect(x: 0, y: totalBottom, width: width, height: 1)
            var qy = quotaDivider.frame.maxY + ComposerMetrics.Spacing.sm
            if let pct = quotaDisplay.usedPercent {
                let qRatio = CGFloat(max(0, min(1, NSDecimalNumber(decimal: pct).doubleValue / 100.0)))
                quotaTrack.frame = CGRect(x: 0, y: qy, width: width, height: Self.quotaBarHeight)
                quotaFill.frame = CGRect(x: 0, y: 0, width: width * qRatio, height: Self.quotaBarHeight)
                qy = quotaTrack.frame.maxY + ComposerMetrics.Spacing.xs
            }
            let refreshSize = Self.refreshButtonSize
            let qTextWidth = max(0, width - refreshSize - ComposerMetrics.Spacing.sm)
            let qTitleH = quotaTitleLabel.sizeThatFits(CGSize(width: qTextWidth, height: .greatestFiniteMagnitude)).height
            let qDetailH = quotaDetailLabel.sizeThatFits(CGSize(width: qTextWidth, height: .greatestFiniteMagnitude)).height
            quotaTitleLabel.frame = directionalFrame(CGRect(x: 0, y: qy, width: qTextWidth, height: qTitleH))
            quotaDetailLabel.frame = directionalFrame(CGRect(x: 0, y: quotaTitleLabel.frame.maxY, width: qTextWidth, height: qDetailH))
            let qTextBlockH = max(refreshSize, qTitleH + qDetailH)
            quotaRefreshButton.frame = directionalFrame(CGRect(
                x: width - refreshSize,
                y: qy + (qTextBlockH - refreshSize) / 2,
                width: refreshSize,
                height: refreshSize,
            ))
            totalBottom = qy + qTextBlockH + ComposerMetrics.Spacing.sm
        }

        // The height published at the moment the panel opened was measured
        // against a width the body did not have yet. Now that it has one, hand
        // the composer the real figure — once.
        let height = totalBottom
        if isExpanded, !isSuppressed, abs(publishedHeight - height) > 0.5 {
            publishedHeight = height
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isExpanded, !self.isSuppressed else { return }
                self.heightPublisher.send(self.preferredHeight)
            }
        }
    }
}
