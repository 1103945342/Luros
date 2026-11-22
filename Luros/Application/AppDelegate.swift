import AlertController
import LurosCore
import LurosProtocol
import UIKit

/// Not `@main`: `main.swift` clears saved scenes before `UIApplicationMain`.
final class AppDelegate: UIResponder, UIApplicationDelegate {
    @objc dynamic func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]?,
    ) -> Bool {
        ExecutableWatch.start {
            let alert = UIAlertController(
                title: String(localized: "Luros Updated or Removed"),
                message: String(localized: "Quit to apply the change, or keep using this version for now."),
                preferredStyle: .alert,
            )
            alert.addAction(UIAlertAction(title: String(localized: "Later"), style: .cancel))
            alert.addAction(UIAlertAction(title: String(localized: "Quit"), style: .destructive) { _ in
                QuietExit.run()
            })
            Self.presentWhenActive(alert, in: application)
        }
        // before anything reads the data folder
        let recovered = DataFolder.container.flatMap { ContainerDataFolder.recover(from: $0, into: .app) }
        AppJournal.start()
        if let recovered {
            AppJournal.note(recovered)
        }
        NetworkAccess.start()
        ConversationNotices.start()
        // the progress card and the alerts carry the app's icon, as Fila's do
        AlertControllerConfiguration.alertImage = UIImage(named: "AppIconMark")
        // the app's own accent (`AppAccent`); the library's default is red
        AlertControllerConfiguration.accentColor = AppAccent.color(glass: .systemBlue)
        AlertControllerConfiguration.accentForegroundColor = AppAccent.foreground(glass: .white)
        ConsoleLaunch.start()
        // models.dev's catalog: the shipped copy in place, then a newer one if
        // the copy on this device is old (ModelDataRefresh).
        ModelDataRefresh.start()
        // The WeChat channel writes its replies in the app's own language,
        // which the host cannot read for itself: told at launch, and again
        // when the channel's page opens. The host may still be starting,
        // hence the retries.
        Task { await ChannelLanguage.pushIfChanged(retries: 5) }
        return true
    }

    /// A quit takes the Live Activity with it: nothing would update it
    /// after (`ChatWidgetPublisher.endActivitiesForQuit`).
    @objc dynamic func applicationWillTerminate(_: UIApplication) {
        ChatWidgetPublisher.endActivitiesForQuit()
    }

    @objc dynamic func application(
        _: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options _: UIScene.ConnectionOptions,
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }

    /// The watch fires once, and may fire with no scene active: at launch,
    /// in the background, or on resume before the scene activates. The
    /// notice then waits for the next activation instead of being lost.
    @objc private dynamic static func presentWhenActive(_ alert: UIAlertController, in application: UIApplication) {
        let active = application.connectedScenes.first { $0.activationState == .foregroundActive }
        guard let scene = active as? UIWindowScene else {
            var observer: NSObjectProtocol?
            observer = NotificationCenter.default.addObserver(
                forName: UIScene.didActivateNotification,
                object: nil,
                queue: .main,
            ) { _ in
                MainActor.assumeIsolated {
                    if let observer {
                        NotificationCenter.default.removeObserver(observer)
                    }
                    presentWhenActive(alert, in: application)
                }
            }
            return
        }
        // In front of whatever the scene shows: a root already presenting a
        // sheet or another alert would drop it.
        guard var top = scene.keyWindow?.rootViewController else { return }
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        top.present(alert, animated: true)
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    @objc dynamic var window: UIWindow?

    func sceneDidBecomeActive(_: UIScene) {
        (window?.rootViewController as? RootInterfaceController)?.checkShareInbox()
    }

    @objc dynamic func scene(
        _ scene: UIScene,
        willConnectTo _: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions,
    ) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.tintColor = AppAccent.windowTint
        let root = RootInterfaceController()
        let urls = connectionOptions.urlContexts.map(\.url)
        // Queue attachments before the view starts restoring the launch conversation.
        root.attachFiles(urls.filter(Self.isAttachment).sorted { $0.absoluteString < $1.absoluteString })
        window.rootViewController = root
        window.makeKeyAndVisible()
        self.window = window
        // A cold launch by Open in Luros or an `lurosdev://` link: the URL
        // comes with the scene. Opened on the next turn, once the root is on
        // screen to present from.
        DispatchQueue.main.async { [weak self] in self?.openSpecialURL(in: urls, scene: scene) }
    }

    /// Open in Luros, or an `lurosdev://` link, while the app runs.
    @objc dynamic func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
        guard let scene = scene as? UIWindowScene else { return }
        let urls = contexts.map(\.url).sorted { $0.absoluteString < $1.absoluteString }
        (window?.rootViewController as? RootInterfaceController)?.attachFiles(urls.filter(Self.isAttachment))
        openSpecialURL(in: urls, scene: scene)
    }

    private static func isAttachment(_ url: URL) -> Bool {
        url.isFileURL && TransferKind(fileName: url.lastPathComponent) == nil
    }

    private func openSpecialURL(in urls: [URL], scene: UIWindowScene) {
        if let special = urls.first(where: { !Self.isAttachment($0) }), !LurosLinkRouter.open(special, in: scene) {
            TransferOpener.open(special, in: scene)
        }
    }
}
