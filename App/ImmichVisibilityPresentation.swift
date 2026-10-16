import Combine
import Foundation
import SuwopShell

extension ImmichVisibility {
    var title: String {
        switch self {
        case .timeline: "タイムライン"
        case .archive: "アーカイブ"
        case .locked: "ロック"
        }
    }
}

extension ImmichVisibilityUnsupportedReason {
    var explanation: String {
        switch self {
        case .live: "Live Photo の表示先変更には対応していません。"
        case .video: "動画の表示先変更には対応していません。"
        case .stack: "まとめられた写真の表示先変更には対応していません。"
        case .unknown: "原本の種類と関連する写真を確認できないため、変更できません。"
        case .unavailable: "現在この表示元を変更できません。"
        }
    }
}

extension ImmichVisibilityWriteAvailability {
    var guidance: String? {
        switch self {
        case .verificationRequired: "Immich の PIN で認証して、表示先を変更できるか確認してください。"
        case .supported: nil
        case .unsupported: "このサーバーではロック写真の表示先を変更できません。閲覧や現在の状態の確認は引き続き利用できます。"
        }
    }
}

extension ImmichVisibilityPrompt {
    var continuingAccessDisclosure: String? {
        guard to == .locked else { return nil }
        return "ロック後も、既存の共有リンクからこの原本を表示・ダウンロードできる場合があります。共有リンクは自動では解除されません。関連する写真や動画がある場合は、共有リンク以外からもこの原本を閲覧できることがあります。関連項目の表示先は変更しません。"
    }
}

extension SelectedConfiguration {
    var selectedObservationExplanation: String {
        switch self {
        case .unlinked: "この原本から動画への関連付けは確認されていません。ほかの項目からの関連付けや閲覧可否は確認していません。"
        case .linked: "この原本は動画に関連付けられています。関連する動画やほかの写真の表示先・閲覧可否は確認していません。"
        case .stacked: "この原本はほかの写真とまとめられています。ほかの写真の状態や閲覧可否は確認していません。"
        case .unverified: "この原本の関連付けやまとまりを確認できません。表示先の確認だけで、変更できるとは限りません。"
        }
    }
}

/// Ephemeral scene-owned presentation; Rust owns every eligibility and journal decision.
@MainActor final class ImmichVisibilityPresentation: ObservableObject {
    @Published private(set) var projection: ImmichVisibilityView?
    @Published private(set) var busy = false
    @Published private(set) var recoveryRequired = false
    private var pendingKey: AssetKey?
    private var pendingSceneID: String?
    var currentSession: (@MainActor (String) -> ImmichLockedView?)?
    var sendEvent: (@MainActor ([String: JSONValue]) -> Void)?

    func stageLock(key: AssetKey, sceneID: String) {
        pendingKey = key
        pendingSceneID = sceneID
    }

    func clear(preservePending: Bool = false) {
        projection = nil
        busy = false
        if !preservePending {
            pendingKey = nil
            pendingSceneID = nil
        }
    }

    func receive(_ snapshot: RuntimeSnapshot, sceneID: String?) {
        busy = snapshot.view.busy
        recoveryRequired = snapshot.view.immichVisibilityView.persistenceUncertain
        let value = snapshot.view.immichVisibilityView
        projection = sceneID != nil && value.sceneID == sceneID ? value : nil
    }

    func preparePending(sceneID: String) {
        guard !busy, sendEvent != nil, pendingSceneID == sceneID, let key = pendingKey,
              currentSession?(sceneID)?.grantID != nil else { return }
        pendingKey = nil
        pendingSceneID = nil
        prepare(key: key, to: .locked, sceneID: sceneID)
    }

    func prepare(key: AssetKey, to: ImmichVisibility, sceneID: String) {
        guard !busy, sendEvent != nil, let grant = currentSession?(sceneID)?.grantID else { return }
        busy = true
        sendEvent?([
            "type": .string("prepareImmichVisibility"), "key": (try? .from(key)) ?? .null,
            "to": .string(to.rawValue), "operationID": .string(UUID().uuidString),
            "grantID": .string(grant), "sceneID": .string(sceneID),
        ])
    }

    func inspect(recordID: String, sceneID: String) {
        authenticatedEvent("inspectImmichVisibility", sceneID: sceneID, fields: ["recordID": .string(recordID)])
    }

    func recover(sceneID: String) {
        authenticatedEvent("recoverImmichVisibilityState", sceneID: sceneID, fields: [:])
    }

    private func authenticatedEvent(_ type: String, sceneID: String, fields: [String: JSONValue]) {
        guard !busy, sendEvent != nil, let grant = currentSession?(sceneID)?.grantID else { return }
        busy = true
        var event = fields
        event["type"] = .string(type)
        event["grantID"] = .string(grant)
        event["sceneID"] = .string(sceneID)
        sendEvent?(event)
    }
}
