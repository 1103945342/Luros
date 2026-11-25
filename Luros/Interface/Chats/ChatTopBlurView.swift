import UIKit

/// VariableBlur's alpha-mask CAFilter approach, on a backdrop UIKit does not reconfigure.
/// Reference: https://github.com/nikstar/VariableBlur
final class ChatTopBlurView: UIView {
    /// The backdrop is only worth having where the variable blur can read it.
    /// Before iOS 26 that filter does not exist, and a backdrop layer left
    /// with no filter to run draws itself as one opaque sheet in the page's
    /// colour — the black (or white) slab the conversation disappeared under
    /// whenever it scrolled beneath the bar. There a plain layer leaves the
    /// material below to do the work.
    override class var layerClass: AnyClass {
        guard #available(iOS 26, *) else { return CALayer.self }
        return NSClassFromString("CABackdropLayer") ?? CALayer.self
    }

    /// What the conversation is drawn on, so the frost above it takes that
    /// colour rather than the app's own background: a paper's own shade, the
    /// colour a picture shows across its top, or the page's background.
    var background: ChatBackground = .none {
        didSet { updateFrost() }
    }

    private let frost = CAGradientLayer()
    /// Before iOS 26 there is no variable blur to ask for: a material under a
    /// mask that fades it out does the same thing, and the frost below is what
    /// only the newer system needs.
    private var blurView: UIVisualEffectView?
    private var blurMask: CAGradientLayer?
    /// Over the material: the sheet's own colour, thinning downwards. The
    /// material alone is still see-through over a bright picture, and the bar
    /// has to read as the frosted edge of the page, not as a window onto it.
    private var veil: TintVeil?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = .clear
        frost.locations = [0, 1]
        layer.addSublayer(frost)
        updateFrost()
        guard #available(iOS 26, *) else {
            let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
            blur.isUserInteractionEnabled = false
            blur.isAccessibilityElement = false
            blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            let mask = CAGradientLayer()
            mask.colors = [UIColor.black.cgColor, UIColor.clear.cgColor]
            mask.locations = [0, 1]
            blur.layer.mask = mask
            addSubview(blur)
            let veil = TintVeil()
            veil.isUserInteractionEnabled = false
            veil.isAccessibilityElement = false
            veil.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(veil)
            blurView = blur
            blurMask = mask
            self.veil = veil
            updateFrost()
            return
        }
        guard let filterClass = NSClassFromString("CAFilter") as? NSObject.Type,
              let filter = filterClass.perform(
                  NSSelectorFromString("filterWithType:"),
                  with: "variableBlur",
              )?.takeUnretainedValue() as? NSObject
        else { return }

        let gradient = CAGradientLayer()
        gradient.frame = CGRect(x: 0, y: 0, width: 2, height: 128)
        gradient.colors = [UIColor.black.cgColor, UIColor.clear.cgColor]
        gradient.locations = frost.locations
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let mask = UIGraphicsImageRenderer(size: gradient.bounds.size, format: format)
            .image { gradient.render(in: $0.cgContext) }
        filter.setValue(5.0, forKey: "inputRadius")
        filter.setValue(mask.cgImage, forKey: "inputMaskImage")
        filter.setValue(true, forKey: "inputNormalizeEdges")
        layer.filters = [filter]
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(frame:)")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frost.frame = bounds
        blurView?.frame = bounds
        blurMask?.frame = bounds
        veil?.frame = bounds
        CATransaction.commit()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateFrost()
    }

    @objc dynamic private func updateFrost() {
        let color: UIColor?
        switch background {
        case .none:
            color = UIColor.pageBackground.resolvedColor(with: traitCollection)
        case let .paper(paper):
            color = ChatBackgroundView.base(paper, traits: traitCollection)
                .resolvedColor(with: traitCollection)
        case .image:
            // The picture's own colour across its top, or the whole picture's
            // when its top cannot be read yet, so the bar is never left with
            // nothing but the material's white.
            color = ChatBackgroundView.topTint() ?? ChatBackgroundView.pictureTint()
        }
        if blurView != nil {
            // The material is milk in light mode and thin in both, so the bar
            // read as a window onto the page and as white rather than as the
            // page. Its own colour, laid on all but solid and thinning only
            // at the very bottom, is the frosted edge it should be.
            frost.colors = [UIColor.clear.cgColor, UIColor.clear.cgColor]
            veil?.gradient.locations = [0, 0.7, 1]
            veil?.gradient.colors = color.map {
                [
                    $0.cgColor,
                    $0.withAlphaComponent(0.85).cgColor,
                    $0.withAlphaComponent(0).cgColor,
                ]
            } ?? [UIColor.clear.cgColor, UIColor.clear.cgColor, UIColor.clear.cgColor]
            return
        }
        frost.colors = color.map {
            [$0.cgColor, $0.withAlphaComponent(0).cgColor]
        } ?? [UIColor.clear.cgColor, UIColor.clear.cgColor]
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let window, layer.isKind(of: NSClassFromString("CABackdropLayer") ?? CALayer.self) else { return }
        layer.setValue(window.traitCollection.displayScale, forKey: "scale")
    }
}

/// A view whose layer is the gradient itself, so the veil is one layer and
/// nothing else: it sits over the material and thins out downwards.
private final class TintVeil: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }

    var gradient: CAGradientLayer { layer as! CAGradientLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        gradient.locations = [0, 1]
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(frame:)")
    }
}
