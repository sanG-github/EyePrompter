import SwiftUI
import UIKit

/// Publishes the window scene's real interface orientation. A size change alone
/// cannot tell landscape-left from landscape-right (the size is identical), so we
/// observe the scene geometry directly.
final class OrientationObserver: ObservableObject {
    @Published private(set) var orientation: UIInterfaceOrientation = .portrait
    private var observation: NSKeyValueObservation?
    private var notification: NSObjectProtocol?

    init() {
        refresh()
        if let scene = Self.scene {
            observation = scene.observe(\.effectiveGeometry, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.refresh() }
            }
        }
        // Fallback: device rotation notifications (fires after the UI has rotated).
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        notification = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self?.refresh() }
        }
    }

    deinit {
        if let notification { NotificationCenter.default.removeObserver(notification) }
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }

    private static var scene: UIWindowScene? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    }

    func refresh() {
        guard let scene = Self.scene else { return }
        let o = scene.effectiveGeometry.interfaceOrientation
        if o != .unknown, o != orientation { orientation = o }
    }
}
