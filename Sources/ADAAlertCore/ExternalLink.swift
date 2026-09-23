import Foundation

/// The alert page asks the native helper to open its feedback link by posting
/// the URL to the `adaOpen` WebKit message handler, so the link lands in the
/// user's default browser instead of navigating the alert's own WebView away.
///
/// Only http(s) is honored. The message body is whatever the page's script
/// posted, so without this check the page could hand `NSWorkspace` a `file:`,
/// `javascript:` or app URL (`claude://`, …) and launch something else.
public enum ExternalLink {
    /// The URL to open for an `adaOpen` message body, or nil when the body is
    /// not a string, does not parse as a URL, is not http/https, or names no
    /// host (a bare `https:` parses, but there is nothing to open). The scheme
    /// comparison is case-insensitive, as URL schemes are.
    public static func openableURL(from body: Any) -> URL? {
        guard let string = body as? String,
              let url = URL(string: string),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty
        else {
            return nil
        }
        return url
    }
}
