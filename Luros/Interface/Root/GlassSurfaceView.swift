import SnapKit
import UIKit

/// Liquid glass, the surface everything in this app sits on: thick rounded
/// glass over a live backdrop, refracting what lies behind it and catching the
/// light across the top (owner, 2026-11-06).
///
/// On iOS 26 it is `UIGlassEffect` itself. Before that there is no glass to
/// ask for, so it is drawn here in full by `GlassRenderer`: a Metal layer over
/// a `CABackdropLayer`, the private layer UIKit's own materials read, which
/// gives the page behind it live without a snapshot each frame. A surface with
/// no corner stays `systemChromeMaterial`, the panel edge it always was.
final class GlassSurfaceView: UIView {
    private let glassHost = GlassHost()
    private let radius: CGFloat

    /// `material` is the blur a corner-less surface falls back to before iOS
    /// 26, where there is no glass: the panels want the chrome one, a drawer
    /// wants a thinner sheet so the page behind it still reads.
    init(cornerRadius: CGFloat = 0, material: UIBlurEffect.Style = .systemChromeMaterial) {
        radius = cornerRadius
        super.init(frame: .zero)

        if #available(iOS 26, *) {
            let effect = UIVisualEffectView()
            effect.effect = UIGlassEffect()
            effect.layer.cornerRadius = cornerRadius
            effect.layer.cornerCurve = .continuous
            effect.clipsToBounds = true
            addSubview(effect)
            effect.snp.makeConstraints { $0.edges.equalToSuperview() }
        } else if cornerRadius > 0 {
            glassHost.isUserInteractionEnabled = false
            glassHost.radius = cornerRadius
            glassHost.isHidden = true
            addSubview(glassHost)
            glassHost.snp.makeConstraints { $0.edges.equalToSuperview() }
            GlassRenderer.shared.prepare { [weak self] in
                self?.glassHost.isHidden = false
                self?.glassHost.setNeedsLayout()
            }
        } else {
            let effect = UIVisualEffectView()
            effect.effect = UIBlurEffect(style: material)
            addSubview(effect)
            effect.snp.makeConstraints { $0.edges.equalToSuperview() }
        }
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(cornerRadius:)")
    }
}

/// A view holding the backdrop and the Metal layer that reads it: the two are
/// kept as sublayers of the same view, so the backdrop sits right behind the
/// Metal sheet and Metal samples what it draws.
private final class GlassHost: UIView {
    var radius: CGFloat = 0
    private var backdropLayer: CALayer?
    private let metalHost = MetalHost()
    private var link: CADisplayLink?

    override init(frame: CGRect) {
        super.init(frame: frame)
        if let cls = NSClassFromString("CABackdropLayer") as? CALayer.Type {
            let backdrop = cls.init()
            backdrop.setValue("default", forKey: "groupName")
            layer.insertSublayer(backdrop, at: 0)
            backdropLayer = backdrop
        }
        metalHost.isUserInteractionEnabled = false
        addSubview(metalHost)
        metalHost.snp.makeConstraints { $0.edges.equalToSuperview() }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            link?.invalidate()
            link = nil
            return
        }
        if link == nil {
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.preferredFramesPerSecond = 60
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        setNeedsLayout()
    }

    @objc private func tick() {
        guard let metal = metalHost.layer as? CAMetalLayer,
              !isHidden,
              alpha > 0.01,
              GlassRenderer.shared.isReady,
              let backdrop = backdropLayer,
              let window
        else { return }
        let scale = window.traitCollection.displayScale
        GlassRenderer.shared.draw(
            GlassRenderer.Request(
                bounds: bounds,
                radius: radius,
                backdrop: backdrop,
                scale: scale,
                dark: traitCollection.userInterfaceStyle == .dark
            ),
            into: metal
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        backdropLayer?.frame = bounds
        guard let metal = metalHost.layer as? CAMetalLayer,
              let window
        else { return }
        let scale = window.traitCollection.displayScale
        metal.device = GlassRenderer.shared.device
        metal.isOpaque = false
        metal.contentsScale = scale
        metal.drawableSize = CGSize(
            width: max(1, bounds.width * scale),
            height: max(1, bounds.height * scale)
        )
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        setNeedsLayout()
    }
}

private final class MetalHost: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
}

class SidebarGlassCell: UITableViewCell {
    private var glow: SidebarFocusGlow?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        isOpaque = false
        contentView.isOpaque = false
        automaticallyUpdatesBackgroundConfiguration = false
        backgroundConfiguration = .clear()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // contentConfiguration may replace contentView. Attach to the cell itself.
        if isSelected || isHighlighted || isFocused {
            let ring = glow ?? SidebarFocusGlow()
            glow = ring
            if ring.superview !== self { addSubview(ring) }
            bringSubviewToFront(ring)
            ring.frame = bounds
        } else {
            glow?.removeFromSuperview()
        }
    }

    override func updateConfiguration(using state: UICellConfigurationState) {
        super.updateConfiguration(using: state)
        setNeedsLayout()
    }
}

/// Two solid strokes on one closed path keep the outline visible on mixed wallpapers.
final class SidebarFocusGlow: UIView {
    private let ring = CAShapeLayer()
    private let keyline = CAShapeLayer()
    private var observer: NSObjectProtocol?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = .clear
        ring.fillColor = nil
        ring.lineWidth = 2
        keyline.fillColor = nil
        layer.addSublayer(keyline)
        layer.addSublayer(ring)
        reloadColors()
        observer = NotificationCenter.default.addObserver(
            forName: ChatBackground.changed,
            object: nil,
            queue: .main,
        ) { [weak self] _ in
            self?.reloadColors()
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(frame:)")
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let pixel = 1 / max(1, traitCollection.displayScale)
        // Leave room for the grouped section's corner clip and the row separator.
        let rect = bounds.insetBy(dx: 8, dy: 4)
        let radius = min(14, min(rect.width, rect.height) / 2)
        let edge = radius > 0 ? CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil) : nil
        keyline.frame = bounds
        keyline.path = edge
        keyline.lineWidth = ring.lineWidth + 2 * pixel
        ring.frame = bounds
        ring.path = edge
        CATransaction.commit()
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if traitCollection.userInterfaceStyle != previous?.userInterfaceStyle {
            reloadColors()
        }
    }

    private func reloadColors() {
        let traits = traitCollection
        let base = UIColor.systemBackground.resolvedColor(with: traits)
        let tint: UIColor
        let opacity: CGFloat
        switch ChatBackground.current {
        case .image:
            tint = ChatBackgroundView.pictureTint() ?? base
            opacity = ChatBackground.opacity
        case let .paper(paper):
            tint = ChatBackgroundView.base(paper, traits: traits)
            opacity = 1
        case .none:
            tint = base
            opacity = 1
        }
        func rgb(_ color: UIColor) -> (CGFloat, CGFloat, CGFloat) {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
            return (r, g, b)
        }
        let (r, g, b) = rgb(tint), (br, bg, bb) = rgb(base)
        func linear(_ channel: CGFloat, over ground: CGFloat) -> CGFloat {
            let c = channel * opacity + ground * (1 - opacity)
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(r, over: br) + 0.7152 * linear(g, over: bg) + 0.0722 * linear(b, over: bb)
        let darkInk = (luminance + 0.05) / 0.05 >= 1.05 / (luminance + 0.05)
        let ink: UIColor = darkInk ? .black : .white
        // An opposite hairline keeps the edge visible over mixed patches in photos.
        keyline.strokeColor = (darkInk ? UIColor.white : UIColor.black).withAlphaComponent(0.85).cgColor
        ring.strokeColor = ink.cgColor
    }
}
