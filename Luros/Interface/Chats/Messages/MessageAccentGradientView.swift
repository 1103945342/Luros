import UIKit

/// The user bubble's ground, shared by the image album.
///
/// The gradient is the view's own layer, so it follows the view's frame the
/// way UIKit moves views: at once outside an animation block, and never on
/// its own. A free-standing sublayer animates every frame change implicitly,
/// so a row out of the pool would slide its ground from the size its
/// previous message left it at.
///
/// The ground itself is `ChatBubbleStyle`: five washes, one of which follows
/// the app's tint. The style is read when the view is drawn, and again when
/// the reader picks another one, so the transcript changes without being
/// rebuilt.
final class MessageAccentGradientView: UIView {
    override class var layerClass: AnyClass {
        CAGradientLayer.self
    }

    @objc dynamic private var gradient: CAGradientLayer {
        layer as! CAGradientLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        gradient.startPoint = CGPoint(x: 0.6, y: 0)
        gradient.endPoint = CGPoint(x: 0.4, y: 1)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(stylingChanged),
            name: ChatBubbleStyle.changed,
            object: nil,
        )
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(frame:)")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        updateColors()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateColors()
    }

    @objc dynamic var showsConversationBorder = false {
        didSet { updateColors() }
    }

    @objc private func stylingChanged() {
        updateColors()
    }

    @objc dynamic private func updateColors() {
        let skin = ChatBubbleStyle.current.colours(
            dark: traitCollection.userInterfaceStyle == .dark,
            accent: tintColor.resolvedColor(with: traitCollection),
        )
        gradient.colors = skin.fill.map(\.cgColor)
        // A message from another channel keeps its green edge, whatever the
        // ground is: the edge says where the message came from.
        if showsConversationBorder {
            layer.borderWidth = 1.5
            layer.borderColor = UIColor.systemGreen.resolvedColor(with: traitCollection).cgColor
        } else {
            layer.borderWidth = skin.width
            layer.borderColor = skin.border?.cgColor
        }
    }
}
