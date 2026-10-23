import Foundation

/// Presentation-only transport diagnostics. Never includes server URLs, response
/// bodies, asset identifiers or credentials.
public enum PreviewLoadError: LocalizedError, Sendable {
    case http(Int)
    case missingConnection
    case invalidImage
    case network(URLError.Code)
    case accessChanged
    /// Apple Photos could not deliver a preview. Carries no domain, code or
    /// userInfo: PhotoKit failures are often undocumented and must not be
    /// presented as a known cause.
    case photoLibraryUnavailable

    /// Maps a PhotoKit image-request failure to a presentation-safe error.
    /// Cancellation stays cancellation; every other failure, including URL
    /// errors, uses the Apple-specific fallback rather than the Immich messages.
    public static func photoLibrary(_ error: (any Error)?) -> any Error {
        guard let error else { return PreviewLoadError.photoLibraryUnavailable }
        if error is CancellationError {
            return error
        }
        let bridged = error as NSError
        if bridged.domain == NSURLErrorDomain, bridged.code == NSURLErrorCancelled {
            return CancellationError()
        }
        return PreviewLoadError.photoLibraryUnavailable
    }

    public var errorDescription: String? {
        switch self {
        case let .http(status):
            let explanation = switch status {
            case 401: "Immich の認証が有効ではありません。接続設定を確認してください。"
            case 403: "Immich がこの画像へのアクセスを拒否しました。写真の公開範囲とアクセス権を確認してください。"
            case 404: "Immich にこのプレビューが見つかりません。写真の存在と、サーバー側のプレビュー生成状況を確認してください。"
            case 429: "Immich へのアクセスが集中しています。少し待ってから再試行してください。"
            case 500 ... 599: "Immich サーバーで画像取得に失敗しました。サーバーの状態を確認してから再試行してください。"
            default: "Immich が画像の要求を処理できませんでした。接続設定とサーバーの状態を確認してください。"
            }
            return "\(explanation)（HTTP \(status)）"
        case .missingConnection:
            return "Immich の接続設定がありません。接続設定を確認して一覧を更新してください。"
        case .invalidImage:
            return "画像データは取得できましたが、この端末で表示できません。Immich のプレビュー生成状況を確認してください。"
        case .accessChanged:
            return "この写真の表示権限を確認できませんでした。一覧の更新後も続く場合は、保存先の接続とアクセス権を確認してください。"
        case .photoLibraryUnavailable:
            return "Apple の写真ライブラリからこの写真のプレビューを取得できませんでした。写真アプリでこの写真が表示できるか確認してから再試行してください。"
        case let .network(code):
            switch code {
            case .notConnectedToInternet, .networkConnectionLost:
                return "ネットワークに接続できません。接続を確認してから再試行してください。"
            case .timedOut:
                return "Immich からの画像応答が時間内に届きませんでした。通信状態を確認してから再試行してください。"
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "Immich サーバーに接続できません。サーバーの稼働状況と接続設定を確認してください。"
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
                return "Immich サーバーとの安全な接続を確認できません。サーバーの証明書と端末の日時を確認してください。"
            default:
                return "画像の通信に失敗しました。接続状態を確認してから再試行してください。（通信エラー \(code.rawValue)）"
            }
        }
    }
}
