import PAIKit
import SwiftUI
import WebKit

/// One report's page in a web view that gives its scripts none of the app's powers
/// (``ReportSandbox`` says how and why). The page arrives as a string, fetched by the app with the
/// token and loaded with no base URL, so its origin is opaque and the token is nowhere a script
/// can reach. The one way out is `window.parent.postMessage`, forwarded as JSON to `onMessage`;
/// what `onMessage` answers (the `init` message) is posted back into the page.
///
/// Pinch zoom works whatever the page's viewport tag says, which is what a figure needs.
struct ReportWebView: UIViewRepresentable {
    let html: String
    /// The page's message as JSON; returns the JSON of a message to post back, if any.
    let onMessage: (String) -> String?
    /// A link the reader tapped in the page, to confirm before it opens outside the app.
    let onOpenLink: (URL) -> Void
    /// The page could not be shown at all.
    let onFailure: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Nothing is shared with anything else: no cookies, no cache, no storage on disk.
        configuration.websiteDataStore = .nonPersistent()
        configuration.ignoresViewportScaleLimits = true
        let controller = configuration.userContentController
        controller.add(context.coordinator, name: ReportSandbox.messageHandlerName)
        controller.addUserScript(
            WKUserScript(source: ReportSandbox.bridgeScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        context.coordinator.webView = webView
        let coordinator = context.coordinator
        let page = html
        Task { @MainActor in await coordinator.load(page) }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: ReportSandbox.messageHandlerName)
        webView.stopLoading()
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        var parent: ReportWebView
        weak var webView: WKWebView?

        init(_ parent: ReportWebView) {
            self.parent = parent
        }

        /// Installs the network rules, then loads the page. A page is never loaded without them:
        /// when they cannot be compiled the reader gets the failure instead of an open page.
        func load(_ html: String) async {
            guard let webView else { return }
            do {
                let list: WKContentRuleList? = try await WKContentRuleListStore.default()
                    .compileContentRuleList(
                        forIdentifier: "pai-report-sandbox", encodedContentRuleList: ReportSandbox.contentRules)
                guard let list else { throw CocoaError(.coderInvalidValue) }
                webView.configuration.userContentController.add(list)
            } catch {
                parent.onFailure("The page could not be opened safely.")
                return
            }
            webView.loadHTMLString(html, baseURL: nil)
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == ReportSandbox.messageHandlerName, let json = message.body as? String,
                let reply = parent.onMessage(json)
            else { return }
            webView?.evaluateJavaScript(ReportSandbox.deliveryScript(messageJSON: reply), completionHandler: nil)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async
            -> WKNavigationActionPolicy
        {
            switch ReportSandbox.decide(
                url: navigationAction.request.url, isTappedLink: navigationAction.navigationType == .linkActivated)
            {
            case .allow: return .allow
            case .confirmOpening(let url):
                parent.onOpenLink(url)
                return .cancel
            case .cancel: return .cancel
            }
        }

        /// `target="_blank"` and `window.open`: never a second web view, only the confirmed link.
        func webView(
            _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if case .confirmOpening(let url) = ReportSandbox.decide(
                url: navigationAction.request.url, isTappedLink: true)
            {
                parent.onOpenLink(url)
            }
            return nil
        }
    }
}
