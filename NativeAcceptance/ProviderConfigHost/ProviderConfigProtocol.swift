import Foundation
import SuwopShell
import UIKit

enum ProviderConfigAccount: String, CaseIterable {
    case accountA = "A"
    case accountB = "B"

    static let assetID = "33333333-3333-4333-8333-333333333333"

    var apiKey: String {
        "suwop-fixture-\(rawValue.lowercased())-key"
    }

    var ownerID: String {
        self == .accountA ? "11111111-1111-4111-8111-111111111111" : "22222222-2222-4222-8222-222222222222"
    }

    func assetKey(endpoint: String) -> AssetKey {
        AssetKey(provider: .immich, scope: "\(endpoint)#\(ownerID)", assetID: Self.assetID)
    }

    func asset(revised: Bool) -> JSONValue {
        let date = "2026-01-01T00:00:00.000Z"
        return .object([
            "id": .string(Self.assetID),
            "ownerId": .string(ownerID),
            "originalFileName": .string("GENERATED-\(rawValue).JPG"),
            "type": .string("IMAGE"),
            "checksum": .string(String(repeating: self == .accountA ? "a" : "b", count: 40)),
            "fileCreatedAt": .string(date),
            "fileModifiedAt": .string(date),
            "updatedAt": .string(revised && self == .accountA ? "2026-02-01T00:00:00.000Z" : date),
            "isFavorite": .bool(false),
            "isOffline": .bool(false),
            "isTrashed": .bool(false),
            "visibility": .string("timeline"),
            "isEdited": .bool(false),
            "isExternal": .bool(false),
            "libraryId": .null,
            "livePhotoVideoId": .null,
            "stack": .null,
            "exifInfo": .object(["fileSizeInByte": .number(1234)]),
        ])
    }

    @MainActor func raster(preview: Bool) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let fill = switch (self, preview) {
        case (.accountA, false): UIColor(red: 233 / 255, green: 31 / 255, blue: 139 / 255, alpha: 1)
        case (.accountA, true): UIColor(red: 201 / 255, green: 31 / 255, blue: 67 / 255, alpha: 1)
        case (.accountB, false): UIColor(red: 18 / 255, green: 184 / 255, blue: 131 / 255, alpha: 1)
        case (.accountB, true): UIColor(red: 28 / 255, green: 127 / 255, blue: 230 / 255, alpha: 1)
        }
        let size = CGSize(width: 120, height: 90)
        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            fill.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }
}

struct ProviderConfigRequest {
    let method: String
    let url: URLComponents
    let headers: [String: String]
    let body: Data

    enum Parse {
        case incomplete
        case invalid
        case complete(ProviderConfigRequest)
    }

    static func parse(_ data: Data) -> Parse {
        guard data.count <= 16384 else { return .invalid }
        guard let boundary = data.range(of: Data("\r\n\r\n".utf8)) else { return .incomplete }
        guard let head = String(data: data[..<boundary.lowerBound], encoding: .utf8) else { return .invalid }
        let lines = head.components(separatedBy: "\r\n")
        guard let first = lines.first else { return .invalid }
        let request = first.split(separator: " ")
        guard request.count == 3, request[2] == "HTTP/1.1", request[1].hasPrefix("/api/"),
              let url = URLComponents(string: String(request[1])), url.host == nil, url.fragment == nil
        else { return .invalid }
        guard let headers = headerFields(lines.dropFirst()) else { return .invalid }
        guard headers["transfer-encoding"] == nil,
              let length = Int(headers["content-length"] ?? "0"), length >= 0,
              length <= 16384 - boundary.upperBound
        else { return .invalid }
        let body = data[boundary.upperBound...]
        guard body.count >= length else { return .incomplete }
        guard body.count == length else { return .invalid }
        return .complete(ProviderConfigRequest(
            method: String(request[0]),
            url: url,
            headers: headers,
            body: Data(body)
        ))
    }

    private static func headerFields(_ lines: ArraySlice<String>) -> [String: String]? {
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let key = line[..<colon].lowercased()
            guard headers[key] == nil else { return nil }
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return headers
    }
}
