# SwiftSTEP: improvement tasks

Each task is small and self-contained, so it can be done in one short session.

**How to keep sessions cheap**
- Do one task per session. Attach only the files listed under "Files".
- Tasks marked **S** need a few edits. **M** is one focused change. **L** should be split further before starting.
- Tasks inside a phase are mostly independent. Phases are ordered by value per effort.
- Nothing here was built or run during the review (no Swift toolchain), so each task ends with "Done when" that you can check with `swift test`.

---

## Phase 0: quick wins (all S)

### T01. Remove `indirect` from `STEPValue`
- Files: `STEPValue.swift`
- Why: `indirect enum` boxes every case, including `.integer` and `.real`. `[STEPValue]` is already heap-backed.
- Do: delete the `indirect` keyword and build.
- Done when: it compiles, existing tests pass, memory use on a large file drops.

### T02. Fix operator precedence in `STEPUnits.scale`
- Files: `STEPUnits.swift`
- Why: `A || B && count == 2` skips the count check for `MEASURE_WITH_UNIT`. The angle version has parentheses.
- Do: add the parentheses. Better, merge `scale` and `angleScale` into one function parameterised by unit type and base unit.
- Done when: the unit tests still pass and the two paths share one implementation.

### T03. Skip a UTF-8 BOM at the start of the file
- Files: `STEPTokenizer.swift` (or `STEPFile.init`)
- Do: if the first three bytes are `EF BB BF`, start after them.
- Done when: a test with a BOM-prefixed fixture parses.

### T04. Tolerate user-defined keywords (`!NAME(...)`)
- Files: `STEPTokenizer.swift`, `STEPFile.swift`
- Do: lex `!` followed by letters as a `.word`. Index it like any other entity. It is ignored by the extractor.
- Done when: a fixture containing `#9=!MY_ENTITY('x');` imports without throwing.

### T05. Add the missing `LINE` vertex check
- Files: `STEPCurves.swift`
- Do: measure the distance from both vertices to the line. If it is above tolerance, throw the same kind of "vertex not on curve" error the other curves use.
- Done when: a test with an off-line vertex is skipped with a diagnostic.

### T06. Make the entity cap an option
- Files: `Model.swift` (`Options`), `STEPFile.swift`, `STEP.swift`
- Do: add `maximumEntityCount` (default 2,000,000) to `STEP.Options` and pass it to `STEPFile`.
- Done when: a test lowering the cap hits the error and the default behaviour is unchanged.

### T07. Public initializers and conformances
- Files: `Model.swift`, `Mesh.swift`, `Surface.swift`
- Do: add public inits for `Edge`, `BodyInfo`, `Diagnostic`, `Frame`, `FaceMesh`. Make `Edge` `Identifiable`. Make `chordError` a `let`. Make `Diagnostic` `Equatable` and `CustomStringConvertible`.
- Done when: an external target can construct these types in a test.

---

## Phase 1: errors, diagnostics and tolerances

### T10. Typed `ParseError` (M)
- Files: `Model.swift`, then each `throw STEP.ParseError("...")` site
- Do:
  1. Add `enum Kind` with `.notSTEP`, `.truncated`, `.malformed`, `.assembly`, `.unresolvedUnits(contextID: Int)`, `.limitExceeded`, `.invalidOptions`.
  2. Keep `description`.
  3. Convert only the file-level throws in `STEPFile` and `STEPEdgeExtractor.extract` first.
  4. Leave per-edge and per-face errors as `.malformed` for now.
- Done when: a test can branch on `.unresolvedUnits` without matching text.

### T11. `Diagnostic` severity and code (S)
- Files: `Model.swift`, `diagnose` calls in `STEPEdgeExtractor.swift` and `STEPTessellator.swift`
- Do: add `severity` (`info`, `warning`, `skipped`) and a short `code` string (`"unsupported-curve"`, `"chord-cap"`, …) to `Diagnostic`.
- Done when: existing diagnostics carry a code and the tests still pass.

### T12. Read the file's uncertainty (M)
- Files: `STEPUnits.swift`, new `STEPTolerances.swift`
- Do:
  1. Read `GLOBAL_UNCERTAINTY_ASSIGNED_CONTEXT` and `UNCERTAINTY_MEASURE_WITH_UNIT` and scale to mm.
  2. Expose it from `STEPUnits`.
  3. Fall back to today's defaults when it is absent.
- Done when: a test with a declared uncertainty returns the scaled value.

### T13. Replace scattered tolerance constants (M, after T12)
- Files: `STEPCurves.swift`, `STEPTessellator.swift`
- Do: replace `connectionTolerance (1e-6)`, `relativeVertexTolerance (1e-4)` and `angularTolerance (1e-3)` with values derived from one `Tolerances` struct.
- Done when: all current tests pass unchanged, and a new test shows two vertices a few microns apart still close a loop.

### T14. Header metadata (S)
- Files: `STEPFile.swift`, `Model.swift`, `STEPEdgeImporter.swift`
- Do: keep the header records. Parse `FILE_SCHEMA` and `FILE_NAME` into `STEP.Header` (schema, name, originating system, timestamp). Add `header` to `EdgeModel`.
- Done when: a fixture's schema and file name come back in the model.

---

## Phase 2: better output for CAM

### T20. Seam flag on edges (S)
- Files: `STEPEdgeExtractor.swift`, `Model.swift`
- Do: during `collectEdges`, count how many times each face uses an edge. Add `isSeam` (the same face uses it twice) to `Edge`.
- Done when: the cylinder test shows exactly one seam edge.

### T21. Analytic curve data on edges (M)
- Files: `STEPCurves.swift`, `Model.swift`
- Do:
  1. Add `Edge.curve` with `.line`, `.circle(frame, radius, startAngle, sweep)`, `.ellipse(...)`, `.other`.
  2. Fill it for lines and circles first, from data `resolveConic` already computes.
  3. Leave ellipse and B-spline as `.other`.
- Done when: the box, cylinder and arc tests can read radius, centre and axis from edges.

### T22. Per-body bounds (S)
- Files: `STEPEdgeExtractor.swift`, `Model.swift`
- Do: add `bounds` to `BodyInfo`, computed from that body's edge points.
- Done when: a two-body fixture reports two different boxes.

### T23. Body and part names (S)
- Files: `STEPEdgeExtractor.swift`, `Model.swift`
- Do: read the name string of the body entity and expose it as `BodyInfo.name`.
- Done when: a fixture with a named brep returns the name.

### T24. Face topology output, step 1: faces without tessellation (M)
- Files: new `STEPFaces.swift`, `Model.swift`
- Do:
  1. Add `STEP.Face` with `id`, `bodyID`, `sameSense`, `surface: Surface?` and `surfaceTypeName`.
  2. Reuse `parseFace` and `parseSurface` from the tessellator, moved into a shared helper.
  3. Add `EdgeModel.faces` or a separate `readTopology` entry point.
- Done when: a body with one unsupported face still lists all its other faces with their surfaces.

### T25. Face topology output, step 2: loops (M, after T24)
- Files: `STEPFaces.swift`
- Do: add `loops: [[OrientedEdgeRef]]` (edge ID plus orientation) and `outerLoopIndex` to `Face`.
- Done when: the box test shows 6 faces with 4-edge outer loops.

---

## Phase 3: tessellation robustness

### T30. Keep partial meshes (M)
- Files: `STEPTessellator.swift`, `Mesh.swift`, `Model.swift`
- Why: a missing face can only under-occlude, so dropping the whole body is more pessimistic than needed.
- Do: when a face fails, keep the faces that worked. Mark the body `isPartial` and list failed face IDs in `SurfaceModel`. Keep the current behaviour behind an option for callers that want it.
- Done when: a body with one bad face returns a mesh plus the failed face ID.

### T31. Proper triangulation for planar faces (L, split)
- Files: new `STEPPolygonTriangulator.swift`, `STEPTessellator.swift`
- Split into:
  1. T31a: ear-clipping with holes (earcut-style) for one outer loop plus holes, with tests on a square-with-hole.
  2. T31b: route `.plane` faces to it and keep the slab triangulator for curved surfaces.
  3. T31c: a test with a plate holding 100 circular holes that checks triangle count stays near linear.
- Done when: T31c passes well under the 1M cap.

### T32. Sphere poles and cone apex (M)
- Files: `STEPTessellator.swift`
- Do: instead of throwing in `parametrize`, insert the pole point and add the vertical boundary run at the pole.
- Done when: a hemisphere test tessellates.

### T33. B-spline surface evaluation (M)
- Files: new `STEPBSplineSurface.swift`
- Do:
  1. Parse `B_SPLINE_SURFACE_WITH_KNOTS`, simple and rational complex records.
  2. Evaluate with de Boor in two directions.
  3. Do not tessellate yet. Add unit tests on a bilinear and a bicubic patch.
- Done when: point and normal evaluation match closed-form values.

### T34. Tessellate B-spline faces (L, after T33)
- Files: `Surface.swift`, `STEPTessellator.swift`
- Do: add `.bspline` to `Surface`, then reuse the slab triangulator with row and lattice counts from knot spans.
- Done when: a fillet-like patch face tessellates.

### T35. Extrusion and revolution surfaces (M)
- Files: `Surface.swift`, `STEPTessellator.swift`
- Do: add `SURFACE_OF_LINEAR_EXTRUSION` and `SURFACE_OF_REVOLUTION` for the cases where the swept curve is a line, circle or arc.
- Done when: one test each tessellates.

---

## Phase 4: format coverage

### T40. Simple B-spline curve types (S)
- Files: `STEPCurves.swift`, `STEPBSpline.swift`
- Do: support `BEZIER_CURVE`, `UNIFORM_B_SPLINE_CURVE`, `QUASI_UNIFORM_CURVE` by generating the knot vector, then reuse the existing evaluator.
- Done when: a Bezier fixture matches the Bernstein test.

### T41. `COMPOSITE_CURVE` (M)
- Files: `STEPCurves.swift`
- Do: resolve each `COMPOSITE_CURVE_SEGMENT` through the existing resolver and join the runs, honouring `same_sense`.
- Done when: a two-segment composite edge returns one polyline.

### T42. Assemblies, step 1: don't throw (S)
- Files: `STEPEdgeExtractor.swift`
- Do: replace the assembly throw with a diagnostic. Import the bodies untransformed.
- Done when: a fixture with a `MAPPED_ITEM` imports with a warning.

### T43. Assemblies, step 2: transforms (L, split)
- Split into:
  1. T43a: parse `ITEM_DEFINED_TRANSFORMATION` into a `simd_double4x4`.
  2. T43b: walk `NEXT_ASSEMBLY_USAGE_OCCURRENCE` and `CONTEXT_DEPENDENT_SHAPE_REPRESENTATION` to build instance paths.
  3. T43c: apply the matrices and extend `BodyID` with the instance path.
- Done when: a two-instance fixture yields two bodies at different positions.

### T44. Wireframe bodies (M)
- Files: `STEPEdgeExtractor.swift`, `Model.swift`
- Do: accept `GEOMETRIC_CURVE_SET` items (trimmed curves, polylines). Make `startVertexID` and `endVertexID` optional.
- Done when: a wire-only fixture returns edges.

### T45. Compressed `.stpz` (S)
- Files: `STEP.swift`
- Do: if the data starts with the gzip magic bytes, inflate before parsing (Compression framework).
- Done when: a gzipped fixture parses.

### T46. String escapes (S)
- Files: `STEPTokenizer.swift`
- Do: decode `\X2\…\X0\`, `\X\` and `\S\` in strings. Only matters once names are exposed (T23).
- Done when: a fixture with an escaped name decodes correctly.

---

## Phase 5: performance

Do these only after the tests in Phase 6 exist, so regressions are caught.

### T50. Benchmark harness (S)
- Files: new test or script
- Do: generate a synthetic 50 MB STEP (many planes and circles) and time `STEPFile.init` and a full `read`.
- Done when: it prints timings and peak memory. This becomes the baseline for T51 to T55.

### T51. Byte-scanning indexer (M)
- Files: `STEPFile.swift`, `STEPTokenizer.swift`
- Do: replace `componentRange` with a scanner that tracks only quotes, comments and parentheses.
- Done when: the same entities are indexed and T50 shows a clear speed-up.

### T52. Unsafe-buffer lexing (M)
- Files: `STEPTokenizer.swift`
- Do: scan through `withUnsafeBytes` instead of `Data` subscripting.
- Done when: all tests pass and T50 improves.

### T53. Intern entity types (M)
- Files: `STEPFile.swift`, callers of `hasType` and `entities`
- Do: map type names to small integers at index time and bucket entity IDs by type.
- Done when: `entities(ofTypes:)` no longer scans the whole index.

### T54. Cache eviction (S)
- Files: `STEPFile.swift`
- Do: cap the component cache (for example by entry count) and clear it between bodies.
- Done when: peak memory in T50 drops with identical output.

### T55. Allocation-free de Boor (S)
- Files: `STEPBSpline.swift`
- Do: use `withUnsafeTemporaryAllocation` (or a fixed buffer) in `point(at:)`.
- Done when: the spline tests pass and sampling a dense spline is faster.

### T56. Progress reporting (M)
- Files: `STEP.swift`, `STEPFile.swift`, `STEPEdgeImporter.swift`
- Do: add an optional `progress: (@Sendable (Double) -> Void)?` to `Options` or to `load`, reporting indexing by byte position and then per body.
- Done when: a test sees monotonically increasing values ending at 1.

---

## Phase 6: tests

### T60. Tokenizer tests (S)
- Cover `''` inside strings, comments, `1.`, `.5E3`, a lone `-`, an unterminated string, and an invalid reference.

### T61. File-level tests (S)
- Cover complex entities, a duplicate ID, a truncated file, the nesting limit, an empty file, and the missing `END-ISO-10303-21`.

### T62. Extractor tests (S)
- Cover `adjacentFaceIDs`, `skippedEdgeCount`, determinism across two runs with the same `importID`, and bounds for multiple bodies.

### T63. Tessellator tests (M)
- Cover a box (12 triangles per the slab output), a cylinder, a face with a hole, void-shell orientation, the triangle cap, and failed-face handling.

### T64. Cancellation tests (S)
- Cancel `STEP.load` mid-parse and expect `CancellationError`.

### T65. Real-file corpus (M)
- Add three to five small public STEP files (a NIST model, a multi-body part, a B-spline-heavy part) with golden checks: body count, edge count, bounds, diagnostic count.

### T66. Fuzz test (S)
- Mutate bytes of a valid fixture in a loop and assert that the parser throws or returns, and never traps.

### T67. Linux CI shim (M)
- Add `#if canImport(simd)` wrappers for the few `simd_*` calls so the package builds and tests on Linux.

---

## Suggested first three sessions

1. T01, T02, T03, T04, T05, T07 (all small, one commit each).
2. T10, T11, T60, T61.
3. T20, T22, T24.

After that, pick from Phases 3 and 4 by what your models need most. Assemblies (T42) and partial meshes (T30) are the biggest practical gaps.
