import Foundation

/// A JSON value box for heterogeneous fields coming back from (or sent to) Python — used for
/// `chatTemplateKwargs`/`logitBias`-shaped dictionaries, method-registry `default` fields,
/// `recommend`/`auto-config` `knobs`, and JSON Schema documents.
///
/// Originally a direct extraction of `VeloxQuant-Studio/VeloxQuantStudio/Models/
/// QuantizationMethod.swift`'s `JSONValue`; the try-cascade decode order (bool, then int, then
/// double, then string, then array) is preserved exactly, since reordering it would change
/// behavior for values that could parse as more than one type. `.array` matches Studio's own
/// later addition (Studio issue #17, tuple-valued `default` fields). `.object` is new in this
/// SDK: it closes the nested-schema gap Phase 1 flagged on `FunctionDefinition.parameters` and
/// `ResponseFormat.JSONSchema.schema` — a real JSON Schema needs nested objects/arrays
/// (`properties`, `items`), which the scalar-only shape could not represent.
public enum JSONValue: Codable, Sendable, Hashable {
    /// A JSON string.
    case string(String)
    /// A JSON number that decoded as an integer.
    case int(Int)
    /// A JSON number that did not decode as an integer.
    case double(Double)
    /// A JSON boolean.
    case bool(Bool)
    /// A JSON array.
    case array([JSONValue])
    /// A JSON object.
    case object([String: JSONValue])
    /// JSON `null` (also the fallback for an undecodable value, as in Studio's original).
    case null

    /// Decodes using Studio's try-cascade order, extended with array then object.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int.self) {
            self = .int(int)
        } else if let double = try? container.decode(Double.self) {
            self = .double(double)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            self = .null
        }
    }

    /// Encodes the wrapped value as its natural JSON form.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}
