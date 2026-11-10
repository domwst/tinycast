import Foundation

/// A provider may move a request within its own origin; a hop elsewhere would carry its key along.
final class AIRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let from = response.url, let to = request.url, MCPOAuth.sameOrigin(from, to) else {
            return completionHandler(nil)
        }
        completionHandler(request)
    }
}
