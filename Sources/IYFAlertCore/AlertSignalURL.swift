import Foundation

public enum AlertSignalURL {
    public static func baseURL(from alertURL: URL) -> URL? {
        let components = URLComponents(url: alertURL, resolvingAgainstBaseURL: false)
        let sport = components?.queryItems?.first(where: { $0.name == "sport" })?.value
        let stoken = components?.queryItems?.first(where: { $0.name == "stoken" })?.value
        guard let sport, let port = Int(sport), port > 0, let stoken, !stoken.isEmpty else {
            return nil
        }
        return URL(string: "http://127.0.0.1:\(port)/\(stoken)/")
    }

    public static func signalURL(baseURL: URL, path: String) -> URL? {
        URL(string: path, relativeTo: baseURL)?.absoluteURL
    }
}
