import SuwopShell
import SwiftUI
import WebKit

@MainActor
private final class AmazonLoginBrowser: ObservableObject {
    let webView: WKWebView
    init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = AmazonCredentials.userAgent
        if let url = URL(string: "https://www.amazon.co.jp/photos/all") {
            webView.load(URLRequest(url: url))
        }
    }
}

struct AmazonLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var browser = AmazonLoginBrowser()
    @State private var error: String?
    let connected: @MainActor (String) -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("日本のAmazonアカウントでログインし、写真一覧が表示されたら接続してください。")
                Text("ログイン用Cookieはこの端末のKeychainに保存します。非公式APIを使うため、期限切れやサービス側の変更で再ログインが必要になる場合があります。")
                    .font(.caption).foregroundStyle(.secondary)
                if let error {
                    Text(error).foregroundStyle(.red)
                }
                AmazonBrowserView(webView: browser.webView)
            }.padding().navigationTitle("Amazon Photosに接続")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("ログインしたアカウントに接続") {
                            Task {
                                do {
                                    let cookies = await browser.webView.configuration.websiteDataStore.httpCookieStore
                                        .allCookies()
                                    let account = try AmazonCredentials.save(cookies)
                                    connected(account)
                                    dismiss()
                                } catch { self.error = error.localizedDescription }
                            }
                        }.accessibilityIdentifier("amazonConnectAfterLogin")
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 900, minHeight: 700)
        #endif
    }
}

#if os(macOS)
    private struct AmazonBrowserView: NSViewRepresentable {
        let webView: WKWebView
        func makeNSView(context: Context) -> WKWebView {
            webView
        }

        func updateNSView(_ nsView: WKWebView, context: Context) {}
    }
#else
    private struct AmazonBrowserView: UIViewRepresentable {
        let webView: WKWebView
        func makeUIView(context: Context) -> WKWebView {
            webView
        }

        func updateUIView(_ uiView: WKWebView, context: Context) {}
    }
#endif
