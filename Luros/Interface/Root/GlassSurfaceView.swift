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

extension UITableViewCell {
    /// A row of a sidebar's list as a pane of the drawer's glass rather than a
    /// white card: the row itself keeps no ground, so the wallpaper behind the
    /// drawer reads through the list, and a picked row wears the light ring
    /// `SidebarFocusGlow` runs round it.
    func useGlassSidebarRow() {
        backgroundColor = .clear
        backgroundConfiguration = .clear()
        selectionStyle = .default
        guard selectedBackgroundView == nil else { return }
        selectedBackgroundView = SidebarFocusGlow()
    }
}

/// The ring a picked sidebar row wears: light running round its edge, in a
/// colour the wallpaper gave, with the inside left open so the row under it
/// reads exactly as it did. A ring rather than a fill, because a fill laid
/// over the glass turns into the grey band a picked row used to be.
final class SidebarFocusGlow: UIView {
    private let sweep = CAGradientLayer()
    private let ring = CAShapeLayer()
    private var observer: NSObjectProtocol?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = .clear
        layer.cornerRadius = 10
        layer.cornerCurve = .continuous
        sweep.type = .conic
        sweep.startPoint = CGPoint(x: 0.5, y: 0.5)
        sweep.endPoint = CGPoint(x: 0.5, y: 0)
        sweep.locations = [0, 0.40, 0.5, 0.60, 1]
        layer.addSublayer(sweep)
        ring.fillColor = UIColor.clear.cgColor
        ring.lineWidth = 2
        ring.lineCap = .round
        layer.mask = ring
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
        // Square and larger than the row, so the ring's light keeps covering
        // it however far round it has turned.
        let side = max(bounds.width, bounds.height) * 1.6
        sweep.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        sweep.position = CGPoint(x: bounds.midX, y: bounds.midY)
        let edge = UIBezierPath(
            roundedRect: bounds.insetBy(dx: 1, dy: 1),
            cornerRadius: max(0, layer.cornerRadius - 1),
        ).cgPath
        ring.frame = bounds
        ring.path = edge
        CATransaction.commit()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            sweep.removeAnimation(forKey: "flow")
            return
        }
        setNeedsLayout()
        guard sweep.animation(forKey: "flow") == nil else { return }
        let flow = CABasicAnimation(keyPath: "transform.rotation.z")
        flow.fromValue = 0
        flow.toValue = Double.pi * 2
        flow.duration = 2.6
        flow.repeatCount = .infinity
        flow.isRemovedOnCompletion = false
        sweep.add(flow, forKey: "flow")
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if traitCollection.userInterfaceStyle != previous?.userInterfaceStyle {
            reloadColors()
        }
    }

    /// The colour the ring runs in: the wallpaper's own, so a picked row
    /// belongs to the sheet behind the drawer rather than to the system's blue.
    private static func tint(traits: UITraitCollection) -> UIColor {
        switch ChatBackground.current {
        case .image:
            ChatBackgroundView.topTint() ?? UIColor.systemBlue
        case let .paper(paper):
            ChatBackgroundView.base(paper, traits: traits)
        case .none:
            UIColor.systemBlue
        }
    }

    private func reloadColors() {
        let tint = Self.tint(traits: traitCollection)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        tint.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        // The light that runs round the ring: the wallpaper's colour, lifted
        // towards white where the sweep's head is.
        let head = UIColor(
            red: min(1, red + 0.55),
            green: min(1, green + 0.45),
            blue: min(1, blue + 0.35),
            alpha: 1,
        )
        sweep.colors = [
            tint.withAlphaComponent(0).cgColor,
            tint.withAlphaComponent(0.55).cgColor,
            head.withAlphaComponent(0.95).cgColor,
            tint.withAlphaComponent(0.55).cgColor,
            tint.withAlphaComponent(0).cgColor,
        ]
    }
}
