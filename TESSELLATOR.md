# The tessellator

## What is a tessellator?

A STEP file describes a part with **exact** mathematics: a face is "the part of this infinite cylinder
of radius 8 that lies inside this loop of edges". A GPU cannot draw that. It draws **triangles**.

A *tessellator* is the step that converts the exact description into triangles: it covers every face
with a mesh that is close enough to the real surface to look right.

```
STEP file ──▶ exact B-rep (faces, loops, edges, surfaces) ──▶ tessellator ──▶ triangle mesh
```

A flat face needs only a few triangles. A curved face is approximated by many small flat ones, and
the number is chosen so the mesh never strays from the true surface by more than a tolerance (in this
library, `Options.chordToleranceMM`, default 0.01 mm).

## What it is for in SwiftSTEP

SwiftSTEP is primarily an **edge** reader. The tessellator (`STEPTessellator.swift`, with
`STEPSlabTriangulator.swift`) exists to give a viewer the *filled faces*:

- shaded faces in a viewer, with analytic normals (smooth on a cylinder, crisp at a sharp edge);
- an occluder, so edges hidden behind the part can be drawn dotted or skipped;
- per-face data (`BodyMesh.faces`) to map a picked triangle back to its face and surface.

It is called from `STEPEdgeImporter.parseGeometry` (`STEP.readGeometry` / `STEP.loadGeometry`) after
the edges are extracted, and returns a `STEP.SurfaceModel`.

## How it works here

### 1. Faces come from the body

For every body (`MANIFOLD_SOLID_BREP`, `BREP_WITH_VOIDS`, `SHELL_BASED_SURFACE_MODEL`) it walks
shell → face, remembering whether a shell is reversed (the voids of a `BREP_WITH_VOIDS`).

### 2. Each face is read as "surface + boundary"

A face is a **surface** (`PLANE`, `CYLINDRICAL_SURFACE`, `CONICAL_SURFACE`, `SPHERICAL_SURFACE`,
`TOROIDAL_SURFACE`, `B_SPLINE_SURFACE_WITH_KNOTS`) plus one or more **loops** of edges: an outer loop and
optional hole loops.

### 3. The boundary reuses the wireframe's polylines

The loops are built from the *same sampled edge polylines* that the edge pass produced. That is what
makes faces and drawn edges agree exactly: no gaps or cracks between a face and its outline.
Consecutive edges must meet within 1e-6 mm, otherwise the loop is "not connected".

### 4. The loop is moved into the surface's (u, v) space

Every surface has a 2D parameter space: a plane has (x, y), a cylinder has (angle, height), a sphere
has (longitude, latitude). Each boundary point is projected into it (`Surface.parameters(of:)`).
Working in 2D turns a hard 3D problem into a flat one.

Angles are unwrapped so neighbouring points do not jump by a full turn, and the loop's winding is
counted. This is how it tells these cases apart:

| Case | Example | Handling |
| --- | --- | --- |
| Ordinary closed loop | a rectangle on a plane, a cylinder patch | triangulate as is |
| Loops that straddle the seam | a hole near angle 0 on a cylinder | `align` shifts them by whole turns, or fails with "straddles the periodic seam" |
| Face that goes all the way round | a cylinder between two circles, no seam edge | the two loops are cut to one period |
| Reaches a pole / apex | a full sphere, a cone tip | not supported, the parameters collapse |
| Wraps a torus tube | a full torus face | not supported |

### 5. The slab triangulator fills the 2D region

`STEPSlabTriangulator` takes the boundary segments in (u, v) and fills the region with triangles. It
cuts the region into vertical **slabs** at every vertex and at lattice lines, then fills each slab
with a strip of triangles. Holes work because the segments of all loops are handled together.

The lattice and row spacing come from the surface:

- a plane: no extra points, only the boundary;
- a cylinder, cone, sphere, torus: spacing from the radius and chord tolerance (the angular step is
  chosen so the chord's sagitta stays under `chordToleranceMM`);
- a B-spline surface: divisions probed from the surface itself.

### 6. Points go back to 3D, with normals

Each (u, v) vertex is evaluated on the exact surface for its 3D position. The normal is the surface's
analytic normal, flipped when the face's `same_sense` is false or the shell is reversed. The
triangle winding is flipped the same way, so normal and winding always agree.

The result is stored per body in `STEP.BodyMesh`: `positions`, `normals`, `indices`, and a `faces`
table that maps triangle ranges back to face IDs. Positions are `Float`, relative to
`SurfaceModel.origin`.

## All or nothing per body

If **any** face of a body cannot be tessellated, the **whole body gets no mesh**
(`SurfaceModel.unsurfacedBodies`). The reason is the occluder use: a partial mesh would make visible
edges look hidden. The edges still load and draw.

That is why a model can show only a wireframe even though 99% of its faces were fine: one
unsupported face is enough.

Limits: one million triangles per import (`STEPTessellator.maximumTriangles`).

## Finding out why a model is not filled

Everything the tessellator could not do is reported:

```swift
let geometry = try STEP.readGeometry(contentsOf: url)
print(geometry.report)
```

`report` prints edge and face counts, then, for each body with no mesh, the failed faces grouped by
surface type and reason, with a hint:

```
Edges: 75 extracted, 0 skipped (75 reachable), 1 body
Faces: 0 filled, 3 failed, 48 reachable; 0 triangles

1 body has no filled faces (one failing face drops its whole body, ...):
  Body #1234
    2 faces on SURFACE_OF_REVOLUTION: Unsupported surface type SURFACE_OF_REVOLUTION at #77
      faces #90, #92
      → SwiftSTEP only meshes planes, cylinders, cones, spheres, tori and B-spline surfaces. ...
    1 face on SPHERICAL_SURFACE: Face reaches a pole or apex of its sphere; not supported yet
      faces #101
      → The face touches a sphere pole or cone tip, ...
```

Programmatic access: `geometry.surfaces.faceFailures` (body, face, surface entity and type, reason),
`unsurfacedBodies`, `failedFaceCount`, and `surfaces.diagnostics`.

The demo prints the same report to stderr on every load and shows it from the toolbar's info button.

### Common reasons

| Message | Meaning |
| --- | --- |
| `Unsupported surface type X` | Swept, offset or other surface kind with no tessellator |
| `Boundary edge #N has no extracted geometry` | The wireframe skipped that edge; the report appends the edge's own note |
| `Face loop is not connected` / `not closed` | Gap between edges larger than 1e-6 mm |
| `Face boundary lies N mm off its <surface>` | Boundary is not on the surface (damaged file or loose tolerance) |
| `Face reaches a pole or apex` | Sphere pole or cone tip inside the face |
| `Face wraps round the ... tube / axis` | Torus tube wrap, or an unusual axis wrap |
| `Face loop straddles the periodic seam` | A hole crosses the seam of a cylinder, cone, sphere or torus |
| `Triangle limit exceeded` | Over one million triangles; raise `chordToleranceMM` |
| `Unsupported face type / bound / loop type` | `ORIENTED_FACE`, vertex or poly loops, etc. |
| `Unsupported B-spline surface layout` / `... not supported yet` | No explicit knots, closed, or collapsed side |

## Where to look in the code

| File | Role |
| --- | --- |
| `STEPTessellator.swift` | Bodies, faces, surfaces, loops, (u, v) mapping, mesh assembly, failure reporting |
| `STEPSlabTriangulator.swift` | Fills a 2D region with triangles |
| `Surface.swift`, `BSplineSurface.swift` | Exact surfaces: point, normal, parameters |
| `Mesh.swift` | `BodyMesh`, `FaceMesh`, `SurfaceModel`, `FaceFailure` |
| `Model.swift` | `Diagnostic`, `Geometry.report` |
