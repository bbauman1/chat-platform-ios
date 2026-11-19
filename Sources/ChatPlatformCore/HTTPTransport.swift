import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// Sends one HTTP request. Swapped for a stub in tests.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

/// URLSession without redirects: the API answers attachment downloads with a
/// 302 to a signed storage URL, which must be fetched without the bearer token.
/// The policy is set per request, so a session the host supplies keeps it too.
public struct URLSessionHTTPTransport: HTTPTransport {
    let session: URLSession

    public init(session: URLSession? = nil) {
        self.session = session ?? URLSession(
            configuration: .default, delegate: NoRedirects(), delegateQueue: nil)
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        #if canImport(FoundationNetworking)
        let (data, response) = try await session.data(for: request)
        #else
        let (data, response) = try await session.data(for: request, delegate: NoRedirects())
        #endif
        guard let http = response as? HTTPURLResponse else { throw ChatError.invalidResponse }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        return HTTPResponse(status: http.statusCode, headers: headers, body: data)
    }
}

final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
