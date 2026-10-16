import Foundation
import SuwopShell
import UniformTypeIdentifiers

/// Transport framing only. Rust supplies the identity, expected length and finite byte budget.
struct PrivateVideoResponse: Sendable {
    let expectedBytes: Int64?
    let maximumBytes: Int64

    func validate(_ response: URLResponse) throws -> Int64? {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              maximumBytes > 0 else { throw invalidResponse() }
        if let encoding = http.value(forHTTPHeaderField: "Content-Encoding") {
            guard encoding.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "identity" else {
                throw invalidResponse()
            }
        }
        if let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() {
            guard !contentType.contains("text/html"), !contentType.contains("application/json") else {
                throw invalidResponse()
            }
        }
        let length = try declaredLength(http)
        if length != nil, http.value(forHTTPHeaderField: "Transfer-Encoding") != nil {
            throw invalidResponse()
        }
        if let length {
            guard length <= maximumBytes, expectedBytes == nil || expectedBytes == length else {
                throw invalidResponse()
            }
        }
        if let expectedBytes {
            guard expectedBytes > 0, expectedBytes <= maximumBytes else { throw invalidResponse() }
        }
        return length
    }

    func validateEnd(received: Int64, declared: Int64?) throws {
        guard received > 0, received <= maximumBytes,
              expectedBytes == nil || received == expectedBytes,
              declared == nil || received == declared else { throw invalidResponse() }
    }

    func nextCount(received: Int64, chunkBytes: Int, declared: Int64?) throws -> Int64 {
        guard chunkBytes >= 0, let count = Int64(exactly: chunkBytes) else { throw invalidResponse() }
        let (next, overflow) = received.addingReportingOverflow(count)
        guard !overflow, next <= maximumBytes else { throw invalidResponse() }
        if let expectedBytes, next > expectedBytes {
            throw invalidResponse()
        }
        if let declared, next > declared {
            throw invalidResponse()
        }
        return next
    }

    private func declaredLength(_ response: HTTPURLResponse) throws -> Int64? {
        guard let raw = response.value(forHTTPHeaderField: "Content-Length") else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.allSatisfy({ (48 ... 57).contains($0) }),
              let length = Int64(value), length > 0 else { throw invalidResponse() }
        return length
    }

    private func invalidResponse() -> SuwopError {
        SuwopError("動画の原本を確認できません。")
    }
}

/// Uses the exact Rust URL and headers; it never derives an Immich endpoint.
enum PrivateVideoRequest {
    static func make(_ operation: HttpRequest) throws -> URLRequest {
        guard operation.method == "GET", operation.files.isEmpty, operation.downloadPath == nil,
              case .null = operation.body, let url = URL(string: operation.url) else { throw CancellationError() }
        var request = URLRequest(url: url)
        request.httpMethod = operation.method
        for (key, value) in operation.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        guard request.value(forHTTPHeaderField: "Accept-Encoding") == "identity" else { throw CancellationError() }
        return request
    }
}

/// Parser hints only. Neither a header nor a filename can authorize presentation.
enum PrivateVideoMediaHint {
    static func response(_ raw: String?) -> String? {
        guard let raw, raw.utf8.count <= 256 else { return nil }
        let mime = raw.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard mime != "application/octet-stream", mime != "binary/octet-stream" else { return nil }
        let parts = mime.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789!#$&^_.+-")
        guard parts.count == 2,
              parts.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains) })
        else {
            return nil
        }
        return mime
    }

    static func filename(_ name: String) -> String? {
        guard name.utf8.count <= 4096 else { return nil }
        let suffix = (name as NSString).pathExtension
        guard let type = UTType(filenameExtension: suffix), type.conforms(to: .audiovisualContent) else { return nil }
        return response(type.preferredMIMEType)
    }
}
