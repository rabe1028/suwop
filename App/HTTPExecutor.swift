import Foundation
import SuwopShell

private final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let first = task.originalRequest?.url, let second = request.url else { completionHandler(nil)
            return
        }
        let input: JSONValue = .object([
            "first": .string(first.absoluteString),
            "second": .string(second.absoluteString),
        ])
        let allowed = (try? CoreBridge.utility(6, input: input).decode(Bool.self)) == true
        completionHandler(allowed ? request : nil)
    }
}

actor HTTPExecutor {
    private let session: URLSession
    private let uploadDirectory: URL
    init(uploadDirectory: URL = FileManager.default.temporaryDirectory) {
        self.uploadDirectory = uploadDirectory
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 32
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3600
        session = URLSession(configuration: config, delegate: RedirectGuard(), delegateQueue: nil)
    }

    func execute(_ operation: HttpRequest, submission: NativeSubmissionPermit? = nil) async throws -> HttpResponse {
        if submission != nil {
            guard operation.downloadPath == nil else { throw CancellationError() }
        }
        var request = try urlRequest(operation)
        if let path = operation.downloadPath {
            let destination = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let (temp, response) = try await session.download(for: request)
            defer { try? FileManager.default.removeItem(at: temp) }
            let status = try statusCode(response)
            if (200 ..< 300).contains(status) {
                try FileManager.default.moveItem(at: temp, to: destination)
            }
            return HttpResponse(body: .null, path: path, status: Int64(status))
        }
        let bytes: Data
        let response: URLResponse
        if let submission, !operation.files.isEmpty {
            let boundary = "Suwop-\(UUID().uuidString)"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            let multipart = try Multipart.make(operation, boundary: boundary, directory: uploadDirectory)
            defer { try? FileManager.default.removeItem(at: multipart) }
            (bytes, response) = try await submittedUpload(request, body: multipart, permit: submission)
        } else if let submission {
            (bytes, response) = try await submittedData(request, permit: submission)
        } else if operation.files.isEmpty {
            (bytes, response) = try await session.data(for: request)
        } else {
            let boundary = "Suwop-\(UUID().uuidString)"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            let multipart = try Multipart.make(operation, boundary: boundary, directory: uploadDirectory)
            defer { try? FileManager.default.removeItem(at: multipart) }
            (bytes, response) = try await session.upload(for: request, fromFile: multipart)
        }
        let status = try statusCode(response)
        let body: JSONValue = (200 ..< 300).contains(status) && !bytes.isEmpty
            ? try Wire.decoder().decode(JSONValue.self, from: bytes) : .null
        return HttpResponse(body: body, path: nil, status: Int64(status))
    }

    private func submittedUpload(
        _ request: URLRequest,
        body: URL,
        permit: NativeSubmissionPermit
    ) async throws -> (Data, URLResponse) {
        let lease = PermittedUploadTask()
        let transport = session
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = transport.uploadTask(with: request, fromFile: body) { data, response, error in
                    lease.finish(data: data, response: response, error: error)
                }
                lease.install(task, continuation: continuation)
                do {
                    try lease.start(permit: permit)
                } catch { lease.refuse(error) }
            }
        } onCancel: { lease.cancel() }
    }

    private func submittedData(
        _ request: URLRequest,
        permit: NativeSubmissionPermit
    ) async throws -> (Data, URLResponse) {
        // Once resumed, preserve the response even if the caller's scene closes.
        let transportSession = session
        return try await withCheckedThrowingContinuation { continuation in
            do {
                try permit.submit {
                    let task = transportSession.dataTask(with: request) { data, response, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else if let data, let response {
                            continuation.resume(returning: (data, response))
                        } else {
                            continuation.resume(throwing: SuwopError("通信結果を確認できません。"))
                        }
                    }
                    task.resume()
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    func thumbnail(_ operation: HttpRequest) async throws -> Data {
        do {
            let (bytes, response) = try await BoundedHTTPData.load(
                urlRequest(operation),
                session: session,
                limit: 8 << 20
            )
            let status = try statusCode(response)
            guard (200 ..< 300).contains(status) else { throw PreviewLoadError.http(status) }
            return bytes
        } catch let error as URLError {
            if error.code == .cancelled {
                throw CancellationError()
            }
            throw PreviewLoadError.network(error.code)
        }
    }

    private func urlRequest(_ operation: HttpRequest) throws -> URLRequest {
        guard let url = URL(string: operation.url) else { throw SuwopError("HTTP 要求の URL が不正です。") }
        var request = URLRequest(url: url)
        request.httpMethod = operation.method
        for (key, value) in operation.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if case .null = operation.body {
            return request
        } else {
            let body = operation.body
            request.httpBody = try Wire.encoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func statusCode(_ response: URLResponse) throws -> Int {
        guard let response = response as? HTTPURLResponse else { throw SuwopError("HTTP 応答ではありません。") }
        return response.statusCode
    }
}

private enum Multipart {
    static func make(_ operation: HttpRequest, boundary: String, directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("suwop-upload-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else {
            throw SuwopError("転送用ファイルを作成できません。")
        }
        do {
            let output = try FileHandle(forWritingTo: url)
            defer { try? output.close() }
            func write(_ text: String) throws {
                try output.write(contentsOf: Data(text.utf8))
            }
            for (key, value) in operation.fields.sorted(by: { $0.key < $1.key }) {
                let key = try quotedParameter(key)
                try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n")
            }
            for file in operation.files {
                let field = try quotedParameter(file.field)
                let filename = try quotedParameter(file.filename)
                let disposition = "Content-Disposition: form-data; name=\"\(field)\"; filename=\"\(filename)\""
                try write("--\(boundary)\r\n\(disposition)\r\nContent-Type: application/octet-stream\r\n\r\n")
                let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: file.path))
                defer { try? input.close() }
                while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
                    try Task.checkCancellation()
                    try output.write(contentsOf: chunk)
                }
                try write("\r\n")
            }
            try write("--\(boundary)--\r\n")
            return url
        } catch { try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// MIME quoted-string parameters preserve literal quotes/backslashes and
    /// cannot introduce additional header lines. Body field values stay data.
    private static func quotedParameter(_ value: String) throws -> String {
        guard !value.isEmpty,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            throw SuwopError("multipartの項目名とファイル名に制御文字は使用できません。")
        }
        return value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
