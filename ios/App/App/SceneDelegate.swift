import SwiftUI
import UIKit
import LEDUnionApp

@MainActor
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private let model = NativeAppModel()

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        NativeAppModel.refreshShortcuts = { LEDUnionShortcuts.updateAppShortcutParameters() }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UIHostingController(rootView: NativeRootView(model: model))
        self.window = window
        window.makeKeyAndVisible()
    }
}
