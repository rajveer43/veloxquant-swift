import Foundation

/// A minimal JSON value box for heterogeneous fields coming back from Python (int, float,
/// bool, string, or null) — used for `chatTemplateKwargs`/`logitBias`-shaped dictionaries and
/// method-registry `default` fields.
///
/// Direct extraction of `VeloxQuant-Studio/VeloxQuantStudio/Models/QuantizationMethod.swift`'s
/// `JSONValue`, not a redesign — the try-cascade decode order (bool, then int, then double,
/// then string, else null) is preserved exactly, since reordering it would change behavior for
/// values that could parse as more than one type.
public enum JSONValue: Codable, Sendable, Hashable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

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
        } else {
            self = .null
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}
