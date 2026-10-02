import Foundation

public struct HealthProbe {
    public static func check(_ app: AppConfig, session: URLSession = .shared) async -> Bool {
        var request = URLRequest(url: app.probeURL)
        request.timeoutInterval = 2
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let finalURL = http.url,
                  finalURL.scheme == app.probeURL.scheme,
                  finalURL.host == app.probeURL.host,
                  (finalURL.port ?? 80) == (app.probeURL.port ?? 80) else { return false }
            guard let expected = app.expectedText, !expected.isEmpty else { return true }
            return String(data: data, encoding: .utf8)?.contains(expected) == true
        } catch {
            return false
        }
    }
}
