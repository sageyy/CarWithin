import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        DiagnosticLogStore.shared.startSession()
        CrashReporter.install()
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Receiver", sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        let navigation = UINavigationController(rootViewController: ReceiverViewController())
        let appearance = UINavigationBarAppearance()
        appearance.configureWithDefaultBackground()
        appearance.titleTextAttributes = [.foregroundColor: UIColor.label]
        navigation.navigationBar.standardAppearance = appearance
        navigation.navigationBar.scrollEdgeAppearance = appearance
        navigation.navigationBar.tintColor = .systemBlue
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        self.window = window
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        RenderState.setBackground(false)
        DiagnosticLogStore.shared.markForeground()
        DiagnosticLogStore.shared.flush()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        RenderState.setBackground(true)
        DiagnosticLogStore.shared.markBackground()
        DiagnosticLogStore.shared.flush()
    }

    func sceneWillTerminate(_ scene: UIScene) {
        DiagnosticLogStore.shared.markCleanExit()
        DiagnosticLogStore.shared.flush()
    }
}
