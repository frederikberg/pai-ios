#if DEBUG

    import UIKit

    /// Activates an element by its accessibility identifier, the way VoiceOver's double tap does,
    /// so a fixture run can press a real control with no touch to press it.
    @MainActor
    enum FixtureTap {
        /// Retries for a few seconds: the element may not be in the tree at the first attempt.
        static func activate(identifier: String) async {
            for _ in 0..<20 {
                if let root = keyWindow(), activate(identifier, in: root) { return }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }

        private static func keyWindow() -> UIWindow? {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first(where: \.isKeyWindow)
        }

        private static func activate(_ identifier: String, in object: NSObject) -> Bool {
            if (object as? UIAccessibilityIdentification)?.accessibilityIdentifier == identifier,
                object.accessibilityActivate()
            {
                return true
            }
            var children: [NSObject] = []
            if let elements = object.accessibilityElements { children += elements.compactMap { $0 as? NSObject } }
            if let view = object as? UIView { children += view.subviews }
            let count = object.accessibilityElementCount()
            if count != NSNotFound, count > 0 {
                for index in 0..<count {
                    if let child = object.accessibilityElement(at: index) as? NSObject { children.append(child) }
                }
            }
            return children.contains { activate(identifier, in: $0) }
        }
    }

#endif
