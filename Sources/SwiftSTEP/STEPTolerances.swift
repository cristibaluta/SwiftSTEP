import Foundation

/// Every distance and angle slack the importer uses, derived from one place: the chord
/// tolerance the caller asked for and the accuracy the file declares for itself.
///
/// A file's `DISTANCE_ACCURACY_VALUE` (typically 0.01 mm) states how far apart two entities may
/// be and still be asserted to connect, so vertices that miss each other or their curve by a few
/// microns are not a defect. Without a declared value the long-standing defaults apply.
struct STEPTolerances: Sendable, Equatable {
    /// Maximum sagitta of sampled curves and surfaces (mm), from `STEP.Options`.
    let chord: Double
    /// The file's own distance accuracy in mm, when it declares one.
    let declaredUncertainty: Double?
    /// Two boundary edges meet when their end points are this close (mm).
    let connection: Double
    /// Floor for how far a vertex may sit off its curve (mm); see `vertexOnCurve`.
    let vertexFloor: Double
    /// Vertex-off-curve slack as a fraction of the curve's extent.
    let relativeVertex = 1e-4
    /// Slack (rad) when comparing trim angles with vertex angles and detecting a full turn.
    let angular = 1e-3

    /// Today's connection tolerance when the file declares nothing.
    static let defaultConnection = 1e-6
    /// Points this close are one point when a loop runs out along an edge and straight back.
    /// Those points come from the same edge sampled twice, so they match exactly: no file slack.
    static let retrace = 1e-6

    init(chord: Double, declaredUncertainty: Double? = nil) {
        self.chord = chord
        let declared: Double?
        if let value = declaredUncertainty, value.isFinite, value > 0 { declared = value } else { declared = nil }
        self.declaredUncertainty = declared
        if let declared {
            // Never finer than the default, never coarser than the sampling can resolve anyway.
            connection = min(max(declared, Self.defaultConnection), max(chord, Self.defaultConnection))
            vertexFloor = max(chord, declared)
        } else {
            connection = Self.defaultConnection
            vertexFloor = chord
        }
    }

    /// How far a vertex may be from its curve, for a curve of the given bounding extent (mm).
    /// At least a fraction of the extent, and the floor, but the floor never more than 1% of the
    /// extent, so a short curve is not swallowed by it.
    func vertexOnCurve(extent: Double, magnitude: Double = 0) -> Double {
        max(relativeVertex * extent, min(vertexFloor, 1e-2 * extent), 1e-9 * (1 + magnitude), 1e-7)
    }
}
