import CoreML
import Darwin
import Foundation
import os

// Core ML execution of the four bundled EmbeddingGemma 2 models. Rust owns model identity,
// token sequences and projection; this adapter only runs fixed-shape predictions.
// Models are touched only on `queue`; deinit runs after every queued owner finishes.
// Core ML prediction is synchronous: callers checkpoint before and after each input.
// swiftlint:disable:next no_force_sendable
public final class EmbeddingRuntime: @unchecked Sendable {
    private struct Models {
        let visionEncoder: MLModel
        let visionHead: MLModel
        let tokens: MLModel
        let encoder: MLModel
    }

    private static let sequenceLength = 128
    private static let hiddenSize = 512
    private static let imageToken: Int32 = 258_880
    private let queue = DispatchQueue(label: "suwop.embedding-native", qos: .utility)
    private var models: Models?
    private var lockDescriptor: Int32 = -1
    private let pressure = OSAllocatedUnfairLock(initialState: false)
    private var monitor: DispatchSourceMemoryPressure?

    public init() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = monitor?.data ?? [.critical]
            let pressured = !flags.isDisjoint(with: [.warning, .critical])
            pressure.withLock { $0 = pressured }
        }
        monitor = source
        source.resume()
    }

    deinit {
        monitor?.cancel()
        if lockDescriptor >= 0 {
            Darwin.close(lockDescriptor)
        }
    }

    /// The bundled compiled models, or nil when this build does not include them.
    public static func bundledModels(_ spec: InferenceSpec, bundle: Bundle = .main) -> URL? {
        guard let directory = bundle.url(forResource: spec.modelDirectory, withExtension: nil) else { return nil }
        let complete = ["VisionEncoder", "VisionHead", "Tokens", "Encoder"].allSatisfy {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("\($0).mlmodelc").path)
        }
        return complete ? directory : nil
    }

    /// fp16 and int8 models produce corrupted vectors on the CPU, so inference requires a Neural Engine.
    public static var hasNeuralEngine: Bool {
        MLComputeDevice.allComputeDevices.contains { device in
            if case .neuralEngine = device {
                return true
            }
            return false
        }
    }

    public func memory() -> InferenceMemory {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return InferenceMemory(
            resident: status == KERN_SUCCESS ? UInt64(info.resident_size) : UInt64.max,
            available: Self.availableMemory(),
            pressure: pressure.withLock { $0 }
        )
    }

    private static func availableMemory() -> UInt64 {
        #if os(iOS)
            return UInt64(os_proc_available_memory())
        #else
            var info = vm_statistics64()
            var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
            let host = mach_host_self()
            defer { mach_port_deallocate(mach_task_self_, host) }
            let status = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    host_statistics64(host, HOST_VM_INFO64, $0, &count)
                }
            }
            guard status == KERN_SUCCESS else { return 0 }
            var pageSize: vm_size_t = 0
            guard host_page_size(host, &pageSize) == KERN_SUCCESS else { return 0 }
            return (UInt64(info.free_count) + UInt64(info.inactive_count)) * UInt64(pageSize)
        #endif
    }

    /// Loads the models once. `lockDirectory` holds the cross-process inference lease.
    public func load(models directory: URL, lockDirectory: URL) async throws {
        try await perform {
            guard self.models == nil else { return }
            guard Self.hasNeuralEngine else { throw SuwopError("この端末では写真の内容検索を利用できません。") }
            try FileManager.default.createDirectory(at: lockDirectory, withIntermediateDirectories: true)
            let descriptor = Darwin.open(
                lockDirectory.appendingPathComponent("inference.lock").path,
                O_CREAT | O_RDWR,
                0o600
            )
            guard descriptor >= 0 else { throw SuwopError("推論の排他制御を開始できません。") }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                Darwin.close(descriptor)
                throw SuwopError("別のウインドウまたはプロセスが解析中です。")
            }
            self.lockDescriptor = descriptor
            defer {
                if self.models == nil {
                    Darwin.close(descriptor)
                    self.lockDescriptor = -1
                }
            }
            func model(_ name: String, _ units: MLComputeUnits) throws -> MLModel {
                let configuration = MLModelConfiguration()
                configuration.computeUnits = units
                return try MLModel(
                    contentsOf: directory.appendingPathComponent("\(name).mlmodelc"),
                    configuration: configuration
                )
            }
            do {
                // The token table and the fp32 head stay on the CPU; fp16 graphs need the Neural Engine.
                self.models = try Models(
                    visionEncoder: model("VisionEncoder", .cpuAndNeuralEngine),
                    visionHead: model("VisionHead", .cpuOnly),
                    tokens: model("Tokens", .cpuOnly),
                    encoder: model("Encoder", .cpuAndNeuralEngine)
                )
            } catch {
                throw SuwopError("モデルを読み込めません。")
            }
        }
    }

    /// Mean-pooled 768-dimensional embedding of `tokens` (from Rust), before projection.
    public func embedding(tokens: [Int32]) async throws -> [Float] {
        try Task.checkCancellation()
        return try await perform {
            guard let models = self.models else { throw SuwopError("推論入力が利用できません。") }
            return try Self.encode(models, tokens: tokens, soft: nil)
        }
    }

    /// Image embedding from prepared patches and the Rust token sequence for its soft tokens.
    public func embedding(patches: EmbeddingPatches, tokens: [Int32]) async throws -> [Float] {
        try Task.checkCancellation()
        return try await perform {
            guard let models = self.models else { throw SuwopError("推論入力が利用できません。") }
            let count = patches.positions.count / 2
            let pixels = try Self.array(patches.pixels, shape: [1, count, patches.pixels.count / max(count, 1)])
            let positions = try Self.array(patches.positions, shape: [1, count, 2])
            let hidden = try Self.output(
                models.visionEncoder,
                ["pixel_values": pixels, "position_ids": positions],
                "hidden"
            )
            let soft = try Self.output(models.visionHead, ["hidden": hidden, "position_ids": positions], "soft_tokens")
            guard tokens.count(where: { $0 == Self.imageToken }) == patches.softTokens else {
                throw SuwopError("画像の入力形式が一致しません。")
            }
            return try Self.encode(models, tokens: tokens, soft: soft)
        }
    }

    public func close() async {
        _ = try? await perform {
            self.models = nil
            if self.lockDescriptor >= 0 {
                Darwin.close(self.lockDescriptor)
                self.lockDescriptor = -1
            }
        }
    }

    private static func encode(_ models: Models, tokens: [Int32], soft: MLMultiArray?) throws -> [Float] {
        guard (2 ... sequenceLength).contains(tokens.count) else { throw SuwopError("推論入力が長すぎます。") }
        let ids = try MLMultiArray(shape: [1, NSNumber(value: sequenceLength)], dataType: .int32)
        let mask = try MLMultiArray(shape: [1, NSNumber(value: sequenceLength)], dataType: .float32)
        let idPointer = ids.dataPointer.bindMemory(to: Int32.self, capacity: sequenceLength)
        let maskPointer = mask.dataPointer.bindMemory(to: Float.self, capacity: sequenceLength)
        for index in 0 ..< sequenceLength {
            let present = index < tokens.count
            // Image placeholders take the pad embedding before soft tokens replace them.
            idPointer[index] = present && tokens[index] != imageToken ? tokens[index] : 0
            maskPointer[index] = present ? 1 : 0
        }
        let embeds = try output(models.tokens, ["input_ids": ids], "inputs_embeds")
        if let soft {
            try replacePlaceholders(in: embeds, tokens: tokens, with: soft)
        }
        let vector = try output(models.encoder, ["inputs_embeds": embeds, "mask": mask], "embedding")
        guard vector.count == 768, vector.dataType == .float32 else { throw SuwopError("モデルの出力形式が異なります。") }
        let values = (0 ..< 768).map { vector[$0].floatValue }
        guard values.allSatisfy(\.isFinite) else { throw SuwopError("この入力の特徴を生成できません。") }
        return values
    }

    private static func replacePlaceholders(in embeds: MLMultiArray, tokens: [Int32], with soft: MLMultiArray) throws {
        guard embeds.dataType == .float32, soft.dataType == .float32 else {
            throw SuwopError("モデルの出力形式が異なります。")
        }
        let target = embeds.dataPointer.bindMemory(to: Float.self, capacity: embeds.count)
        let source = soft.dataPointer.bindMemory(to: Float.self, capacity: soft.count)
        let targetRow = embeds.strides[1].intValue, targetColumn = embeds.strides[2].intValue
        let sourceRow = soft.strides[1].intValue, sourceColumn = soft.strides[2].intValue
        var next = 0
        for (index, id) in tokens.enumerated() where id == imageToken {
            for column in 0 ..< hiddenSize {
                target[index * targetRow + column * targetColumn] = source[next * sourceRow + column * sourceColumn]
            }
            next += 1
        }
    }

    private static func array<T>(_ values: [T], shape: [Int]) throws -> MLMultiArray {
        let type: MLMultiArrayDataType = T.self == Float.self ? .float32 : .int32
        let array = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: type)
        guard array.count == values.count else { throw SuwopError("推論入力の形式が不正です。") }
        values.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                array.dataPointer.copyMemory(from: base, byteCount: raw.count)
            }
        }
        return array
    }

    private static func output(
        _ model: MLModel,
        _ inputs: [String: MLMultiArray],
        _ name: String
    ) throws -> MLMultiArray {
        let provider = try MLDictionaryFeatureProvider(dictionary: inputs.mapValues { MLFeatureValue(multiArray: $0) })
        guard let value = try model.prediction(from: provider).featureValue(for: name)?.multiArrayValue else {
            throw SuwopError("モデルの出力形式が異なります。")
        }
        return value
    }

    private func perform<Value: Sendable>(_ body: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try autoreleasepool(invoking: body) })
            }
        }
    }
}

public struct InferenceMemory: Sendable {
    public let resident: UInt64
    public let available: UInt64
    public let pressure: Bool
}
