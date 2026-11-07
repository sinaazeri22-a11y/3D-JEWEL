import Foundation
@testable import FacetForge

/// A small JSON Schema validator for the vocabulary the shipped `.ffp` schema
/// actually uses.
///
/// A full validator would be a dependency the project does not have. This one
/// is honest about its scope: it supports a fixed keyword set, and a test
/// asserts the schema contains no keyword outside that set. Adding `oneOf` to
/// the schema therefore fails the suite until the validator learns it, rather
/// than silently validating nothing. `$ref` resolves only inside this document
/// (`#/$defs/...`), which is all the schema needs.
struct FFPJSONSchemaValidator {
    static let supportedKeywords: Set<String> = [
        "$schema", "$id", "$defs", "$ref", "title", "description",
        "type", "required", "properties", "additionalProperties",
        "enum", "const", "pattern", "minimum", "maximum", "minItems", "items"
    ]

    private let root: FFPJSONValue
    private(set) var keywords: Set<String>

    init(schemaURL: URL) throws {
        root = try FFPJSONValue.parse(Data(contentsOf: schemaURL))
        keywords = Self.collectKeywords(in: root)
    }

    /// Every keyword the schema uses. A test compares this with
    /// `supportedKeywords` so the validator cannot silently under-validate.
    var unsupportedKeywords: Set<String> {
        keywords.subtracting(Self.supportedKeywords)
    }

    func validate(_ instance: FFPJSONValue) -> [String] {
        var errors: [String] = []
        validate(instance, against: root, path: "$", errors: &errors)
        return errors
    }

    // MARK: - Validation

    private func validate(
        _ instance: FFPJSONValue,
        against schema: FFPJSONValue,
        path: String,
        errors: inout [String]
    ) {
        let schema = resolve(schema)
        guard let keywords = schema.objectValue else { return }

        if let constant = keywords["const"], instance != constant {
            errors.append("\(path): expected \(describe(constant))")
        }
        if let allowed = keywords["enum"]?.arrayValue, !allowed.contains(instance) {
            errors.append("\(path): \(describe(instance)) is not one of the enum values")
        }
        if let type = keywords["type"] {
            let names: [String]
            if let single = type.stringValue {
                names = [single]
            } else {
                names = type.arrayValue?.compactMap(\.stringValue) ?? []
            }
            if !names.contains(where: { matches(type: $0, instance) }) {
                errors.append("\(path): expected type \(names.joined(separator: " or "))")
                return
            }
        }

        if let number = instance.doubleValue {
            if let minimum = keywords["minimum"]?.doubleValue, number < minimum {
                errors.append("\(path): \(number) is below \(minimum)")
            }
            if let maximum = keywords["maximum"]?.doubleValue, number > maximum {
                errors.append("\(path): \(number) is above \(maximum)")
            }
        }

        if let string = instance.stringValue, let pattern = keywords["pattern"]?.stringValue {
            if (try? NSRegularExpression(pattern: pattern))?.firstMatch(
                in: string,
                range: NSRange(string.startIndex..., in: string)
            ) == nil {
                errors.append("\(path): \(describe(instance)) does not match \(pattern)")
            }
        }

        if let object = instance.objectValue {
            if let required = keywords["required"]?.arrayValue {
                for name in required.compactMap(\.stringValue) where object[name] == nil {
                    errors.append("\(path): missing required member \"\(name)\"")
                }
            }
            let properties = keywords["properties"]?.objectValue ?? [:]
            for (name, value) in object {
                if let propertySchema = properties[name] {
                    validate(value, against: propertySchema, path: "\(path).\(name)", errors: &errors)
                } else if keywords["additionalProperties"]?.boolValue == false {
                    errors.append("\(path): member \"\(name)\" is not allowed")
                }
            }
        }

        if let array = instance.arrayValue {
            if let minimum = keywords["minItems"]?.intValue, array.count < minimum {
                errors.append("\(path): needs at least \(minimum) items")
            }
            if let itemSchema = keywords["items"] {
                for (index, item) in array.enumerated() {
                    validate(item, against: itemSchema, path: "\(path)[\(index)]", errors: &errors)
                }
            }
        }
    }

    private func resolve(_ schema: FFPJSONValue) -> FFPJSONValue {
        guard let reference = schema["$ref"]?.stringValue else { return schema }
        let prefix = "#/$defs/"
        guard reference.hasPrefix(prefix) else { return schema }
        let name = String(reference.dropFirst(prefix.count))
        guard let definition = root["$defs"]?[name] else { return schema }
        return definition
    }

    private func matches(type: String, _ instance: FFPJSONValue) -> Bool {
        switch (type, instance) {
        case ("number", .int), ("number", .double): return true
        case ("integer", .int): return true
        case ("integer", .double(let value)): return value.rounded() == value
        case ("string", .string): return true
        case ("boolean", .bool): return true
        case ("object", .object): return true
        case ("array", .array): return true
        case ("null", .null): return true
        default: return false
        }
    }

    private func describe(_ value: FFPJSONValue) -> String {
        switch value {
        case .null: return "null"
        case .bool(let flag): return flag ? "true" : "false"
        case .int(let number): return "\(number)"
        case .double(let number): return "\(number)"
        case .string(let string): return "\"\(string)\""
        case .array: return "an array"
        case .object: return "an object"
        }
    }

    // MARK: - Keyword collection

    private static func collectKeywords(in schema: FFPJSONValue) -> Set<String> {
        guard let object = schema.objectValue else { return [] }
        var result: Set<String> = []
        for (key, value) in object {
            switch key {
            case "properties":
                for property in (value.objectValue ?? [:]).values {
                    result.formUnion(collectKeywords(in: property))
                }
            case "$defs":
                for definition in (value.objectValue ?? [:]).values {
                    result.formUnion(collectKeywords(in: definition))
                }
            case "items":
                result.insert(key)
                result.formUnion(collectKeywords(in: value))
            case "enum", "const", "required", "title", "description":
                result.insert(key)
            default:
                if key.hasPrefix("$") || supportedKeywords.contains(key) {
                    result.insert(key)
                }
            }
        }
        return result
    }
}
