import CoreML
import Foundation
import SuwopShell

// Usage: MacBench <bench-dir> litert
//        MacBench <bench-dir> coreml <int8|pal6|fp16|fp32> <ane|gpu|cpu|all>
// <bench-dir> holds reference.json, litert/model.litertlm, compiled/*.mlmodelc and
// benchin/*.bin (preprocessed by transformers). Prints one JSON object.

struct Reference: Codable {
    let id: String, file: String, query: String
    let image: [Float], text: [Float]
}

let args = CommandLine.arguments
let root = URL(fileURLWithPath: args[1])
let references = try JSONDecoder().decode(
    [Reference].self, from: Data(contentsOf: root.appendingPathComponent("benchin/reference.json"))
)
// Single-threaded benchmark state.
nonisolated(unsafe) var result: [String: Double] = [:]
nonisolated(unsafe) var peak = 0.0

func footprint() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    _ = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    let mib = Double(info.phys_footprint) / 1_048_576
    peak = max(peak, mib)
    return mib
}

func ms(_ start: Date) -> Double { Date().timeIntervalSince(start) * 1000 }

func cosine(_ a: [Float], _ b: [Float]) -> Double {
    let dot = zip(a, b).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
    let na = sqrt(a.reduce(0.0) { $0 + Double($1) * Double($1) })
    let nb = sqrt(b.reduce(0.0) { $0 + Double($1) * Double($1) })
    return dot / (na * nb)
}

func record(_ name: String, _ values: [Double]) {
    let sorted = values.sorted()
    result["\(name)_first"] = values[0]
    result["\(name)_median"] = sorted[sorted.count / 2]
    result["\(name)_p90"] = sorted[min(sorted.count - 1, sorted.count * 9 / 10)]
}

func liteRT() async throws {
    let catalog = FileManager.default.temporaryDirectory.appendingPathComponent("macbench-\(UUID().uuidString)")
    let store = try LocalStore(root: catalog)
    let spec = try await store.inferenceSpec(dimensions: 256)
    let runtime = EmbeddingRuntime()
    var start = Date()
    try await runtime.load(path: root.appendingPathComponent("litert/model.litertlm").path, spec: spec)
    result["load_ms"] = ms(start)
    result["footprint_after_load_mib"] = footprint()
    var prepare: [Double] = [], images: [Double] = [], texts: [Double] = [], imageCos: [Double] = [], textCos: [Double] = []
    for reference in references {
        let jpeg = try Data(contentsOf: URL(fileURLWithPath: reference.file))
        start = Date()
        let prepared = try await EmbeddingImage.prepare(jpeg, edge: Int(spec.imageEdge))
        prepare.append(ms(start))
        start = Date()
        let image = try await runtime.embedding(prepared, image: true)
        images.append(ms(start))
        _ = footprint()
        let query = try await store.queryText(reference.query)
        start = Date()
        let text = try await runtime.embedding(Data(query.utf8), image: false)
        texts.append(ms(start))
        _ = footprint()
        imageCos.append(cosine(image, reference.image))
        textCos.append(cosine(text, reference.text))
    }
    record("image_preprocess_ms", prepare)
    record("image_ms", images)
    record("text_ms", texts)
    result["image_cos_min"] = imageCos.min()
    result["text_cos_min"] = textCos.min()
    await runtime.close()
    try? FileManager.default.removeItem(at: catalog)
}

func load(_ name: String, _ units: MLComputeUnits) throws -> MLModel {
    let config = MLModelConfiguration()
    config.computeUnits = units
    let start = Date()
    let model = try MLModel(contentsOf: root.appendingPathComponent("compiled/\(name).mlmodelc"), configuration: config)
    result["load_\(name)_ms"] = ms(start)
    return model
}

func array(_ file: String, _ shape: [Int], _ type: MLMultiArrayDataType) throws -> MLMultiArray {
    let data = try Data(contentsOf: root.appendingPathComponent("benchin/\(file)"))
    let array = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: type)
    data.withUnsafeBytes { raw in
        if let base = raw.baseAddress { memcpy(array.dataPointer, base, data.count) }
    }
    return array
}

func ids(_ file: String) throws -> [Int32] {
    let data = try Data(contentsOf: root.appendingPathComponent("benchin/\(file)"))
    return data.withUnsafeBytes { Array($0.bindMemory(to: Int32.self)) }
}

func output(_ model: MLModel, _ inputs: [String: MLMultiArray], _ name: String) throws -> MLMultiArray {
    let provider = try MLDictionaryFeatureProvider(dictionary: inputs.mapValues { MLFeatureValue(multiArray: $0) })
    guard let value = try model.prediction(from: provider).featureValue(for: name)?.multiArrayValue else {
        throw NSError(domain: "MacBench", code: 1)
    }
    return value
}

func embed(_ tokens: MLModel, _ encoder: MLModel, _ list: [Int32], soft: MLMultiArray?) throws -> [Float] {
    let imageToken: Int32 = 258_880
    let input = try MLMultiArray(shape: [1, 128], dataType: .int32)
    let mask = try MLMultiArray(shape: [1, 128], dataType: .float32)
    let inputPointer = input.dataPointer.bindMemory(to: Int32.self, capacity: 128)
    let maskPointer = mask.dataPointer.bindMemory(to: Float.self, capacity: 128)
    for i in 0 ..< 128 {
        inputPointer[i] = i < list.count && list[i] != imageToken ? list[i] : 0
        maskPointer[i] = i < list.count ? 1 : 0
    }
    let embeds = try output(tokens, ["input_ids": input], "inputs_embeds")
    if let soft {
        // Copy soft tokens into placeholder rows; strides come from the arrays.
        var next = 0
        for (i, id) in list.enumerated() where id == imageToken {
            for d in 0 ..< 512 { embeds[[0, i, d] as [NSNumber]] = soft[[0, next, d] as [NSNumber]] }
            next += 1
        }
    }
    let vector = try output(encoder, ["inputs_embeds": embeds, "mask": mask], "embedding")
    return (0 ..< 768).map { vector[$0].floatValue }
}

func coreML(precision: String, unitsName: String) throws {
    let units: MLComputeUnits = switch unitsName {
    case "cpu": .cpuOnly
    case "gpu": .cpuAndGPU
    case "ane": .cpuAndNeuralEngine
    default: .all
    }
    let start = Date()
    let split = precision != "fp32"
    let vision = try load(split ? "vision-encoder-\(precision)" : "vision-fp32", units)
    let head = split ? try load("vision-head-fp32", .cpuOnly) : nil
    let tokens = try load("tokens-\(precision)", .cpuOnly)
    let encoder = try load("encoder-\(precision)", units)
    result["load_ms"] = ms(start)
    result["footprint_after_load_mib"] = footprint()
    var images: [Double] = [], texts: [Double] = [], imageCos: [Double] = [], textCos: [Double] = []
    for (i, reference) in references.enumerated() {
        let pixels = try array("pixels\(i).bin", [1, 630, 768], .float32)
        let positions = try array("positions\(i).bin", [1, 630, 2], .int32)
        var t = Date()
        let soft: MLMultiArray
        if let head {
            let hidden = try output(vision, ["pixel_values": pixels, "position_ids": positions], "hidden")
            soft = try output(head, ["hidden": hidden, "position_ids": positions], "soft_tokens")
        } else {
            soft = try output(vision, ["pixel_values": pixels, "position_ids": positions], "soft_tokens")
        }
        let image = try embed(tokens, encoder, ids("image_ids\(i).bin"), soft: soft)
        images.append(ms(t))
        _ = footprint()
        t = Date()
        let text = try embed(tokens, encoder, ids("text_ids\(i).bin"), soft: nil)
        texts.append(ms(t))
        _ = footprint()
        imageCos.append(cosine(image, reference.image))
        textCos.append(cosine(text, reference.text))
    }
    record("image_ms", images)
    record("text_ms", texts)
    result["image_cos_min"] = imageCos.min()
    result["text_cos_min"] = textCos.min()
}

result["footprint_start_mib"] = footprint()
if args[2] == "litert" {
    try await liteRT()
} else {
    try coreML(precision: args[3], unitsName: args[4])
}
result["footprint_peak_sampled_mib"] = peak
let label = args.dropFirst(2).joined(separator: "-")
let json = try JSONSerialization.data(withJSONObject: ["config": label, "bundle": Bundle.main.bundleIdentifier ?? "none", "metrics": result], options: [.sortedKeys])
print(String(decoding: json, as: UTF8.self))
