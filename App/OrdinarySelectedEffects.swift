import Foundation
import SuwopShell

@MainActor enum OrdinarySelectedEffects {
    static let types: Set<String> = [
        "readOrdinarySelectedImage", "publishOrdinarySelectedImage",
        "releaseOrdinarySelectedImage", "releaseOrdinarySelectedImages",
    ]

    static func execute(
        _ type: String,
        data: JSONValue,
        access: OrdinarySelectedNativeAccess,
        http: HTTPExecutor,
        context: ContentPresentationContext
    ) async throws -> JSONValue {
        switch type {
        case "readOrdinarySelectedImage":
            return try await .from(access.read(
                data["ticket"].decode(OrdinarySelectedImageTicket.self), http: http, context: context
            ))
        case "publishOrdinarySelectedImage":
            return try await .from(access.publish(
                data["ticket"].decode(OrdinarySelectedImageTicket.self),
                stagedID: data["stagedID"].decode(String.self),
                context: context
            ))
        case "releaseOrdinarySelectedImage":
            try access.release(stagedID: data["stagedID"].decode(String.self))
        case "releaseOrdinarySelectedImages":
            try access.release(generation: data["generation"].decode(Int64.self))
        default: throw CancellationError()
        }
        return .null
    }
}
