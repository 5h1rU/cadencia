import SwiftUI
import UIKit

final class CadenciaAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        RouteExplorerOrientation.supported
    }
}

/// Landscape belongs to the explorer; the rest of the app keeps its portrait layout.
@MainActor enum RouteExplorerOrientation {
    static var supported: UIInterfaceOrientationMask = .portrait
    private static weak var scene: UIWindowScene?

    static func enter(in scene: UIWindowScene) {
        self.scene = scene
        update(.landscape, in: scene)
    }

    static func leave() {
        supported = .portrait
        if let scene { update(.portrait, in: scene) }
        scene = nil
    }

    private static func update(_ orientations: UIInterfaceOrientationMask, in scene: UIWindowScene) {
        supported = orientations
        var controller = scene.keyWindow?.rootViewController
        while let current = controller {
            current.setNeedsUpdateOfSupportedInterfaceOrientations()
            controller = current.presentedViewController
        }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientations))
    }
}

struct RouteExplorerRotation: UIViewControllerRepresentable {
    final class Controller: UIViewController {
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            if let scene = view.window?.windowScene { RouteExplorerOrientation.enter(in: scene) }
        }
    }
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ uiViewController: Controller, context: Context) {}
}
