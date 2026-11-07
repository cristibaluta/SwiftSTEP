import Foundation

struct STEPUnits {
    let file: STEPFile

    private static let siPrefixes: [String: Double] = [
        "EXA": 1e18, "PETA": 1e15, "TERA": 1e12, "GIGA": 1e9,
        "MEGA": 1e6, "KILO": 1e3, "HECTO": 1e2, "DECA": 1e1,
        "DECI": 1e-1, "CENTI": 1e-2, "MILLI": 1e-3, "MICRO": 1e-6,
        "NANO": 1e-9, "PICO": 1e-12, "FEMTO": 1e-15, "ATTO": 1e-18
    ]

    /// What differs between the two kinds of unit this file resolves.
    private struct Kind {
        let unitType: String
        let baseUnit: String
        let measureType: String
        /// How the unit is named in "not a … unit" and "Unsupported … unit".
        let noun: String
        /// How it is named in "Unsupported SI … unit" and "Invalid … scale".
        let shortNoun: String
        /// Result for the base unit with no prefix: millimetres per metre, radians per radian.
        let baseScale: Double

        static let length = Kind(unitType: "LENGTH_UNIT", baseUnit: "METRE", measureType: "LENGTH_MEASURE_WITH_UNIT",
                                 noun: "length", shortNoun: "length", baseScale: 1000)
        static let angle = Kind(unitType: "PLANE_ANGLE_UNIT", baseUnit: "RADIAN", measureType: "PLANE_ANGLE_MEASURE_WITH_UNIT",
                                noun: "plane angle", shortNoun: "angle", baseScale: 1)
    }

    func scaleToMM(contextID: Int) throws -> Double {
        try scale(contextID: contextID, kind: .length)
    }

    /// Radians per context angle unit. Trim parameters on circles are expressed in
    /// this unit, so it is resolved only when a parameter trim is actually used.
    func angleScaleToRadians(contextID: Int) throws -> Double {
        try scale(contextID: contextID, kind: .angle)
    }

    private func scale(contextID: Int, kind: Kind) throws -> Double {
        let parameters = try file.parameters(contextID, type: "GLOBAL_UNIT_ASSIGNED_CONTEXT")
        let units = try parameters.references(at: 0)
        let matching = units.filter { file.hasType($0, kind.unitType) }
        guard matching.count == 1, let unit = matching.first else {
            throw STEP.ParseError("Context #\(contextID) must specify exactly one \(kind.noun) unit")
        }
        return try scale(unit, kind: kind, visited: [])
    }

    private func scale(_ id: Int, kind: Kind, visited: Set<Int>) throws -> Double {
        try Task.checkCancellation()
        guard visited.count < 64, !visited.contains(id) else { throw STEP.ParseError("Cyclic/deep unit reference #\(id)") }
        var visited = visited
        visited.insert(id)
        guard file.hasType(id, kind.unitType) else { throw STEP.ParseError("Unit #\(id) is not a \(kind.noun) unit") }
        let components = try file.components(id)
        let result: Double
        if let si = components.first(where: { $0.type == "SI_UNIT" }) {
            guard si.parameters.count == 2, si.parameters[1].enumeration == kind.baseUnit else {
                throw STEP.ParseError("Unsupported SI \(kind.shortNoun) unit #\(id)")
            }
            if si.parameters[0] == .unset {
                result = kind.baseScale
            } else {
                guard let name = si.parameters[0].enumeration, let prefix = Self.siPrefixes[name] else {
                    throw STEP.ParseError("Unsupported SI prefix at #\(id)")
                }
                result = kind.baseScale * prefix
            }
        } else if let converted = components.first(where: { $0.type == "CONVERSION_BASED_UNIT" }) {
            let measureID = try converted.parameters.reference(at: 1)
            let measure = try file.components(measureID)
            // Parenthesised: the parameter count applies to both measure types.
            guard let values = measure.first(where: {
                      ($0.type == "MEASURE_WITH_UNIT" || $0.type == kind.measureType) && $0.parameters.count == 2
                  })?.parameters,
                  let factor = try values.argument(0).number, factor.isFinite, factor > 0 else {
                throw STEP.ParseError("Invalid conversion measure #\(measureID)")
            }
            result = try factor * scale(values.reference(at: 1), kind: kind, visited: visited)
        } else {
            throw STEP.ParseError("Unsupported \(kind.noun) unit #\(id)")
        }
        guard result.isFinite, result > 0 else { throw STEP.ParseError("Invalid \(kind.shortNoun) scale #\(id)") }
        return result
    }
}
