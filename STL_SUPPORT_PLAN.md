# Adding STL support to SwiftSTEP

Goal: read `.stl` (binary and ASCII, optionally gzipped) into the existing `STEP.Geometry` type, so the
demo renderer and any consumer of `BodyMesh` work unchanged. Minimum new code: one source file, one test file.

## What is reused and what is not

| Reused as is | Not reused (STEP-specific) |
| --- | --- |
| `STEP.BodyMesh`, `SurfaceModel`, `Geometry` | Tokenizer, `STEPFile` index |
| `STEP.ParseError`, `Diagnostic` | Units resolver, curves, B-splines |
| `STEP.Options` (`assumedUnitScaleToMM`, `maximumTriangleCount`) | Tessellator and triangulators |
| `STEP.Bounds`, `BodyInfo`, `BodyID` | Edge extractor |
| `STEPGzip.inflateIfGzip` (gives `.stl.gz` for free) | |
| `STEPEdgeImporter.detached` (async and cancellable) | |

## Scope decisions (settle first)

1. **Edges**: v1 returns an empty `EdgeModel` (shaded mesh only). Feature edges are Phase 2, optional.
2. **Normals**: v1 uses flat per-triangle normals recomputed from winding. Stored STL normals are ignored
   (often zero or wrong). Smooth shading is Phase 2.
3. **Units**: STL has none. Default is mm, recorded as `unitsAssumed = true`.
   `Options.assumedUnitScaleToMM` overrides it.
4. **Naming**: a top-level `public enum STL` in the same module. No rename of the package for now.
5. **Faces**: `BodyMesh.faces` stays empty, because `FaceMesh.surface` is non-optional and STL has no
   analytic surfaces. `face(ofTriangle:)` then returns `nil`, which is already handled.

## Phase 1: reader (shaded mesh)

### Step 1. Check the model types can be built from outside the STEP pipeline
- `EdgeModel.importID` is `let`, and the other fields are `internal(set)`. Confirm an in-module initializer
  exists, or add `init(importID:)` (internal is enough).
- `BodyMesh` has `internal(set)` fields and needs an in-module `init(id:)`. Same check.
- Confirm `STEP.Geometry` has an in-module memberwise init.

### Step 2. Create `Sources/SwiftSTEP/STL.swift`
Public API:
```swift
public enum STL {
    public static func readGeometry(data: Data, importID: UUID = UUID(),
                                    options: STEP.Options = STEP.Options()) throws -> STEP.Geometry
    public static func readGeometry(contentsOf url: URL, importID: UUID = UUID(),
                                    options: STEP.Options = STEP.Options()) throws -> STEP.Geometry
    public static func loadGeometry(contentsOf url: URL, importID: UUID = UUID(),
                                    options: STEP.Options = STEP.Options()) async throws -> STEP.Geometry
}
```

Internals, in order:
1. `Task.checkCancellation()`, then `STEPGzip.inflateIfGzip(data)`.
2. **Format detection by size, not by prefix** (binary files often start with `solid`):
   - If `data.count >= 84` and `data.count == 84 + 50 * N`, where `N` is the little-endian UInt32 at offset 80,
     the file is binary.
   - Otherwise, if the file is UTF-8 text containing `facet` and `vertex`, it is ASCII.
   - Otherwise throw `ParseError(kind: .malformed)`. If the size is almost right but short, throw `.truncated`.
3. **Triangle cap**: if `N > options.maximumTriangleCount`, throw `.limitExceeded` before allocating.
4. **Binary decode**: for each 50-byte record, skip the 12-byte normal, read 3 vertices of 3 Float32 each
   (little endian, use `loadUnaligned`), skip the 2-byte attribute count.
5. **ASCII decode**: a line scanner over the UTF-8 bytes. Read only `vertex x y z` lines and group them by 3.
   Ignore `facet normal`, `outer loop` and so on. Throw `.malformed` if the vertex count is not a multiple of 3.
   Support multiple `solid … endsolid` blocks, either as one body or as one body each (pick one; one body is simpler).
6. **Validation**: reject non-finite coordinates. Drop zero-area triangles (cross product length below a
   small epsilon) and report the number dropped in a single `info` diagnostic with code `degenerate-triangles`.
7. **Build the mesh**:
   - `positions`: 3 per triangle (unwelded), relative to `origin`, as `SIMD3<Float>`.
   - `normals`: `normalize(cross(b - a, c - a))` per triangle, repeated for its 3 vertices.
   - `indices`: `0..<3n`.
   - `origin = Bounds.workpieceOrigin`, to match the STEP convention.
8. **Assemble**: `BodyInfo(id: BodyID(representationID: 0, entityID: 0), contextID: 0,
   unitScaleToMM: options.assumedUnitScaleToMM ?? 1, unitsAssumed: true, bounds: bounds, name: <solid name or nil>)`.
   An `EdgeModel` has empty `edges`, the body, `bounds`, and an `info` diagnostic `stl-no-edges`.
   Wrap both in `STEP.Geometry`. Set `tessellatedFaceCount` and similar counters sensibly (0 faces).
9. Apply the unit scale to positions and bounds if it is not 1.

### Step 3. Async wrapper
`loadGeometry(contentsOf:)` calls `STEPEdgeImporter.detached { try readGeometry(...) }`. Read the file with
`Data(contentsOf:options: .mappedIfSafe)` as the STEP entry points do.

### Step 4. Demo app
- `Viewer.swift`: add `"stl"` to `stepTypes` (rename to `supportedTypes`).
- In the load function, branch on `url.pathExtension.lowercased()`: `"stl"` calls `STL.loadGeometry`, otherwise
  `STEP.loadGeometry`.
- Check `Renderer.load` copes with `edges.edges.isEmpty` (camera framing should use `edges.bounds`, which we set).
- Optional: bundle one small `cube.stl` in `Samples/`.

### Step 5. Tests: `Tests/SwiftSTEPTests/STLTests.swift`
Build the files in memory, no fixtures needed:
- Binary cube (12 triangles): triangle count, bounds, normals point outward.
- ASCII cube: same results as binary.
- Binary file that starts with `solid` still parses as binary.
- Truncated binary (header says N, data is short): throws `.truncated`.
- Non-STL data: throws `.malformed`.
- Zero-area triangle: dropped, diagnostic present.
- NaN coordinate: throws.
- `N > maximumTriangleCount`: throws `.limitExceeded`.
- Gzipped STL (Darwin only): round trip.
- `assumedUnitScaleToMM = 25.4`: bounds scale.
- Cancellation: a cancelled task throws `CancellationError`.

### Step 6. Docs
Add a short "STL" section to `README.md`: the API, the "no edges, flat shading, units assumed mm" caveats.

## Phase 2 (optional): feature edges and smooth shading

New file `Sources/SwiftSTEP/STLFeatureEdges.swift`, behind an option such as `STL.Options.featureAngleDegrees`.

1. **Weld vertices**: quantise positions to a grid (tolerance about 1e-5 × bounding box diagonal) and map them
   to shared indices with a dictionary.
2. **Edge map**: key each triangle edge by its sorted welded index pair, and store the adjacent triangles.
3. **Classify edges**:
   - boundary (1 adjacent triangle) → edge,
   - non-manifold (3 or more) → edge, plus a diagnostic,
   - interior where the dihedral angle between face normals exceeds the threshold → edge.
4. **Chain into polylines**: link feature edges end to end at vertices of degree 2, so lines are not hundreds of
   two-point segments. Emit as `STEP.Edge(kind: .polyline, …)` with synthetic `EdgeID.entityID` values (the
   index) and empty `adjacentFaceIDs`.
5. **Smooth shading**: with the welded mesh, average normals only across edges below the crease angle, and
   split vertices at feature edges.
6. Tests: cube yields 12 edges (or 8 corners chained into 12), a sphere yields none, an open sheet yields its
   boundary loop.

## Risks and notes
- STL has no topology guarantees: expect duplicate, open or non-manifold meshes. Report, do not repair.
- Memory: unwelded meshes use 3 vertices per triangle. The existing 1M triangle default cap bounds this.
- Some exporters write ASCII STL with scientific notation or CRLF line endings. The scanner must tolerate both.
- Very old binary STL variants (e.g. colour in the attribute bytes) are fine: the attribute is ignored.

## Estimated size
| Scope | New files | Approx. lines |
| --- | --- | --- |
| Phase 1 | `STL.swift`, `STLTests.swift` (+ small edits to `Viewer.swift`, `README.md`) | ~250 |
| Phase 2 | `STLFeatureEdges.swift` (+ tests) | ~150–250 |
