// Lakr233's Inhouse Code, from FlowDown.
// I CAN DO WHAT THE FUCK I WANT.

import UIKit

/// FlowDown's square icon tile with its caption underneath.
///
/// The panel sits below the composer's glass card, on the chat's background
/// rather than on it, so the tile carries that same material itself: its 5%
/// wash was all but invisible over a picture, and the icon and caption with
/// it.
final class ComposerGiantButton: UIButton {
    private let iconView = UIImageView()
    private let backgroundView = UIVisualEffectView()
    private let labelView = UILabel()
    @objc dynamic var actionBlock: () -> Void = {}

    init(title: String, icon: String) {
        super.init(frame: .zero)
        if #available(iOS 26, *) {
            backgroundView.effect = UIGlassEffect()
        } else {
            // What the composer's own card is made of here: readable over a
            // background, and still letting the page behind it through.
            backgroundView.effect = UIBlurEffect(style: .systemThinMaterial)
        }
        backgroundView.clipsToBounds = true
        backgroundView.layer.cornerRadius = 16
        backgroundView.layer.cornerCurve = .continuous
        backgroundView.isUserInteractionEnabled = false
        addSubview(backgroundView)
        iconView.contentMode = .scaleAspectFit
        iconView.tintColor = .label.withAlphaComponent(0.75)
        iconView.image = UIImage(named: icon)?.withRenderingMode(.alwaysTemplate)
        backgroundView.contentView.addSubview(iconView)
        labelView.text = title
        labelView.textAlignment = .center
        labelView.font = .preferredFont(forTextStyle: .footnote)
        labelView.adjustsFontForContentSizeCategory = true
        labelView.adjustsFontSizeToFitWidth = true
        labelView.minimumScaleFactor = 0.7
        labelView.textColor = .secondaryLabel
        backgroundView.contentView.addSubview(labelView)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = title
        addTarget(self, action: #selector(onTapped), for: .primaryActionTriggered)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(title:icon:)")
    }

    @objc dynamic private func onTapped() {
        actionBlock()
    }

    override var isHighlighted: Bool {
        didSet {
            backgroundView.contentView.alpha = isHighlighted ? 0.4 : 1
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        backgroundView.frame = bounds
        // The caption is on the glass with the icon now, so the tile's height
        // is the button's whole height: the icon sits in what the caption
        // leaves over it.
        let labelHeight = max(32, labelView.font.lineHeight + 12)
        let iconArea = max(0, bounds.height - labelHeight)
        iconView.frame = CGRect(
            x: (bounds.width - 28) / 2,
            y: (iconArea - 28) / 2,
            width: 28,
            height: 28,
        )
        labelView.frame = CGRect(
            x: 8,
            y: iconArea,
            width: max(0, bounds.width - 16),
            height: min(labelHeight, bounds.height),
        )
    }
}