import Foundation
import FoundationModels

/// JSON Schema (the subset tool arguments use) -> FoundationModels guided-generation schema.
/// Unsupported shapes (free-form objects, `$ref`) fall back to a string.
struct SchemaConverter {
    private var counter = 0

    mutating func convert(_ schema: [String: Any], name: String = "Root") -> DynamicGenerationSchema {
        counter += 1
        let name = "\(name)_\(counter)"
        let description = schema["description"] as? String
        if let c = schema["const"] {
            return DynamicGenerationSchema(name: name, description: description, anyOf: ["\(c)"])
        }
        if let options = schema["enum"] as? [Any] {
            return DynamicGenerationSchema(name: name, description: description, anyOf: options.map { "\($0)" })
        }
        if var choices = (schema["anyOf"] ?? schema["oneOf"]) as? [[String: Any]] {
            // The on-device model leans toward earlier choices; put a plain answer (a choice
            // with an "answer" property) first so finishing is never the unlikely branch.
            if let i = choices.firstIndex(where: { ($0["properties"] as? [String: Any])?["answer"] != nil }), i > 0 {
                choices.insert(choices.remove(at: i), at: 0)
            }
            return DynamicGenerationSchema(
                name: name, description: description,
                anyOf: choices.enumerated().map { convert($0.element, name: "\(name)Choice\($0.offset)") })
        }
        var type = schema["type"] as? String
        if type == nil, let types = schema["type"] as? [String] {
            type = types.first { $0 != "null" }
        }
        if type == nil, schema["properties"] != nil { type = "object" }
        switch type {
        case "object":
            let props = schema["properties"] as? [String: Any] ?? [:]
            let requiredList = schema["required"] as? [String] ?? []
            let required = Set(requiredList)
            if props.isEmpty { return DynamicGenerationSchema(type: String.self) }
            // Generation order matters (e.g. "thought" before "action"), and JSONSerialization
            // loses key order: follow `required`, then the optional keys alphabetically.
            let keys = requiredList.filter { props[$0] != nil } + props.keys.filter { !required.contains($0) }.sorted()
            let properties = keys.map { key in
                let sub = props[key] as? [String: Any] ?? [:]
                return DynamicGenerationSchema.Property(
                    name: key, description: sub["description"] as? String,
                    schema: convert(sub, name: "\(name)_\(key)"), isOptional: !required.contains(key))
            }
            return DynamicGenerationSchema(name: name, description: description, properties: properties)
        case "array":
            let items = schema["items"] as? [String: Any] ?? ["type": "string"]
            return DynamicGenerationSchema(
                arrayOf: convert(items, name: "\(name)Item"),
                minimumElements: schema["minItems"] as? Int, maximumElements: schema["maxItems"] as? Int)
        case "integer": return DynamicGenerationSchema(type: Int.self)
        case "number": return DynamicGenerationSchema(type: Double.self)
        case "boolean": return DynamicGenerationSchema(type: Bool.self)
        default: return DynamicGenerationSchema(type: String.self)
        }
    }

    static func generationSchema(_ json: [String: Any]) throws -> GenerationSchema {
        var c = SchemaConverter()
        return try GenerationSchema(root: c.convert(json), dependencies: [])
    }
}
