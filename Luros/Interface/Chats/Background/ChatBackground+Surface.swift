import UIKit

extension ChatBackground {
    /// Which end of the screen a surface stands at: the bar's band at the top,
    /// the composer's and its panels' at the bottom.
    enum Band {
        case top, bottom
    }

    /// Whether the reader chose anything. With nothing chosen every surface
    /// keeps the colour it always had.
    static var isChosen: Bool {
        if case .none = current { return false }
        return true
    }

    /// The colour the chosen background shows across `band`, as the chat's bar
    /// takes its own: the paper's shade, the picture's colour there, or the
    /// page's ground when nothing is chosen.
    static func tint(traits: UITraitCollection, band: Band) -> UIColor {
        switch current {
        case .none:
            .pageBackground.resolvedColor(with: traits)
        case let .paper(paper):
            ChatBackgroundView.base(paper, traits: traits).resolvedColor(with: traits)
        case .image:
            ChatBackgroundView.tint(band) ?? .pageBackground.resolvedColor(with: traits)
        }
    }

    /// The ground of a card drawn over the background — the composer's, a
    /// panel's: the background's own colour mixed most of the way into the
    /// colour it would have had with nothing chosen, so the card belongs to
    /// what is behind it and what is written on it keeps its contrast.
    static func surface(
        traits: UITraitCollection,
        band: Band = .bottom,
        fallback: UIColor,
    ) -> UIColor {
        guard isChosen else { return fallback }
        return tint(traits: traits, band: band)
            .blended(with: fallback.resolvedColor(with: traits), amount: 0.8)
    }
}

private extension UIColor {
    /// This colour moved `amount` of the way towards `other` (0 keeps this
    /// one, 1 is `other`). Both are colours already resolved for a trait
    /// collection, so nothing here reads the environment.
    func blended(with other: UIColor, amount: CGFloat) -> UIColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        guard getRed(&r1, green: &g1, blue: &b1, alpha: &a1),
              other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        else { return self }
        let t = min(max(amount, 0), 1)
        return UIColor(
            red: r1 + (r2 - r1) * t,
            green: g1 + (g2 - g1) * t,
            blue: b1 + (b2 - b1) * t,
            alpha: a1 + (a2 - a1) * t,
        )
    }
}
