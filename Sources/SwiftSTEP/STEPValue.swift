import Foundation

/// Part 21 values. Enumeration spelling is retained (including T/F/U).
indirect enum STEPValue: Equatable, Sendable {
    case integer(Int), real(Double), string(String), reference(Int), enumeration(String)
    case list([STEPValue]), typed(String, [STEPValue]), unset, derived

    var reference: Int? { if case .reference(let id) = self { return id }; return nil }
    var list: [STEPValue]? { if case .list(let values) = self { return values }; return nil }
    var enumeration: String? { if case .enumeration(let name) = self { return name }; return nil }
    var number: Double? {
        switch self {
            case .integer(let value): return Double(value)
            case .real(let value): return value
            case .typed(_, let values) where values.count == 1: return values[0].number
            default: return nil
        }
    }
}

struct STEPComponent: Sendable {
    let type: String
    let parameters: [STEPValue]
}
