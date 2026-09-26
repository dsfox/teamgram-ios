import UIKit

// The UIScene lifecycle, which an app linked against the iOS 27 SDK must adopt
// or it is stopped at launch (ice9 #183). Upstream Telegram-iOS has not moved
// yet - tools/upstream_scene_check.py asks every month - so this is ours, kept
// in one file of its own: when upstream moves, take theirs and delete this.
//
// It changes as little as it can. AppDelegate still builds the window during
// launch, before any scene exists; this attaches that window to the scene when
// the scene connects, and hands every event the scene now receives to the
// application-delegate method that used to receive it, so what happens next is
// still upstream's code.
@objc(Ice9SceneDelegate)
final class Ice9SceneDelegate: UIResponder, UIWindowSceneDelegate {
    private var appDelegate: AppDelegate? {
        return UIApplication.shared.delegate as? AppDelegate
    }

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene, let appDelegate = self.appDelegate else {
            return
        }
        if let window = appDelegate.window {
            window.windowScene = windowScene
            window.makeKeyAndVisible()
        }

        // What a launch used to find in its launch options now arrives here.
        for context in connectionOptions.urlContexts {
            self.open(context)
        }
        for activity in connectionOptions.userActivities {
            let _ = appDelegate.application(UIApplication.shared, continue: activity, restorationHandler: { _ in })
        }
        if let shortcutItem = connectionOptions.shortcutItem {
            appDelegate.application(UIApplication.shared, performActionFor: shortcutItem, completionHandler: { _ in })
        }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        for context in URLContexts {
            self.open(context)
        }
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        let _ = self.appDelegate?.application(UIApplication.shared, continue: userActivity, restorationHandler: { _ in })
    }

    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem, completionHandler: @escaping (Bool) -> Void) {
        guard let appDelegate = self.appDelegate else {
            completionHandler(false)
            return
        }
        appDelegate.application(UIApplication.shared, performActionFor: shortcutItem, completionHandler: completionHandler)
    }

    func sceneWillResignActive(_ scene: UIScene) {
        self.appDelegate?.applicationWillResignActive(UIApplication.shared)
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        self.appDelegate?.applicationDidEnterBackground(UIApplication.shared)
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        self.appDelegate?.applicationWillEnterForeground(UIApplication.shared)
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        self.appDelegate?.applicationDidBecomeActive(UIApplication.shared)
    }

    // What WindowRootViewController says when it finds a scene already
    // connected; under this lifecycle the window is made before there is one.
    @available(iOS 26.0, *)
    func preferredWindowingControlStyle(for windowScene: UIWindowScene) -> UIWindowScene.WindowingControlStyle {
        return .minimal
    }

    private func open(_ context: UIOpenURLContext) {
        var options: [UIApplication.OpenURLOptionsKey: Any] = [.openInPlace: context.options.openInPlace]
        if let sourceApplication = context.options.sourceApplication {
            options[.sourceApplication] = sourceApplication
        }
        let _ = self.appDelegate?.application(UIApplication.shared, open: context.url, options: options)
    }
}
