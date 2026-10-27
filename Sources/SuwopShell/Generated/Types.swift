// Generated from Rust schema. Run make generate-types; do not edit.
import Foundation

private struct GeneratedSchemaKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
private func requireSchemaKeys(_ decoder: any Decoder, allowed: Set<String>) throws {
    let values = try decoder.container(keyedBy: GeneratedSchemaKey.self)
    guard Set(values.allKeys.map(\.stringValue)).isSubset(of: allowed) else {
        throw DecodingError.dataCorrupted(.init(
            codingPath: decoder.codingPath, debugDescription: "Unknown object field"
        ))
    }
}

public struct Accepted204: Codable, Sendable {
    public var attemptId: String
    public var batchId: String
    public var intentDigest: String
    public var key: AssetKey
    public var stepId: String
    public init(attemptId: String, batchId: String, intentDigest: String, key: AssetKey, stepId: String) {
        self.attemptId = attemptId
        self.batchId = batchId
        self.intentDigest = intentDigest
        self.key = key
        self.stepId = stepId
    }
    private enum CodingKeys: String, CodingKey { case attemptId, batchId, intentDigest, key, stepId }
    public init(from decoder: any Decoder) throws {
        try requireSchemaKeys(decoder, allowed: ["attemptId", "batchId", "intentDigest", "key", "stepId"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        attemptId = try values.decode(String.self, forKey: .attemptId)
        batchId = try values.decode(String.self, forKey: .batchId)
        intentDigest = try values.decode(String.self, forKey: .intentDigest)
        key = try values.decode(AssetKey.self, forKey: .key)
        stepId = try values.decode(String.self, forKey: .stepId)
    }
}

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

public enum AlbumDateOrder: String, Codable, CaseIterable, Sendable {
    case `asc`
    case `desc`
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
    public var collections: [StoredCollection]
    public var provider: Provider
    public var scope: String
    public init(access: ScanAccess, albums: [StoredAlbum] = [], collections: [StoredCollection] = [], provider: Provider, scope: String) {
        self.access = access
        self.albums = albums
        self.collections = collections
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

public struct Alias: Codable, Sendable {
    public var destination: Placement
    public var edgeId: String
    public var id: String
    public var resourceId: String
    public var role: Role
    public init(destination: Placement, edgeId: String, id: String, resourceId: String, role: Role) {
        self.destination = destination
        self.edgeId = edgeId
        self.id = id
        self.resourceId = resourceId
        self.role = role
    }
}

public struct AmazonConnection: Codable, Sendable {
    public var credentialID: String
    public var ownerId: String
    public var rootId: String
    public var scope: String
    public init(credentialID: String, ownerId: String, rootId: String, scope: String) {
        self.credentialID = credentialID
        self.ownerId = ownerId
        self.rootId = rootId
        self.scope = scope
    }
}

public struct AmazonHash: Codable, Sendable {
    public var md5: String
    public var sha1: String
    public var signature: FileSignature
    public init(md5: String, sha1: String, signature: FileSignature) {
        self.md5 = md5
        self.sha1 = sha1
        self.signature = signature
    }
}

public struct AmazonRequest: Codable, Sendable {
    public var byteLimit: Int64
    public var credentialID: String
    public var http: HttpRequest
    public init(byteLimit: Int64, credentialID: String, http: HttpRequest) {
        self.byteLimit = byteLimit
        self.credentialID = credentialID
        self.http = http
    }
}

public struct AmazonResponse: Codable, Sendable {
    public var body: JSONValue
    public var location: String?
    public var path: String?
    public var status: Int64
    public init(body: JSONValue, location: String? = nil, path: String? = nil, status: Int64) {
        self.body = body
        self.location = location
        self.path = path
        self.status = status
    }
}

public struct AmazonUploadRecord: Codable, Sendable {
    public var md5: String
    public var name: String
    public var nodeId: String?
    public var receiptId: String
    public var scope: String
    public var signature: FileSignature
    public var verified: Bool
    public init(md5: String, name: String, nodeId: String? = nil, receiptId: String, scope: String, signature: FileSignature, verified: Bool) {
        self.md5 = md5
        self.name = name
        self.nodeId = nodeId
        self.receiptId = receiptId
        self.scope = scope
        self.signature = signature
        self.verified = verified
    }
}

public struct AmazonUploadSubmission: Codable, Sendable {
    public var failure: String?
    public var response: AmazonResponse?
    public var submitted: Bool
    public init(failure: String? = nil, response: AmazonResponse? = nil, submitted: Bool) {
        self.failure = failure
        self.response = response
        self.submitted = submitted
    }
}

public struct AnalysisBudget: Codable, Sendable {
    public var cacheBytes: Int64
    public var maxBatchRows: Int64
    public var workingBytes: Int64
    public init(cacheBytes: Int64, maxBatchRows: Int64, workingBytes: Int64) {
        self.cacheBytes = cacheBytes
        self.maxBatchRows = maxBatchRows
        self.workingBytes = workingBytes
    }
}

public struct AnalysisModel: Codable, Sendable {
    public var dimensions: Int64
    public var name: String
    public var preprocessing: String
    public var rendition: String
    public var version: String
    public init(dimensions: Int64, name: String, preprocessing: String, rendition: String, version: String) {
        self.dimensions = dimensions
        self.name = name
        self.preprocessing = preprocessing
        self.rendition = rendition
        self.version = version
    }
}

public struct AnalysisStatus: Codable, Sendable {
    public var activeGeneration: Int64?
    public var awaitingEmbeddings: Int64
    public var budget: AnalysisBudget
    public var error: String?
    public var generation: Int64
    public var indexed: Int64
    public var model: AnalysisModel
    public var modelKey: String
    public var queuedVectors: Int64
    public var skipped: Int64
    public var state: String
    public init(activeGeneration: Int64? = nil, awaitingEmbeddings: Int64, budget: AnalysisBudget, error: String? = nil, generation: Int64, indexed: Int64, model: AnalysisModel, modelKey: String, queuedVectors: Int64, skipped: Int64, state: String) {
        self.activeGeneration = activeGeneration
        self.awaitingEmbeddings = awaitingEmbeddings
        self.budget = budget
        self.error = error
        self.generation = generation
        self.indexed = indexed
        self.model = model
        self.modelKey = modelKey
        self.queuedVectors = queuedVectors
        self.skipped = skipped
        self.state = state
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

public struct Batch: Codable, Sendable {
    public var formatVersion: Int64
    public var id: String
    public var intent: Intent
    public var latestObservations: [MemberObservation]
    public var steps: [Step]
    public init(formatVersion: Int64, id: String, intent: Intent, latestObservations: [MemberObservation] = [], steps: [Step] = []) {
        self.formatVersion = formatVersion
        self.id = id
        self.intent = intent
        self.latestObservations = latestObservations
        self.steps = steps
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

public enum CollectionAbility: String, Codable, CaseIterable, Sendable {
    case `createChild`
    case `removeChild`
    case `rename`
    case `delete`
    case `move`
    case `reorderChildren`
    case `reorderPhotos`
    case `dateOrder`
}

public enum CollectionAction: String, Codable, CaseIterable, Sendable {
    case `createFolder`
    case `renameFolder`
    case `deleteFolder`
    case `move`
    case `reorderChildren`
    case `reorderPhotos`
    case `setDateOrder`
}

public struct CollectionEdit: Codable, Sendable {
    public var action: CollectionAction
    public var collections: [AlbumKey]
    public var index: Int64
    public var key: AlbumKey?
    public var order: AlbumDateOrder?
    public var parent: AlbumKey?
    public var photos: [AssetKey]
    public var title: String?
    public init(action: CollectionAction, collections: [AlbumKey] = [], index: Int64, key: AlbumKey? = nil, order: AlbumDateOrder? = nil, parent: AlbumKey? = nil, photos: [AssetKey] = [], title: String? = nil) {
        self.action = action
        self.collections = collections
        self.index = index
        self.key = key
        self.order = order
        self.parent = parent
        self.photos = photos
        self.title = title
    }
}

public enum CollectionKind: String, Codable, CaseIterable, Sendable {
    case `album`
    case `folder`
    case `shared`
    case `smart`
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

public struct CurrentMediaExport: Codable, Sendable {
    public var asset: StoredAsset
    public var files: [CurrentMediaFile]
    public var freshAsset: StoredAsset
    public var inputAudioTracks: Int64
    public var inputDurationMs: Int64
    public var inputVideoTracks: Int64
    public var kind: PlaybackKind
    public var locationRemoved: Bool
    public init(asset: StoredAsset, files: [CurrentMediaFile] = [], freshAsset: StoredAsset, inputAudioTracks: Int64, inputDurationMs: Int64, inputVideoTracks: Int64, kind: PlaybackKind, locationRemoved: Bool) {
        self.asset = asset
        self.files = files
        self.freshAsset = freshAsset
        self.inputAudioTracks = inputAudioTracks
        self.inputDurationMs = inputDurationMs
        self.inputVideoTracks = inputVideoTracks
        self.kind = kind
        self.locationRemoved = locationRemoved
    }
}

public struct CurrentMediaFile: Codable, Sendable {
    public var audioTracks: Int64
    public var contentIdentifier: String?
    public var durationMs: Int64
    public var hasLocation: Bool
    public var hasStillImageTime: Bool
    public var image: CurrentImageFacts?
    public var metadataTracks: Int64
    public var onlyPairMetadata: Bool
    public var path: String
    public var role: ResourceRole
    public var videoTracks: Int64
    public init(audioTracks: Int64, contentIdentifier: String? = nil, durationMs: Int64, hasLocation: Bool, hasStillImageTime: Bool, image: CurrentImageFacts? = nil, metadataTracks: Int64, onlyPairMetadata: Bool, path: String, role: ResourceRole, videoTracks: Int64) {
        self.audioTracks = audioTracks
        self.contentIdentifier = contentIdentifier
        self.durationMs = durationMs
        self.hasLocation = hasLocation
        self.hasStillImageTime = hasStillImageTime
        self.image = image
        self.metadataTracks = metadataTracks
        self.onlyPairMetadata = onlyPairMetadata
        self.path = path
        self.role = role
        self.videoTracks = videoTracks
    }
}

public struct CurrentMovieOutput: Codable, Sendable {
    public var file: CurrentMediaFile
    public var inputAudioTracks: Int64
    public var inputDurationMs: Int64
    public var inputVideoTracks: Int64
    public init(file: CurrentMediaFile, inputAudioTracks: Int64, inputDurationMs: Int64, inputVideoTracks: Int64) {
        self.file = file
        self.inputAudioTracks = inputAudioTracks
        self.inputDurationMs = inputDurationMs
        self.inputVideoTracks = inputVideoTracks
    }
}

public struct Dependency: Codable, Sendable {
    public var after: String
    public var before: String
    public init(after: String, before: String) {
        self.after = after
        self.before = before
    }
}

public enum Direction: String, Codable, CaseIterable, Sendable {
    case `lock`
    case `restore`
    case `reposition`
}

public struct Edge: Codable, Sendable {
    public var id: String
    public var motionResource: String
    public var parentResource: String
    public var selectionId: String
    public init(id: String, motionResource: String, parentResource: String, selectionId: String) {
        self.id = id
        self.motionResource = motionResource
        self.parentResource = parentResource
        self.selectionId = selectionId
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

public struct EmbeddingInput: Codable, Sendable {
    public var jobId: String
    public var vector: [Double]
    public init(jobId: String, vector: [Double] = []) {
        self.jobId = jobId
        self.vector = vector
    }
}

public struct EmbeddingJob: Codable, Sendable {
    public var asset: StoredAsset
    public var generation: Int64
    public var id: String
    public var model: AnalysisModel
    public var modelKey: String
    public init(asset: StoredAsset, generation: Int64, id: String, model: AnalysisModel, modelKey: String) {
        self.asset = asset
        self.generation = generation
        self.id = id
        self.model = model
        self.modelKey = modelKey
    }
}

public struct Fact: Codable, Sendable {
    public var checksum: String
    public var forward: Forward
    public var key: AssetKey
    public var media: Media
    public var offline: Bool
    public var ownerId: String
    public var placement: Placement
    public var revision: String
    public var trashed: Bool
    public var unstacked: Bool
    public init(checksum: String, forward: Forward, key: AssetKey, media: Media, offline: Bool, ownerId: String, placement: Placement, revision: String, trashed: Bool, unstacked: Bool) {
        self.checksum = checksum
        self.forward = forward
        self.key = key
        self.media = media
        self.offline = offline
        self.ownerId = ownerId
        self.placement = placement
        self.revision = revision
        self.trashed = trashed
        self.unstacked = unstacked
    }
    private enum CodingKeys: String, CodingKey { case checksum, forward, key, media, offline, ownerId, placement, revision, trashed, unstacked }
    public init(from decoder: any Decoder) throws {
        try requireSchemaKeys(decoder, allowed: ["checksum", "forward", "key", "media", "offline", "ownerId", "placement", "revision", "trashed", "unstacked"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        checksum = try values.decode(String.self, forKey: .checksum)
        forward = try values.decode(Forward.self, forKey: .forward)
        key = try values.decode(AssetKey.self, forKey: .key)
        media = try values.decode(Media.self, forKey: .media)
        offline = try values.decode(Bool.self, forKey: .offline)
        ownerId = try values.decode(String.self, forKey: .ownerId)
        placement = try values.decode(Placement.self, forKey: .placement)
        revision = try values.decode(String.self, forKey: .revision)
        trashed = try values.decode(Bool.self, forKey: .trashed)
        unstacked = try values.decode(Bool.self, forKey: .unstacked)
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

public enum Forward: Codable, Sendable {
    case `unlinked`
    case `linked`(AssetKey)
    private enum CodingKeys: String, CodingKey { case type, data }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(String.self, forKey: .type) {
        case "unlinked":
            try requireSchemaKeys(decoder, allowed: ["type"])
            self = .unlinked
        case "linked":
            try requireSchemaKeys(decoder, allowed: ["type", "data"])
            self = .linked(try values.decode(AssetKey.self, forKey: .data))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: values,
                debugDescription: "Unknown enum tag")
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .unlinked:
            try values.encode("unlinked", forKey: .type)
        case let .linked(data):
            try values.encode("linked", forKey: .type)
            try values.encode(data, forKey: .data)
        }
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

public struct ImmichLiveResourcePlan: Codable, Sendable {
    public var additionalParents: LiveParentObservation
    public var planID: String
    public var readTargets: [LiveResourceReadFact]
    public init(additionalParents: LiveParentObservation, planID: String, readTargets: [LiveResourceReadFact] = []) {
        self.additionalParents = additionalParents
        self.planID = planID
        self.readTargets = readTargets
    }
}

public struct ImmichLiveResourcesView: Codable, Sendable {
    public var error: String?
    public var pending: Bool
    public var plan: ImmichLiveResourcePlan?
    public var requestID: String
    public init(error: String? = nil, pending: Bool, plan: ImmichLiveResourcePlan? = nil, requestID: String) {
        self.error = error
        self.pending = pending
        self.plan = plan
        self.requestID = requestID
    }
}

public struct ImmichLockedEntry: Codable, Sendable {
    public var asset: StoredAsset
    public var canPlayVideo: Bool
    public var id: String
    public var liveDiscovery: ImmichLockedLiveDiscovery
    public var visibilityAction: ImmichVisibilityActionHint
    public init(asset: StoredAsset, canPlayVideo: Bool = false, id: String, liveDiscovery: ImmichLockedLiveDiscovery, visibilityAction: ImmichVisibilityActionHint) {
        self.asset = asset
        self.canPlayVideo = canPlayVideo
        self.id = id
        self.liveDiscovery = liveDiscovery
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

public struct ImmichLockedLiveAcquisitionState: Codable, Sendable {
    public var acknowledgedLeaseID: Int64
    public var initialLease: ImmichLockedVideoAcquisitionLease
    public var lease: ImmichLockedVideoAcquisitionLease
    public var pairLeaseID: String
    public var pending: ImmichLockedLivePending
    public init(acknowledgedLeaseID: Int64, initialLease: ImmichLockedVideoAcquisitionLease, lease: ImmichLockedVideoAcquisitionLease, pairLeaseID: String, pending: ImmichLockedLivePending) {
        self.acknowledgedLeaseID = acknowledgedLeaseID
        self.initialLease = initialLease
        self.lease = lease
        self.pairLeaseID = pairLeaseID
        self.pending = pending
    }
}

public enum ImmichLockedLiveDiscovery: String, Codable, CaseIterable, Sendable {
    case `unknown`
    case `observedLinked`
    case `observedUnlinked`
    case `unsupported`
}

public struct ImmichLockedLiveMember: Codable, Sendable {
    public var commitmentMode: ImmichLockedVideoCommitmentMode
    public var expectedBytes: Int64?
    public var expectedRevision: String
    public var expectedSha1: String
    public var initialClaimBytes: Int64
    public var key: AssetKey
    public var maxReceivedBytes: Int64
    public var role: ImmichLockedLiveRole
    public init(commitmentMode: ImmichLockedVideoCommitmentMode, expectedBytes: Int64? = nil, expectedRevision: String, expectedSha1: String, initialClaimBytes: Int64, key: AssetKey, maxReceivedBytes: Int64, role: ImmichLockedLiveRole) {
        self.commitmentMode = commitmentMode
        self.expectedBytes = expectedBytes
        self.expectedRevision = expectedRevision
        self.expectedSha1 = expectedSha1
        self.initialClaimBytes = initialClaimBytes
        self.key = key
        self.maxReceivedBytes = maxReceivedBytes
        self.role = role
    }
}

public struct ImmichLockedLiveOriginal: Codable, Sendable {
    public var acquisitionLeaseID: Int64
    public var pairLeaseID: String
    public var requestID: String
    public var role: ImmichLockedLiveRole
    public var sha1: String
    public var signature: FileSignature
    public init(acquisitionLeaseID: Int64, pairLeaseID: String, requestID: String, role: ImmichLockedLiveRole, sha1: String, signature: FileSignature) {
        self.acquisitionLeaseID = acquisitionLeaseID
        self.pairLeaseID = pairLeaseID
        self.requestID = requestID
        self.role = role
        self.sha1 = sha1
        self.signature = signature
    }
}

public struct ImmichLockedLivePending: Codable, Sendable {
    public var generation: Int64
    public var grantID: String
    public var motionKey: AssetKey
    public var parentKey: AssetKey
    public var phase: ImmichLockedLivePhase
    public var planID: String
    public var requestID: String
    public var sceneID: String
    public init(generation: Int64, grantID: String, motionKey: AssetKey, parentKey: AssetKey, phase: ImmichLockedLivePhase, planID: String, requestID: String, sceneID: String) {
        self.generation = generation
        self.grantID = grantID
        self.motionKey = motionKey
        self.parentKey = parentKey
        self.phase = phase
        self.planID = planID
        self.requestID = requestID
        self.sceneID = sceneID
    }
}

public enum ImmichLockedLivePhase: String, Codable, CaseIterable, Sendable {
    case `checking`
    case `acquiring`
    case `preparing`
    case `publishing`
}

public struct ImmichLockedLivePrepared: Codable, Sendable {
    public var acquisitionLeaseID: Int64
    public var pairLeaseID: String
    public var preparedID: String
    public var requestID: String
    public init(acquisitionLeaseID: Int64, pairLeaseID: String, preparedID: String, requestID: String) {
        self.acquisitionLeaseID = acquisitionLeaseID
        self.pairLeaseID = pairLeaseID
        self.preparedID = preparedID
        self.requestID = requestID
    }
}

public struct ImmichLockedLivePublication: Codable, Sendable {
    public var expectedAcquisitionLeaseID: Int64
    public var pairLeaseID: String
    public var pending: ImmichLockedLivePending
    public var preparedID: String
    public var publicationID: String
    public init(expectedAcquisitionLeaseID: Int64, pairLeaseID: String, pending: ImmichLockedLivePending, preparedID: String, publicationID: String) {
        self.expectedAcquisitionLeaseID = expectedAcquisitionLeaseID
        self.pairLeaseID = pairLeaseID
        self.pending = pending
        self.preparedID = preparedID
        self.publicationID = publicationID
    }
}

public struct ImmichLockedLiveRead: Codable, Sendable {
    public var request: HttpRequest
    public var role: ImmichLockedLiveRole
    public var ticket: ImmichLockedLiveTicket
    public init(request: HttpRequest, role: ImmichLockedLiveRole, ticket: ImmichLockedLiveTicket) {
        self.request = request
        self.role = role
        self.ticket = ticket
    }
}

public struct ImmichLockedLiveReleased: Codable, Sendable {
    public var pairLeaseID: String?
    public var pending: ImmichLockedLivePending
    public init(pairLeaseID: String? = nil, pending: ImmichLockedLivePending) {
        self.pairLeaseID = pairLeaseID
        self.pending = pending
    }
}

public struct ImmichLockedLiveRenewed: Codable, Sendable {
    public var leaseID: Int64
    public var pairLeaseID: String
    public var previousLeaseID: Int64
    public var requestID: String
    public init(leaseID: Int64, pairLeaseID: String, previousLeaseID: Int64, requestID: String) {
        self.leaseID = leaseID
        self.pairLeaseID = pairLeaseID
        self.previousLeaseID = previousLeaseID
        self.requestID = requestID
    }
}

public struct ImmichLockedLiveRepresentation: Codable, Sendable {
    public var maximumBytes: Int64
    public var name: String
    public init(maximumBytes: Int64, name: String) {
        self.maximumBytes = maximumBytes
        self.name = name
    }
}

public enum ImmichLockedLiveRole: String, Codable, CaseIterable, Sendable {
    case `parent`
    case `motion`
}

public struct ImmichLockedLiveStorageFacts: Codable, Sendable {
    public var representations: [ImmichLockedLiveRepresentation]
    public var storage: ImmichLockedVideoStorageFacts
    public init(representations: [ImmichLockedLiveRepresentation] = [], storage: ImmichLockedVideoStorageFacts) {
        self.representations = representations
        self.storage = storage
    }
}

public struct ImmichLockedLiveTicket: Codable, Sendable {
    public var acquisitionLease: ImmichLockedVideoAcquisitionLease
    public var displayLeaseID: Int64
    public var initialAcquisitionLease: ImmichLockedVideoAcquisitionLease
    public var members: [ImmichLockedLiveMember]
    public var minimumRemainingBytes: Int64
    public var pairDiskCeilingBytes: Int64
    public var pending: ImmichLockedLivePending
    public var representationReservationBytes: Int64
    public var representations: [ImmichLockedLiveRepresentation]
    public var storage: ImmichLockedVideoStorageFacts
    public var totalMaxReceivedBytes: Int64
    public init(acquisitionLease: ImmichLockedVideoAcquisitionLease, displayLeaseID: Int64, initialAcquisitionLease: ImmichLockedVideoAcquisitionLease, members: [ImmichLockedLiveMember] = [], minimumRemainingBytes: Int64, pairDiskCeilingBytes: Int64, pending: ImmichLockedLivePending, representationReservationBytes: Int64, representations: [ImmichLockedLiveRepresentation] = [], storage: ImmichLockedVideoStorageFacts, totalMaxReceivedBytes: Int64) {
        self.acquisitionLease = acquisitionLease
        self.displayLeaseID = displayLeaseID
        self.initialAcquisitionLease = initialAcquisitionLease
        self.members = members
        self.minimumRemainingBytes = minimumRemainingBytes
        self.pairDiskCeilingBytes = pairDiskCeilingBytes
        self.pending = pending
        self.representationReservationBytes = representationReservationBytes
        self.representations = representations
        self.storage = storage
        self.totalMaxReceivedBytes = totalMaxReceivedBytes
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

public struct ImmichLockedVideoAcquisitionLease: Codable, Sendable {
    public var deadlineUnixMilliseconds: Int64
    public var extensionMilliseconds: Int64
    public var leaseID: Int64
    public var remainingMilliseconds: Int64
    public init(deadlineUnixMilliseconds: Int64, extensionMilliseconds: Int64, leaseID: Int64, remainingMilliseconds: Int64) {
        self.deadlineUnixMilliseconds = deadlineUnixMilliseconds
        self.extensionMilliseconds = extensionMilliseconds
        self.leaseID = leaseID
        self.remainingMilliseconds = remainingMilliseconds
    }
}

public struct ImmichLockedVideoAcquisitionRenewed: Codable, Sendable {
    public var leaseID: Int64
    public var previousLeaseID: Int64
    public var requestID: String
    public var stagedID: String
    public init(leaseID: Int64, previousLeaseID: Int64, requestID: String, stagedID: String) {
        self.leaseID = leaseID
        self.previousLeaseID = previousLeaseID
        self.requestID = requestID
        self.stagedID = stagedID
    }
}

public struct ImmichLockedVideoAcquisitionState: Codable, Sendable {
    public var acknowledgedLeaseID: Int64
    public var initialLease: ImmichLockedVideoAcquisitionLease
    public var lease: ImmichLockedVideoAcquisitionLease
    public var pending: ImmichLockedVideoPending
    public var stagedID: String
    public init(acknowledgedLeaseID: Int64, initialLease: ImmichLockedVideoAcquisitionLease, lease: ImmichLockedVideoAcquisitionLease, pending: ImmichLockedVideoPending, stagedID: String) {
        self.acknowledgedLeaseID = acknowledgedLeaseID
        self.initialLease = initialLease
        self.lease = lease
        self.pending = pending
        self.stagedID = stagedID
    }
}

public enum ImmichLockedVideoCapacityClass: String, Codable, CaseIterable, Sendable {
    case `importantUsage`
    case `available`
}

public enum ImmichLockedVideoCommitmentMode: String, Codable, CaseIterable, Sendable {
    case `fullUpfront`
    case `incremental`
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
    public var acquisitionLeaseID: Int64
    public var requestID: String
    public var stagedID: String
    public init(acquisitionLeaseID: Int64, requestID: String, stagedID: String) {
        self.acquisitionLeaseID = acquisitionLeaseID
        self.requestID = requestID
        self.stagedID = stagedID
    }
}

public struct ImmichLockedVideoResult: Codable, Sendable {
    public var acquisitionLeaseID: Int64
    public var requestID: String
    public var sha1: String
    public var signature: FileSignature
    public var stagedID: String
    public init(acquisitionLeaseID: Int64, requestID: String, sha1: String, signature: FileSignature, stagedID: String) {
        self.acquisitionLeaseID = acquisitionLeaseID
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
    public var acquisitionLease: ImmichLockedVideoAcquisitionLease
    public var commitmentMode: ImmichLockedVideoCommitmentMode
    public var deadlineUnixMilliseconds: Int64
    public var displayLeaseID: Int64
    public var expectedBytes: Int64?
    public var expectedRevision: String
    public var expectedSha1: String
    public var initialAcquisitionLease: ImmichLockedVideoAcquisitionLease
    public var maxReceivedBytes: Int64
    public var minimumRemainingBytes: Int64
    public var pending: ImmichLockedVideoPending
    public var request: HttpRequest
    public var storage: ImmichLockedVideoStorageFacts
    public init(acquisitionLease: ImmichLockedVideoAcquisitionLease, commitmentMode: ImmichLockedVideoCommitmentMode, deadlineUnixMilliseconds: Int64, displayLeaseID: Int64, expectedBytes: Int64? = nil, expectedRevision: String, expectedSha1: String, initialAcquisitionLease: ImmichLockedVideoAcquisitionLease, maxReceivedBytes: Int64, minimumRemainingBytes: Int64, pending: ImmichLockedVideoPending, request: HttpRequest, storage: ImmichLockedVideoStorageFacts) {
        self.acquisitionLease = acquisitionLease
        self.commitmentMode = commitmentMode
        self.deadlineUnixMilliseconds = deadlineUnixMilliseconds
        self.displayLeaseID = displayLeaseID
        self.expectedBytes = expectedBytes
        self.expectedRevision = expectedRevision
        self.expectedSha1 = expectedSha1
        self.initialAcquisitionLease = initialAcquisitionLease
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
    public var live: ImmichLockedLivePublication?
    public var liveAcquisition: ImmichLockedLiveAcquisitionState?
    public var livePending: ImmichLockedLivePending?
    public var remoteLockConfirmed: Bool?
    public var sceneID: String?
    public var state: ImmichLockedState
    public var video: ImmichLockedVideoAccess?
    public var videoAcquisition: ImmichLockedVideoAcquisitionState?
    public var videoPending: ImmichLockedVideoPending?
    public init(entries: [ImmichLockedEntry]? = [], error: String? = nil, generation: Int64, grantID: String? = nil, image: ImmichLockedImageAccess? = nil, leaseID: Int64, live: ImmichLockedLivePublication? = nil, liveAcquisition: ImmichLockedLiveAcquisitionState? = nil, livePending: ImmichLockedLivePending? = nil, remoteLockConfirmed: Bool? = nil, sceneID: String? = nil, state: ImmichLockedState, video: ImmichLockedVideoAccess? = nil, videoAcquisition: ImmichLockedVideoAcquisitionState? = nil, videoPending: ImmichLockedVideoPending? = nil) {
        self.entries = entries
        self.error = error
        self.generation = generation
        self.grantID = grantID
        self.image = image
        self.leaseID = leaseID
        self.live = live
        self.liveAcquisition = liveAcquisition
        self.livePending = livePending
        self.remoteLockConfirmed = remoteLockConfirmed
        self.sceneID = sceneID
        self.state = state
        self.video = video
        self.videoAcquisition = videoAcquisition
        self.videoPending = videoPending
    }
}

public struct ImmichStackMembership: Codable, Sendable {
    public var assetCount: Int64
    public var id: String
    public var primaryAssetId: String
    public init(assetCount: Int64, id: String, primaryAssetId: String) {
        self.assetCount = assetCount
        self.id = id
        self.primaryAssetId = primaryAssetId
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

public struct ImportItem: Codable, Sendable {
    public var id: String
    public var metadata: ImportMetadata
    public var resources: [StagedResource]
    public init(id: String, metadata: ImportMetadata, resources: [StagedResource] = []) {
        self.id = id
        self.metadata = metadata
        self.resources = resources
    }
}

public struct ImportJournal: Codable, Sendable {
    public var created: Bool?
    public var createdAt: Date
    public var destination: Provider
    public var destinationKeys: [AssetKey]
    public var destinationScope: String
    public var id: String
    public var item: ImportItem
    public var phase: ImportPhase
    public var purpose: ImportPurpose
    public var sourceKeys: [AssetKey]
    public var stagingOperation: String
    public init(created: Bool? = nil, createdAt: Date, destination: Provider, destinationKeys: [AssetKey] = [], destinationScope: String, id: String, item: ImportItem, phase: ImportPhase, purpose: ImportPurpose, sourceKeys: [AssetKey] = [], stagingOperation: String) {
        self.created = created
        self.createdAt = createdAt
        self.destination = destination
        self.destinationKeys = destinationKeys
        self.destinationScope = destinationScope
        self.id = id
        self.item = item
        self.phase = phase
        self.purpose = purpose
        self.sourceKeys = sourceKeys
        self.stagingOperation = stagingOperation
    }
}

public struct ImportMetadata: Codable, Sendable {
    public var capturedAt: String?
    public var favorite: Bool
    public var latitude: Double?
    public var longitude: Double?
    public init(capturedAt: String? = nil, favorite: Bool, latitude: Double? = nil, longitude: Double? = nil) {
        self.capturedAt = capturedAt
        self.favorite = favorite
        self.latitude = latitude
        self.longitude = longitude
    }
}

public struct ImportNotice: Codable, Sendable {
    public var canInspect: Bool
    public var id: String
    public var phase: ImportPhase
    public init(canInspect: Bool, id: String, phase: ImportPhase) {
        self.canInspect = canInspect
        self.id = id
        self.phase = phase
    }
}

public enum ImportPhase: String, Codable, CaseIterable, Sendable {
    case `prepared`
    case `submitting`
    case `verified`
    case `alreadyPresent`
    case `uncertain`
    case `cancelled`
}

public enum ImportPurpose: String, Codable, CaseIterable, Sendable {
    case `external`
    case `duplicateOriginal`
    case `duplicateCurrent`
}

public struct InferenceSelection: Codable, Sendable {
    public var analysis: AnalysisStatus?
    public var inference: InferenceStatus?
    public var model: AnalysisModel
    public init(analysis: AnalysisStatus? = nil, inference: InferenceStatus? = nil, model: AnalysisModel) {
        self.analysis = analysis
        self.inference = inference
        self.model = model
    }
}

public struct InferenceSpec: Codable, Sendable {
    public var canaryEmbedding: [Double]
    public var canaryMinCosine: Double
    public var imageEdge: Int64
    public var imageTokens: Int64
    public var maxPatches: Int64
    public var model: AnalysisModel
    public var modelDirectory: String
    public var patchSize: Int64
    public var poolingKernel: Int64
    public var textTokens: Int64
    public init(canaryEmbedding: [Double] = [], canaryMinCosine: Double, imageEdge: Int64, imageTokens: Int64, maxPatches: Int64, model: AnalysisModel, modelDirectory: String, patchSize: Int64, poolingKernel: Int64, textTokens: Int64) {
        self.canaryEmbedding = canaryEmbedding
        self.canaryMinCosine = canaryMinCosine
        self.imageEdge = imageEdge
        self.imageTokens = imageTokens
        self.maxPatches = maxPatches
        self.model = model
        self.modelDirectory = modelDirectory
        self.patchSize = patchSize
        self.poolingKernel = poolingKernel
        self.textTokens = textTokens
    }
}

public struct InferenceStatus: Codable, Sendable {
    public var budgetBytes: Int64
    public var error: String?
    public var failedJob: String?
    public var modelKey: String
    public var state: String
    public init(budgetBytes: Int64, error: String? = nil, failedJob: String? = nil, modelKey: String, state: String) {
        self.budgetBytes = budgetBytes
        self.error = error
        self.failedJob = failedJob
        self.modelKey = modelKey
        self.state = state
    }
}

public struct Intent: Codable, Sendable {
    public var aliases: [Alias]
    public var dependencies: [Dependency]
    public var digest: String
    public var direction: Direction
    public var edges: [Edge]
    public var encodingVersion: Int64
    public var observedAdditionalParents: [AssetKey]
    public var orderedStepIds: [String]
    public var ownerId: String
    public var resources: [Resource]
    public var scope: String
    public var selections: [Selection]
    public var sharedReferenceLimitationsAcknowledged: Bool
    public var supersedes: [StepRef]
    public init(aliases: [Alias] = [], dependencies: [Dependency] = [], digest: String, direction: Direction, edges: [Edge] = [], encodingVersion: Int64, observedAdditionalParents: [AssetKey] = [], orderedStepIds: [String] = [], ownerId: String, resources: [Resource] = [], scope: String, selections: [Selection] = [], sharedReferenceLimitationsAcknowledged: Bool, supersedes: [StepRef] = []) {
        self.aliases = aliases
        self.dependencies = dependencies
        self.digest = digest
        self.direction = direction
        self.edges = edges
        self.encodingVersion = encodingVersion
        self.observedAdditionalParents = observedAdditionalParents
        self.orderedStepIds = orderedStepIds
        self.ownerId = ownerId
        self.resources = resources
        self.scope = scope
        self.selections = selections
        self.sharedReferenceLimitationsAcknowledged = sharedReferenceLimitationsAcknowledged
        self.supersedes = supersedes
    }
}

public struct LegacyReconciliation: Codable, Sendable {
    public var confirmedGraph: [ResourceObservation]
    public var digest: String
    public var formatVersion: Int64
    public var id: String
    public var legacy: [LegacyRef]
    public var parent: AssetKey
    public init(confirmedGraph: [ResourceObservation] = [], digest: String, formatVersion: Int64, id: String, legacy: [LegacyRef] = [], parent: AssetKey) {
        self.confirmedGraph = confirmedGraph
        self.digest = digest
        self.formatVersion = formatVersion
        self.id = id
        self.legacy = legacy
        self.parent = parent
    }
}

public struct LegacyRef: Codable, Sendable {
    public var acknowledgedAlbums: AlbumMembershipObservation
    public var acknowledgedObservation: ImmichVisibility?
    public var acknowledgedSelected: SelectedVisibilityObservation?
    public var operationId: String
    public var recordDigest: String
    public init(acknowledgedAlbums: AlbumMembershipObservation, acknowledgedObservation: ImmichVisibility? = nil, acknowledgedSelected: SelectedVisibilityObservation? = nil, operationId: String, recordDigest: String) {
        self.acknowledgedAlbums = acknowledgedAlbums
        self.acknowledgedObservation = acknowledgedObservation
        self.acknowledgedSelected = acknowledgedSelected
        self.operationId = operationId
        self.recordDigest = recordDigest
    }
    private enum CodingKeys: String, CodingKey { case acknowledgedAlbums, acknowledgedObservation, acknowledgedSelected, operationId, recordDigest }
    public init(from decoder: any Decoder) throws {
        try requireSchemaKeys(decoder, allowed: ["acknowledgedAlbums", "acknowledgedObservation", "acknowledgedSelected", "operationId", "recordDigest"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        acknowledgedAlbums = try values.decode(AlbumMembershipObservation.self, forKey: .acknowledgedAlbums)
        acknowledgedObservation = try values.decodeIfPresent(ImmichVisibility.self, forKey: .acknowledgedObservation)
        acknowledgedSelected = try values.decodeIfPresent(SelectedVisibilityObservation.self, forKey: .acknowledgedSelected)
        operationId = try values.decode(String.self, forKey: .operationId)
        recordDigest = try values.decode(String.self, forKey: .recordDigest)
    }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(acknowledgedAlbums, forKey: .acknowledgedAlbums)
        try values.encode(acknowledgedObservation, forKey: .acknowledgedObservation)
        try values.encode(acknowledgedSelected, forKey: .acknowledgedSelected)
        try values.encode(operationId, forKey: .operationId)
        try values.encode(recordDigest, forKey: .recordDigest)
    }
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

public struct LiveAdditionalParent: Codable, Sendable {
    public var hasStack: Bool?
    public var isOffline: Bool?
    public var isTrashed: Bool?
    public var key: AssetKey
    public var revision: String
    public var visibility: LiveObservedVisibility?
    public init(hasStack: Bool? = nil, isOffline: Bool? = false, isTrashed: Bool? = nil, key: AssetKey, revision: String, visibility: LiveObservedVisibility? = nil) {
        self.hasStack = hasStack
        self.isOffline = isOffline
        self.isTrashed = isTrashed
        self.key = key
        self.revision = revision
        self.visibility = visibility
    }
}

public enum LiveDiscoveryTermination: String, Codable, CaseIterable, Sendable {
    case `exhaustedPages`
    case `pageBudget`
    case `unavailable`
}

public struct LiveKeepPrompt: Codable, Sendable {
    public var aliases: [LivePlacementPromptAlias]
    public var batchID: String
    public var closureID: String
    public var explanation: String
    public var generation: Int64
    public var grantID: String
    public var resources: [LivePlacementPromptResource]
    public var sceneID: String
    public var targets: [LiveKeepTarget]
    public init(aliases: [LivePlacementPromptAlias] = [], batchID: String, closureID: String, explanation: String, generation: Int64, grantID: String, resources: [LivePlacementPromptResource] = [], sceneID: String, targets: [LiveKeepTarget] = []) {
        self.aliases = aliases
        self.batchID = batchID
        self.closureID = closureID
        self.explanation = explanation
        self.generation = generation
        self.grantID = grantID
        self.resources = resources
        self.sceneID = sceneID
        self.targets = targets
    }
}

public struct LiveKeepTarget: Codable, Sendable {
    public var key: AssetKey
    public var name: String
    public var stepID: String
    public init(key: AssetKey, name: String, stepID: String) {
        self.key = key
        self.name = name
        self.stepID = stepID
    }
}

public enum LiveObservedVisibility: String, Codable, CaseIterable, Sendable {
    case `timeline`
    case `archive`
    case `hidden`
    case `locked`
}

public struct LiveParentObservation: Codable, Sendable {
    public var graphComplete: Bool
    public var malformedCandidates: Int64
    public var observations: Int64
    public var pagesObserved: Int64
    public var parents: [LiveAdditionalParent]
    public var protectedCandidates: Int64
    public var termination: LiveDiscoveryTermination
    public init(graphComplete: Bool, malformedCandidates: Int64, observations: Int64, pagesObserved: Int64, parents: [LiveAdditionalParent] = [], protectedCandidates: Int64, termination: LiveDiscoveryTermination) {
        self.graphComplete = graphComplete
        self.malformedCandidates = malformedCandidates
        self.observations = observations
        self.pagesObserved = pagesObserved
        self.parents = parents
        self.protectedCandidates = protectedCandidates
        self.termination = termination
    }
}

public struct LivePlacementCleanup: Codable, Sendable {
    public var canRetry: Bool
    public var captureID: String
    public var status: String
    public init(canRetry: Bool, captureID: String, status: String) {
        self.canRetry = canRetry
        self.captureID = captureID
        self.status = status
    }
}

public enum LivePlacementDestination: String, Codable, CaseIterable, Sendable {
    case `locked`
    case `timeline`
    case `archive`
}

public struct LivePlacementHistory: Codable, Sendable {
    public var batches: [LivePlacementHistoryBatch]
    public init(batches: [LivePlacementHistoryBatch] = []) {
        self.batches = batches
    }
}

public struct LivePlacementHistoryBatch: Codable, Sendable {
    public var batchID: String
    public var canInspect: Bool
    public var canNewIntent: Bool
    public var parentKeys: [AssetKey]
    public var resources: [LivePlacementHistoryResource]
    public var retired: Bool
    public var supersedesStepIDs: [String]
    public init(batchID: String, canInspect: Bool, canNewIntent: Bool, parentKeys: [AssetKey] = [], resources: [LivePlacementHistoryResource] = [], retired: Bool, supersedesStepIDs: [String] = []) {
        self.batchID = batchID
        self.canInspect = canInspect
        self.canNewIntent = canNewIntent
        self.parentKeys = parentKeys
        self.resources = resources
        self.retired = retired
        self.supersedesStepIDs = supersedesStepIDs
    }
}

public struct LivePlacementHistoryResource: Codable, Sendable {
    public var allowedDestinations: [Placement]
    public var canKeep: Bool
    public var currentObservation: String
    public var historicalOutcome: String
    public var key: AssetKey
    public var name: String
    public var proposedDestination: Placement
    public var stepID: String?
    public init(allowedDestinations: [Placement] = [], canKeep: Bool, currentObservation: String, historicalOutcome: String, key: AssetKey, name: String, proposedDestination: Placement, stepID: String? = nil) {
        self.allowedDestinations = allowedDestinations
        self.canKeep = canKeep
        self.currentObservation = currentObservation
        self.historicalOutcome = historicalOutcome
        self.key = key
        self.name = name
        self.proposedDestination = proposedDestination
        self.stepID = stepID
    }
}

public struct LivePlacementPrompt: Codable, Sendable {
    public var aliases: [LivePlacementPromptAlias]
    public var batchID: String
    public var continuingAccessDisclosure: String
    public var generation: Int64
    public var grantID: String
    public var intentDigest: String
    public var resources: [LivePlacementPromptResource]
    public var sceneID: String
    public var sharedReferenceLimitationsAcknowledged: Bool
    public init(aliases: [LivePlacementPromptAlias] = [], batchID: String, continuingAccessDisclosure: String, generation: Int64, grantID: String, intentDigest: String, resources: [LivePlacementPromptResource] = [], sceneID: String, sharedReferenceLimitationsAcknowledged: Bool) {
        self.aliases = aliases
        self.batchID = batchID
        self.continuingAccessDisclosure = continuingAccessDisclosure
        self.generation = generation
        self.grantID = grantID
        self.intentDigest = intentDigest
        self.resources = resources
        self.sceneID = sceneID
        self.sharedReferenceLimitationsAcknowledged = sharedReferenceLimitationsAcknowledged
    }
}

public struct LivePlacementPromptAlias: Codable, Sendable {
    public var motionKey: AssetKey
    public var parentKey: AssetKey
    public init(motionKey: AssetKey, parentKey: AssetKey) {
        self.motionKey = motionKey
        self.parentKey = parentKey
    }
}

public struct LivePlacementPromptResource: Codable, Sendable {
    public var albumCount: Int64
    public var from: Placement
    public var key: AssetKey
    public var name: String
    public var removesAllAlbumMembership: Bool
    public var role: Role
    public var to: Placement
    public var unchanged: Bool
    public init(albumCount: Int64, from: Placement, key: AssetKey, name: String, removesAllAlbumMembership: Bool, role: Role, to: Placement, unchanged: Bool) {
        self.albumCount = albumCount
        self.from = from
        self.key = key
        self.name = name
        self.removesAllAlbumMembership = removesAllAlbumMembership
        self.role = role
        self.to = to
        self.unchanged = unchanged
    }
}

public struct LiveResourceDestination: Codable, Sendable {
    public var destination: Placement
    public var key: AssetKey
    public init(destination: Placement, key: AssetKey) {
        self.destination = destination
        self.key = key
    }
}

public struct LiveResourceReadFact: Codable, Sendable {
    public var checksum: String
    public var key: AssetKey
    public var revision: String
    public var role: LiveResourceRole
    public var visibility: LiveObservedVisibility
    public init(checksum: String, key: AssetKey, revision: String, role: LiveResourceRole, visibility: LiveObservedVisibility) {
        self.checksum = checksum
        self.key = key
        self.revision = revision
        self.role = role
        self.visibility = visibility
    }
}

public enum LiveResourceRole: String, Codable, CaseIterable, Sendable {
    case `parent`
    case `motion`
}

public enum Media: String, Codable, CaseIterable, Sendable {
    case `image`
    case `video`
}

public struct MemberObservation: Codable, Sendable {
    public var key: AssetKey
    public var state: ObservedState
    public init(key: AssetKey, state: ObservedState) {
        self.key = key
        self.state = state
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

public struct MetadataEditCapturedAtData: Codable, Sendable {
    public var local: String
    public var occurrence: Occurrence?
    public var zone: String
    public init(local: String, occurrence: Occurrence? = nil, zone: String) {
        self.local = local
        self.occurrence = occurrence
        self.zone = zone
    }
    private enum CodingKeys: String, CodingKey { case local, occurrence, zone }
    public init(from decoder: any Decoder) throws {
        try requireSchemaKeys(decoder, allowed: ["local", "occurrence", "zone"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        local = try values.decode(String.self, forKey: .local)
        occurrence = try values.decodeIfPresent(Occurrence.self, forKey: .occurrence)
        zone = try values.decode(String.self, forKey: .zone)
    }
}

public struct MetadataEditLocationData: Codable, Sendable {
    public var latitude: String
    public var longitude: String
    public init(latitude: String, longitude: String) {
        self.latitude = latitude
        self.longitude = longitude
    }
    private enum CodingKeys: String, CodingKey { case latitude, longitude }
    public init(from decoder: any Decoder) throws {
        try requireSchemaKeys(decoder, allowed: ["latitude", "longitude"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        latitude = try values.decode(String.self, forKey: .latitude)
        longitude = try values.decode(String.self, forKey: .longitude)
    }
}

public struct MetadataEditDescriptionData: Codable, Sendable {
    public var text: String
    public init(text: String) {
        self.text = text
    }
    private enum CodingKeys: String, CodingKey { case text }
    public init(from decoder: any Decoder) throws {
        try requireSchemaKeys(decoder, allowed: ["text"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        text = try values.decode(String.self, forKey: .text)
    }
}

public enum MetadataEdit: Codable, Sendable {
    case `capturedAt`(MetadataEditCapturedAtData)
    case `location`(MetadataEditLocationData)
    case `removeLocation`
    case `description`(MetadataEditDescriptionData)
    private enum CodingKeys: String, CodingKey { case type, data }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(String.self, forKey: .type) {
        case "capturedAt":
            try requireSchemaKeys(decoder, allowed: ["type", "data"])
            self = .capturedAt(try values.decode(MetadataEditCapturedAtData.self, forKey: .data))
        case "location":
            try requireSchemaKeys(decoder, allowed: ["type", "data"])
            self = .location(try values.decode(MetadataEditLocationData.self, forKey: .data))
        case "removeLocation":
            try requireSchemaKeys(decoder, allowed: ["type"])
            self = .removeLocation
        case "description":
            try requireSchemaKeys(decoder, allowed: ["type", "data"])
            self = .description(try values.decode(MetadataEditDescriptionData.self, forKey: .data))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: values,
                debugDescription: "Unknown enum tag")
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .capturedAt(data):
            try values.encode("capturedAt", forKey: .type)
            try values.encode(data, forKey: .data)
        case let .location(data):
            try values.encode("location", forKey: .type)
            try values.encode(data, forKey: .data)
        case .removeLocation:
            try values.encode("removeLocation", forKey: .type)
        case let .description(data):
            try values.encode("description", forKey: .type)
            try values.encode(data, forKey: .data)
        }
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

public struct MetadataObservation: Codable, Sendable {
    public var key: AssetKey
    public var unavailable: Bool
    public var witness: MetadataWitness?
    public init(key: AssetKey, unavailable: Bool, witness: MetadataWitness? = nil) {
        self.key = key
        self.unavailable = unavailable
        self.witness = witness
    }
}

public enum MetadataOutcome: String, Codable, CaseIterable, Sendable {
    case `submittedUnknown`
    case `notApplied`
    case `verifiedApplied`
}

public struct MetadataRecord: Codable, Sendable {
    public var after: [MetadataWitness]
    public var before: [MetadataWitness]
    public var current: [MetadataObservation]
    public var edit: MetadataEdit
    public var id: String
    public var keys: [AssetKey]
    public var memberEdits: [MetadataEdit]
    public var outcome: MetadataOutcome
    public var restores: String?
    public init(after: [MetadataWitness] = [], before: [MetadataWitness] = [], current: [MetadataObservation] = [], edit: MetadataEdit, id: String, keys: [AssetKey] = [], memberEdits: [MetadataEdit] = [], outcome: MetadataOutcome, restores: String? = nil) {
        self.after = after
        self.before = before
        self.current = current
        self.edit = edit
        self.id = id
        self.keys = keys
        self.memberEdits = memberEdits
        self.outcome = outcome
        self.restores = restores
    }
}

public struct MetadataRestoreAvailability: Codable, Sendable {
    public var id: String
    public var originalReason: String?
    public var undoReason: String?
    public init(id: String, originalReason: String? = nil, undoReason: String? = nil) {
        self.id = id
        self.originalReason = originalReason
        self.undoReason = undoReason
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

public struct MetadataValues: Codable, Sendable {
    public var capturedAt: Date?
    public var description: String
    public var latitude: Double?
    public var longitude: Double?
    public var timeZone: String?
    public init(capturedAt: Date? = nil, description: String, latitude: Double? = nil, longitude: Double? = nil, timeZone: String? = nil) {
        self.capturedAt = capturedAt
        self.description = description
        self.latitude = latitude
        self.longitude = longitude
        self.timeZone = timeZone
    }
}

public struct MetadataWitness: Codable, Sendable {
    public var asset: StoredAsset
    public var values: MetadataValues
    public init(asset: StoredAsset, values: MetadataValues) {
        self.asset = asset
        self.values = values
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

public struct NoSubmissionRecord: Codable, Sendable {
    public var attemptId: String
    public var batchId: String
    public var intentDigest: String
    public var key: AssetKey
    public var stepId: String
    public init(attemptId: String, batchId: String, intentDigest: String, key: AssetKey, stepId: String) {
        self.attemptId = attemptId
        self.batchId = batchId
        self.intentDigest = intentDigest
        self.key = key
        self.stepId = stepId
    }
    private enum CodingKeys: String, CodingKey { case attemptId, batchId, intentDigest, key, stepId }
    public init(from decoder: any Decoder) throws {
        try requireSchemaKeys(decoder, allowed: ["attemptId", "batchId", "intentDigest", "key", "stepId"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        attemptId = try values.decode(String.self, forKey: .attemptId)
        batchId = try values.decode(String.self, forKey: .batchId)
        intentDigest = try values.decode(String.self, forKey: .intentDigest)
        key = try values.decode(AssetKey.self, forKey: .key)
        stepId = try values.decode(String.self, forKey: .stepId)
    }
}

public enum ObservationFailure: String, Codable, CaseIterable, Sendable {
    case `denied`
    case `unavailable`
    case `identityMismatch`
    case `unsupported`
    case `malformed`
}

public enum ObservedState: Codable, Sendable {
    case `notObserved`
    case `own`(Fact)
    case `unavailable`(ObservationFailure)
    private enum CodingKeys: String, CodingKey { case type, data }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(String.self, forKey: .type) {
        case "notObserved":
            try requireSchemaKeys(decoder, allowed: ["type"])
            self = .notObserved
        case "own":
            try requireSchemaKeys(decoder, allowed: ["type", "data"])
            self = .own(try values.decode(Fact.self, forKey: .data))
        case "unavailable":
            try requireSchemaKeys(decoder, allowed: ["type", "data"])
            self = .unavailable(try values.decode(ObservationFailure.self, forKey: .data))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: values,
                debugDescription: "Unknown enum tag")
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .notObserved:
            try values.encode("notObserved", forKey: .type)
        case let .own(data):
            try values.encode("own", forKey: .type)
            try values.encode(data, forKey: .data)
        case let .unavailable(data):
            try values.encode("unavailable", forKey: .type)
            try values.encode(data, forKey: .data)
        }
    }
}

public enum Occurrence: String, Codable, CaseIterable, Sendable {
    case `earlier`
    case `later`
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

public struct OrdinaryLivePairAction: Codable, Sendable {
    public var canPlay: Bool
    public var canRefresh: Bool
    public var cleanupRequestID: String?
    public var parentKey: AssetKey
    public init(canPlay: Bool, canRefresh: Bool, cleanupRequestID: String? = nil, parentKey: AssetKey) {
        self.canPlay = canPlay
        self.canRefresh = canRefresh
        self.cleanupRequestID = cleanupRequestID
        self.parentKey = parentKey
    }
}

public struct OrdinaryLiveReadProgress: Codable, Sendable {
    public var canCancel: Bool
    public var phase: String
    public var requestID: String
    public init(canCancel: Bool, phase: String, requestID: String) {
        self.canCancel = canCancel
        self.phase = phase
        self.requestID = requestID
    }
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

public struct OutcomeUnknownData: Codable, Sendable {
    public var accepted: Accepted204?
    public var attempt_id: String
    public init(accepted: Accepted204? = nil, attempt_id: String) {
        self.accepted = accepted
        self.attempt_id = attempt_id
    }
    private enum CodingKeys: String, CodingKey { case accepted, attempt_id }
    public init(from decoder: any Decoder) throws {
        try requireSchemaKeys(decoder, allowed: ["accepted", "attempt_id"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        accepted = try values.decodeIfPresent(Accepted204.self, forKey: .accepted)
        attempt_id = try values.decode(String.self, forKey: .attempt_id)
    }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(accepted, forKey: .accepted)
        try values.encode(attempt_id, forKey: .attempt_id)
    }
}

public struct OutcomeAppliedData: Codable, Sendable {
    public var accepted: Accepted204
    public var attempt_id: String
    public var verified_post: PostFacts
    public init(accepted: Accepted204, attempt_id: String, verified_post: PostFacts) {
        self.accepted = accepted
        self.attempt_id = attempt_id
        self.verified_post = verified_post
    }
    private enum CodingKeys: String, CodingKey { case accepted, attempt_id, verified_post }
    public init(from decoder: any Decoder) throws {
        try requireSchemaKeys(decoder, allowed: ["accepted", "attempt_id", "verified_post"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        accepted = try values.decode(Accepted204.self, forKey: .accepted)
        attempt_id = try values.decode(String.self, forKey: .attempt_id)
        verified_post = try values.decode(PostFacts.self, forKey: .verified_post)
    }
}

public struct OutcomeNotAppliedData: Codable, Sendable {
    public var attempt_id: String
    public var no_submission: NoSubmissionRecord
    public init(attempt_id: String, no_submission: NoSubmissionRecord) {
        self.attempt_id = attempt_id
        self.no_submission = no_submission
    }
    private enum CodingKeys: String, CodingKey { case attempt_id, no_submission }
    public init(from decoder: any Decoder) throws {
        try requireSchemaKeys(decoder, allowed: ["attempt_id", "no_submission"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        attempt_id = try values.decode(String.self, forKey: .attempt_id)
        no_submission = try values.decode(NoSubmissionRecord.self, forKey: .no_submission)
    }
}

public enum Outcome: Codable, Sendable {
    case `notStarted`
    case `unknown`(OutcomeUnknownData)
    case `applied`(OutcomeAppliedData)
    case `notApplied`(OutcomeNotAppliedData)
    private enum CodingKeys: String, CodingKey { case type, data }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(String.self, forKey: .type) {
        case "notStarted":
            try requireSchemaKeys(decoder, allowed: ["type"])
            self = .notStarted
        case "unknown":
            try requireSchemaKeys(decoder, allowed: ["type", "data"])
            self = .unknown(try values.decode(OutcomeUnknownData.self, forKey: .data))
        case "applied":
            try requireSchemaKeys(decoder, allowed: ["type", "data"])
            self = .applied(try values.decode(OutcomeAppliedData.self, forKey: .data))
        case "notApplied":
            try requireSchemaKeys(decoder, allowed: ["type", "data"])
            self = .notApplied(try values.decode(OutcomeNotAppliedData.self, forKey: .data))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: values,
                debugDescription: "Unknown enum tag")
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .notStarted:
            try values.encode("notStarted", forKey: .type)
        case let .unknown(data):
            try values.encode("unknown", forKey: .type)
            try values.encode(data, forKey: .data)
        case let .applied(data):
            try values.encode("applied", forKey: .type)
            try values.encode(data, forKey: .data)
        case let .notApplied(data):
            try values.encode("notApplied", forKey: .type)
            try values.encode(data, forKey: .data)
        }
    }
}

public struct PairImageAccess: Codable, Sendable {
    public var kind: OrdinarySelectedImageKind
    public var ownerID: String
    public var presentation: PairPresentation
    public var requestID: String
    public var sceneID: String
    public var stagedID: String
    public init(kind: OrdinarySelectedImageKind, ownerID: String, presentation: PairPresentation, requestID: String, sceneID: String, stagedID: String) {
        self.kind = kind
        self.ownerID = ownerID
        self.presentation = presentation
        self.requestID = requestID
        self.sceneID = sceneID
        self.stagedID = stagedID
    }
}

public struct PairImagePending: Codable, Sendable {
    public var kind: OrdinarySelectedImageKind
    public var ownerID: String
    public var presentation: PairPresentation
    public var requestID: String
    public var sceneID: String
    public init(kind: OrdinarySelectedImageKind, ownerID: String, presentation: PairPresentation, requestID: String, sceneID: String) {
        self.kind = kind
        self.ownerID = ownerID
        self.presentation = presentation
        self.requestID = requestID
        self.sceneID = sceneID
    }
}

public struct PairImageResult: Codable, Sendable {
    public var requestID: String
    public var stagedID: String
    public init(requestID: String, stagedID: String) {
        self.requestID = requestID
        self.stagedID = stagedID
    }
}

public struct PairImageTicket: Codable, Sendable {
    public var expectedRevision: String
    public var kind: OrdinarySelectedImageKind
    public var ownerID: String
    public var presentation: PairPresentation
    public var request: HttpRequest
    public var requestID: String
    public var sceneID: String
    public init(expectedRevision: String, kind: OrdinarySelectedImageKind, ownerID: String, presentation: PairPresentation, request: HttpRequest, requestID: String, sceneID: String) {
        self.expectedRevision = expectedRevision
        self.kind = kind
        self.ownerID = ownerID
        self.presentation = presentation
        self.request = request
        self.requestID = requestID
        self.sceneID = sceneID
    }
}

public struct PairPresentation: Codable, Sendable {
    public var generation: Int64
    public var motionKey: AssetKey
    public var motionVisibility: Placement
    public var parentKey: AssetKey
    public var parentVisibility: Placement
    public var proofID: String
    public init(generation: Int64, motionKey: AssetKey, motionVisibility: Placement, parentKey: AssetKey, parentVisibility: Placement, proofID: String) {
        self.generation = generation
        self.motionKey = motionKey
        self.motionVisibility = motionVisibility
        self.parentKey = parentKey
        self.parentVisibility = parentVisibility
        self.proofID = proofID
    }
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

public enum Placement: String, Codable, CaseIterable, Sendable {
    case `timeline`
    case `archive`
    case `hidden`
    case `locked`
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

public struct PostFacts: Codable, Sendable {
    public var attemptId: String
    public var batchId: String
    public var digest: String
    public var encodingVersion: Int64
    public var intentDigest: String
    public var resources: [ResourceObservation]
    public var stepId: String
    public init(attemptId: String, batchId: String, digest: String, encodingVersion: Int64, intentDigest: String, resources: [ResourceObservation] = [], stepId: String) {
        self.attemptId = attemptId
        self.batchId = batchId
        self.digest = digest
        self.encodingVersion = encodingVersion
        self.intentDigest = intentDigest
        self.resources = resources
        self.stepId = stepId
    }
    private enum CodingKeys: String, CodingKey { case attemptId, batchId, digest, encodingVersion, intentDigest, resources, stepId }
    public init(from decoder: any Decoder) throws {
        try requireSchemaKeys(decoder, allowed: ["attemptId", "batchId", "digest", "encodingVersion", "intentDigest", "resources", "stepId"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        attemptId = try values.decode(String.self, forKey: .attemptId)
        batchId = try values.decode(String.self, forKey: .batchId)
        digest = try values.decode(String.self, forKey: .digest)
        encodingVersion = try values.decode(Int64.self, forKey: .encodingVersion)
        intentDigest = try values.decode(String.self, forKey: .intentDigest)
        resources = try values.decode([ResourceObservation].self, forKey: .resources)
        stepId = try values.decode(String.self, forKey: .stepId)
    }
}

public enum Presence: String, Codable, CaseIterable, Sendable {
    case `amazon`
    case `multiple`
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

public enum PrivateMediaCleanupState: String, Codable, CaseIterable, Sendable {
    case `joining`
    case `needsAttention`
    case `quarantined`
}

public struct PrivateMediaCleanupView: Codable, Sendable {
    public var expectedAttempt: Int64
    public var recoveryID: String?
    public var state: PrivateMediaCleanupState
    public init(expectedAttempt: Int64, recoveryID: String? = nil, state: PrivateMediaCleanupState) {
        self.expectedAttempt = expectedAttempt
        self.recoveryID = recoveryID
        self.state = state
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
    case `amazon`
}

public struct PublishedLibrary: Codable, Sendable {
    public var albums: [AlbumSnapshot]
    public var amazonConnection: AmazonConnection?
    public var amazonUploads: [AmazonUploadRecord]
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
    public init(albums: [AlbumSnapshot] = [], amazonConnection: AmazonConnection? = nil, amazonUploads: [AmazonUploadRecord] = [], appleScope: String, appleVisibilityOperations: [AppleVisibilitySummary] = [], connection: ConnectionSettings? = nil, editClipboard: EditClipboard? = nil, pendingAppleTrash: [AppleTrashOperation] = [], pendingEditPastes: [PendingEditPaste] = [], pendingTrash: [TrashOperation] = [], pendingUploads: [PendingUpload] = [], receipts: [TransferReceipt] = [], schemaVersion: Int64, snapshots: [LibrarySnapshot] = [], trash: TrashSnapshot? = nil, uploadIntents: [UploadIntent] = []) {
        self.albums = albums
        self.amazonConnection = amazonConnection
        self.amazonUploads = amazonUploads
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

public struct Resource: Codable, Sendable {
    public var destination: Placement
    public var id: String
    public var initial: Fact
    public var initialAlbums: [String]
    public var stepId: String?
    public init(destination: Placement, id: String, initial: Fact, initialAlbums: [String] = [], stepId: String? = nil) {
        self.destination = destination
        self.id = id
        self.initial = initial
        self.initialAlbums = initialAlbums
        self.stepId = stepId
    }
    private enum CodingKeys: String, CodingKey { case destination, id, initial, initialAlbums, stepId }
    public init(from decoder: any Decoder) throws {
        try requireSchemaKeys(decoder, allowed: ["destination", "id", "initial", "initialAlbums", "stepId"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        destination = try values.decode(Placement.self, forKey: .destination)
        id = try values.decode(String.self, forKey: .id)
        initial = try values.decode(Fact.self, forKey: .initial)
        initialAlbums = try values.decode([String].self, forKey: .initialAlbums)
        stepId = try values.decodeIfPresent(String.self, forKey: .stepId)
    }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(destination, forKey: .destination)
        try values.encode(id, forKey: .id)
        try values.encode(initial, forKey: .initial)
        try values.encode(initialAlbums, forKey: .initialAlbums)
        try values.encode(stepId, forKey: .stepId)
    }
}

public struct ResourceObservation: Codable, Sendable {
    public var albums: [String]
    public var fact: Fact
    public init(albums: [String] = [], fact: Fact) {
        self.albums = albums
        self.fact = fact
    }
    private enum CodingKeys: String, CodingKey { case albums, fact }
    public init(from decoder: any Decoder) throws {
        try requireSchemaKeys(decoder, allowed: ["albums", "fact"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        albums = try values.decode([String].self, forKey: .albums)
        fact = try values.decode(Fact.self, forKey: .fact)
    }
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

public enum Role: String, Codable, CaseIterable, Sendable {
    case `parent`
    case `motion`
}

public struct SavedLibrary: Codable, Sendable {
    public var albums: [AlbumSnapshot]
    public var amazonConnection: AmazonConnection?
    public var amazonUploads: [AmazonUploadRecord]
    public var appleScope: String
    public var appleVisibilityOperations: [AppleVisibilityOperation]
    public var connection: ConnectionSettings?
    public var editClipboard: EditClipboard?
    public var externalImports: [ImportJournal]
    public var immichLiveLegacyReconciliations: [LegacyReconciliation]
    public var immichLiveOperations: [Batch]
    public var immichLiveUnstartedClosures: [UnstartedClosure]
    public var immichVisibilityOperations: [ImmichVisibilityOperation]
    public var metadataOperations: [MetadataRecord]
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
    public init(albums: [AlbumSnapshot] = [], amazonConnection: AmazonConnection? = nil, amazonUploads: [AmazonUploadRecord] = [], appleScope: String, appleVisibilityOperations: [AppleVisibilityOperation] = [], connection: ConnectionSettings? = nil, editClipboard: EditClipboard? = nil, externalImports: [ImportJournal] = [], immichLiveLegacyReconciliations: [LegacyReconciliation] = [], immichLiveOperations: [Batch] = [], immichLiveUnstartedClosures: [UnstartedClosure] = [], immichVisibilityOperations: [ImmichVisibilityOperation] = [], metadataOperations: [MetadataRecord] = [], pendingAppleTrash: [AppleTrashOperation] = [], pendingEditPastes: [PendingEditPaste] = [], pendingTrash: [TrashOperation] = [], pendingUploads: [PendingUpload] = [], protectedEntries: [PersistentProtectedEntry] = [], receipts: [TransferReceipt] = [], schemaVersion: Int64, snapshots: [LibrarySnapshot] = [], trash: TrashSnapshot? = nil, uploadIntents: [UploadIntent] = []) {
        self.albums = albums
        self.amazonConnection = amazonConnection
        self.amazonUploads = amazonUploads
        self.appleScope = appleScope
        self.appleVisibilityOperations = appleVisibilityOperations
        self.connection = connection
        self.editClipboard = editClipboard
        self.externalImports = externalImports
        self.immichLiveLegacyReconciliations = immichLiveLegacyReconciliations
        self.immichLiveOperations = immichLiveOperations
        self.immichLiveUnstartedClosures = immichLiveUnstartedClosures
        self.immichVisibilityOperations = immichVisibilityOperations
        self.metadataOperations = metadataOperations
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

public struct Selection: Codable, Sendable {
    public var id: String
    public var parent: AssetKey
    public init(id: String, parent: AssetKey) {
        self.id = id
        self.parent = parent
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

public struct SimilarityHit: Codable, Sendable {
    public var asset: AssetKey
    public var distance: Double
    public var revision: String
    public init(asset: AssetKey, distance: Double, revision: String) {
        self.asset = asset
        self.distance = distance
        self.revision = revision
    }
}

public struct StagedResource: Codable, Sendable {
    public var bytes: Int64
    public var contentIdentifier: String?
    public var mediaType: String
    public var name: String
    public var role: ResourceRole
    public var sha256: String
    public var token: String
    public init(bytes: Int64, contentIdentifier: String? = nil, mediaType: String, name: String, role: ResourceRole, sha256: String, token: String) {
        self.bytes = bytes
        self.contentIdentifier = contentIdentifier
        self.mediaType = mediaType
        self.name = name
        self.role = role
        self.sha256 = sha256
        self.token = token
    }
}

public struct Step: Codable, Sendable {
    public var id: String
    public var outcome: Outcome
    public var resourceId: String
    public init(id: String, outcome: Outcome, resourceId: String) {
        self.id = id
        self.outcome = outcome
        self.resourceId = resourceId
    }
}

public struct StepRef: Codable, Sendable {
    public var batchId: String
    public var intentDigest: String
    public var retiredOutcomesDigest: String
    public var stepId: String
    public init(batchId: String, intentDigest: String, retiredOutcomesDigest: String, stepId: String) {
        self.batchId = batchId
        self.intentDigest = intentDigest
        self.retiredOutcomesDigest = retiredOutcomesDigest
        self.stepId = stepId
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
    public var immichStackMembership: ImmichStackMembership?
    public var immichVisibility: ImmichVisibility?
    public init(appleVisibility: AppleVisibility = .unknown, key: AssetKey, name: String, capturedAt: Date? = nil, modifiedAt: Date? = nil, revision: String, resources: [PhotoResource] = [], isFavorite: Bool = false, latitude: Double? = nil, longitude: Double? = nil, inventoryComplete: Bool = true, isOffline: Bool = false, deletionBlockers: [String] = [], immichStack: ImmichStackState = .unknown, immichStackMembership: ImmichStackMembership? = nil, immichVisibility: ImmichVisibility? = nil) {
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
        self.immichStackMembership = immichStackMembership
        self.immichVisibility = immichVisibility
    }
}

public struct StoredCollection: Codable, Sendable {
    public var abilities: [CollectionAbility]
    public var children: [AlbumKey]
    public var dateOrder: AlbumDateOrder?
    public var explanation: String?
    public var externalUrl: String?
    public var key: AlbumKey
    public var kind: CollectionKind
    public var parent: AlbumKey?
    public var title: String
    public init(abilities: [CollectionAbility] = [], children: [AlbumKey] = [], dateOrder: AlbumDateOrder? = nil, explanation: String? = nil, externalUrl: String? = nil, key: AlbumKey, kind: CollectionKind, parent: AlbumKey? = nil, title: String) {
        self.abilities = abilities
        self.children = children
        self.dateOrder = dateOrder
        self.explanation = explanation
        self.externalUrl = externalUrl
        self.key = key
        self.kind = kind
        self.parent = parent
        self.title = title
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

public struct UnstartedClosure: Codable, Sendable {
    public var currentGraph: [ResourceObservation]
    public var digest: String
    public var formatVersion: Int64
    public var id: String
    public var references: [StepRef]
    public init(currentGraph: [ResourceObservation] = [], digest: String, formatVersion: Int64, id: String, references: [StepRef] = []) {
        self.currentGraph = currentGraph
        self.digest = digest
        self.formatVersion = formatVersion
        self.id = id
        self.references = references
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
    public var externalImports: [ImportJournal]
    public var immichArchiveActions: [ImmichArchiveActionHint]
    public var immichArchiveView: ImmichArchiveView
    public var immichLiveResources: ImmichLiveResourcesView?
    public var immichLockedView: ImmichLockedView
    public var immichVisibilityActions: [ImmichVisibilityActionHint]
    public var immichVisibilityView: ImmichVisibilityView
    public var importNotices: [ImportNotice]
    public var liveKeepPrompt: LiveKeepPrompt?
    public var livePlacementCandidates: [AssetKey]
    public var livePlacementCleanup: LivePlacementCleanup?
    public var livePlacementHistory: LivePlacementHistory
    public var livePlacementPrompt: LivePlacementPrompt?
    public var media: [String: PlaybackKind]
    public var metadataOperations: [MetadataRecord]
    public var metadataRestoreAvailability: [MetadataRestoreAvailability]
    public var metadataTargets: [String: [MetadataTarget]]
    public var moveBlockers: [String: [String]]
    public var ordinaryContentKeys: [AssetKey]
    public var ordinaryLiveActions: [OrdinaryLivePairAction]
    public var ordinaryLiveImagePending: [PairImagePending]
    public var ordinaryLiveImages: [PairImageAccess]
    public var ordinaryLivePairs: [PairPresentation]
    public var ordinaryLiveProgress: OrdinaryLiveReadProgress?
    public var ordinarySelectedGeneration: Int64
    public var ordinarySelectedImages: [OrdinarySelectedImageAccess]
    public var ordinarySelectedPending: [OrdinarySelectedImageRequest]
    public var ordinarySelectedPresentation: [OrdinarySelectedPresentation]
    public var pendingAppleCount: Int64
    public var photos: [UnifiedPhoto]
    public var previewChoices: [String: [PreviewChoice]]
    public var previewSources: [String: AssetKey]
    public var privateContentRevision: String
    public var privateMediaCleanup: [PrivateMediaCleanupView]
    public var protectedView: ProtectedView
    public var remoteVersion: Version?
    public var serverVersion: String?
    public var state: PublishedLibrary
    public var status: String
    public init(albums: [AlbumView] = [], appleVisibilityHideKeys: [AssetKey] = [], browser: BrowserView, busy: Bool, canTransfer: Bool, editingTargets: [String: [EditingTarget]] = [:], error: String? = nil, externalImports: [ImportJournal] = [], immichArchiveActions: [ImmichArchiveActionHint] = [], immichArchiveView: ImmichArchiveView, immichLiveResources: ImmichLiveResourcesView? = nil, immichLockedView: ImmichLockedView, immichVisibilityActions: [ImmichVisibilityActionHint] = [], immichVisibilityView: ImmichVisibilityView, importNotices: [ImportNotice] = [], liveKeepPrompt: LiveKeepPrompt? = nil, livePlacementCandidates: [AssetKey] = [], livePlacementCleanup: LivePlacementCleanup? = nil, livePlacementHistory: LivePlacementHistory, livePlacementPrompt: LivePlacementPrompt? = nil, media: [String: PlaybackKind] = [:], metadataOperations: [MetadataRecord] = [], metadataRestoreAvailability: [MetadataRestoreAvailability] = [], metadataTargets: [String: [MetadataTarget]] = [:], moveBlockers: [String: [String]] = [:], ordinaryContentKeys: [AssetKey] = [], ordinaryLiveActions: [OrdinaryLivePairAction] = [], ordinaryLiveImagePending: [PairImagePending] = [], ordinaryLiveImages: [PairImageAccess] = [], ordinaryLivePairs: [PairPresentation] = [], ordinaryLiveProgress: OrdinaryLiveReadProgress? = nil, ordinarySelectedGeneration: Int64, ordinarySelectedImages: [OrdinarySelectedImageAccess] = [], ordinarySelectedPending: [OrdinarySelectedImageRequest] = [], ordinarySelectedPresentation: [OrdinarySelectedPresentation] = [], pendingAppleCount: Int64, photos: [UnifiedPhoto] = [], previewChoices: [String: [PreviewChoice]] = [:], previewSources: [String: AssetKey] = [:], privateContentRevision: String, privateMediaCleanup: [PrivateMediaCleanupView] = [], protectedView: ProtectedView, remoteVersion: Version? = nil, serverVersion: String? = nil, state: PublishedLibrary, status: String) {
        self.albums = albums
        self.appleVisibilityHideKeys = appleVisibilityHideKeys
        self.browser = browser
        self.busy = busy
        self.canTransfer = canTransfer
        self.editingTargets = editingTargets
        self.error = error
        self.externalImports = externalImports
        self.immichArchiveActions = immichArchiveActions
        self.immichArchiveView = immichArchiveView
        self.immichLiveResources = immichLiveResources
        self.immichLockedView = immichLockedView
        self.immichVisibilityActions = immichVisibilityActions
        self.immichVisibilityView = immichVisibilityView
        self.importNotices = importNotices
        self.liveKeepPrompt = liveKeepPrompt
        self.livePlacementCandidates = livePlacementCandidates
        self.livePlacementCleanup = livePlacementCleanup
        self.livePlacementHistory = livePlacementHistory
        self.livePlacementPrompt = livePlacementPrompt
        self.media = media
        self.metadataOperations = metadataOperations
        self.metadataRestoreAvailability = metadataRestoreAvailability
        self.metadataTargets = metadataTargets
        self.moveBlockers = moveBlockers
        self.ordinaryContentKeys = ordinaryContentKeys
        self.ordinaryLiveActions = ordinaryLiveActions
        self.ordinaryLiveImagePending = ordinaryLiveImagePending
        self.ordinaryLiveImages = ordinaryLiveImages
        self.ordinaryLivePairs = ordinaryLivePairs
        self.ordinaryLiveProgress = ordinaryLiveProgress
        self.ordinarySelectedGeneration = ordinarySelectedGeneration
        self.ordinarySelectedImages = ordinarySelectedImages
        self.ordinarySelectedPending = ordinarySelectedPending
        self.ordinarySelectedPresentation = ordinarySelectedPresentation
        self.pendingAppleCount = pendingAppleCount
        self.photos = photos
        self.previewChoices = previewChoices
        self.previewSources = previewSources
        self.privateContentRevision = privateContentRevision
        self.privateMediaCleanup = privateMediaCleanup
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
