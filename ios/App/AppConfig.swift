import Foundation

enum AppConfig {
    /// Backend base URL, from the `DMAPIBaseURL` Info.plist key (build setting `API_BASE_URL`).
    static var apiBaseURL: URL {
        if let string = Bundle.main.object(forInfoDictionaryKey: "DMAPIBaseURL") as? String,
           let url = URL(string: string), url.scheme != nil {
            return url
        }
        return URL(string: "http://localhost:3000")!
    }
}
