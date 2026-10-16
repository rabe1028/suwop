import CLiteRTLM
import Darwin
import Foundation
import os

// The native handle is serialized on queue; deinit runs only after all queued owners finish. C inference
// is synchronous and cannot be interrupted inside a kernel. Callers checkpoint
// before/after each image; close drains the one in-flight call before freeing it.
// Remove this exception when LiteRT offers a nonblocking, cancellable C API.
// swiftlint:disable:next no_force_sendable
public final class EmbeddingRuntime: @unchecked Sendable {
    private let queue = DispatchQueue(label: "suwop.embedding-native", qos: .utility)
    private var handle: OpaquePointer?
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
        // All queued closures retain self, so no native operation remains at deinit.
        if let handle {
            litert_lm_embedding_engine_delete(handle)
        }
        if lockDescriptor >= 0 {
            Darwin.close(lockDescriptor)
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

    public func load(path: String, spec: InferenceSpec) async throws {
        try await perform {
            guard self.handle == nil else { return }
            let lockPath = URL(fileURLWithPath: path).deletingLastPathComponent()
                .appendingPathComponent("inference.lock").path
            let descriptor = Darwin.open(lockPath, O_CREAT | O_RDWR, 0o600)
            guard descriptor >= 0 else { throw SuwopError("推論の排他制御を開始できません。") }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                Darwin.close(descriptor)
                throw SuwopError("別のウインドウまたはプロセスが解析中です。")
            }
            self.lockDescriptor = descriptor
            defer {
                if self.handle == nil {
                    Darwin.close(descriptor)
                    self.lockDescriptor = -1
                }
            }
            guard let settings = litert_lm_embedding_engine_settings_create(path, "cpu", "cpu", nil) else {
                throw SuwopError("推論設定を作成できません。")
            }
            defer { litert_lm_embedding_engine_settings_delete(settings) }
            litert_lm_embedding_engine_settings_set_num_threads(settings, Int32(spec.threads))
            litert_lm_embedding_engine_settings_set_max_input_length(settings, Int32(spec.textTokens))
            litert_lm_embedding_engine_settings_set_vision_tokens_per_image(settings, Int32(spec.imageTokens))
            guard let handle = litert_lm_embedding_engine_create(settings) else {
                throw SuwopError("モデルを読み込めません。メモリ予算とモデルを確認してください。")
            }
            self.handle = handle
        }
    }

    public func embedding(_ data: Data, image: Bool) async throws -> [Float] {
        try Task.checkCancellation()
        return try await perform {
            guard let handle = self.handle, data.count <= 8 << 20 else { throw SuwopError("推論入力が利用できません。") }
            let input = data.withUnsafeBytes {
                litert_lm_input_data_create(
                    image ? kLiteRtLmInputDataTypeImage : kLiteRtLmInputDataTypeText,
                    $0.baseAddress,
                    data.count
                )
            }
            guard let input else { throw SuwopError("推論入力を作成できません。") }
            defer { litert_lm_input_data_delete(input) }
            guard let options = litert_lm_embedding_options_create() else { throw SuwopError("推論設定を作成できません。") }
            defer { litert_lm_embedding_options_delete(options) }
            litert_lm_embedding_options_set_normalize(options, false)
            litert_lm_embedding_options_set_output_size(options, 768)
            var pointer: OpaquePointer? = input
            guard let response = litert_lm_embedding_engine_compute_embedding(handle, &pointer, 1, options) else {
                throw SuwopError("この入力の特徴を生成できません。")
            }
            defer { litert_lm_embedding_response_delete(response) }
            let count = litert_lm_embedding_response_get_size(response)
            guard count == 768, let values = litert_lm_embedding_response_get_values(response) else {
                throw SuwopError("モデルの出力形式が異なります。")
            }
            return Array(UnsafeBufferPointer(start: values, count: count))
        }
    }

    public func close() async {
        _ = try? await perform {
            if let handle = self.handle {
                litert_lm_embedding_engine_delete(handle)
            }
            self.handle = nil
            if self.lockDescriptor >= 0 {
                Darwin.close(self.lockDescriptor)
                self.lockDescriptor = -1
            }
        }
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
