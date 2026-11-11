# SwiftSTEP

Reads STEP (ISO 10303-21) B-rep solids and shells and returns plain `simd` data, under the `STEP`
namespace. Foundation and `simd` only: no UI, renderer or CAM types. Apple platforms (macOS, iOS).

```swift
import SwiftSTEP

let model = try STEP.read(contentsOf: url)           // STEP.EdgeModel
for edge in model.edges {
    print(edge.id.entityID, edge.kind, edge.points)   // [SIMD3<Double>], millimetres
}
for note in model.diagnostics { print(note.entityID ?? 0, note.message) }
```

The result is display geometry: edges as polylines sampled to a chord tolerance. It does not heal
geometry or produce machining contours.

## API

| Call | Returns |
| --- | --- |
| `STEP.read(data:importID:options:)` / `read(contentsOf:…)` | `STEP.EdgeModel` (synchronous) |
| `STEP.readGeometry(data:…)` / `readGeometry(contentsOf:…)` | `STEP.Geometry`: `edges` plus `surfaces` (synchronous) |
| `STEP.readTopology(data:…)` / `readTopology(contentsOf:…)` | `STEP.Topology`: `edges` plus the faces of every body (surface, sense, boundary loops), no triangles |
| `STEP.load(contentsOf:…)` / `loadGeometry(contentsOf:…)` / `loadTopology(contentsOf:…)` | Same, `async`: detached worker, memory-mapped, cancellable |

Call the synchronous forms from a background task, never the main actor.

- `importID: UUID` is stamped into every `STEP.EdgeID`. Pass the same ID when re-parsing an unchanged
  source so stored selections stay valid.
- `STEP.Options`: `assumedUnitScaleToMM: Double?` (default `nil`: an unresolvable length unit fails the
  import) and `chordToleranceMM: Double` (default `0.01`).

### Bodies and assemblies

A file can hold several solids (multi-body) and can place the same part several times (an assembly).
`readBodies` returns both as one array, with every body already in assembly coordinates (mm):

```swift
let bodies = try STEP.readBodies(contentsOf: url)      // [STEP.Body]
for body in bodies {
    print(body.displayName, body.id.instance, body.bounds?.size ?? .zero)
}
let assembly = try STEP.readAssembly(contentsOf: url)  // same bodies + header, bounds, origin, diagnostics, report
```

- `STEP.Body`: `id` (`BodyID.instance` counts the placements of one part: 0, 1, 2, …), `info`, `transform`
  (part → assembly, already applied), `path` (occurrence names from the top down), `edges`, `mesh`
  (`nil` without faces). `includeSurfaces: false` skips tessellation.
- Placements come from `NEXT_ASSEMBLY_USAGE_OCCURRENCE` with `CONTEXT_DEPENDENT_SHAPE_REPRESENTATION` /
  `ITEM_DEFINED_TRANSFORMATION`, or from `MAPPED_ITEM` (used only when the file has no usage placements).
  Nesting is followed; translations are converted from the unit of the representation they are written in.
  Parts are read and tessellated once and copied through each placement. Mesh positions are relative to
  `Assembly.origin`.
- Only rotations with translation (and uniform scale) are supported; a mirrored or skewed placement is
  skipped with an `assembly-placement-skipped` diagnostic. `Options.maximumInstanceCount` caps the expansion.
- `read`, `readGeometry` and `readTopology` still import a body once, untransformed, with an
  `assembly-untransformed` warning when the file places parts.

### Output types

| Type | Contents |
| --- | --- |
| `STEP.EdgeModel` | `importID`, `header`, `edges`, `bodies`, `bounds`, `diagnostics`, `indexedEntityCount`, `reachableEdgeCount`, `skippedEdgeCount` |
| `STEP.Header` | From the file's header: `schemas`, `descriptions`, `implementationLevel`, `name`, `timestamp`, `authors`, `organizations`, `preprocessorVersion`, `originatingSystem`, `authorization` |
| `STEP.Diagnostic` | `entityID`, `message`, `severity` (`info`, `warning`, `skipped`), `code` (stable short id such as `unsupported-curve`, `vertex-off-curve`, `chord-cap`) |
| `STEP.ParseError` | `description` and `kind`: `.notSTEP`, `.truncated`, `.malformed`, `.assembly`, `.unresolvedUnits(contextID:)`, `.limitExceeded`, `.invalidOptions` |
| `STEP.Options` | `assumedUnitScaleToMM`, `chordToleranceMM`, `maximumEntityCount`. When a file declares its distance accuracy, boundary edges that meet within it (capped at the chord tolerance) close a face loop |
| `STEP.Edge` | `id`, `kind`, `points: [SIMD3<Double>]` (mm, source coordinates), `startVertexID`, `endVertexID`, `adjacentFaceIDs`, `chordError`, `isSeam` (one face uses it in both directions: a cylinder's seam), `curve` |
| `STEP.Edge.Curve` | The exact curve behind `points`: `.line`, `.circle(frame:radius:startAngle:sweep:)` (centre `frame.origin`, axis `frame.z`, signed sweep in radians), `.other` for ellipses, B-splines and polylines (`.ellipse` is reserved, not filled yet) |
| `STEP.BodyInfo` | `id`, `contextID`, `unitScaleToMM`, `unitsAssumed`, `uncertaintyMM`, `bounds` (min/max of the body's own edges), `name` (the body entity's name string, as written) |
| `STEP.Topology` | `edges: EdgeModel`, `faces: [Face]` (by body, then face ID), `diagnostics`, `faces(of:)` |
| `STEP.Face` | `id`, `bodyID`, `sameSense`, `isShellReversed` (void shell), `surface: Surface?` (`nil` for a surface kind that is not supported, the face is still listed), `surfaceTypeName`, `loops: [[OrientedEdgeRef]]`, `outerLoopIndex`, `outerLoop` |
| `STEP.OrientedEdgeRef` | `edge: EdgeID` (matches `Edge.id`), `isForward`. Loops run in the direction of their face bound, so a bound written `.F` is reversed |
| `STEP.EdgeID` / `STEP.BodyID` | Stable identity for one import: `importID` + body (representation and body entity IDs) + `EDGE_CURVE` entity ID |
| `STEP.Bounds` | `min`, `max`, `size`, `workpieceOrigin` (min X, min Y, max Z) as `SIMD3<Double>` |
| `STEP.Geometry` | `edges: EdgeModel`, `surfaces: SurfaceModel` |
| `STEP.SurfaceModel` | `origin: SIMD3<Double>` and per fully tessellated body a `STEP.BodyMesh` |
| `STEP.BodyMesh` | `positions`/`normals: [SIMD3<Float>]` (mm, relative to `SurfaceModel.origin`), `indices: [UInt32]`, `faces: [STEP.FaceMesh]`, `face(ofTriangle:)`, `occluderTriangles(offset:)` |
| `STEP.FaceMesh` | `faceID`, `surface: STEP.Surface`, `sameSense`, `triangles` |
| `STEP.Surface` | `.plane`, `.cylinder`, `.cone`, `.sphere`, `.torus`, each with a `STEP.Frame` (`origin`, `x`, `y`, `z`), and `.bspline(STEP.BSplineSurface)`. `frame` is `nil` for a B-spline surface |
| `STEP.BSplineSurface` | `uDegree`, `vDegree`, `uDomain`, `vDomain`, `point(u:v:)`, `normal(u:v:)` (`∂P/∂u × ∂P/∂v`); u, v are the file's knot parameters |

Edges are unique per body, in deterministic order (body, then `EDGE_CURVE` entity ID). Every edge has at
least two points; the first and last are exactly the scaled vertex coordinates.

## Supported

| Geometry | Handled as |
| --- | --- |
| `LINE` | Two vertices |
| `CIRCLE`, `ELLIPSE` | Arc or full curve from the vertices, `same_sense`, trims; sampled to the chord tolerance |
| `POLYLINE` | Cut to the edge between its vertices; closed polylines can wrap past their seam |
| `B_SPLINE_CURVE_WITH_KNOTS` | Simple and complex rational records; de Boor evaluation, vertex projection, adaptive sampling |
| `TRIMMED_CURVE` | Point or parameter trims, `sense_agreement`, context angle units (circles and ellipses) |
| `SURFACE_CURVE`, `SEAM_CURVE`, `INTERSECTION_CURVE` | Unwrapped to `curve_3d`, also around a trimmed curve |
| Bodies | `MANIFOLD_SOLID_BREP`, `BREP_WITH_VOIDS`, `SHELL_BASED_SURFACE_MODEL`, several per file, each with its own units |
| Units | SI with prefixes, `CONVERSION_BASED_UNIT` chains (inch, foot, degree) |

Not supported (the edge is skipped with a diagnostic, never drawn as a guessed chord): offset curves,
parabolas, hyperbolas, `COMPOSITE_CURVE`, B-splines without explicit knots, nested trimmed curves.

Surfaces (`readGeometry`): `PLANE` (holes included), `CYLINDRICAL_SURFACE`, `CONICAL_SURFACE`,
`SPHERICAL_SURFACE`, `TOROIDAL_SURFACE` and `B_SPLINE_SURFACE_WITH_KNOTS` (rational or not, simple or
complex record), trimmed by their loops. A face whose boundary lies more than the chord tolerance off its
B-spline surface fails with the distance. Swept surfaces (revolution, linear extrusion), B-spline surfaces
without explicit knots, collapsed-side B-spline surfaces, faces
reaching a sphere pole or cone apex, faces wrapping a torus tube, vertex/poly loops and `ORIENTED_FACE` are
not supported: such a face, or a skipped boundary edge, drops that body's whole mesh (a partial occluder
would hide visible edges) and the body is listed in `unsurfacedBodies`. Cap: 1,000,000 triangles per import.

## Errors versus diagnostics

**Throws** `STEP.ParseError` (its `description` is the message) or `CancellationError` for problems with the
file as a whole: malformed or truncated Part 21, duplicate entity IDs, excessive nesting, non-finite
numbers, an unresolvable length unit without
`assumedUnitScaleToMM`, invalid options.

**Succeeds with a diagnostic** for problems with one edge or face. Always check `diagnostics` (and
`surfaces.diagnostics`): an empty `edges` array comes with one explaining why. An empty file is a successful
result with `bounds == nil`.

## Sampling and tolerances

- Curves are sampled to `chordToleranceMM`. A full circle never has fewer than 8 segments.
- Caps: 4096 segments per circle or ellipse, 20,000 points per B-spline edge; a diagnostic reports the actual
  error when a cap is hit.
- Vertices are checked against their curve with a tolerance relative to the curve size (1e-4 of the largest
  axis or bounding diagonal); edges whose vertices are farther off are skipped.
- Double precision throughout; only `BodyMesh` is Float, recentred on `SurfaceModel.origin`.
- Deterministic: the same bytes and `importID` give the same edges, IDs and order.

## Layout

| File | Role |
| --- | --- |
| `STEP.swift` | Namespace and public entry points |
| `Model.swift`, `Mesh.swift`, `Surface.swift`, `BSplineSurface.swift` | Public output types |
| `STEPEdgeImporter.swift` | Internal drivers (parse, surfaces, detached worker) |
| `STEPTokenizer.swift`, `STEPFile.swift`, `STEPValue.swift` | Part 21 lexer, lazy entity index and cache |
| `STEPUnits.swift` | Length and plane-angle units per representation context |
| `STEPEdgeExtractor.swift` | Body → shell → face → loop → edge traversal |
| `STEPCurves.swift`, `STEPBSpline.swift` | Curve resolution, trims, sampling, B-splines |
| `STEPFaces.swift` | Faces and surfaces read once for both the tessellator and `readTopology`; `Face`, `Topology` |
| `STEPTessellator.swift`, `STEPSlabTriangulator.swift` | Face triangulation |

A `STEPFile` and its extractor are task-confined: never share them across tasks. Use the static entry points.

## STL

```swift
let geometry = try STL.readGeometry(contentsOf: url)           // same STEP.Geometry as STEP.readGeometry
let geometry = try await STL.loadGeometry(contentsOf: url)     // async, cancellable
let assembly = try await STL.loadAssembly(contentsOf: url)     // one-body STEP.Assembly (what the demo uses)
```

Reads binary and ASCII STL, optionally gzipped. Binary is detected by file size, not by a leading `solid`.
Caveats: no edges (the edge model is empty), flat shading from triangle winding (stored normals are
ignored), no units (millimetres unless `Options.assumedUnitScaleToMM` is set, reported as `unitsAssumed`),
`BodyMesh.faces` is empty, and several `solid` blocks become one body. Zero-area triangles are dropped
with a `degenerate-triangles` note. Meshes are not repaired.

Optional edges and smooth shading, off by default:

```swift
let options = STL.Options(featureAngleDegrees: 30, smoothShading: true)
let geometry = try STL.readGeometry(contentsOf: url, stl: options)
```

`featureAngleDegrees` extracts edges (boundary, non-manifold, and creases sharper than the angle) as chained
polylines; `smoothShading` welds vertices and averages normals across non-crease edges, splitting at creases.
Welding uses a grid of about 1e-5 of the bounding-box diagonal. Inconsistent triangle winding shows up as
false creases. Non-manifold edges add an `stl-non-manifold` warning.

### Converting STEP to STL

`swift run -c release step2stl <file-or-folder> [<output-folder>] [--chord <mm>]` writes binary STL with the
library's tessellator (`STL.binaryData(for:)`). `Scripts/make_stl_samples.sh` converts every demo sample into
`Sources/SwiftSTEPDemo/Samples/`, where the demo's dropdown picks the `.stl` files up next to the `.step` ones.

## Tests

`swift test`. `STEPCurveTests.swift` (Swift Testing) builds Part 21 fixtures in code: box, cylinder, arcs,
trims, ellipses, polylines, B-splines, units and failure cases. Real CAD exports (holes, fillets, spline
edges, multi-body parts, 50 to 100 MB files) are still to be added.
