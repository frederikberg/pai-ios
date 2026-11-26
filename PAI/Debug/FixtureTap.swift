#if DEBUG

    import UIKit

    /// Activates an element by its accessibility identifier, the way VoiceOver's double tap does,
    /// so a fixture run can press a real control with no touch to press it. What it did is
    /// reported as the `fixtureTap` fact, so a run that did not navigate says whether the element
    /// was never found or was found and ignored the activation.
    @MainActor
    enum FixtureTap {
        private struct Outcome {
            var visited = 0
            var identifiers: [String] = []
            var found = 0
            var activated = false
        }

        /// Retries for a few seconds: the element may not be in the tree at the first attempt.
        static func activate(identifier: String) async {
            var outcome = Outcome()
            var attempts = 0
            while attempts < 20, !outcome.activated {
                attempts += 1
                outcome = Outcome()
                for window in windows() { visit(identifier, in: window, outcome: &outcome, depth: 0) }
                if !outcome.activated { try? await Task.sleep(for: .milliseconds(500)) }
            }
            let sample = outcome.identifiers.prefix(6).joined(separator: "|")
            FixtureFacts.shared.record(
                "fixtureTap",
                "attempts=\(attempts) found=\(outcome.found) activated=\(outcome.activated) visited=\(outcome.visited) ids=\(outcome.identifiers.count) sample=\(sample)"
            )
        }

        private static func windows() -> [UIWindow] {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
        }

        private static func identifier(of object: NSObject) -> String? {
            if let view = object as? UIView { return view.accessibilityIdentifier }
            let selector = NSSelectorFromString("accessibilityIdentifier")
            guard object.responds(to: selector) else { return nil }
            return object.value(forKey: "accessibilityIdentifier") as? String
        }

        private static func visit(_ target: String, in object: NSObject, outcome: inout Outcome, depth: Int) {
            guard depth < 40, !outcome.activated else { return }
            outcome.visited += 1
            if let id = identifier(of: object), !id.isEmpty {
                outcome.identifiers.append(id)
                if id == target {
                    outcome.found += 1
                    if object.accessibilityActivate() { outcome.activated = true; return }
                }
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
            for child in children { visit(target, in: child, outcome: &outcome, depth: depth + 1) }
        }
    }

#endif
