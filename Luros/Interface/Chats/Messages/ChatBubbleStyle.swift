import UIKit

/// What the reader's own messages are written on. Replies are never drawn on
/// it: they sit on the paper itself, which is the contrast the chat reads by.
///
/// Every style is a wash rather than a colour of its own — the message's text
/// is the app's label colour, black on a light page and white on a dark one —
/// so a style lightens or darkens the paper under it, and never fights the
/// words on top.
enum ChatBubbleStyle: String, CaseIterable {
    /// The accent of the moment, as the chat has always drawn it.
    case tinted
    /// A sheet of paper laid on the paper: a hairline edge, a shade paler.
    case paper
    /// No ground at all: a hairline drawn round the message.
    case outline
    /// Warm brown, at a strength that reads as kraft rather than as a tint.
    case kraft
    /// Cool ink, barely there: the quietest of the five.
    case inkWash

    var title: String {
        switch self {
        case .tinted: String(localized: "Tinted")
        case .paper: String(localized: "Paper")
        case .outline: String(localized: "Outline")
        case .kraft: String(localized: "Kraft")
        case .inkWash: String(localized: "Ink Wash")
        }
    }

    // MARK: - Storing

    static let changed = Notification.Name("com.fluoxetine.luros.chatBubbleStyleChanged")

    private static let key = "chat.bubbleStyle"

    static var current: ChatBubbleStyle {
        get {
            UserDefaults.standard.string(forKey: key)
                .flatMap(Self.init(rawValue:)) ?? .tinted
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    // MARK: - The ground

    /// The two stops of the ground and the edge drawn round it. `accent` is
    /// the app's tint, which the `tinted` style follows; the others ignore it.
    func colours(dark: Bool, accent: UIColor) -> (fill: [UIColor], border: UIColor?, width: CGFloat) {
        switch self {
        case .tinted:
            // The wash of the accent, edged so it reads on a paper of any
            // colour rather than sinking into it.
            return (
                [accent.withAlphaComponent(0.10), accent.withAlphaComponent(0.15)],
                accent.withAlphaComponent(dark ? 0.16 : 0.12),
                1,
            )
        case .paper:
            return dark
                ? ([Self.rgb(0x3A3A3C, alpha: 0.90), Self.rgb(0x2C2C2E, alpha: 0.94)], Self.white(0.06), 1)
                : ([Self.white(0.92), Self.rgb(0xF4F4F7, alpha: 0.88)], Self.black(0.05), 1)
        case .outline:
            return (
                [.clear, .clear],
                dark ? Self.white(0.20) : Self.black(0.16),
                1,
            )
        case .kraft:
            return dark
                ? ([Self.rgb(0xC79A63, alpha: 0.16), Self.rgb(0x8A5E2E, alpha: 0.12)], Self.rgb(0xC79A63, alpha: 0.14), 1)
                : ([Self.rgb(0xC08A4E, alpha: 0.14), Self.rgb(0x8A5E2E, alpha: 0.10)], Self.rgb(0x8A5E2E, alpha: 0.16), 1)
        case .inkWash:
            // Cool ink, and an edge fine enough to say the wash is deliberate
            // rather than a mark on the paper.
            return dark
                ? ([Self.white(0.05), Self.white(0.09)], Self.white(0.10), 1)
                : ([Self.rgb(0x0F1720, alpha: 0.05), Self.rgb(0x0F1720, alpha: 0.09)], Self.rgb(0x0F1720, alpha: 0.10), 1)
        }
    }

    /// A small rounded card of the ground, as the settings row shows it: wide
    /// enough to read as a bubble rather than as a swatch.
    func preview(size: CGSize, traits: UITraitCollection, accent: UIColor) -> UIImage {
        let dark = traits.userInterfaceStyle == .dark
        let skin = colours(
            dark: dark,
            accent: accent.resolvedColor(with: traits),
        )
        let format = UIGraphicsImageRendererFormat.preferred()
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: skin.width, dy: skin.width)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: rect.height * 0.42)
            path.addClip()
            let colours = skin.fill.map { $0.resolvedColor(with: traits).cgColor }
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colours as CFArray,
                locations: [0, 1],
            ) {
                context.cgContext.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: rect.midX, y: rect.minY),
                    end: CGPoint(x: rect.midX, y: rect.maxY),
                    options: [],
                )
            }
            if let border = skin.border, skin.width > 0 {
                border.resolvedColor(with: traits).setStroke()
                path.lineWidth = skin.width
                path.stroke()
            }
        }
    }

    private static func white(_ alpha: CGFloat) -> UIColor {
        UIColor(white: 1, alpha: alpha)
    }

    private static func black(_ alpha: CGFloat) -> UIColor {
        UIColor(white: 0, alpha: alpha)
    }

    private static func rgb(_ value: UInt32, alpha: CGFloat) -> UIColor {
        UIColor(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: alpha,
        )
    }
}
