import UIKit

/// The background the reader chose, behind a screen of its own: the picture or
/// paper at the lowest layer, read again whenever the setting changes or the
/// screen comes forward.
///
/// A screen that carries one leaves its own ground open — the Git screen, a
/// sheet — so what the reader picked shows through where the system's grey used
/// to be, as it does behind the conversation.
final class AppBackgroundView: ChatBackgroundView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        refresh()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refresh),
            name: ChatBackground.changed,
            object: nil,
        )
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        refresh()
    }

    @objc dynamic func refresh() {
        background = ChatBackground.current
        opacity = ChatBackground.opacity
    }

    /// Puts one at the back of `host`, filling it.
    @discardableResult
    static func install(in host: UIView) -> AppBackgroundView {
        let view = AppBackgroundView(frame: host.bounds)
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.insertSubview(view, at: 0)
        return view
    }
}
