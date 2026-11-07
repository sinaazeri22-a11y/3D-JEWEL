import CoreFoundation
import Foundation

/// A JSON tree with enough structure to be re-serialised without loss.
///
/// The `.ffp` manifest is read, merged with typed values and written back, so
/// the format needs a representation that keeps unknown keys, integers and
/// doubles distinct, and produces deterministic bytes. `JSONSerialization`
/// supplies the parsing and the sorted-key writer; this type supplies the tree
/// and the merge rule.
enum FFPJSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([FFPJSONValue])
    case object([String: FFPJSONValue])

    // MARK: - Parsing and writing

    static func parse(_ data: Data) throws -> FFPJSONValue {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return value(fromFoundation: object)
    }

    /// Sorted keys and unescaped slashes make the encoding canonical, so two
    /// encodings of the same tree are byte-identical. `pretty` is for files a
    /// human may open; it keeps the same order and content.
    func encoded(pretty: Bool = false) throws -> Data {
        var options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        if pretty { options.insert(.prettyPrinted) }
        return try JSONSerialization.data(withJSONObject: foundationObject, options: options)
    }

    private static func value(fromFoundation object: Any) -> FFPJSONValue {
        switch object {
        case is NSNull:
            return .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            if CFNumberIsFloatType(number) {
                return .double(number.doubleValue)
            }
            return .int(number.intValue)
        case let string as String:
            return .string(string)
        case let array as [Any]:
            return .array(array.map(value(fromFoundation:)))
        case let dictionary as [String: Any]:
            return .object(dictionary.mapValues(value(fromFoundation:)))
        default:
            return .null
        }
    }

    private var foundationObject: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .string(let value): return value
        case .array(let values): return values.map(\.foundationObject)
        case .object(let values): return values.mapValues(\.foundationObject)
        }
    }

    // MARK: - Accessors

    var objectValue: [String: FFPJSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var arrayValue: [FFPJSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var intValue: Int? {
        switch self {
        case .int(let value): return value
        case .double(let value) where value.rounded() == value: return Int(value)
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        default: return nil
        }
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    subscript(key: String) -> FFPJSONValue? {
        objectValue?[key]
    }

    /// Replaces a key in an object. Returns the receiver unchanged when it is
    /// not an object, which keeps the merge code free of optional dances.
    func setting(_ key: String, to value: FFPJSONValue) -> FFPJSONValue {
        guard case .object(var dictionary) = self else { return self }
        dictionary[key] = value
        return .object(dictionary)
    }

    func removing(_ key: String) -> FFPJSONValue {
        guard case .object(var dictionary) = self else { return self }
        dictionary.removeValue(forKey: key)
        return .object(dictionary)
    }

    // MARK: - Preservation merge

    /// Overlays `typed` on a tree read from disk.
    ///
    /// The typed value wins for every key it emits. Keys only the old tree has
    /// are kept, which is what preserves future fields. Objects merge
    /// recursively; arrays merge element-wise when both elements are objects
    /// with the same `id`, so a future field on a node survives while a deleted
    /// node does not come back. Everything else is replaced by the typed value.
    static func merge(typed: FFPJSONValue, over preserved: FFPJSONValue?) -> FFPJSONValue {
        guard let preserved else { return typed }
        switch (typed, preserved) {
        case let (.object(typedValues), .object(preservedValues)):
            var result = preservedValues
            for (key, value) in typedValues {
                result[key] = merge(typed: value, over: preservedValues[key])
            }
            return .object(result)

        case let (.array(typedValues), .array(preservedValues)):
            let preservedByID = Dictionary(
                preservedValues.compactMap { element -> (String, FFPJSONValue)? in
                    guard let id = element["id"]?.stringValue else { return nil }
                    return (id, element)
                },
                uniquingKeysWith: { first, _ in first }
            )
            let merged = typedValues.map { element -> FFPJSONValue in
                guard let id = element["id"]?.stringValue,
                      let previous = preservedByID[id] else { return element }
                return merge(typed: element, over: previous)
            }
            return .array(merged)

        default:
            return typed
        }
    }
}
