import Foundation
import SuwopShell

private final class AmazonRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

actor AmazonHTTP {
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3600
        return URLSession(configuration: configuration, delegate: AmazonRedirectGuard(), delegateQueue: nil)
    }

    private func nativeRequest(_ operation: AmazonRequest) async throws -> URLRequest {
        try Task.checkCancellation()
        let http = operation.http
        let authenticated = try CoreBridge.utility(20, input: .object([
            "type": .string("admit"), "url": .string(http.url), "method": .string(http.method),
        ])).decode(Bool.self)
        guard let url = URL(string: http.url) else { throw SuwopError("Amazon PhotosのURLが不正です。") }
        var request = URLRequest(url: url)
        request.httpMethod = http.method
        for (name, value) in http.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if case .null = http.body {
            // GET and raw uploads have no JSON body.
        } else {
            request.httpBody = try Wire.encoder().encode(http.body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let prepared = request
        return try await NativeKeychainRead.run {
            var authorized = prepared
            try AmazonCredentials.authorize(&authorized, account: operation.credentialID, allowed: authenticated)
            return authorized
        }
    }

    func execute(_ operation: AmazonRequest, submission: NativeSubmissionPermit? = nil) async throws -> AmazonResponse {
        let request = try await nativeRequest(operation)
        let transport = session()
        defer { transport.invalidateAndCancel() }
        do {
            if let path = operation.http.downloadPath {
                return try await download(request, session: transport, path: path, limit: operation.byteLimit)
            }
            // Uploads use upload(_:permit:) so their submission state is reported.
            guard operation.http.files.isEmpty else { throw SuwopError("Amazon Photosのアップロード要求が不正です。") }
            let (data, response) = try await BoundedHTTPData.load(
                request,
                session: transport,
                limit: 16 * 1024 * 1024,
                allowRedirects: false,
                submit: { task in
                    if let submission {
                        try submission.submit { task.resume() }
                    } else {
                        task.resume()
                    }
                }
            )
            return Self.response(data, response)
        } catch {
            throw Self.sanitized(error)
        }
    }

    /// Upload POST only. A failure before `task.resume()` is returned as unsent
    /// evidence; any failure after it is thrown and remains ambiguous in the core.
    func upload(_ operation: AmazonRequest, permit: NativeSubmissionPermit) async throws -> AmazonUploadSubmission {
        let mark = NativeSubmissionMark()
        let transport = session()
        defer { transport.invalidateAndCancel() }
        do {
            let request = try await nativeRequest(operation)
            guard let file = operation.http.files.first, operation.http.files.count == 1,
                  operation.http.downloadPath == nil,
                  request.httpMethod == "POST", request.url?.path == "/v2/upload"
            else { throw SuwopError("Amazon Photosのアップロード要求が不正です。") }
            let (data, response) = try await BoundedHTTPData.load(
                request,
                session: transport,
                uploadFile: URL(fileURLWithPath: file.path),
                limit: 16 * 1024 * 1024,
                allowRedirects: false,
                submit: { task in try permit.submit { mark.resume(task) } }
            )
            return AmazonUploadSubmission(response: Self.response(data, response), submitted: true)
        } catch {
            // Terminal: a late submit closure can no longer start the task.
            guard mark.sealUnsubmitted() else { throw Self.sanitized(error) }
            return AmazonUploadSubmission(failure: (error as? SuwopError)?.message, submitted: false)
        }
    }

    private static func response(_ data: Data, _ response: HTTPURLResponse) -> AmazonResponse {
        let body: JSONValue = data
            .isEmpty ? .null : (try? Wire.decoder().decode(JSONValue.self, from: data)) ?? .null
        return AmazonResponse(
            body: body,
            location: response.value(forHTTPHeaderField: "Location"),
            path: nil,
            status: Int64(response.statusCode)
        )
    }

    private static func sanitized(_ error: Error) -> Error {
        if error is CancellationError {
            return CancellationError()
        }
        if let error = error as? URLError {
            // localizedDescription can contain signed URLs and credentials.
            return SuwopError("Amazon Photosとの通信に失敗しました（\(error.code.rawValue)）。書込みは自動再送しません。")
        }
        return error
    }

    func image(_ operation: AmazonRequest) async throws -> Data {
        let transport = session()
        defer { transport.invalidateAndCancel() }
        let (data, response) = try await BoundedHTTPData.load(
            nativeRequest(operation), session: transport, limit: 24 * 1024 * 1024, allowRedirects: false
        )
        guard response.statusCode == 200 else { throw PreviewLoadError.http(response.statusCode) }
        guard response.mimeType?.hasPrefix("image/") == true else { throw PreviewLoadError.invalidImage }
        return data
    }

    private func download(
        _ request: URLRequest,
        session: URLSession,
        path: String,
        limit: Int64
    ) async throws -> AmazonResponse {
        guard limit > 0 else { throw SuwopError("Amazon Photosの原本サイズを確認できません。") }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw SuwopError("Amazon PhotosのHTTP応答が不正です。") }
        let result = AmazonResponse(
            body: .null,
            location: response.value(forHTTPHeaderField: "Location"),
            path: response.statusCode == 200 ? path : nil,
            status: Int64(response.statusCode)
        )
        guard response.statusCode == 200 else { return result }
        guard response.expectedContentLength <= 0 || response.expectedContentLength <= limit else {
            throw SuwopError("Amazon Photosの原本が確認したサイズを超えています。")
        }
        let destination = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard !FileManager.default.fileExists(atPath: path),
              FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        else { throw SuwopError("原本の一時ファイルを作成できません。") }
        let output = try FileHandle(forWritingTo: destination)
        var complete = false
        defer {
            try? output.close()
            if !complete {
                try? FileManager.default.removeItem(at: destination)
            }
        }
        var count: UInt64 = 0
        var chunk = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            count += 1
            guard count <= UInt64(limit) else { throw SuwopError("原本のサイズが取得中に変わりました。") }
            chunk.append(byte)
            if chunk.count >= 65536 {
                try output.write(contentsOf: chunk)
                chunk.removeAll(keepingCapacity: true)
            }
        }
        try output.write(contentsOf: chunk)
        try output.synchronize()
        complete = true
        return result
    }
}
