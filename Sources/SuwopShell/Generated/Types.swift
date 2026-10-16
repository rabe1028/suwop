// Generated from Rust schema. Run make generate-types; do not edit.
import Foundation

public enum AdjustmentBase: String, Codable, CaseIterable, Sendable {
    case `original`
    case `rendered`
}

public enum AlbumAction: String, Codable, CaseIterable, Sendable {
    case `rename`
    case `add`
    case `remove`
    case `delete`
}

public struct AlbumCandidate: Codable, Sendable {
    public var key: AssetKey
    public var photoID: String
    public init(key: AssetKey, photoID: String) {
        self.key = key
        self.photoID = photoID
    }
}

public struct AlbumEdit: Codable, Sendable {
    public var action: AlbumAction
    public var keys: [AssetKey]
    public var title: String?
    public init(action: AlbumAction, keys: [AssetKey] = [], title: String? = nil) {
        self.action = action
        self.keys = keys
        self.title = title
    }
}

public struct AlbumKey: Codable, Sendable {
    public var provider: Provider
    public var scope: String
    public var albumID: String
    public init(provider: Provider, scope: String, albumID: String) {
        self.provider = provider
        self.scope = scope
        self.albumID = albumID
    }
}

public enum AlbumMembershipObservation: String, Codable, CaseIterable, Sendable {
    case `notChecked`
    case `noAccessibleMemberships`
    case `accessibleMembershipsRemain`
}

public struct AlbumPermissions: Codable, Sendable {
    public var add: Bool
    public var delete: Bool
    public var remove: Bool
    public var rename: Bool
    public init(add: Bool, delete: Bool, remove: Bool, rename: Bool) {
        self.add = add
        self.delete = delete
        self.remove = remove
        self.rename = rename
    }
}

public struct AlbumSnapshot: Codable, Sendable {
    public var access: ScanAccess
    public var albums: [StoredAlbum]
    public var provider: Provider
    public var scope: String
    public init(access: ScanAccess, albums: [StoredAlbum] = [], provider: Provider, scope: String) {
        self.access = access
        self.albums = albums
        self.provider = provider
        self.scope = scope
    }
}

public struct AlbumView: Codable, Sendable {
    public var access: ScanAccess
    public var album: StoredAlbum
    public var candidates: [AlbumCandidate]
    public var photoIDs: [String]
    public init(access: ScanAccess, album: StoredAlbum, candidates: [AlbumCandidate] = [], photoIDs: [String] = []) {
        self.access = access
        self.album = album
        self.candidates = candidates
        self.photoIDs = photoIDs
    }
}

public struct AppleAdjustment: Codable, Sendable {
    public var data: String
    public var formatIdentifier: String
    public var formatVersion: String
    public init(data: String, formatIdentifier: String, formatVersion: String) {
        self.data = data
        self.formatIdentifier = formatIdentifier
        self.formatVersion = formatVersion
    }
}

public struct AppleEditInput: Codable, Sendable {
    public var adjustment: AppleAdjustment?
    public var asset: StoredAsset
    public var canEdit: Bool
    public var defaultFormat: String?
    public var hasAdjustments: Bool
    public var image: ImageEncodingFacts
    public var path: String
    public var supportedFormats: [String]
    public var token: String
    public init(adjustment: AppleAdjustment? = nil, asset: StoredAsset, canEdit: Bool, defaultFormat: String? = nil, hasAdjustments: Bool, image: ImageEncodingFacts, path: String, supportedFormats: [String] = [], token: String) {
        self.adjustment = adjustment
        self.asset = asset
        self.canEdit = canEdit
        self.defaultFormat = defaultFormat
        self.hasAdjustments = hasAdjustments
        self.image = image
        self.path = path
        self.supportedFormats = supportedFormats
        self.token = token
    }
}

public struct AppleEditResult: Codable, Sendable {
    public var adjustment: AppleAdjustment
    public var asset: StoredAsset
    public var image: ImageEncodingFacts
    public init(adjustment: AppleAdjustment, asset: StoredAsset, image: ImageEncodingFacts) {
        self.adjustment = adjustment
        self.asset = asset
        self.image = image
    }
}

public struct AppleFacts: Codable, Sendable {
    public var asset: StoredAsset
    public var burst: Bool
    public var canDelete: Bool
    public var fullAccess: Bool
    public var live: Bool
    public var shared: Bool
    public init(asset: StoredAsset, burst: Bool, canDelete: Bool, fullAccess: Bool, live: Bool, shared: Bool) {
        self.asset = asset
        self.burst = burst
        self.canDelete = canDelete
        self.fullAccess = fullAccess
        self.live = live
        self.shared = shared
    }
}

public struct AppleImportEntry: Codable, Sendable {
    public var file: TransferFile
    public var kind: String
    public init(file: TransferFile, kind: String) {
        self.file = file
        self.kind = kind
    }
}

public struct AppleImportPlan: Codable, Sendable {
    public var entries: [AppleImportEntry]
    public var metadata: StoredAsset
    public init(entries: [AppleImportEntry] = [], metadata: StoredAsset) {
        self.entries = entries
        self.metadata = metadata
    }
}

public struct AppleReversionFacts: Codable, Sendable {
    public var asset: StoredAsset
    public var canEdit: Bool
    public var hasAdjustments: Bool
    public init(asset: StoredAsset, canEdit: Bool, hasAdjustments: Bool) {
        self.asset = asset
        self.canEdit = canEdit
        self.hasAdjustments = hasAdjustments
    }
}

public struct AppleTrashInspection: Codable, Sendable {
    public var assets: [AppleFacts]
    public var fullAccess: Bool
    public var scope: String
    public init(assets: [AppleFacts] = [], fullAccess: Bool, scope: String) {
        self.assets = assets
        self.fullAccess = fullAccess
        self.scope = scope
    }
}

public struct AppleTrashOperation: Codable, Sendable {
    public var assets: [StoredAsset]
    public var id: String
    public var outcome: AppleTrashOutcome
    public var scope: String
    public var visibility: AppleTrashVisibility?
    public init(assets: [StoredAsset] = [], id: String, outcome: AppleTrashOutcome, scope: String, visibility: AppleTrashVisibility? = nil) {
        self.assets = assets
        self.id = id
        self.outcome = outcome
        self.scope = scope
        self.visibility = visibility
    }
}

public enum AppleTrashOutcome: String, Codable, CaseIterable, Sendable {
    case `unknown`
    case `applied`
    case `notApplied`
}

public struct AppleTrashPrompt: Codable, Sendable {
    public var names: [String]
    public var scope: String
    public init(names: [String] = [], scope: String) {
        self.names = names
        self.scope = scope
    }
}

public struct AppleTrashResult: Codable, Sendable {
    public var applied: Bool
    public var error: String?
    public init(applied: Bool, error: String? = nil) {
        self.applied = applied
        self.error = error
    }
}

public enum AppleTrashVisibility: String, Codable, CaseIterable, Sendable {
    case `present`
    case `absent`
    case `mixed`
}

public enum AppleVisibility: String, Codable, CaseIterable, Sendable {
    case `unknown`
    case `visible`
    case `hidden`
}

public struct AppleVisibilityApply: Codable, Sendable {
    public var action: VisibilityAction
    public var id: String
    public var scope: String
    public var targets: [VisibilityApplyTarget]
    public init(action: VisibilityAction, id: String, scope: String, targets: [VisibilityApplyTarget] = []) {
        self.action = action
        self.id = id
        self.scope = scope
        self.targets = targets
    }
}

public struct AppleVisibilityFacts: Codable, Sendable {
    public var canEditProperties: Bool
    public var freshRevision: String
    public var fullAccess: Bool
    public var identity: VisibilityIdentity
    public var key: AssetKey
    public var visibility: AppleVisibility
    public init(canEditProperties: Bool, freshRevision: String, fullAccess: Bool, identity: VisibilityIdentity, key: AssetKey, visibility: AppleVisibility) {
        self.canEditProperties = canEditProperties
        self.freshRevision = freshRevision
        self.fullAccess = fullAccess
        self.identity = identity
        self.key = key
        self.visibility = visibility
    }
}

public struct AppleVisibilityInspection: Codable, Sendable {
    public var assets: [AppleVisibilityFacts]
    public var fullAccess: Bool
    public var scope: String
    public init(assets: [AppleVisibilityFacts] = [], fullAccess: Bool, scope: String) {
        self.assets = assets
        self.fullAccess = fullAccess
        self.scope = scope
    }
}

public struct AppleVisibilityOperation: Codable, Sendable {
    public var action: VisibilityAction
    public var id: String
    public var outcome: VisibilityOutcome
    public var scope: String
    public var targets: [VisibilityTarget]
    public init(action: VisibilityAction, id: String, outcome: VisibilityOutcome, scope: String, targets: [VisibilityTarget] = []) {
        self.action = action
        self.id = id
        self.outcome = outcome
        self.scope = scope
        self.targets = targets
    }
}

public struct AppleVisibilityPrompt: Codable, Sendable {
    public var action: VisibilityAction
    public var count: Int64
    public var id: String
    public init(action: VisibilityAction, count: Int64, id: String) {
        self.action = action
        self.count = count
        self.id = id
    }
}

public struct AppleVisibilityResult: Codable, Sendable {
    public var outcome: VisibilityOutcome
    public init(outcome: VisibilityOutcome) {
        self.outcome = outcome
    }
}

public struct AppleVisibilitySummary: Codable, Sendable {
    public var action: VisibilityAction
    public var canInspect: Bool
    public var canUnhide: Bool
    public var count: Int64
    public var id: String
    public var observations: [VisibilityObservation?]
    public var outcome: VisibilityOutcome
    public var photosHandoff: Bool
    public init(action: VisibilityAction, canInspect: Bool, canUnhide: Bool, count: Int64, id: String, observations: [VisibilityObservation?] = [], outcome: VisibilityOutcome, photosHandoff: Bool) {
        self.action = action
        self.canInspect = canInspect
        self.canUnhide = canUnhide
        self.count = count
        self.id = id
        self.observations = observations
        self.outcome = outcome
        self.photosHandoff = photosHandoff
    }
}

public struct AssetKey: Codable, Sendable {
    public var provider: Provider
    public var scope: String
    public var assetID: String
    public init(provider: Provider, scope: String, assetID: String) {
        self.provider = provider
        self.scope = scope
        self.assetID = assetID
    }
}

public struct BrowserOptions: Codable, Sendable {
    public var filter: PhotoFilter
    public var presence: Presence?
    public var query: String
    public var sort: PhotoSort
    public var timeZone: String?
    public init(filter: PhotoFilter, presence: Presence? = nil, query: String, sort: PhotoSort, timeZone: String? = nil) {
        self.filter = filter
        self.presence = presence
        self.query = query
        self.sort = sort
        self.timeZone = timeZone
    }
}

public struct BrowserView: Codable, Sendable {
    public var favorites: Int64
    public var live: Int64
    public var photoIDs: [String]
    public var raw: Int64
    public var total: Int64
    public var videos: Int64
    public init(favorites: Int64, live: Int64, photoIDs: [String] = [], raw: Int64, total: Int64, videos: Int64) {
        self.favorites = favorites
        self.live = live
        self.photoIDs = photoIDs
        self.raw = raw
        self.total = total
        self.videos = videos
    }
}

public struct ColorAdjustments: Codable, Sendable {
    public var brightness: Int64
    public var contrast: Int64
    public var exposure: Int64
    public var filter: ImageColorFilter
    public var saturation: Int64
    public init(brightness: Int64, contrast: Int64, exposure: Int64, filter: ImageColorFilter, saturation: Int64) {
        self.brightness = brightness
        self.contrast = contrast
        self.exposure = exposure
        self.filter = filter
        self.saturation = saturation
    }
}

public enum ColorControlKind: String, Codable, CaseIterable, Sendable {
    case `exposure`
    case `brightness`
    case `contrast`
    case `saturation`
}

public struct ColorControlSpec: Codable, Sendable {
    public var kind: ColorControlKind
    public var maximum: Int64
    public var minimum: Int64
    public init(kind: ColorControlKind, maximum: Int64, minimum: Int64) {
        self.kind = kind
        self.maximum = maximum
        self.minimum = minimum
    }
}

public struct ConnectionSettings: Codable, Sendable {
    public var address: String
    public var allowHTTP: Bool
    public var credentialID: String
    public init(address: String, allowHTTP: Bool, credentialID: String) {
        self.address = address
        self.allowHTTP = allowHTTP
        self.credentialID = credentialID
    }
}

public struct Coordinates: Codable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

public struct CurrentImageExport: Codable, Sendable {
    public var asset: StoredAsset
    public var freshAsset: StoredAsset
    public var image: CurrentImageFacts
    public var path: String
    public init(asset: StoredAsset, freshAsset: StoredAsset, image: CurrentImageFacts, path: String) {
        self.asset = asset
        self.freshAsset = freshAsset
        self.image = image
        self.path = path
    }
}

public struct CurrentImageFacts: Codable, Sendable {
    public var contentType: String
    public var frames: Int64
    public var height: Int64
    public var orientation: Int64
    public var width: Int64
    public init(contentType: String, frames: Int64, height: Int64, orientation: Int64, width: Int64) {
        self.contentType = contentType
        self.frames = frames
        self.height = height
        self.orientation = orientation
        self.width = width
    }
}

public struct CurrentImageMetadata: Codable, Sendable {
    public var dateTimeOriginal: String?
    public var latitude: Double?
    public var longitude: Double?
    public var subsecTimeOriginal: String?
    public init(dateTimeOriginal: String? = nil, latitude: Double? = nil, longitude: Double? = nil, subsecTimeOriginal: String? = nil) {
        self.dateTimeOriginal = dateTimeOriginal
        self.latitude = latitude
        self.longitude = longitude
        self.subsecTimeOriginal = subsecTimeOriginal
    }
}

public struct CurrentImageRenderPlan: Codable, Sendable {
    public var dimensions: PixelSize
    public var metadata: CurrentImageMetadata
    public var orientation: Int64
    public var transform: ImageTransform
    public init(dimensions: PixelSize, metadata: CurrentImageMetadata, orientation: Int64, transform: ImageTransform) {
        self.dimensions = dimensions
        self.metadata = metadata
        self.orientation = orientation
        self.transform = transform
    }
}

public struct CurrentImageRenderResult: Codable, Sendable {
    public var image: CurrentImageFacts
    public var metadata: CurrentImageMetadata
    public init(image: CurrentImageFacts, metadata: CurrentImageMetadata) {
        self.image = image
        self.metadata = metadata
    }
}

public struct EditClipboard: Codable, Sendable {
    public var dimensions: PixelSize
    public var options: EditCopyOptions
    public var sourceKey: AssetKey?
    public var sourceName: String
    public var transform: ImageTransform
    public init(dimensions: PixelSize, options: EditCopyOptions, sourceKey: AssetKey? = nil, sourceName: String, transform: ImageTransform) {
        self.dimensions = dimensions
        self.options = options
        self.sourceKey = sourceKey
        self.sourceName = sourceName
        self.transform = transform
    }
}

public struct EditCommand: Codable, Sendable {
    public var color: ColorAdjustments?
    public var crop: PixelCrop?
    public var kind: EditCommandKind
    public init(color: ColorAdjustments? = nil, crop: PixelCrop? = nil, kind: EditCommandKind) {
        self.color = color
        self.crop = crop
        self.kind = kind
    }
}

public enum EditCommandKind: String, Codable, CaseIterable, Sendable {
    case `rotateClockwise`
    case `mirrorHorizontal`
    case `mirrorVertical`
    case `crop`
    case `setColor`
    case `undo`
    case `redo`
    case `resetDraft`
}

public struct EditCopyOptions: Codable, Sendable {
    public var adjustments: Bool
    public var filter: Bool
    public var geometry: Bool
    public init(adjustments: Bool, filter: Bool, geometry: Bool) {
        self.adjustments = adjustments
        self.filter = filter
        self.geometry = geometry
    }
}

public struct EditDraftRequest: Codable, Sendable {
    public var command: EditCommand?
    public var draft: ImageEditDraft
    public init(command: EditCommand? = nil, draft: ImageEditDraft) {
        self.command = command
        self.draft = draft
    }
}

public struct EditingSourceCheck: Codable, Sendable {
    public var expected: StoredAsset
    public var fresh: StoredAsset
    public init(expected: StoredAsset, fresh: StoredAsset) {
        self.expected = expected
        self.fresh = fresh
    }
}

public struct EditingTarget: Codable, Sendable {
    public var disabledReason: String?
    public var key: AssetKey
    public var name: String
    public init(disabledReason: String? = nil, key: AssetKey, name: String) {
        self.disabledReason = disabledReason
        self.key = key
        self.name = name
    }
}

public struct FileSignature: Codable, Sendable {
    public var bytes: Int64
    public var sha256: String
    public init(bytes: Int64, sha256: String) {
        self.bytes = bytes
        self.sha256 = sha256
    }
}

public struct HashResult: Codable, Sendable {
    public var sha1: String
    public var signature: FileSignature
    public init(sha1: String, signature: FileSignature) {
        self.sha1 = sha1
        self.signature = signature
    }
}

public struct HttpRequest: Codable, Sendable {
    public var body: JSONValue
    public var downloadPath: String?
    public var fields: [String: String]
    public var files: [UploadPart]
    public var headers: [String: String]
    public var immichArchiveAuthorization: ImmichArchiveAuthorization?
    public var immichVisibilityAuthorization: ImmichVisibilityAuthorization?
    public var method: String
    public var ordinaryContentAuthorization: OrdinaryContentAuthorization?
    public var url: String
    public init(body: JSONValue, downloadPath: String? = nil, fields: [String: String] = [:], files: [UploadPart] = [], headers: [String: String] = [:], immichArchiveAuthorization: ImmichArchiveAuthorization? = nil, immichVisibilityAuthorization: ImmichVisibilityAuthorization? = nil, method: String, ordinaryContentAuthorization: OrdinaryContentAuthorization? = nil, url: String) {
        self.body = body
        self.downloadPath = downloadPath
        self.fields = fields
        self.files = files
        self.headers = headers
        self.immichArchiveAuthorization = immichArchiveAuthorization
        self.immichVisibilityAuthorization = immichVisibilityAuthorization
        self.method = method
        self.ordinaryContentAuthorization = ordinaryContentAuthorization
        self.url = url
    }
}

public struct HttpResponse: Codable, Sendable {
    public var body: JSONValue
    public var path: String?
    public var status: Int64
    public init(body: JSONValue, path: String? = nil, status: Int64) {
        self.body = body
        self.path = path
        self.status = status
    }
}

public enum ImageColorFilter: String, Codable, CaseIterable, Sendable {
    case `original`
    case `mono`
    case `noir`
    case `sepia`
}

public struct ImageEditDraft: Codable, Sendable {
    public var cursor: Int64
    public var dimensions: PixelSize
    public var history: [ImageTransform]
    public var initial: ImageTransform
    public init(cursor: Int64, dimensions: PixelSize, history: [ImageTransform] = [], initial: ImageTransform) {
        self.cursor = cursor
        self.dimensions = dimensions
        self.history = history
        self.initial = initial
    }
}

public struct ImageEditPresentation: Codable, Sendable {
    public var base: AdjustmentBase
    public var draft: ImageEditDraft
    public var name: String
    public var orientation: Int64
    public var outputFormat: RenderFormat
    public var path: String
    public init(base: AdjustmentBase, draft: ImageEditDraft, name: String, orientation: Int64, outputFormat: RenderFormat, path: String) {
        self.base = base
        self.draft = draft
        self.name = name
        self.orientation = orientation
        self.outputFormat = outputFormat
        self.path = path
    }
}

public struct ImageEditState: Codable, Sendable {
    public var canRedo: Bool
    public var canSave: Bool
    public var canUndo: Bool
    public var colorControls: [ColorControlSpec]
    public var draft: ImageEditDraft
    public var outputSize: PixelSize
    public var transform: ImageTransform
    public init(canRedo: Bool, canSave: Bool, canUndo: Bool, colorControls: [ColorControlSpec] = [], draft: ImageEditDraft, outputSize: PixelSize, transform: ImageTransform) {
        self.canRedo = canRedo
        self.canSave = canSave
        self.canUndo = canUndo
        self.colorControls = colorControls
        self.draft = draft
        self.outputSize = outputSize
        self.transform = transform
    }
}

public struct ImageEncodingFacts: Codable, Sendable {
    public var hasAlpha: Bool
    public var hasColorSpace: Bool
    public var hdr: Bool
    public var orientation: Int64
    public var rawDimensions: PixelSize
    public init(hasAlpha: Bool, hasColorSpace: Bool, hdr: Bool, orientation: Int64, rawDimensions: PixelSize) {
        self.hasAlpha = hasAlpha
        self.hasColorSpace = hasColorSpace
        self.hdr = hdr
        self.orientation = orientation
        self.rawDimensions = rawDimensions
    }
}

public struct ImageRenderPlan: Codable, Sendable {
    public var adjustment: AppleAdjustment
    public var dimensions: PixelSize
    public var orientation: Int64
    public var outputFormat: RenderFormat
    public var transform: ImageTransform
    public init(adjustment: AppleAdjustment, dimensions: PixelSize, orientation: Int64, outputFormat: RenderFormat, transform: ImageTransform) {
        self.adjustment = adjustment
        self.dimensions = dimensions
        self.orientation = orientation
        self.outputFormat = outputFormat
        self.transform = transform
    }
}

public struct ImageTransform: Codable, Sendable {
    public var clockwiseQuarterTurns: Int64
    public var color: ColorAdjustments
    public var crop: PixelCrop
    public var flipHorizontal: Bool
    public init(clockwiseQuarterTurns: Int64, color: ColorAdjustments, crop: PixelCrop, flipHorizontal: Bool) {
        self.clockwiseQuarterTurns = clockwiseQuarterTurns
        self.color = color
        self.crop = crop
        self.flipHorizontal = flipHorizontal
    }
}

public struct ImmichArchiveActionHint: Codable, Sendable {
    public var key: AssetKey
    public var reason: ImmichVisibilityUnsupportedReason?
    public var to: ImmichArchiveDestination?
    public init(key: AssetKey, reason: ImmichVisibilityUnsupportedReason? = nil, to: ImmichArchiveDestination? = nil) {
        self.key = key
        self.reason = reason
        self.to = to
    }
}

public struct ImmichArchiveAuthorization: Codable, Sendable {
    public var generation: Int64
    public var key: AssetKey
    public var operationID: String
    public var sceneID: String
    public var scope: String
    public var to: ImmichArchiveDestination
    public var url: String
    public init(generation: Int64, key: AssetKey, operationID: String, sceneID: String, scope: String, to: ImmichArchiveDestination, url: String) {
        self.generation = generation
        self.key = key
        self.operationID = operationID
        self.sceneID = sceneID
        self.scope = scope
        self.to = to
        self.url = url
    }
}

public enum ImmichArchiveDestination: String, Codable, CaseIterable, Sendable {
    case `timeline`
    case `archive`
}

public struct ImmichArchivePrompt: Codable, Sendable {
    public var from: ImmichArchiveDestination
    public var generation: Int64
    public var operationID: String
    public var sceneID: String
    public var to: ImmichArchiveDestination
    public init(from: ImmichArchiveDestination, generation: Int64, operationID: String, sceneID: String, to: ImmichArchiveDestination) {
        self.from = from
        self.generation = generation
        self.operationID = operationID
        self.sceneID = sceneID
        self.to = to
    }
}

public struct ImmichArchiveSummary: Codable, Sendable {
    public var from: ImmichArchiveDestination
    public var observation: ImmichArchiveDestination?
    public var outcome: VisibilityOutcome
    public var recordID: String
    public var to: ImmichArchiveDestination
    public init(from: ImmichArchiveDestination, observation: ImmichArchiveDestination? = nil, outcome: VisibilityOutcome, recordID: String, to: ImmichArchiveDestination) {
        self.from = from
        self.observation = observation
        self.outcome = outcome
        self.recordID = recordID
        self.to = to
    }
}

public struct ImmichArchiveView: Codable, Sendable {
    public var activeOperation: ImmichArchiveAuthorization?
    public var canRecover: Bool
    public var generation: Int64
    public var history: [ImmichArchiveSummary]?
    public var persistenceUncertain: Bool
    public var sceneID: String?
    public var status: String?
    public init(activeOperation: ImmichArchiveAuthorization? = nil, canRecover: Bool, generation: Int64, history: [ImmichArchiveSummary]? = [], persistenceUncertain: Bool, sceneID: String? = nil, status: String? = nil) {
        self.activeOperation = activeOperation
        self.canRecover = canRecover
        self.generation = generation
        self.history = history
        self.persistenceUncertain = persistenceUncertain
        self.sceneID = sceneID
        self.status = status
    }
}

public struct ImmichLockedEntry: Codable, Sendable {
    public var asset: StoredAsset
    public var canPlayVideo: Bool
    public var id: String
    public var visibilityAction: ImmichVisibilityActionHint
    public init(asset: StoredAsset, canPlayVideo: Bool = false, id: String, visibilityAction: ImmichVisibilityActionHint) {
        self.asset = asset
        self.canPlayVideo = canPlayVideo
        self.id = id
        self.visibilityAction = visibilityAction
    }
}

public struct ImmichLockedImageAccess: Codable, Sendable {
    public var entryID: String
    public var generation: Int64
    public var grantID: String
    public var requestID: String
    public var sceneID: String
    public var stagedID: String
    public init(entryID: String, generation: Int64, grantID: String, requestID: String, sceneID: String, stagedID: String) {
        self.entryID = entryID
        self.generation = generation
        self.grantID = grantID
        self.requestID = requestID
        self.sceneID = sceneID
        self.stagedID = stagedID
    }
}

public struct ImmichLockedImageResult: Codable, Sendable {
    public var requestID: String
    public var stagedID: String
    public init(requestID: String, stagedID: String) {
        self.requestID = requestID
        self.stagedID = stagedID
    }
}

public struct ImmichLockedImageTicket: Codable, Sendable {
    public var entryID: String
    public var expectedRevision: String
    public var generation: Int64
    public var grantID: String
    public var key: AssetKey
    public var request: HttpRequest
    public var requestID: String
    public var sceneID: String
    public init(entryID: String, expectedRevision: String, generation: Int64, grantID: String, key: AssetKey, request: HttpRequest, requestID: String, sceneID: String) {
        self.entryID = entryID
        self.expectedRevision = expectedRevision
        self.generation = generation
        self.grantID = grantID
        self.key = key
        self.request = request
        self.requestID = requestID
        self.sceneID = sceneID
    }
}

public enum ImmichLockedState: String, Codable, CaseIterable, Sendable {
    case `locked`
    case `connecting`
    case `open`
}

public struct ImmichLockedVideoAccess: Codable, Sendable {
    public var pending: ImmichLockedVideoPending
    public var stagedID: String
    public init(pending: ImmichLockedVideoPending, stagedID: String) {
        self.pending = pending
        self.stagedID = stagedID
    }
}

public enum ImmichLockedVideoCapacityClass: String, Codable, CaseIterable, Sendable {
    case `importantUsage`
    case `available`
}

public struct ImmichLockedVideoPending: Codable, Sendable {
    public var entryID: String
    public var generation: Int64
    public var grantID: String
    public var key: AssetKey
    public var phase: ImmichLockedVideoPhase
    public var requestID: String
    public var sceneID: String
    public init(entryID: String, generation: Int64, grantID: String, key: AssetKey, phase: ImmichLockedVideoPhase, requestID: String, sceneID: String) {
        self.entryID = entryID
        self.generation = generation
        self.grantID = grantID
        self.key = key
        self.phase = phase
        self.requestID = requestID
        self.sceneID = sceneID
    }
}

public enum ImmichLockedVideoPhase: String, Codable, CaseIterable, Sendable {
    case `checking`
    case `acquiring`
    case `preparing`
}

public struct ImmichLockedVideoPrepared: Codable, Sendable {
    public var requestID: String
    public var stagedID: String
    public init(requestID: String, stagedID: String) {
        self.requestID = requestID
        self.stagedID = stagedID
    }
}

public struct ImmichLockedVideoResult: Codable, Sendable {
    public var requestID: String
    public var sha1: String
    public var signature: FileSignature
    public var stagedID: String
    public init(requestID: String, sha1: String, signature: FileSignature, stagedID: String) {
        self.requestID = requestID
        self.sha1 = sha1
        self.signature = signature
        self.stagedID = stagedID
    }
}

public struct ImmichLockedVideoStorageFacts: Codable, Sendable {
    public var allocationUnitBytes: Int64
    public var availableBytes: Int64
    public var capacityClass: ImmichLockedVideoCapacityClass
    public var deadlineUnixMilliseconds: Int64
    public var leaseID: String
    public var measurementNonce: String
    public var otherUnallocatedBytes: Int64
    public init(allocationUnitBytes: Int64, availableBytes: Int64, capacityClass: ImmichLockedVideoCapacityClass, deadlineUnixMilliseconds: Int64, leaseID: String, measurementNonce: String, otherUnallocatedBytes: Int64) {
        self.allocationUnitBytes = allocationUnitBytes
        self.availableBytes = availableBytes
        self.capacityClass = capacityClass
        self.deadlineUnixMilliseconds = deadlineUnixMilliseconds
        self.leaseID = leaseID
        self.measurementNonce = measurementNonce
        self.otherUnallocatedBytes = otherUnallocatedBytes
    }
}

public struct ImmichLockedVideoTicket: Codable, Sendable {
    public var deadlineUnixMilliseconds: Int64
    public var displayLeaseID: Int64
    public var expectedBytes: Int64?
    public var expectedRevision: String
    public var expectedSha1: String
    public var maxReceivedBytes: Int64
    public var minimumRemainingBytes: Int64
    public var pending: ImmichLockedVideoPending
    public var request: HttpRequest
    public var storage: ImmichLockedVideoStorageFacts
    public init(deadlineUnixMilliseconds: Int64, displayLeaseID: Int64, expectedBytes: Int64? = nil, expectedRevision: String, expectedSha1: String, maxReceivedBytes: Int64, minimumRemainingBytes: Int64, pending: ImmichLockedVideoPending, request: HttpRequest, storage: ImmichLockedVideoStorageFacts) {
        self.deadlineUnixMilliseconds = deadlineUnixMilliseconds
        self.displayLeaseID = displayLeaseID
        self.expectedBytes = expectedBytes
        self.expectedRevision = expectedRevision
        self.expectedSha1 = expectedSha1
        self.maxReceivedBytes = maxReceivedBytes
        self.minimumRemainingBytes = minimumRemainingBytes
        self.pending = pending
        self.request = request
        self.storage = storage
    }
}

public struct ImmichLockedView: Codable, Sendable {
    public var entries: [ImmichLockedEntry]?
    public var error: String?
    public var generation: Int64
    public var grantID: String?
    public var image: ImmichLockedImageAccess?
    public var leaseID: Int64
    public var remoteLockConfirmed: Bool?
    public var sceneID: String?
    public var state: ImmichLockedState
    public var video: ImmichLockedVideoAccess?
    public var videoPending: ImmichLockedVideoPending?
    public init(entries: [ImmichLockedEntry]? = [], error: String? = nil, generation: Int64, grantID: String? = nil, image: ImmichLockedImageAccess? = nil, leaseID: Int64, remoteLockConfirmed: Bool? = nil, sceneID: String? = nil, state: ImmichLockedState, video: ImmichLockedVideoAccess? = nil, videoPending: ImmichLockedVideoPending? = nil) {
        self.entries = entries
        self.error = error
        self.generation = generation
        self.grantID = grantID
        self.image = image
        self.leaseID = leaseID
        self.remoteLockConfirmed = remoteLockConfirmed
        self.sceneID = sceneID
        self.state = state
        self.video = video
        self.videoPending = videoPending
    }
}

public enum ImmichStackState: String, Codable, CaseIterable, Sendable {
    case `unknown`
    case `unstacked`
    case `stacked`
}

public enum ImmichVisibility: String, Codable, CaseIterable, Sendable {
    case `timeline`
    case `archive`
    case `locked`
}

public struct ImmichVisibilityActionHint: Codable, Sendable {
    public var canLock: Bool
    public var canShowArchive: Bool
    public var canShowTimeline: Bool
    public var key: AssetKey
    public var reason: ImmichVisibilityUnsupportedReason?
    public var writeAvailability: ImmichVisibilityWriteAvailability
    public init(canLock: Bool, canShowArchive: Bool, canShowTimeline: Bool, key: AssetKey, reason: ImmichVisibilityUnsupportedReason? = nil, writeAvailability: ImmichVisibilityWriteAvailability) {
        self.canLock = canLock
        self.canShowArchive = canShowArchive
        self.canShowTimeline = canShowTimeline
        self.key = key
        self.reason = reason
        self.writeAvailability = writeAvailability
    }
}

public struct ImmichVisibilityAuthorization: Codable, Sendable {
    public var deadlineUnixMilliseconds: Int64
    public var generation: Int64
    public var grantID: String
    public var operationID: String
    public var sceneID: String
    public init(deadlineUnixMilliseconds: Int64, generation: Int64, grantID: String, operationID: String, sceneID: String) {
        self.deadlineUnixMilliseconds = deadlineUnixMilliseconds
        self.generation = generation
        self.grantID = grantID
        self.operationID = operationID
        self.sceneID = sceneID
    }
}

public struct ImmichVisibilityOperation: Codable, Sendable {
    public var albumMembershipObservation: AlbumMembershipObservation
    public var from: ImmichVisibility
    public var id: String
    public var key: AssetKey
    public var kind: ImmichVisibilityOperationKind
    public var observation: ImmichVisibility?
    public var outcome: VisibilityOutcome
    public var scope: String
    public var selectedObservation: SelectedVisibilityObservation?
    public var to: ImmichVisibility
    public var witnessDigest: String
    public init(albumMembershipObservation: AlbumMembershipObservation, from: ImmichVisibility, id: String, key: AssetKey, kind: ImmichVisibilityOperationKind, observation: ImmichVisibility? = nil, outcome: VisibilityOutcome, scope: String, selectedObservation: SelectedVisibilityObservation? = nil, to: ImmichVisibility, witnessDigest: String) {
        self.albumMembershipObservation = albumMembershipObservation
        self.from = from
        self.id = id
        self.key = key
        self.kind = kind
        self.observation = observation
        self.outcome = outcome
        self.scope = scope
        self.selectedObservation = selectedObservation
        self.to = to
        self.witnessDigest = witnessDigest
    }
}

public enum ImmichVisibilityOperationKind: String, Codable, CaseIterable, Sendable {
    case `lockedTransition`
    case `ordinaryArchive`
}

public struct ImmichVisibilityPrompt: Codable, Sendable {
    public var from: ImmichVisibility
    public var generation: Int64
    public var grantID: String
    public var noAutomaticAlbumRestore: Bool
    public var operationID: String
    public var removesAllAlbumMembership: Bool
    public var sceneID: String
    public var to: ImmichVisibility
    public init(from: ImmichVisibility, generation: Int64, grantID: String, noAutomaticAlbumRestore: Bool, operationID: String, removesAllAlbumMembership: Bool, sceneID: String, to: ImmichVisibility) {
        self.from = from
        self.generation = generation
        self.grantID = grantID
        self.noAutomaticAlbumRestore = noAutomaticAlbumRestore
        self.operationID = operationID
        self.removesAllAlbumMembership = removesAllAlbumMembership
        self.sceneID = sceneID
        self.to = to
    }
}

public struct ImmichVisibilitySummary: Codable, Sendable {
    public var albumMembershipObservation: AlbumMembershipObservation
    public var from: ImmichVisibility
    public var observation: ImmichVisibility?
    public var outcome: VisibilityOutcome
    public var recordID: String
    public var selectedObservation: SelectedVisibilitySummary?
    public var to: ImmichVisibility
    public init(albumMembershipObservation: AlbumMembershipObservation, from: ImmichVisibility, observation: ImmichVisibility? = nil, outcome: VisibilityOutcome, recordID: String, selectedObservation: SelectedVisibilitySummary? = nil, to: ImmichVisibility) {
        self.albumMembershipObservation = albumMembershipObservation
        self.from = from
        self.observation = observation
        self.outcome = outcome
        self.recordID = recordID
        self.selectedObservation = selectedObservation
        self.to = to
    }
}

public enum ImmichVisibilityUnsupportedReason: String, Codable, CaseIterable, Sendable {
    case `live`
    case `video`
    case `stack`
    case `unknown`
    case `unavailable`
}

public struct ImmichVisibilityView: Codable, Sendable {
    public var canRecover: Bool
    public var history: [ImmichVisibilitySummary]?
    public var persistenceUncertain: Bool
    public var sceneID: String?
    public var status: String?
    public init(canRecover: Bool, history: [ImmichVisibilitySummary]? = [], persistenceUncertain: Bool, sceneID: String? = nil, status: String? = nil) {
        self.canRecover = canRecover
        self.history = history
        self.persistenceUncertain = persistenceUncertain
        self.sceneID = sceneID
        self.status = status
    }
}

public enum ImmichVisibilityWriteAvailability: String, Codable, CaseIterable, Sendable {
    case `verificationRequired`
    case `supported`
    case `unsupported`
}

public struct LibrarySnapshot: Codable, Sendable {
    public var provider: Provider
    public var scope: String
    public var assets: [StoredAsset]
    public var access: ScanAccess
    public var scannedAt: Date?
    public init(provider: Provider, scope: String, assets: [StoredAsset] = [], access: ScanAccess, scannedAt: Date? = nil) {
        self.provider = provider
        self.scope = scope
        self.assets = assets
        self.access = access
        self.scannedAt = scannedAt
    }
}

public enum MetadataAction: String, Codable, CaseIterable, Sendable {
    case `setCapturedAt`
    case `setLocation`
    case `removeLocation`
}

public struct MetadataChange: Codable, Sendable {
    public var action: MetadataAction
    public var capturedAt: Date?
    public var location: Coordinates?
    public var timeZone: String?
    public init(action: MetadataAction, capturedAt: Date? = nil, location: Coordinates? = nil, timeZone: String? = nil) {
        self.action = action
        self.capturedAt = capturedAt
        self.location = location
        self.timeZone = timeZone
    }
}

public struct MetadataInput: Codable, Sendable {
    public var action: MetadataAction
    public var capturedAt: Date?
    public var latitude: String?
    public var longitude: String?
    public var timeZone: String?
    public init(action: MetadataAction, capturedAt: Date? = nil, latitude: String? = nil, longitude: String? = nil, timeZone: String? = nil) {
        self.action = action
        self.capturedAt = capturedAt
        self.latitude = latitude
        self.longitude = longitude
        self.timeZone = timeZone
    }
}

public struct MetadataTarget: Codable, Sendable {
    public var canRemoveLocation: Bool
    public var capturedAt: Date?
    public var datesVary: Bool
    public var disabledReason: String?
    public var id: String
    public var keys: [AssetKey]
    public var location: Coordinates?
    public var locationsVary: Bool
    public var provider: Provider
    public init(canRemoveLocation: Bool, capturedAt: Date? = nil, datesVary: Bool, disabledReason: String? = nil, id: String, keys: [AssetKey] = [], location: Coordinates? = nil, locationsVary: Bool, provider: Provider) {
        self.canRemoveLocation = canRemoveLocation
        self.capturedAt = capturedAt
        self.datesVary = datesVary
        self.disabledReason = disabledReason
        self.id = id
        self.keys = keys
        self.location = location
        self.locationsVary = locationsVary
        self.provider = provider
    }
}

public struct NativeColorPlan: Codable, Sendable {
    public var brightness: Double
    public var contrast: Double
    public var exposureEv: Double
    public var filter: ImageColorFilter
    public var saturation: Double
    public init(brightness: Double, contrast: Double, exposureEv: Double, filter: ImageColorFilter, saturation: Double) {
        self.brightness = brightness
        self.contrast = contrast
        self.exposureEv = exposureEv
        self.filter = filter
        self.saturation = saturation
    }
}

public struct OrdinaryContentAuthorization: Codable, Sendable {
    public var expectedRevision: String
    public var purpose: OrdinaryContentPurpose
    public var sourceKeys: [AssetKey]
    public init(expectedRevision: String, purpose: OrdinaryContentPurpose, sourceKeys: [AssetKey] = []) {
        self.expectedRevision = expectedRevision
        self.purpose = purpose
        self.sourceKeys = sourceKeys
    }
}

public enum OrdinaryContentPurpose: String, Codable, CaseIterable, Sendable {
    case `read`
    case `destinationReadback`
    case `visibilityReconciliation`
    case `selectedPresentationMetadata`
}

public struct OrdinarySelectedImageAccess: Codable, Sendable {
    public var generation: Int64
    public var key: AssetKey
    public var kind: OrdinarySelectedImageKind
    public var proofID: String
    public var requestID: String
    public var sceneID: String
    public var stagedID: String
    public init(generation: Int64, key: AssetKey, kind: OrdinarySelectedImageKind, proofID: String, requestID: String, sceneID: String, stagedID: String) {
        self.generation = generation
        self.key = key
        self.kind = kind
        self.proofID = proofID
        self.requestID = requestID
        self.sceneID = sceneID
        self.stagedID = stagedID
    }
}

public enum OrdinarySelectedImageKind: String, Codable, CaseIterable, Sendable {
    case `thumbnail`
    case `preview`
}

public struct OrdinarySelectedImageRequest: Codable, Sendable {
    public var generation: Int64
    public var key: AssetKey
    public var kind: OrdinarySelectedImageKind
    public var proofID: String
    public var requestID: String
    public var sceneID: String
    public init(generation: Int64, key: AssetKey, kind: OrdinarySelectedImageKind, proofID: String, requestID: String, sceneID: String) {
        self.generation = generation
        self.key = key
        self.kind = kind
        self.proofID = proofID
        self.requestID = requestID
        self.sceneID = sceneID
    }
}

public struct OrdinarySelectedImageResult: Codable, Sendable {
    public var requestID: String
    public var stagedID: String
    public init(requestID: String, stagedID: String) {
        self.requestID = requestID
        self.stagedID = stagedID
    }
}

public struct OrdinarySelectedImageTicket: Codable, Sendable {
    public var expectedRevision: String
    public var generation: Int64
    public var key: AssetKey
    public var kind: OrdinarySelectedImageKind
    public var proofID: String
    public var request: HttpRequest
    public var requestID: String
    public var sceneID: String
    public init(expectedRevision: String, generation: Int64, key: AssetKey, kind: OrdinarySelectedImageKind, proofID: String, request: HttpRequest, requestID: String, sceneID: String) {
        self.expectedRevision = expectedRevision
        self.generation = generation
        self.key = key
        self.kind = kind
        self.proofID = proofID
        self.request = request
        self.requestID = requestID
        self.sceneID = sceneID
    }
}

public struct OrdinarySelectedPresentation: Codable, Sendable {
    public var currentVisibility: OrdinarySelectedVisibility
    public var generation: Int64
    public var key: AssetKey
    public var proofID: String
    public init(currentVisibility: OrdinarySelectedVisibility, generation: Int64, key: AssetKey, proofID: String) {
        self.currentVisibility = currentVisibility
        self.generation = generation
        self.key = key
        self.proofID = proofID
    }
}

public enum OrdinarySelectedVisibility: String, Codable, CaseIterable, Sendable {
    case `timeline`
    case `archive`
}

public struct PasteEditsPrompt: Codable, Sendable {
    public var names: [String]
    public var options: EditCopyOptions
    public var sourceName: String
    public var unchangedCount: Int64
    public init(names: [String] = [], options: EditCopyOptions, sourceName: String, unchangedCount: Int64) {
        self.names = names
        self.options = options
        self.sourceName = sourceName
        self.unchangedCount = unchangedCount
    }
}

public struct PendingEditPaste: Codable, Sendable {
    public var before: TransferBundle
    public var initialAdjustment: AppleAdjustment?
    public var key: AssetKey
    public var name: String
    public var plan: ImageRenderPlan
    public init(before: TransferBundle, initialAdjustment: AppleAdjustment? = nil, key: AssetKey, name: String, plan: ImageRenderPlan) {
        self.before = before
        self.initialAdjustment = initialAdjustment
        self.key = key
        self.name = name
        self.plan = plan
    }
}

public struct PendingUpload: Codable, Sendable {
    public var key: AssetKey
    public var liveId: String?
    public var phase: UploadPhase
    public var resource: PhotoResource
    public var signature: FileSignature
    public var source: StoredAsset
    public init(key: AssetKey, liveId: String? = nil, phase: UploadPhase, resource: PhotoResource, signature: FileSignature, source: StoredAsset) {
        self.key = key
        self.liveId = liveId
        self.phase = phase
        self.resource = resource
        self.signature = signature
        self.source = source
    }
}

public struct PersistentProtectedEntry: Codable, Sendable {
    public var id: String
    public var key: AssetKey
    public init(id: String, key: AssetKey) {
        self.id = id
        self.key = key
    }
}

public enum PhotoFilter: String, Codable, CaseIterable, Sendable {
    case `all`
    case `favorites`
    case `photos`
    case `videos`
    case `live`
    case `raw`
}

public struct PhotoResource: Codable, Sendable {
    public var id: String
    public var name: String
    public var role: ResourceRole
    public var sha1: String?
    public var bytes: Int64?
    public init(id: String, name: String, role: ResourceRole, sha1: String? = nil, bytes: Int64? = nil) {
        self.id = id
        self.name = name
        self.role = role
        self.sha1 = sha1
        self.bytes = bytes
    }
}

public enum PhotoSort: String, Codable, CaseIterable, Sendable {
    case `newest`
    case `oldest`
    case `name`
}

public struct PixelCrop: Codable, Sendable {
    public var height: Int64
    public var width: Int64
    public var x: Int64
    public var y: Int64
    public init(height: Int64, width: Int64, x: Int64, y: Int64) {
        self.height = height
        self.width = width
        self.x = x
        self.y = y
    }
}

public struct PixelSize: Codable, Sendable {
    public var height: Int64
    public var width: Int64
    public init(height: Int64, width: Int64) {
        self.height = height
        self.width = width
    }
}

public enum PlaybackKind: String, Codable, CaseIterable, Sendable {
    case `video`
    case `live`
}

public struct PlaybackPlan: Codable, Sendable {
    public var files: [String]
    public var kind: PlaybackKind
    public var name: String
    public var sourceKeys: [AssetKey]
    public init(files: [String] = [], kind: PlaybackKind, name: String, sourceKeys: [AssetKey] = []) {
        self.files = files
        self.kind = kind
        self.name = name
        self.sourceKeys = sourceKeys
    }
}

public enum Presence: String, Codable, CaseIterable, Sendable {
    case `both`
    case `appleOnly`
    case `immichOnly`
    case `partial`
    case `unverified`
}

public struct PreviewChoice: Codable, Sendable {
    public var cacheId: String
    public var capturedAt: Date?
    public var disabledReason: String?
    public var key: AssetKey
    public var modifiedAt: Date?
    public var name: String
    public var selected: Bool
    public init(cacheId: String, capturedAt: Date? = nil, disabledReason: String? = nil, key: AssetKey, modifiedAt: Date? = nil, name: String, selected: Bool) {
        self.cacheId = cacheId
        self.capturedAt = capturedAt
        self.disabledReason = disabledReason
        self.key = key
        self.modifiedAt = modifiedAt
        self.name = name
        self.selected = selected
    }
}

public enum ProtectedAuthOutcome: String, Codable, CaseIterable, Sendable {
    case `success`
    case `cancelled`
    case `unavailable`
    case `failed`
}

public struct ProtectedAuthResult: Codable, Sendable {
    public var challengeID: String
    public var outcome: ProtectedAuthOutcome
    public var sceneID: String
    public var scope: String
    public init(challengeID: String, outcome: ProtectedAuthOutcome, sceneID: String, scope: String) {
        self.challengeID = challengeID
        self.outcome = outcome
        self.sceneID = sceneID
        self.scope = scope
    }
}

public struct ProtectedChallenge: Codable, Sendable {
    public var challengeID: String
    public var generation: Int64
    public var purpose: ProtectedPurpose
    public var sceneID: String
    public var scope: String
    public init(challengeID: String, generation: Int64, purpose: ProtectedPurpose, sceneID: String, scope: String) {
        self.challengeID = challengeID
        self.generation = generation
        self.purpose = purpose
        self.sceneID = sceneID
        self.scope = scope
    }
}

public struct ProtectedEntryView: Codable, Sendable {
    public var asset: StoredAsset?
    public var id: String
    public init(asset: StoredAsset? = nil, id: String) {
        self.asset = asset
        self.id = id
    }
}

public struct ProtectedImageAccess: Codable, Sendable {
    public var entryID: String
    public var generation: Int64
    public var grantID: String
    public var kind: ProtectedImageKind
    public var requestID: String
    public var sceneID: String
    public var stagedID: String
    public init(entryID: String, generation: Int64, grantID: String, kind: ProtectedImageKind, requestID: String, sceneID: String, stagedID: String) {
        self.entryID = entryID
        self.generation = generation
        self.grantID = grantID
        self.kind = kind
        self.requestID = requestID
        self.sceneID = sceneID
        self.stagedID = stagedID
    }
}

public enum ProtectedImageKind: String, Codable, CaseIterable, Sendable {
    case `thumbnail`
    case `preview`
}

public struct ProtectedImageResult: Codable, Sendable {
    public var freshAppleAsset: StoredAsset?
    public var fullAccess: Bool
    public var requestID: String
    public var stagedID: String
    public init(freshAppleAsset: StoredAsset? = nil, fullAccess: Bool, requestID: String, stagedID: String) {
        self.freshAppleAsset = freshAppleAsset
        self.fullAccess = fullAccess
        self.requestID = requestID
        self.stagedID = stagedID
    }
}

public struct ProtectedImageTicket: Codable, Sendable {
    public var entryID: String
    public var expectedRevision: String
    public var generation: Int64
    public var grantID: String
    public var key: AssetKey
    public var kind: ProtectedImageKind
    public var remoteRequest: HttpRequest?
    public var requestID: String
    public var sceneID: String
    public init(entryID: String, expectedRevision: String, generation: Int64, grantID: String, key: AssetKey, kind: ProtectedImageKind, remoteRequest: HttpRequest? = nil, requestID: String, sceneID: String) {
        self.entryID = entryID
        self.expectedRevision = expectedRevision
        self.generation = generation
        self.grantID = grantID
        self.key = key
        self.kind = kind
        self.remoteRequest = remoteRequest
        self.requestID = requestID
        self.sceneID = sceneID
    }
}

public enum ProtectedPurpose: String, Codable, CaseIterable, Sendable {
    case `view`
    case `protect`
}

public struct ProtectedView: Codable, Sendable {
    public var canRecover: Bool
    public var entries: [ProtectedEntryView]?
    public var error: String?
    public var generation: Int64
    public var grantID: String?
    public var image: ProtectedImageAccess?
    public var persistenceUncertain: Bool
    public var purpose: ProtectedPurpose?
    public var sceneID: String?
    public var state: ProtectedViewState
    public init(canRecover: Bool, entries: [ProtectedEntryView]? = [], error: String? = nil, generation: Int64, grantID: String? = nil, image: ProtectedImageAccess? = nil, persistenceUncertain: Bool, purpose: ProtectedPurpose? = nil, sceneID: String? = nil, state: ProtectedViewState) {
        self.canRecover = canRecover
        self.entries = entries
        self.error = error
        self.generation = generation
        self.grantID = grantID
        self.image = image
        self.persistenceUncertain = persistenceUncertain
        self.purpose = purpose
        self.sceneID = sceneID
        self.state = state
    }
}

public enum ProtectedViewState: String, Codable, CaseIterable, Sendable {
    case `locked`
    case `authenticating`
    case `open`
}

public enum ProtectionScenePhase: String, Codable, CaseIterable, Sendable {
    case `background`
    case `active`
    case `inactive`
}

public enum Provider: String, Codable, CaseIterable, Sendable {
    case `apple`
    case `immich`
}

public struct PublishedLibrary: Codable, Sendable {
    public var albums: [AlbumSnapshot]
    public var appleScope: String
    public var appleVisibilityOperations: [AppleVisibilitySummary]
    public var connection: ConnectionSettings?
    public var editClipboard: EditClipboard?
    public var pendingAppleTrash: [AppleTrashOperation]
    public var pendingEditPastes: [PendingEditPaste]
    public var pendingTrash: [TrashOperation]
    public var pendingUploads: [PendingUpload]
    public var receipts: [TransferReceipt]
    public var schemaVersion: Int64
    public var snapshots: [LibrarySnapshot]
    public var trash: TrashSnapshot?
    public var uploadIntents: [UploadIntent]
    public init(albums: [AlbumSnapshot] = [], appleScope: String, appleVisibilityOperations: [AppleVisibilitySummary] = [], connection: ConnectionSettings? = nil, editClipboard: EditClipboard? = nil, pendingAppleTrash: [AppleTrashOperation] = [], pendingEditPastes: [PendingEditPaste] = [], pendingTrash: [TrashOperation] = [], pendingUploads: [PendingUpload] = [], receipts: [TransferReceipt] = [], schemaVersion: Int64, snapshots: [LibrarySnapshot] = [], trash: TrashSnapshot? = nil, uploadIntents: [UploadIntent] = []) {
        self.albums = albums
        self.appleScope = appleScope
        self.appleVisibilityOperations = appleVisibilityOperations
        self.connection = connection
        self.editClipboard = editClipboard
        self.pendingAppleTrash = pendingAppleTrash
        self.pendingEditPastes = pendingEditPastes
        self.pendingTrash = pendingTrash
        self.pendingUploads = pendingUploads
        self.receipts = receipts
        self.schemaVersion = schemaVersion
        self.snapshots = snapshots
        self.trash = trash
        self.uploadIntents = uploadIntents
    }
}

public enum RenderFormat: String, Codable, CaseIterable, Sendable {
    case `jpeg`
    case `heic`
}

public enum ResourceRole: String, Codable, CaseIterable, Sendable {
    case `image`
    case `rawImage`
    case `video`
    case `liveVideo`
    case `auxiliary`
}

public struct ReversionPrompt: Codable, Sendable {
    public var key: AssetKey
    public var name: String
    public init(key: AssetKey, name: String) {
        self.key = key
        self.name = name
    }
}

public struct SavedLibrary: Codable, Sendable {
    public var albums: [AlbumSnapshot]
    public var appleScope: String
    public var appleVisibilityOperations: [AppleVisibilityOperation]
    public var connection: ConnectionSettings?
    public var editClipboard: EditClipboard?
    public var immichVisibilityOperations: [ImmichVisibilityOperation]
    public var pendingAppleTrash: [AppleTrashOperation]
    public var pendingEditPastes: [PendingEditPaste]
    public var pendingTrash: [TrashOperation]
    public var pendingUploads: [PendingUpload]
    public var protectedEntries: [PersistentProtectedEntry]
    public var receipts: [TransferReceipt]
    public var schemaVersion: Int64
    public var snapshots: [LibrarySnapshot]
    public var trash: TrashSnapshot?
    public var uploadIntents: [UploadIntent]
    public init(albums: [AlbumSnapshot] = [], appleScope: String, appleVisibilityOperations: [AppleVisibilityOperation] = [], connection: ConnectionSettings? = nil, editClipboard: EditClipboard? = nil, immichVisibilityOperations: [ImmichVisibilityOperation] = [], pendingAppleTrash: [AppleTrashOperation] = [], pendingEditPastes: [PendingEditPaste] = [], pendingTrash: [TrashOperation] = [], pendingUploads: [PendingUpload] = [], protectedEntries: [PersistentProtectedEntry] = [], receipts: [TransferReceipt] = [], schemaVersion: Int64, snapshots: [LibrarySnapshot] = [], trash: TrashSnapshot? = nil, uploadIntents: [UploadIntent] = []) {
        self.albums = albums
        self.appleScope = appleScope
        self.appleVisibilityOperations = appleVisibilityOperations
        self.connection = connection
        self.editClipboard = editClipboard
        self.immichVisibilityOperations = immichVisibilityOperations
        self.pendingAppleTrash = pendingAppleTrash
        self.pendingEditPastes = pendingEditPastes
        self.pendingTrash = pendingTrash
        self.pendingUploads = pendingUploads
        self.protectedEntries = protectedEntries
        self.receipts = receipts
        self.schemaVersion = schemaVersion
        self.snapshots = snapshots
        self.trash = trash
        self.uploadIntents = uploadIntents
    }
}

public enum ScanAccess: String, Codable, CaseIterable, Sendable {
    case `full`
    case `limited`
    case `unavailable`
}

public enum SelectedConfiguration: String, Codable, CaseIterable, Sendable {
    case `unlinked`
    case `linked`
    case `stacked`
    case `unverified`
}

public struct SelectedVisibilityObservation: Codable, Sendable {
    public var configuration: SelectedConfiguration
    public var configurationDigest: String?
    public var selectedIdentityDigest: String
    public var visibility: ImmichVisibility
    public init(configuration: SelectedConfiguration, configurationDigest: String? = nil, selectedIdentityDigest: String, visibility: ImmichVisibility) {
        self.configuration = configuration
        self.configurationDigest = configurationDigest
        self.selectedIdentityDigest = selectedIdentityDigest
        self.visibility = visibility
    }
}

public struct SelectedVisibilitySummary: Codable, Sendable {
    public var configuration: SelectedConfiguration
    public var visibility: ImmichVisibility
    public init(configuration: SelectedConfiguration, visibility: ImmichVisibility) {
        self.configuration = configuration
        self.visibility = visibility
    }
}

public struct ShareFile: Codable, Sendable {
    public var name: String
    public var path: String
    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

public struct SharePresentation: Codable, Sendable {
    public var files: [ShareFile]
    public var sourceKeys: [AssetKey]?
    public init(files: [ShareFile] = [], sourceKeys: [AssetKey]? = []) {
        self.files = files
        self.sourceKeys = sourceKeys
    }
}

public struct StoredAlbum: Codable, Sendable {
    public var key: AlbumKey
    public var members: [AssetKey]
    public var permissions: AlbumPermissions
    public var title: String
    public init(key: AlbumKey, members: [AssetKey] = [], permissions: AlbumPermissions, title: String) {
        self.key = key
        self.members = members
        self.permissions = permissions
        self.title = title
    }
}

public struct StoredAsset: Codable, Sendable {
    public var appleVisibility: AppleVisibility
    public var key: AssetKey
    public var name: String
    public var capturedAt: Date?
    public var modifiedAt: Date?
    public var revision: String
    public var resources: [PhotoResource]
    public var isFavorite: Bool
    public var latitude: Double?
    public var longitude: Double?
    public var inventoryComplete: Bool
    public var isOffline: Bool
    public var deletionBlockers: [String]
    public var immichStack: ImmichStackState
    public var immichVisibility: ImmichVisibility?
    public init(appleVisibility: AppleVisibility = .unknown, key: AssetKey, name: String, capturedAt: Date? = nil, modifiedAt: Date? = nil, revision: String, resources: [PhotoResource] = [], isFavorite: Bool = false, latitude: Double? = nil, longitude: Double? = nil, inventoryComplete: Bool = true, isOffline: Bool = false, deletionBlockers: [String] = [], immichStack: ImmichStackState = .unknown, immichVisibility: ImmichVisibility? = nil) {
        self.appleVisibility = appleVisibility
        self.key = key
        self.name = name
        self.capturedAt = capturedAt
        self.modifiedAt = modifiedAt
        self.revision = revision
        self.resources = resources
        self.isFavorite = isFavorite
        self.latitude = latitude
        self.longitude = longitude
        self.inventoryComplete = inventoryComplete
        self.isOffline = isOffline
        self.deletionBlockers = deletionBlockers
        self.immichStack = immichStack
        self.immichVisibility = immichVisibility
    }
}

public struct TransferBundle: Codable, Sendable {
    public var assets: [StoredAsset]
    public var files: [TransferFile]
    public init(assets: [StoredAsset] = [], files: [TransferFile] = []) {
        self.assets = assets
        self.files = files
    }
}

public struct TransferFile: Codable, Sendable {
    public var resource: PhotoResource
    public var path: String
    public var signature: FileSignature
    public init(resource: PhotoResource, path: String, signature: FileSignature) {
        self.resource = resource
        self.path = path
        self.signature = signature
    }
}

public enum TransferIntent: String, Codable, CaseIterable, Sendable {
    case `copy`
    case `move`
}

public enum TransferPhase: String, Codable, CaseIterable, Sendable {
    case `copying`
    case `copied`
    case `deletingSource`
    case `moved`
    case `deletionUncertain`
}

public struct TransferReceipt: Codable, Sendable {
    public var createdAt: Date
    public var destination: [StoredAsset]
    public var destinationProvider: Provider
    public var destinationScope: String
    public var id: String
    public var intent: TransferIntent
    public var phase: TransferPhase
    public var signatures: [FileSignature]
    public var source: [StoredAsset]
    public init(createdAt: Date, destination: [StoredAsset] = [], destinationProvider: Provider, destinationScope: String, id: String, intent: TransferIntent, phase: TransferPhase, signatures: [FileSignature] = [], source: [StoredAsset] = []) {
        self.createdAt = createdAt
        self.destination = destination
        self.destinationProvider = destinationProvider
        self.destinationScope = destinationScope
        self.id = id
        self.intent = intent
        self.phase = phase
        self.signatures = signatures
        self.source = source
    }
}

public enum TrashAction: String, Codable, CaseIterable, Sendable {
    case `trash`
    case `restore`
}

public struct TrashIdentity: Codable, Sendable {
    public var checksum: String
    public var createdAt: String
    public var key: AssetKey
    public var livePhotoVideoId: String?
    public var mediaType: String
    public var modifiedAt: String
    public var name: String
    public init(checksum: String, createdAt: String, key: AssetKey, livePhotoVideoId: String? = nil, mediaType: String, modifiedAt: String, name: String) {
        self.checksum = checksum
        self.createdAt = createdAt
        self.key = key
        self.livePhotoVideoId = livePhotoVideoId
        self.mediaType = mediaType
        self.modifiedAt = modifiedAt
        self.name = name
    }
}

public struct TrashItem: Codable, Sendable {
    public var asset: StoredAsset
    public var identity: TrashIdentity
    public init(asset: StoredAsset, identity: TrashIdentity) {
        self.asset = asset
        self.identity = identity
    }
}

public struct TrashOperation: Codable, Sendable {
    public var action: TrashAction
    public var assets: [TrashIdentity]
    public var id: String
    public var scope: String
    public init(action: TrashAction, assets: [TrashIdentity] = [], id: String, scope: String) {
        self.action = action
        self.assets = assets
        self.id = id
        self.scope = scope
    }
}

public struct TrashPrompt: Codable, Sendable {
    public var action: TrashAction
    public var address: String
    public var names: [String]
    public var retentionDays: Int64?
    public init(action: TrashAction, address: String, names: [String] = [], retentionDays: Int64? = nil) {
        self.action = action
        self.address = address
        self.names = names
        self.retentionDays = retentionDays
    }
}

public struct TrashSnapshot: Codable, Sendable {
    public var items: [TrashItem]
    public var scope: String
    public var verified: Bool
    public init(items: [TrashItem] = [], scope: String, verified: Bool) {
        self.items = items
        self.scope = scope
        self.verified = verified
    }
}

public struct UnifiedPhoto: Codable, Sendable {
    public var assets: [StoredAsset]
    public var presence: Presence
    public init(assets: [StoredAsset] = [], presence: Presence) {
        self.assets = assets
        self.presence = presence
    }
}

public struct UploadForgetPrompt: Codable, Sendable {
    public var key: AssetKey
    public var name: String
    public init(key: AssetKey, name: String) {
        self.key = key
        self.name = name
    }
}

public struct UploadIntent: Codable, Sendable {
    public var liveId: String?
    public var resource: PhotoResource
    public var scope: String
    public var signature: FileSignature
    public var source: StoredAsset
    public var token: String
    public init(liveId: String? = nil, resource: PhotoResource, scope: String, signature: FileSignature, source: StoredAsset, token: String) {
        self.liveId = liveId
        self.resource = resource
        self.scope = scope
        self.signature = signature
        self.source = source
        self.token = token
    }
}

public struct UploadIntentForgetPrompt: Codable, Sendable {
    public var name: String
    public var scope: String
    public var token: String
    public init(name: String, scope: String, token: String) {
        self.name = name
        self.scope = scope
        self.token = token
    }
}

public struct UploadPart: Codable, Sendable {
    public var field: String
    public var filename: String
    public var path: String
    public init(field: String, filename: String, path: String) {
        self.field = field
        self.filename = filename
        self.path = path
    }
}

public enum UploadPhase: String, Codable, CaseIterable, Sendable {
    case `metadataPending`
    case `metadataStarted`
}

public struct UploadResumePrompt: Codable, Sendable {
    public var key: AssetKey
    public var name: String
    public var source: StoredAsset
    public init(key: AssetKey, name: String, source: StoredAsset) {
        self.key = key
        self.name = name
        self.source = source
    }
}

public struct Version: Codable, Sendable {
    public var major: Int64
    public var minor: Int64
    public var patch: Int64
    public init(major: Int64, minor: Int64, patch: Int64) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }
}

public struct ViewModel: Codable, Sendable {
    public var albums: [AlbumView]
    public var appleVisibilityHideKeys: [AssetKey]
    public var browser: BrowserView
    public var busy: Bool
    public var canTransfer: Bool
    public var editingTargets: [String: [EditingTarget]]
    public var error: String?
    public var immichArchiveActions: [ImmichArchiveActionHint]
    public var immichArchiveView: ImmichArchiveView
    public var immichLockedView: ImmichLockedView
    public var immichVisibilityActions: [ImmichVisibilityActionHint]
    public var immichVisibilityView: ImmichVisibilityView
    public var media: [String: PlaybackKind]
    public var metadataTargets: [String: [MetadataTarget]]
    public var moveBlockers: [String: [String]]
    public var ordinaryContentKeys: [AssetKey]
    public var ordinarySelectedGeneration: Int64
    public var ordinarySelectedImages: [OrdinarySelectedImageAccess]
    public var ordinarySelectedPending: [OrdinarySelectedImageRequest]
    public var ordinarySelectedPresentation: [OrdinarySelectedPresentation]
    public var pendingAppleCount: Int64
    public var photos: [UnifiedPhoto]
    public var previewChoices: [String: [PreviewChoice]]
    public var previewSources: [String: AssetKey]
    public var privateContentRevision: String
    public var protectedView: ProtectedView
    public var remoteVersion: Version?
    public var serverVersion: String?
    public var state: PublishedLibrary
    public var status: String
    public init(albums: [AlbumView] = [], appleVisibilityHideKeys: [AssetKey] = [], browser: BrowserView, busy: Bool, canTransfer: Bool, editingTargets: [String: [EditingTarget]] = [:], error: String? = nil, immichArchiveActions: [ImmichArchiveActionHint] = [], immichArchiveView: ImmichArchiveView, immichLockedView: ImmichLockedView, immichVisibilityActions: [ImmichVisibilityActionHint] = [], immichVisibilityView: ImmichVisibilityView, media: [String: PlaybackKind] = [:], metadataTargets: [String: [MetadataTarget]] = [:], moveBlockers: [String: [String]] = [:], ordinaryContentKeys: [AssetKey] = [], ordinarySelectedGeneration: Int64, ordinarySelectedImages: [OrdinarySelectedImageAccess] = [], ordinarySelectedPending: [OrdinarySelectedImageRequest] = [], ordinarySelectedPresentation: [OrdinarySelectedPresentation] = [], pendingAppleCount: Int64, photos: [UnifiedPhoto] = [], previewChoices: [String: [PreviewChoice]] = [:], previewSources: [String: AssetKey] = [:], privateContentRevision: String, protectedView: ProtectedView, remoteVersion: Version? = nil, serverVersion: String? = nil, state: PublishedLibrary, status: String) {
        self.albums = albums
        self.appleVisibilityHideKeys = appleVisibilityHideKeys
        self.browser = browser
        self.busy = busy
        self.canTransfer = canTransfer
        self.editingTargets = editingTargets
        self.error = error
        self.immichArchiveActions = immichArchiveActions
        self.immichArchiveView = immichArchiveView
        self.immichLockedView = immichLockedView
        self.immichVisibilityActions = immichVisibilityActions
        self.immichVisibilityView = immichVisibilityView
        self.media = media
        self.metadataTargets = metadataTargets
        self.moveBlockers = moveBlockers
        self.ordinaryContentKeys = ordinaryContentKeys
        self.ordinarySelectedGeneration = ordinarySelectedGeneration
        self.ordinarySelectedImages = ordinarySelectedImages
        self.ordinarySelectedPending = ordinarySelectedPending
        self.ordinarySelectedPresentation = ordinarySelectedPresentation
        self.pendingAppleCount = pendingAppleCount
        self.photos = photos
        self.previewChoices = previewChoices
        self.previewSources = previewSources
        self.privateContentRevision = privateContentRevision
        self.protectedView = protectedView
        self.remoteVersion = remoteVersion
        self.serverVersion = serverVersion
        self.state = state
        self.status = status
    }
}

public enum VisibilityAction: String, Codable, CaseIterable, Sendable {
    case `hide`
    case `unhide`
}

public struct VisibilityApplyTarget: Codable, Sendable {
    public var expectedWitness: String
    public var freshRevision: String
    public var key: AssetKey
    public init(expectedWitness: String, freshRevision: String, key: AssetKey) {
        self.expectedWitness = expectedWitness
        self.freshRevision = freshRevision
        self.key = key
    }
}

public struct VisibilityIdentity: Codable, Sendable {
    public var creationDate: Double?
    public var mediaSubtypes: Int64
    public var mediaType: Int64
    public var pixelHeight: Int64
    public var pixelWidth: Int64
    public var resources: [VisibilityResource]
    public init(creationDate: Double? = nil, mediaSubtypes: Int64, mediaType: Int64, pixelHeight: Int64, pixelWidth: Int64, resources: [VisibilityResource] = []) {
        self.creationDate = creationDate
        self.mediaSubtypes = mediaSubtypes
        self.mediaType = mediaType
        self.pixelHeight = pixelHeight
        self.pixelWidth = pixelWidth
        self.resources = resources
    }
}

public enum VisibilityObservation: String, Codable, CaseIterable, Sendable {
    case `observedVisible`
    case `observedHidden`
}

public enum VisibilityOutcome: String, Codable, CaseIterable, Sendable {
    case `unknown`
    case `applied`
    case `notApplied`
}

public struct VisibilityResource: Codable, Sendable {
    public var id: String
    public var originalFilename: String
    public var role: ResourceRole
    public init(id: String, originalFilename: String, role: ResourceRole) {
        self.id = id
        self.originalFilename = originalFilename
        self.role = role
    }
}

public struct VisibilityTarget: Codable, Sendable {
    public var key: AssetKey
    public var observation: VisibilityObservation?
    public var witnessDigest: String
    public init(key: AssetKey, observation: VisibilityObservation? = nil, witnessDigest: String) {
        self.key = key
        self.observation = observation
        self.witnessDigest = witnessDigest
    }
}
