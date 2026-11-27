import PAIKit
import UIKit

/// The Home Screen quick actions (a long press on the app icon), declared in `Config/Info.plist`
/// under `UIApplicationShortcutItems`. A scene-based app is handed the chosen item by its scene
/// delegate, or at connection time on a cold launch; SwiftUI has neither, so the app delegate
/// names a scene delegate for the window scene, and both paths park the item's link in
/// `DeepLinkInbox` like any other way in from outside.
enum HomeScreenQuickActions {
    /// `UIApplicationShortcutItemType` in `Config/Info.plist`.
    static let newTodoType = "com.frederikberg.pai.new-todo"
    static let describeTodoType = "com.frederikberg.pai.describe-todo"

    static func link(for item: UIApplicationShortcutItem) -> DeepLink? {
        switch item.type {
        case newTodoType: .newTodo
        case describeTodoType: .describeTodo
        default: nil
        }
    }

    @MainActor
    static func open(_ item: UIApplicationShortcutItem) -> Bool {
        guard let link = link(for: item) else { return false }
        DeepLinkInbox.shared.receive(link)
        return true
    }
}

extension PushRegistrar {
    func application(
        _ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        // A cold launch from a quick action delivers the item here and to no delegate method.
        if let item = options.shortcutItem { _ = HomeScreenQuickActions.open(item) }
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        if connectingSceneSession.role == .windowApplication {
            configuration.delegateClass = HomeScreenQuickActionSceneDelegate.self
        }
        return configuration
    }
}

/// Receives a quick action chosen while the app is already running.
final class HomeScreenQuickActionSceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(
        _ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        MainActor.assumeIsolated { completionHandler(HomeScreenQuickActions.open(shortcutItem)) }
    }
}
