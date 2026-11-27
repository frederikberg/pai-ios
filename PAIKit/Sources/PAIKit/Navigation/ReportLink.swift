import Foundation

/// A link into the Reports app: `https://<backend host>/apps/reports` (the list) or
/// `.../apps/reports/<id>` (one report — what an agent puts in its reply, `DynamicReport.url`).
public enum ReportLink: Equatable, Sendable {
    case list
    case report(id: String)

    /// A report id is a UUID; anything else is no report.
    public static func isValidID(_ id: String) -> Bool {
        guard (1...64).contains(id.utf8.count) else { return false }
        return id.unicodeScalars.allSatisfy {
            ($0.value < 128) && (CharacterSet.alphanumerics.contains($0) || $0 == "-")
        }
    }

    /// The link `url` stands for when it is an https link into this backend's Reports app, else
    /// `nil` — a link to any other host is an ordinary external link.
    public static func parse(_ url: URL, backendHost: String?) -> ReportLink? {
        guard url.scheme?.lowercased() == "https", let backendHost,
            url.host?.lowercased() == backendHost.lowercased()
        else { return nil }
        return parse(percentEncodedPath: url.path(percentEncoded: true))
    }

    /// The same link as a path alone: used where the host is already settled (a universal link
    /// the system matched to the app's own domain).
    public static func parse(percentEncodedPath path: String) -> ReportLink? {
        let segments = path.split(separator: "/").map(String.init)
        guard segments.count >= 2, segments[0] == "apps", segments[1] == "reports" else { return nil }
        if segments.count == 2 { return .list }
        guard segments.count == 3 else { return nil }
        let id = segments[2].removingPercentEncoding ?? segments[2]
        return isValidID(id) ? .report(id: id) : nil
    }
}
