import CoreML
import Foundation
import SuwopShell
import SwiftUI

// Simulator load/inference benchmark. Configure with SIMCTL_CHILD_BENCH_* variables.
@main
struct LoadBenchApp: App {
    var body: some Scene {
        WindowGroup { Text("LoadBench").task { await Bench.run() } }
    }
}

struct Fixture: Codable {
    let id: String, file: String, query: String
    let image: [Float], text: [Float]
}

enum Bench {
    static let env = ProcessInfo.processInfo.environment
    static let root = URL(fileURLWithPath: env["BENCH_DIR"] ?? "/tmp")
    nonisolated(unsafe) static var lines: [String] = []

    static func log(_ line: String) {
        print("BENCH " + line)
        lines.append(line)
    }

    static func footprint() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return Double(info.phys_footprint) / 1_048_576
    }

    static func ms(_ start: Date) -> Double { Date().timeIntervalSince(start) * 1000 }

    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        let dot = zip(a, b).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
        let na = sqrt(a.reduce(0.0) { $0 + Double($1) * Double($1) })
        let nb = sqrt(b.reduce(0.0) { $0 + Double($1) * Double($1) })
        return dot / (na * nb)
    }

    static func run() async {
        let mode = env["BENCH_MODE"] ?? "litert"
        do {
            let fixture = try JSONDecoder().decode(
                Fixture.self, from: Data(contentsOf: root.appendingPathComponent("fixture.json"))
            )
            log("mode=\(mode) footprint_start_mib=\(Int(footprint()))")
            if mode == "litert" {
                try await liteRT(fixture)
            } else {
                try coreML(fixture, precision: env["BENCH_PRECISION"] ?? "int8", units: mode)
            }
        } catch {
            log("error=\(error)")
        }
        let out = root.appendingPathComponent("result-\(env["BENCH_LABEL"] ?? mode).txt")
        try? (lines.joined(separator: "\n") + "\n").write(to: out, atomically: true, encoding: .utf8)
        exit(0)
    }

    static func liteRT(_ fixture: Fixture) async throws {
        let store = try LocalStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("catalog"))
        let spec = try await store.inferenceSpec(dimensions: 256)
        let runtime = EmbeddingRuntime()
        var start = Date()
        try await runtime.load(path: root.appendingPathComponent("litert/model.litertlm").path, spec: spec)
        log(String(format: "load_ms=%.0f footprint_after_load_mib=%.0f", ms(start), footprint()))
        let jpeg = try Data(contentsOf: URL(fileURLWithPath: fixture.file))
        start = Date()
        let prepared = try await EmbeddingImage.prepare(jpeg, edge: Int(spec.imageEdge))
        let image = try await runtime.embedding(prepared, image: true)
        log(String(format: "image_ms=%.0f", ms(start)))
        start = Date()
        let query = try await store.queryText(fixture.query)
        let text = try await runtime.embedding(Data(query.utf8), image: false)
        log(String(format: "text_ms=%.0f", ms(start)))
        log(String(
            format: "image_cos_vs_coreml_ane=%.4f text_cos=%.4f footprint_peak_mib=%.0f",
            cosine(image, fixture.image), cosine(text, fixture.text), footprint()
        ))
        await runtime.close()
    }

    static func load(_ name: String, _ units: MLComputeUnits) throws -> MLModel {
        let config = MLModelConfiguration()
        config.computeUnits = units
        return try MLModel(contentsOf: root.appendingPathComponent("compiled/\(name).mlmodelc"), configuration: config)
    }

    static func array(_ file: String, _ shape: [Int], _ type: MLMultiArrayDataType) throws -> MLMultiArray {
        let data = try Data(contentsOf: root.appendingPathComponent("benchin/\(file)"))
        let array = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: type)
        data.withUnsafeBytes { raw in
            if let base = raw.baseAddress { memcpy(array.dataPointer, base, data.count) }
        }
        return array
    }

    static func ids(_ file: String) throws -> [Int32] {
        let data = try Data(contentsOf: root.appendingPathComponent("benchin/\(file)"))
        return data.withUnsafeBytes { Array($0.bindMemory(to: Int32.self)) }
    }

    static func output(_ model: MLModel, _ inputs: [String: MLMultiArray], _ name: String) throws -> MLMultiArray {
        let provider = try MLDictionaryFeatureProvider(dictionary: inputs.mapValues { MLFeatureValue(multiArray: $0) })
        guard let value = try model.prediction(from: provider).featureValue(for: name)?.multiArrayValue else {
            throw NSError(domain: "bench", code: 1)
        }
        return value
    }

    static func embed(_ tokens: MLModel, _ encoder: MLModel, _ list: [Int32], soft: MLMultiArray?) throws -> [Float] {
        let length = 128, imageToken: Int32 = 258_880
        let input = try MLMultiArray(shape: [1, 128], dataType: .int32)
        let mask = try MLMultiArray(shape: [1, 128], dataType: .float32)
        for i in 0 ..< length {
            input[i] = NSNumber(value: i < list.count && list[i] != imageToken ? list[i] : 0)
            mask[i] = NSNumber(value: i < list.count ? 1 : 0)
        }
        let embeds = try output(tokens, ["input_ids": input], "inputs_embeds")
        if let soft {
            var next = 0
            for (i, id) in list.enumerated() where id == imageToken {
                for d in 0 ..< 512 { embeds[[0, i, d] as [NSNumber]] = soft[[0, next, d] as [NSNumber]] }
                next += 1
            }
        }
        let vector = try output(encoder, ["inputs_embeds": embeds, "mask": mask], "embedding")
        return (0 ..< 768).map { vector[$0].floatValue }
    }

    static func coreML(_ fixture: Fixture, precision: String, units name: String) throws {
        let units: MLComputeUnits = switch name {
        case "cpu": .cpuOnly
        case "gpu": .cpuAndGPU
        case "ane": .cpuAndNeuralEngine
        default: .all
        }
        var start = Date()
        let vision = try load("vision-encoder-\(precision)", units)
        let head = try load("vision-head-fp32", .cpuOnly)
        let tokens = try load("tokens-\(precision)", .cpuOnly)
        let encoder = try load("encoder-\(precision)", units)
        log(String(format: "precision=%@ load_ms=%.0f footprint_after_load_mib=%.0f", precision, ms(start), footprint()))
        let pixels = try array("pixels0.bin", [1, 630, 768], .float32)
        let positions = try array("positions0.bin", [1, 630, 2], .int32)
        start = Date()
        let hidden = try output(vision, ["pixel_values": pixels, "position_ids": positions], "hidden")
        let soft = try output(head, ["hidden": hidden, "position_ids": positions], "soft_tokens")
        let image = try embed(tokens, encoder, ids("image_ids0.bin"), soft: soft)
        log(String(format: "image_ms=%.0f", ms(start)))
        start = Date()
        let text = try embed(tokens, encoder, ids("text_ids0.bin"), soft: nil)
        log(String(format: "text_ms=%.0f", ms(start)))
        log(String(
            format: "image_cos_vs_coreml_ane=%.4f text_cos=%.4f finite=%@ footprint_peak_mib=%.0f",
            cosine(image, fixture.image), cosine(text, fixture.text),
            String(image.allSatisfy(\.isFinite) && text.allSatisfy(\.isFinite)), footprint()
        ))
    }
}
