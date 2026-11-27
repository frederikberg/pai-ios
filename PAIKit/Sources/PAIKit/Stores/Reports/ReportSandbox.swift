import Foundation

/// What a report's web view allows. The page is an agent's HTML, and an agent can be steered by
/// what it read, so the page runs with none of the app's powers
/// (`docs/architecture/dynamic-reports.md` in pai-cloud, *The page is never trusted*). The web
/// gets that from an opaque-origin sandboxed frame; the phone gets it from four things together:
///
/// - The page is fetched by the app, with the token, and loaded as a string with no base URL: its
///   origin is opaque, so it has no storage, and the token is never anywhere a script can reach.
/// - The web view has a non-persistent data store, so it shares no cookies with anything.
/// - ``contentRules`` refuse every network request but the template's font hosts, the same
///   allowance the page's own response header makes (`connect-src 'none'`, fonts only).
/// - ``NavigationDecision`` lets a link out of the page only as a tapped link the reader confirms,
///   and keeps the page's own navigations inside it.
///
/// The only way from the page to the app is ``ReportProtocol``, parsed by the one function that
/// treats everything as untrusted.
public enum ReportSandbox {
    /// WebKit content-blocker rules: block every http(s) and ws(s) load, then let the font hosts
    /// through (a later `ignore-previous-rules` wins). `data:` and `blob:` images are not network
    /// loads and need no rule. No alternation in a `url-filter`, hence one rule per host.
    public static let contentRules = """
        [
          {"trigger": {"url-filter": "^https?://"}, "action": {"type": "block"}},
          {"trigger": {"url-filter": "^wss?://"}, "action": {"type": "block"}},
          {"trigger": {"url-filter": "^https://fonts\\\\.googleapis\\\\.com/"}, "action": {"type": "ignore-previous-rules"}},
          {"trigger": {"url-filter": "^https://fonts\\\\.gstatic\\\\.com/"}, "action": {"type": "ignore-previous-rules"}}
        ]
        """

    /// The name the host's script message handler answers to.
    public static let messageHandlerName = "paiReport"

    /// Runs in the page before its own scripts: it forwards the page's `window.parent.postMessage`
    /// calls to the host. A web view shows the page as its top-level document, so `window.parent`
    /// is the window itself and the page's message arrives as a `message` event on it; this
    /// listener hands those of this protocol to the native handler, as JSON. The page's own
    /// `message` listener gets the host's `init` the same way, and sees its own outgoing messages
    /// as events too, which carry a `type` it does not handle.
    public static let bridgeScript = """
        window.addEventListener('message', function (event) {
          var data = event.data;
          if (event.source !== window || !data || data.protocol !== '\(ReportProtocol.name)') return;
          if (data.type !== 'ready' && data.type !== 'answers' && data.type !== 'add-to-message') return;
          try {
            window.webkit.messageHandlers.\(messageHandlerName).postMessage(JSON.stringify(data));
          } catch (e) {}
        });
        """

    /// The script that delivers a host message to the page: an ordinary `message` event on its
    /// window, whose `source` is the window (its `parent`).
    public static func deliveryScript(messageJSON: String) -> String {
        "window.postMessage(\(messageJSON), '*');"
    }

    /// What to do with a navigation the page asks for.
    public enum NavigationDecision: Equatable, Sendable {
        /// Let the web view do it: the page's own load and an in-page `#anchor`.
        case allow
        /// Ask the reader, then open in the system browser.
        case confirmOpening(URL)
        case cancel
    }

    /// `isTappedLink` is whether a person's tap on a link started it (not a script or a redirect).
    public static func decide(url: URL?, isTappedLink: Bool) -> NavigationDecision {
        guard let url, let scheme = url.scheme?.lowercased() else { return .allow }
        if scheme == "about" { return .allow }
        if (scheme == "http" || scheme == "https") && isTappedLink { return .confirmOpening(url) }
        return .cancel
    }
}
