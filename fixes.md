# SwiftSTEP: improvement tasks

Each task is small and self-contained, so it can be done in one short session.

**How to keep sessions cheap**
- Do one task per session. Attach only the files listed under "Files".
- Tasks marked **S** need a few edits. **M** is one focused change. **L** should be split further before starting.
- Tasks inside a phase are mostly independent. Phases are ordered by value per effort.
- Nothing here was built or run during the review (no Swift toolchain), so each task ends with "Done when" that you can check with `swift test`.

---

## Phase 0: quick wins (all S)

### T01. Remove `indirect` from `STEPValue` — DONE
- Files: `STEPValue.swift`
- Why: `indirect enum` boxes every case, including `.integer` and `.real`. `[STEPValue]` is already heap-backed.
- Do: delete the `indirect` keyword and build.
- Done when: it compiles, existing tests pass, memory use on a large file drops.
- Status: done. `indirect` removed. Not built or run (no Swift toolchain here): run `swift test`.

### T02. Fix operator precedence in `STEPUnits.scale` — DONE
- Files: `STEPUnits.swift`
- Why: `A || B && count == 2` skips the count check for `MEASURE_WITH_UNIT`. The angle version has parentheses.
- Do: add the parentheses. Better, merge `scale` and `angleScale` into one function parameterised by unit type and base unit.
- Done when: the unit tests still pass and the two paths share one implementation.
- Status: done. `scale`/`angleScale` merged into one `Kind`-driven function; parentheses bug gone. Phase 0 tests: unit tests unchanged. Not built or run (no Swift toolchain here): run `swift test`.

### T03. Skip a UTF-8 BOM at the start of the file — DONE
- Files: `STEPTokenizer.swift` (or `STEPFile.init`)
- Do: if the first three bytes are `EF BB BF`, start after them.
- Done when: a test with a BOM-prefixed fixture parses.
- Status: done. Test `byteOrderMarkIsSkipped`. Not built or run (no Swift toolchain here): run `swift test`.

### T04. Tolerate user-defined keywords (`!NAME(...)`) — DONE
- Files: `STEPTokenizer.swift`, `STEPFile.swift`
- Do: lex `!` followed by letters as a `.word`. Index it like any other entity. It is ignored by the extractor.
- Done when: a fixture containing `#9=!MY_ENTITY('x');` imports without throwing.
- Status: done. Test `userDefinedKeywordsAreIndexedAndIgnored`. Not built or run (no Swift toolchain here): run `swift test`.

### T05. Add the missing `LINE` vertex check — DONE
- Files: `STEPCurves.swift`
- Do: measure the distance from both vertices to the line. If it is above tolerance, throw the same kind of "vertex not on curve" error the other curves use.
- Done when: a test with an off-line vertex is skipped with a diagnostic.
- Status: done. Test `vertexOffItsLineIsSkippedWithADiagnostic` (message "not on its line"). Not built or run (no Swift toolchain here): run `swift test`.

### T06. Make the entity cap an option — DONE
- Files: `Model.swift` (`Options`), `STEPFile.swift`, `STEP.swift`
- Do: add `maximumEntityCount` (default 2,000,000) to `STEP.Options` and pass it to `STEPFile`.
- Done when: a test lowering the cap hits the error and the default behaviour is unchanged.
- Status: done. `Options.maximumEntityCount`; test `entityCapIsAnOption`. Not built or run (no Swift toolchain here): run `swift test`.

### T07. Public initializers and conformances — DONE
- Files: `Model.swift`, `Mesh.swift`, `Surface.swift`
- Do: add public inits for `Edge`, `BodyInfo`, `Diagnostic`, `Frame`, `FaceMesh`. Make `Edge` `Identifiable`. Make `chordError` a `let`. Make `Diagnostic` `Equatable` and `CustomStringConvertible`.
- Done when: an external target can construct these types in a test.
- Status: done. Public inits, `Edge: Identifiable`, `chordError` is a `let`, `Diagnostic: Equatable`; test `publicTypesCanBeConstructedAndCompared`. Not built or run (no Swift toolchain here): run `swift test`.

---

## Phase 1: errors, diagnostics and tolerances

### T10. Typed `ParseError` (M) — DONE
- Files: `Model.swift`, then each `throw STEP.ParseError("...")` site
- Do:
  1. Add `enum Kind` with `.notSTEP`, `.truncated`, `.malformed`, `.assembly`, `.unresolvedUnits(contextID: Int)`, `.limitExceeded`, `.invalidOptions`.
  2. Keep `description`.
  3. Convert only the file-level throws in `STEPFile` and `STEPEdgeExtractor.extract` first.
  4. Leave per-edge and per-face errors as `.malformed` for now.
- Done when: a test can branch on `.unresolvedUnits` without matching text.
- Status: done. `ParseError.Kind` with all seven cases. Converted: `STEPFile`, `STEPTokenizer`, `STEPEdgeExtractor.extract`, tessellator options check. Tests: `fileLevelErrorsCarryAKind`, `unresolvedUnitsCanBeToldApartWithoutMatchingText`. Not built or run (no Swift toolchain here): run `swift test`.

### T11. `Diagnostic` severity and code (S) — DONE
- Files: `Model.swift`, `diagnose` calls in `STEPEdgeExtractor.swift` and `STEPTessellator.swift`
- Do: add `severity` (`info`, `warning`, `skipped`) and a short `code` string (`"unsupported-curve"`, `"chord-cap"`, …) to `Diagnostic`.
- Done when: existing diagnostics carry a code and the tests still pass.
- Status: done. `Diagnostic.severity` (`info`/`warning`/`skipped`) and `code`. Codes: `assumed-units`, `topology-cycle`, `unsupported-topology`, `unsupported-curve`, `vertex-off-curve`, `edge-skipped`, `chord-cap`, `no-bodies`, `no-edges`, `body-unsurfaced`, `no-faces`, `face-failed`, `body-unfilled`, `zero-triangles`, `surfaces-unavailable`. Test: `diagnosticsCarrySeverityAndCode`. Not built or run (no Swift toolchain here): run `swift test`.

### T12. Read the file's uncertainty (M) — DONE
- Files: `STEPUnits.swift`, new `STEPTolerances.swift`
- Do:
  1. Read `GLOBAL_UNCERTAINTY_ASSIGNED_CONTEXT` and `UNCERTAINTY_MEASURE_WITH_UNIT` and scale to mm.
  2. Expose it from `STEPUnits`.
  3. Fall back to today's defaults when it is absent.
- Done when: a test with a declared uncertainty returns the scaled value.
- Status: done. `STEPUnits.uncertaintyMM(contextID:)`, new `STEPTolerances.swift`, `BodyInfo.uncertaintyMM`. Test: `declaredUncertaintyIsScaledToMillimetres`. Not built or run (no Swift toolchain here): run `swift test`.

### T13. Replace scattered tolerance constants (M, after T12) — DONE
- Files: `STEPCurves.swift`, `STEPTessellator.swift`
- Do: replace `connectionTolerance (1e-6)`, `relativeVertexTolerance (1e-4)` and `angularTolerance (1e-3)` with values derived from one `Tolerances` struct.
- Done when: all current tests pass unchanged, and a new test shows two vertices a few microns apart still close a loop.
- Status: done. `STEPTolerances` replaces `connectionTolerance`, `relativeVertexTolerance`, `angularTolerance`. The connection tolerance follows the declared accuracy (capped at the chord tolerance); without one it stays 1e-6. Tests: `verticesAFewMicronsApartCloseALoopWhenTheFileSaysSo`, `tolerancesDeriveFromOnePlace`. Not built or run (no Swift toolchain here): run `swift test`.

### T14. Header metadata (S) — DONE
- Files: `STEPFile.swift`, `Model.swift`, `STEPEdgeImporter.swift`
- Do: keep the header records. Parse `FILE_SCHEMA` and `FILE_NAME` into `STEP.Header` (schema, name, originating system, timestamp). Add `header` to `EdgeModel`.
- Done when: a fixture's schema and file name come back in the model.
- Status: done. `STEP.Header` on `EdgeModel.header`. Tests: `headerComesBackInTheModel`, `headerFieldsAreFilledWhenPresent`. Not built or run (no Swift toolchain here): run `swift test`.

---

## Phase 2: better output for CAM

### T20. Seam flag on edges (S) — DONE
- Files: `STEPEdgeExtractor.swift`, `Model.swift`
- Do: during `collectEdges`, count how many times each face uses an edge. Add `isSeam` (the same face uses it twice) to `Edge`.
- Done when: the cylinder test shows exactly one seam edge.
- Status: done. `Edge.isSeam`; `collectEdges` now counts uses per face before its visited check. Tests: the cylinder test (one seam, the line), `aBoxHasNoSeams`. Not built or run (no Swift toolchain here): run `swift test`.

### T21. Analytic curve data on edges (M) — DONE
- Files: `STEPCurves.swift`, `Model.swift`
- Do:
  1. Add `Edge.curve` with `.line`, `.circle(frame, radius, startAngle, sweep)`, `.ellipse(...)`, `.other`.
  2. Fill it for lines and circles first, from data `resolveConic` already computes.
  3. Leave ellipse and B-spline as `.other`.
- Done when: the box, cylinder and arc tests can read radius, centre and axis from edges.
- Status: done. `Edge.Curve` (`.line`, `.circle(frame:radius:startAngle:sweep:)`, `.ellipse` reserved, `.other`), filled for lines and circles from `arcSpan`/`conicGeometry`. `STEP.Frame` is now `Equatable`. Tests: cylinder test, `arcsKeepTheirFrameRadiusAndSweep`, `circleFrameFollowsAMovedPlacement`, `ellipsesAndSplinesStayOther`. Not built or run (no Swift toolchain here): run `swift test`.

### T22. Per-body bounds (S) — DONE
- Files: `STEPEdgeExtractor.swift`, `Model.swift`
- Do: add `bounds` to `BodyInfo`, computed from that body's edge points.
- Done when: a two-body fixture reports two different boxes.
- Status: done. `BodyInfo.bounds` (`nil` when no edge was extracted); `EdgeModel.bounds` is the union. Tests: `eachBodyReportsItsOwnBounds`, `aBodyWithoutExtractedEdgesHasNoBounds`. Not built or run (no Swift toolchain here): run `swift test`.

### T23. Body and part names (S) — DONE
- Files: `STEPEdgeExtractor.swift`, `Model.swift`
- Do: read the name string of the body entity and expose it as `BodyInfo.name`.
- Done when: a fixture with a named brep returns the name.
- Status: done. `BodyInfo.name` is the body entity's first parameter (`nil` when `$` or empty). Complex-record bodies are not supported by the extractor at all, so only the plain record is read. Test: `bodyNamesAreRead` (including a `BREP_WITH_VOIDS`). Not built or run (no Swift toolchain here): run `swift test`.

### T24. Face topology output, step 1: faces without tessellation (M) — DONE
- Files: new `STEPFaces.swift`, `Model.swift`
- Do:
  1. Add `STEP.Face` with `id`, `bodyID`, `sameSense`, `surface: Surface?` and `surfaceTypeName`.
  2. Reuse `parseFace` and `parseSurface` from the tessellator, moved into a shared helper.
  3. Add `EdgeModel.faces` or a separate `readTopology` entry point.
- Done when: a body with one unsupported face still lists all its other faces with their surfaces.
- Status: done. New `STEPFaces.swift`: `STEPFaceReader` holds `collectFaces`, `parseFace`, `parseSurface` (moved out of the tessellator, which now calls it). Separate entry point `STEP.readTopology` / `loadTopology` returning `STEP.Topology` (`edges` plus `faces`), so `read` pays nothing. `Face` has `isShellReversed` as well, because void-shell faces need it to find the material side. Diagnostic codes: `unsupported-surface` (warning), `face-skipped`, `body-unfaced` (skipped). Tests: `aBoxListsItsFacesWithTheirPlanes`, `anUnsupportedFaceDoesNotHideTheOthers`, `voidShellFacesAreMarkedReversed`, `facesFollowTheBodyOrder`. Not built or run (no Swift toolchain here): run `swift test`.

### T25. Face topology output, step 2: loops (M, after T24) — DONE
- Files: `STEPFaces.swift`
- Do: add `loops: [[OrientedEdgeRef]]` (edge ID plus orientation) and `outerLoopIndex` to `Face`.
- Done when: the box test shows 6 faces with 4-edge outer loops.
- Status: done. `Face.loops: [[OrientedEdgeRef]]` (`EdgeID` plus direction) and `outerLoopIndex`. A bound written `.F` is reversed with every use flipped. `outerLoopIndex` is `nil` when no bound is a FACE_OUTER_BOUND (nothing is guessed). A face with an unreadable bound lists no loops and gets a `face-loops-unreadable` warning. Tests: `theBoxHasSixOuterLoopsOfFourEdges`, `holesAreListedAfterTheOuterLoop`, `aBoundWrittenBackwardsIsReversed`, `anUnmarkedOuterBoundIsNotGuessed`, `unreadableLoopsAreReportedNotHalfListed`. Not built or run (no Swift toolchain here): run `swift test`.

---

## Phase 3: tessellation robustness

### T30. Keep partial meshes (M) — DONE
- Files: `STEPTessellator.swift`, `Mesh.swift`, `Model.swift`
- Why: a missing face can only under-occlude, so dropping the whole body is more pessimistic than needed.
- Do: when a face fails, keep the faces that worked. Mark the body `isPartial` and list failed face IDs in `SurfaceModel`. Keep the current behaviour behind an option for callers that want it.
- Done when: a body with one bad face returns a mesh plus the failed face ID.
- Status: done. Partial meshes are the new default: `BodyMesh.isPartial` / `failedFaceIDs`, `SurfaceModel.partialBodies`, diagnostic `body-partial`, `Geometry.report` lists them. `Options.keepPartialSurfaces = false` restores all-or-nothing. A body whose every face fails still has no mesh. Existing tests that asserted the old behaviour now pass the option; the Phase 2 unsupported-face test and `boundaryThatLeavesTheSurface...` assert the partial result. Not built or run (no Swift toolchain here): run `swift test`.

### T31. Proper triangulation for planar faces (L, split) — DONE
- Files: new `STEPPolygonTriangulator.swift`, `STEPTessellator.swift`
- Split into:
  1. T31a: ear-clipping with holes (earcut-style) for one outer loop plus holes, with tests on a square-with-hole.
  2. T31b: route `.plane` faces to it and keep the slab triangulator for curved surfaces.
  3. T31c: a test with a plate holding 100 circular holes that checks triangle count stays near linear.
- Done when: T31c passes well under the 1M cap.
- Status: done. `STEPPolygonTriangulator.swift` is an earcut port (holes joined by bridges, then ear clipping with the filter, cure and split fallbacks). It adds no points, so `n` boundary points and `h` holes give `n + 2h - 2` triangles. Its result is verified (triangle areas must equal outer area minus holes, none backwards); a failed check throws and the tessellator falls back to the slab sweep for that plane. `.plane` faces use it, every curved surface still uses the slab sweep. Known limit: a boundary point exactly on a straight run may be left out of the triangles (a T-junction with a neighbour that uses it); the ear search is quadratic, with no z-order hashing. Tests: `STEPPolygonTriangulatorTests` (T31a), `aFaceWithACircularHoleLeavesTheHoleOpen` (T31b), `aPlateWithAHundredHolesStaysNearLinear` (T31c). The algorithm was checked in a Python port first (random holes, 100-hole grid, rows, columns, invalid inputs). Not built or run (no Swift toolchain here): run `swift test`.

### T32. Sphere poles and cone apex (M) — DONE
- Files: `STEPTessellator.swift`
- Do: instead of throwing in `parametrize`, insert the pole point and add the vertical boundary run at the pole.
- Done when: a hemisphere test tessellates.
- Status: done. Most of it was already in `parametrize` (a pole vertex becomes two points, a seam edge out to the pole and back marks the pole as inside) but had no test. New: a cap written as one circle with no seam edge (a dome, a cone tip with no apex vertex) used to fail; `enclosedPole` now reads which pole (or apex) it contains from the loop's direction and the face's `same_sense`, and refuses a cone whose apex is behind the loop. A cylinder or torus with one wrapping loop is still refused. Tests: `aHemisphereWithASeamToThePoleIsFilled`, `aDomeWrittenAsOneCircleContainsThePoleItsDirectionPointsTo`, `theSameDomeTurnedInsideOutIsTheSameRegionWithTheOppositeVolume`, `aConeTipWithNoSeamAndNoApexVertexIsFilled`, `aSingleCircleOnACylinderStillHasNoPoleToFill`. Not built or run (no Swift toolchain here): run `swift test`.

### T33. B-spline surface evaluation (M) — DONE
- Files: new `STEPBSplineSurface.swift`
- Do:
  1. Parse `B_SPLINE_SURFACE_WITH_KNOTS`, simple and rational complex records.
  2. Evaluate with de Boor in two directions.
  3. Do not tessellate yet. Add unit tests on a bilinear and a bicubic patch.
- Done when: point and normal evaluation match closed-form values.
- Status: already in the package before this session (`BSplineSurface.swift`, `BSplineSurfaceTests`): simple and rational complex records, point and normal evaluation. Nothing changed.

### T34. Tessellate B-spline faces (L, after T33) — DONE
- Files: `Surface.swift`, `STEPTessellator.swift`
- Do: add `.bspline` to `Surface`, then reuse the slab triangulator with row and lattice counts from knot spans.
- Done when: a fillet-like patch face tessellates.
- Status: already in the package before this session: `Surface.bspline`, slab triangulator with divisions probed from the surface, `FreeformSolidTests`. Not covered: B-splines without explicit knots, closed or collapsed-side surfaces (refused with a reason).

### T35. Extrusion and revolution surfaces (M)
- Files: `Surface.swift`, `STEPTessellator.swift`
- Do: add `SURFACE_OF_LINEAR_EXTRUSION` and `SURFACE_OF_REVOLUTION` for the cases where the swept curve is a line, circle or arc.
- Done when: one test each tessellates.
- Status: NOT done. Finding: both entities already work when the swept curve is a B-spline (`parseSurfaceOfLinearExtrusion`, `parseSurfaceOfRevolution` turn them into a `.bspline` surface); only line, circle and arc profiles are refused. Mapping those onto the analytic surfaces needs care with orientation, because a `Surface` cannot be inside out (only the face's `same_sense` can): an extruded circle against its own axis, or a revolved line, would come out with the normal reversed. Most CAD systems write these shapes as PLANE, CYLINDRICAL_SURFACE, CONICAL_SURFACE or TOROIDAL_SURFACE anyway. Better done with a real file that needs it and a toolchain to run the test.

---

## Phase 4: format coverage

### T40. Simple B-spline curve types (S) — DONE
- Files: `STEPCurves.swift`, `STEPBSpline.swift`
- Do: support `BEZIER_CURVE`, `UNIFORM_B_SPLINE_CURVE`, `QUASI_UNIFORM_CURVE` by generating the knot vector, then reuse the existing evaluator.
- Done when: a Bezier fixture matches the Bernstein test.
- Status: done. Simple and complex records of the three types; knots are generated (Bezier needs exactly degree + 1 points). Tests: `bezierCurveMatchesTheBernsteinForm`, `quasiUniformCurveIsClampedWithEvenInteriorKnots`, `uniformCurveStartsAndEndsAwayFromItsEndControlPoints`, `aBezierCurveWithTheWrongPointCountIsSkippedWithAReason`. Not built or run (no Swift toolchain here): run `swift test`.

### T41. `COMPOSITE_CURVE` (M) — DONE
- Files: `STEPCurves.swift`
- Do: resolve each `COMPOSITE_CURVE_SEGMENT` through the existing resolver and join the runs, honouring `same_sense`.
- Done when: a two-segment composite edge returns one polyline.
- Status: done. `Edge.CurveKind.composite`. A segment needs trim points (cartesian) or a bounded curve (polyline, B-spline); parameter-only trims, untrimmed lines and nested composites are skipped with a reason. Segments must meet within the connection tolerance. Tests in `STEPPhase4Tests`: two segments, `same_sense` false, reversed edge, gap, vertex mismatch. Not built or run (no Swift toolchain here): run `swift test`.

### T42. Assemblies, step 1: don't throw (S) — DONE
- Files: `STEPEdgeExtractor.swift`
- Do: replace the assembly throw with a diagnostic. Import the bodies untransformed.
- Done when: a fixture with a `MAPPED_ITEM` imports with a warning.
- Status: done. The throw became an `assembly-untransformed` warning; `ParseError.Kind.assembly` stays but is no longer thrown. `fileLevelErrorsCarryAKind` updated; test `aMappedItemImportsWithAWarning`. Not built or run (no Swift toolchain here): run `swift test`.

### T43. Assemblies, step 2: transforms (L, split)
- Split into:
  1. T43a: parse `ITEM_DEFINED_TRANSFORMATION` into a `simd_double4x4`.
  2. T43b: walk `NEXT_ASSEMBLY_USAGE_OCCURRENCE` and `CONTEXT_DEPENDENT_SHAPE_REPRESENTATION` to build instance paths.
  3. T43c: apply the matrices and extend `BodyID` with the instance path.
- Done when: a two-instance fixture yields two bodies at different positions.

### T44. Wireframe bodies (M) — DONE
- Files: `STEPEdgeExtractor.swift`, `Model.swift`
- Do: accept `GEOMETRIC_CURVE_SET` items (trimmed curves, polylines). Make `startVertexID` and `endVertexID` optional.
- Done when: a wire-only fixture returns edges.
- Status: done. `GEOMETRIC_CURVE_SET` bodies (also in `GEOMETRICALLY_BOUNDED_WIREFRAME_SHAPE_REPRESENTATION`); `Edge.startVertexID`/`endVertexID` are now `Int?`, which changes the type for existing callers. The tessellator and `readTopology` skip wire bodies silently. Tests: `aWireOnlyFileReturnsItsCurvesAsEdges`, `aBareCircleInACurveSetIsAFullCircle`, `anUntrimmedLineHasNoEndsAndIsSkippedWithAReason`. Not built or run (no Swift toolchain here): run `swift test`.

### T45. Compressed `.stpz` (S) — DONE
- Files: `STEP.swift`
- Do: if the data starts with the gzip magic bytes, inflate before parsing (Compression framework).
- Done when: a gzipped fixture parses.
- Status: done. `STEPGzip.inflateIfGzip` (header parsed by hand, deflate via `NSData.decompressed(using: .zlib)`), used by every entry point. The trailer CRC is not verified; the declared size is capped at 1 GiB and checked again afterwards, but a stream that lies about its size is only caught after inflating. Non-Apple platforms throw. Tests: `aGzippedFileParsesLikeThePlainOne`, `brokenGzipIsRefusedWithAnError`. Not built or run (no Swift toolchain here): run `swift test`.

### T46. String escapes (S) — DONE
- Files: `STEPTokenizer.swift`
- Do: decode `\X2\…\X0\`, `\X\` and `\S\` in strings. Only matters once names are exposed (T23).
- Done when: a fixture with an escaped name decodes correctly.
- Status: done. `STEPStringEscapes.decode` in the tokenizer: `\X2\`, `\X4\`, `\X\hh`, `\S\c`, `\\`; `\Pn\` dropped; malformed sequences kept as written. Tests: `stringEscapesAreDecoded`, `anEscapedNameIsDecodedInTheModel`. Not built or run (no Swift toolchain here): run `swift test`.

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

### T60. Tokenizer tests (S) — DONE
- Cover `''` inside strings, comments, `1.`, `.5E3`, a lone `-`, an unterminated string, and an invalid reference.
- Status: done in `STEPTokenizerAndFileTests.swift` (`STEPTokenizerTests`): doubled quotes, comments (also inside strings, unterminated, `/*/`), every number spelling and malformed or overflowing ones, enumerations, references (`#`, `#0`, `#-1`, overflow), words and `!KEYWORD`, every symbol and unexpected bytes, a whole record, the token size limit, a tokenizer over a sub-range. These assume `Double("1.")` and `Double("2.E0")` parse; if one does not, that is a real tokenizer bug. Not built or run (no Swift toolchain here): run `swift test`.

### T61. File-level tests (S) — DONE
- Cover complex entities, a duplicate ID, a truncated file, the nesting limit, an empty file, and the missing `END-ISO-10303-21`.
- Status: done in the same file (`STEPFileStructureTests`): complex entities (and their 128-component cap, repeated or empty ones), duplicate IDs, the entity cap, nesting at 128 and 129, empty and foreign files (`.notSTEP`), truncation at each stage (`.truncated`), the closing lines, every shorter prefix of a valid file being refused, malformed records (`.malformed`), lazy parameter grammar errors, lookups of what is not there. Not built or run (no Swift toolchain here): run `swift test`.

### T62. Extractor tests (S) — DONE
- Cover `adjacentFaceIDs`, `skippedEdgeCount`, determinism across two runs with the same `importID`, and bounds for multiple bodies.
- Status: done in `STEPExtractorTests.swift`: a box's edges each name two different faces and each face is named by four edges, a face with a hole, skipped and unreachable edges, three runs with one `importID` giving identical edges, bodies, diagnostics and bounds, a new `importID` changing only the IDs, edge order, bounds over three bodies across zero, `workpieceOrigin`. Not built or run (no Swift toolchain here): run `swift test`.

### T63. Tessellator tests (M) — DONE
- Cover a box (12 triangles per the slab output), a cylinder, a face with a hole, void-shell orientation, the triangle cap, and failed-face handling.
- Status: done in `STEPTessellatorTests.swift`: box (12 triangles, volume, winding, face ranges), flipped `same_sense`, cylinder (volume, radial normals, tolerance), face with a hole, void shell (volume 5936), unsupported face (partial and strict), triangle cap. The cap needed a way in, so `Options.maximumTriangleCount` (default 1,000,000) is new. `LengthUnit`, `AngleUnit`, `StepBuilder` and `boxBody` in `STEPCurveTests.swift` lost `private` so the new files can use them. Not built or run (no Swift toolchain here): run `swift test`.

### T64. Cancellation tests (S) — DONE
- Cancel `STEP.load` mid-parse and expect `CancellationError`.
- Status: done in `STEPRobustnessTests.swift` (`STEPCancellationTests`). A true mid-parse cancel is a race, so the strict tests start the task already cancelled (it spins until `isCancelled`, then calls the importer) and expect `CancellationError` from `load`, `loadGeometry`, `loadTopology` and the three synchronous readers. One test cancels 5 ms into a 16 MB file and accepts either `CancellationError` or a finished model, but never another error. Not built or run (no Swift toolchain here): run `swift test`.

### T65. Real-file corpus (M)
- Add three to five small public STEP files (a NIST model, a multi-body part, a B-spline-heavy part) with golden checks: body count, edge count, bounds, diagnostic count.

### T66. Fuzz test (S) — DONE
- Mutate bytes of a valid fixture in a loop and assert that the parser throws or returns, and never traps.
- Status: done in `STEPRobustnessTests.swift` (`STEPFuzzTests`). Seeded SplitMix64, so a run repeats exactly. Mutations: bit flip, replace, delete, insert, cut short, repeat a chunk, and swapping a number for an extreme one (huge, zero, negative, overflow). Fixture: box, cylinder, sphere cap, ellipse, polynomial and rational spline, polyline. Four seeds x 300 mutations of that, 500 of a box, about 150 prefixes, and 5,000 random buffers through `STEPFile` and the tokenizer; `STEP_FUZZ_ITERATIONS=10` multiplies the counts. Every input is written to `swiftstep-fuzz-last-input.step` in the temp folder first, because a trap cannot be caught: if a run dies, that file is the input that killed it. This test is expected to find real bugs (a huge multiplicity or count is the likeliest). Not built or run (no Swift toolchain here): run `swift test`.

### T67. Linux CI shim (M)
- Add `#if canImport(simd)` wrappers for the few `simd_*` calls so the package builds and tests on Linux.

---

## Suggested first three sessions

1. T01, T02, T03, T04, T05, T07 (all small, one commit each).
2. T10, T11, T60, T61.
3. T20, T22, T24.

After that, pick from Phases 3 and 4 by what your models need most. Assemblies (T42) and partial meshes (T30) are the biggest practical gaps.
