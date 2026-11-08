import Foundation

/// Triangulates one planar region: an outer loop and any number of holes, all in the plane's
/// (u, v) coordinates. Ear clipping with holes joined to the outer loop by bridges, after the
/// public-domain "earcut" algorithm, so no point is ever added: every triangle corner is a
/// boundary vertex, and a face with `n` boundary points and `h` holes comes out as
/// `n + 2h - 2` triangles however many holes there are.
///
/// Why this and not `STEPSlabTriangulator` for planes: the slab sweep cuts the face at every
/// vertex u, so a plate with 100 holes gets long thin triangles and extra points on its outline.
/// A plane needs no interior points at all, and curved faces still do, which is why those keep
/// the slab sweep.
///
/// Limits, all checked: input that is not a simple region (loops that cross or touch, a hole
/// outside the outer loop) can come out wrong, so the result is verified (its triangle areas
/// must add up to the region's area, none may point backwards) and a failed check throws
/// `STEP.ParseError`; the caller falls back to the slab sweep. A boundary point that lies exactly on
/// the line between its two neighbours can be left out of the triangles (the outline stays on the
/// same straight line, so the surface is unchanged, but a neighbouring face that does use the point
/// then meets this one at a T-junction). The search for an ear is quadratic in the
/// worst case; a face with tens of thousands of boundary points is slow, which is why the
/// caller bounds the work through the triangle budget and cancellation.
///
/// Triangles come out counter-clockwise in (u, v), like the slab sweep's.
enum STEPPolygonTriangulator {
    typealias Vertex = STEPSlabTriangulator.Vertex

    /// The signed area of a loop in (u, v), positive when it runs counter-clockwise.
    static func signedArea(_ points: [Vertex]) -> Double {
        guard let origin = points.first else { return 0 }
        var sum = 0.0
        var previous = points[points.count - 1]
        for point in points {
            // Relative to the first point, so a face far from the origin does not lose digits.
            sum += (previous.u - origin.u) * (point.v - origin.v) - (point.u - origin.u) * (previous.v - origin.v)
            previous = point
        }
        return sum / 2
    }

    /// `outer` and each of `holes` are closed loops without a repeated end point, in either
    /// direction. The result's vertices are the used boundary points, unchanged.
    static func triangulate(outer: [Vertex], holes: [[Vertex]], triangleLimit: Int) throws -> STEPSlabTriangulator.Result {
        guard outer.count >= 3 else { throw STEP.ParseError("Face has no boundary") }
        var all = outer
        for hole in holes { all.append(contentsOf: hole) }
        for vertex in all {
            guard vertex.u.isFinite, vertex.v.isFinite else {
                throw STEP.ParseError("Face boundary has nonfinite coordinates")
            }
        }
        let outerArea = abs(signedArea(outer))
        guard outerArea > 0 else { throw STEP.ParseError("Face boundary has no area") }

        var chain = Chain()
        guard var outerNode = chain.addRing(outer, offset: 0, counterClockwise: true) else {
            throw STEP.ParseError("Face has no boundary")
        }
        var rings: [Int] = []
        var offset = outer.count
        for hole in holes {
            if hole.count >= 3, let ring = chain.addRing(hole, offset: offset, counterClockwise: false) {
                rings.append(ring)
            }
            offset += hole.count
        }
        if !rings.isEmpty { outerNode = chain.eliminateHoles(rings, outer: outerNode) }
        try chain.earcutLinked(outerNode, pass: 0)

        // Check the result against what it must be: the outer area minus the holes.
        var expected = outerArea
        for hole in holes { expected -= abs(signedArea(hole)) }
        var covered = 0.0
        for triangle in chain.triangles {
            let a = all[triangle.x], b = all[triangle.y], c = all[triangle.z]
            let area = ((b.u - a.u) * (c.v - a.v) - (c.u - a.u) * (b.v - a.v)) / 2
            guard area >= -1e-9 * outerArea else {
                throw STEP.ParseError("Planar face boundary could not be triangulated (loops cross or touch)")
            }
            covered += area
        }
        guard !chain.triangles.isEmpty, abs(covered - expected) <= 1e-6 * outerArea else {
            throw STEP.ParseError("Planar face boundary could not be triangulated (loops cross or touch)")
        }
        guard chain.triangles.count <= triangleLimit else { throw STEP.ParseError("Triangle limit exceeded") }

        // Only the points the triangles use, in the order they first appear.
        var result = STEPSlabTriangulator.Result()
        var mapped = [Int](repeating: -1, count: all.count)
        result.triangles.reserveCapacity(chain.triangles.count)
        for triangle in chain.triangles {
            var corners = SIMD3<Int>(0, 0, 0)
            for k in 0..<3 {
                let index = triangle[k]
                if mapped[index] < 0 {
                    mapped[index] = result.vertices.count
                    result.vertices.append(all[index])
                }
                corners[k] = mapped[index]
            }
            result.triangles.append(corners)
        }
        return result
    }

    // MARK: Doubly linked rings

    /// All rings share one set of arrays; a node is an index. Splitting a ring at a bridge or a
    /// diagonal creates new nodes for the two ends, which keep their `vertex` (the index into the
    /// caller's point list), so a bridge's two ends emit the same vertex twice.
    private struct Chain {
        var vertex: [Int] = []
        var x: [Double] = []
        var y: [Double] = []
        var prev: [Int] = []
        var next: [Int] = []
        /// A ring of fewer than three points: kept as it is, never filtered away.
        var steiner: [Bool] = []
        var triangles: [SIMD3<Int>] = []
        private var work = 0

        private mutating func add(vertex index: Int, x px: Double, y py: Double) -> Int {
            vertex.append(index)
            x.append(px)
            y.append(py)
            prev.append(-1)
            next.append(-1)
            steiner.append(false)
            return vertex.count - 1
        }

        /// Links `points` as a ring running the wanted way round; returns its first node.
        mutating func addRing(_ points: [Vertex], offset: Int, counterClockwise: Bool) -> Int? {
            guard !points.isEmpty else { return nil }
            let forward = (STEPPolygonTriangulator.signedArea(points) > 0) == counterClockwise
            var first = -1
            var last = -1
            for k in points.indices {
                let i = forward ? k : points.count - 1 - k
                let node = add(vertex: offset + i, x: points[i].u, y: points[i].v)
                if first < 0 {
                    first = node
                } else {
                    next[last] = node
                    prev[node] = last
                }
                last = node
            }
            next[last] = first
            prev[first] = last
            return first
        }

        // MARK: Geometry

        /// Negative when p, q, r turn counter-clockwise (a convex corner of a counter-clockwise ring).
        func area(_ p: Int, _ q: Int, _ r: Int) -> Double {
            (y[q] - y[p]) * (x[r] - x[q]) - (x[q] - x[p]) * (y[r] - y[q])
        }

        func equals(_ a: Int, _ b: Int) -> Bool { x[a] == x[b] && y[a] == y[b] }

        private static func inTriangle(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double,
                                       _ cx: Double, _ cy: Double, _ px: Double, _ py: Double) -> Bool {
            (cx - px) * (ay - py) >= (ax - px) * (cy - py)
                && (ax - px) * (by - py) >= (bx - px) * (ay - py)
                && (bx - px) * (cy - py) >= (cx - px) * (by - py)
        }

        private func onSegment(_ p: Int, _ q: Int, _ r: Int) -> Bool {
            x[q] <= max(x[p], x[r]) && x[q] >= min(x[p], x[r])
                && y[q] <= max(y[p], y[r]) && y[q] >= min(y[p], y[r])
        }

        private static func sign(_ value: Double) -> Int { value > 0 ? 1 : (value < 0 ? -1 : 0) }

        private func intersects(_ p1: Int, _ q1: Int, _ p2: Int, _ q2: Int) -> Bool {
            let o1 = Self.sign(area(p1, q1, p2))
            let o2 = Self.sign(area(p1, q1, q2))
            let o3 = Self.sign(area(p2, q2, p1))
            let o4 = Self.sign(area(p2, q2, q1))
            if o1 != o2 && o3 != o4 { return true }
            if o1 == 0 && onSegment(p1, p2, q1) { return true }
            if o2 == 0 && onSegment(p1, q2, q1) { return true }
            if o3 == 0 && onSegment(p2, p1, q2) { return true }
            if o4 == 0 && onSegment(p2, q1, q2) { return true }
            return false
        }

        /// True when the diagonal a-b leaves node `a` into the ring's inside.
        private func locallyInside(_ a: Int, _ b: Int) -> Bool {
            if area(prev[a], a, next[a]) < 0 {
                return area(a, b, next[a]) >= 0 && area(a, prev[a], b) >= 0
            }
            return area(a, b, prev[a]) < 0 || area(a, next[a], b) < 0
        }

        private func middleInside(_ a: Int, _ b: Int) -> Bool {
            var p = a
            var inside = false
            let px = (x[a] + x[b]) / 2
            let py = (y[a] + y[b]) / 2
            repeat {
                let n = next[p]
                if (y[p] > py) != (y[n] > py), y[n] != y[p],
                   px < (x[n] - x[p]) * (py - y[p]) / (y[n] - y[p]) + x[p] {
                    inside.toggle()
                }
                p = n
            } while p != a
            return inside
        }

        private func intersectsPolygon(_ a: Int, _ b: Int) -> Bool {
            var p = a
            repeat {
                let n = next[p]
                if vertex[p] != vertex[a], vertex[n] != vertex[a], vertex[p] != vertex[b], vertex[n] != vertex[b],
                   intersects(p, n, a, b) { return true }
                p = n
            } while p != a
            return false
        }

        private func isValidDiagonal(_ a: Int, _ b: Int) -> Bool {
            guard vertex[next[a]] != vertex[b], vertex[prev[a]] != vertex[b], !intersectsPolygon(a, b) else { return false }
            if locallyInside(a, b), locallyInside(b, a), middleInside(a, b),
               area(prev[a], a, prev[b]) != 0 || area(a, prev[b], b) != 0 { return true }
            return equals(a, b) && area(prev[a], a, next[a]) > 0 && area(prev[b], b, next[b]) > 0
        }

        /// Whether the corner at `p` opens into the corner at `m`.
        private func sectorContainsSector(_ m: Int, _ p: Int) -> Bool {
            area(prev[m], m, prev[p]) < 0 && area(next[p], m, next[m]) < 0
        }

        // MARK: Editing

        private mutating func removeNode(_ node: Int) {
            next[prev[node]] = next[node]
            prev[next[node]] = prev[node]
        }

        /// Splits the ring in two along a-b; returns the new node that copies b. A node removed
        /// earlier keeps its own links, which the loops below rely on.
        private mutating func splitPolygon(_ a: Int, _ b: Int) -> Int {
            let a2 = add(vertex: vertex[a], x: x[a], y: y[a])
            let b2 = add(vertex: vertex[b], x: x[b], y: y[b])
            let an = next[a]
            let bp = prev[b]
            next[a] = b
            prev[b] = a
            next[a2] = an
            prev[an] = a2
            next[b2] = a2
            prev[a2] = b2
            next[bp] = b2
            prev[b2] = bp
            return b2
        }

        /// Removes duplicate points and points on a straight line between their neighbours.
        private mutating func filterPoints(_ start: Int, _ endNode: Int? = nil) -> Int {
            var end = endNode ?? start
            var p = start
            var again: Bool
            repeat {
                again = false
                if !steiner[p] && (equals(p, next[p]) || area(prev[p], p, next[p]) == 0) {
                    removeNode(p)
                    end = prev[p]
                    p = end
                    if p == next[p] { break }
                    again = true
                } else {
                    p = next[p]
                }
            } while again || p != end
            return end
        }

        // MARK: Holes

        private func leftmost(_ start: Int) -> Int {
            var p = start
            var best = start
            repeat {
                if x[p] < x[best] || (x[p] == x[best] && y[p] < y[best]) { best = p }
                p = next[p]
            } while p != start
            return best
        }

        /// The node of the outer ring to join a hole's leftmost point to: found by a ray to the
        /// left, then the visible point at the smallest angle to that ray.
        private func findHoleBridge(_ hole: Int, _ outer: Int) -> Int? {
            var p = outer
            let hx = x[hole]
            let hy = y[hole]
            var qx = -Double.infinity
            var m = -1
            repeat {
                if equals(hole, p) { return p }
                let n = next[p]
                if hy <= y[p] && hy >= y[n] && y[n] != y[p] {
                    let crossing = x[p] + (hy - y[p]) * (x[n] - x[p]) / (y[n] - y[p])
                    if crossing <= hx && crossing > qx {
                        qx = crossing
                        m = x[p] < x[n] ? p : n
                        if crossing == hx { return m }
                    }
                }
                p = n
            } while p != outer
            guard m >= 0 else { return nil }

            let stop = m
            let mx = x[m]
            let my = y[m]
            var tanMin = Double.infinity
            p = m
            repeat {
                if hx >= x[p] && x[p] >= mx && hx != x[p],
                   Self.inTriangle(hy < my ? hx : qx, hy, mx, my, hy < my ? qx : hx, hy, x[p], y[p]) {
                    let slope = abs(hy - y[p]) / (hx - x[p])
                    if locallyInside(p, hole),
                       slope < tanMin || (slope == tanMin && (x[p] > x[m] || (x[p] == x[m] && sectorContainsSector(m, p)))) {
                        m = p
                        tanMin = slope
                    }
                }
                p = next[p]
            } while p != stop
            return m
        }

        /// Joins every hole to the outer ring, leftmost hole first, and returns a node of the result.
        mutating func eliminateHoles(_ holes: [Int], outer outerNode: Int) -> Int {
            var outer = outerNode
            let xs = x
            let ys = y
            let queue = holes.map { leftmost($0) }.sorted { xs[$0] != xs[$1] ? xs[$0] < xs[$1] : ys[$0] < ys[$1] }
            for hole in queue {
                guard let bridge = findHoleBridge(hole, outer) else { continue }
                let reverse = splitPolygon(bridge, hole)
                _ = filterPoints(reverse, next[reverse])
                outer = filterPoints(bridge, next[bridge])
            }
            return outer
        }

        // MARK: Ear clipping

        private func isEar(_ ear: Int) -> Bool {
            let a = prev[ear]
            let c = next[ear]
            if area(a, ear, c) >= 0 { return false } // reflex or flat
            let ax = x[a], ay = y[a], bx = x[ear], by = y[ear], cx = x[c], cy = y[c]
            let x0 = min(ax, bx, cx), x1 = max(ax, bx, cx)
            let y0 = min(ay, by, cy), y1 = max(ay, by, cy)
            var p = next[c]
            while p != a {
                if x[p] >= x0 && x[p] <= x1 && y[p] >= y0 && y[p] <= y1
                    && !(ax == x[p] && ay == y[p])
                    && Self.inTriangle(ax, ay, bx, by, cx, cy, x[p], y[p])
                    && area(prev[p], p, next[p]) >= 0 { return false }
                p = next[p]
            }
            return true
        }

        /// Tries to cut ears off the ring one by one. When none is left: filter, then cure small
        /// self-intersections, then split along a diagonal (passes 0, 1, 2).
        mutating func earcutLinked(_ start: Int, pass: Int) throws {
            var ear = start
            var stop = ear
            while prev[ear] != next[ear] {
                work += 1
                if work & 255 == 0 { try Task.checkCancellation() }
                let before = prev[ear]
                let after = next[ear]
                if isEar(ear) {
                    triangles.append(SIMD3<Int>(vertex[before], vertex[ear], vertex[after]))
                    removeNode(ear)
                    // Skipping the next corner gives fewer slivers.
                    ear = next[after]
                    stop = next[after]
                    continue
                }
                ear = after
                if ear == stop {
                    switch pass {
                        case 0:
                            try earcutLinked(filterPoints(ear), pass: 1)
                        case 1:
                            let cured = cureLocalIntersections(filterPoints(ear))
                            try earcutLinked(cured, pass: 2)
                        default:
                            try splitEarcut(ear)
                    }
                    break
                }
            }
        }

        private mutating func cureLocalIntersections(_ startNode: Int) -> Int {
            var start = startNode
            var p = start
            repeat {
                let a = prev[p]
                let b = next[next[p]]
                if !equals(a, b) && intersects(a, p, next[p], b) && locallyInside(a, b) && locallyInside(b, a) {
                    triangles.append(SIMD3<Int>(vertex[a], vertex[p], vertex[b]))
                    removeNode(p)
                    removeNode(next[p])
                    start = b
                    p = b
                }
                p = next[p]
            } while p != start
            return filterPoints(p)
        }

        /// Last resort: cut the ring in two along a diagonal that stays inside it, and start over on each half.
        private mutating func splitEarcut(_ start: Int) throws {
            var a = start
            repeat {
                var b = next[next[a]]
                while b != prev[a] {
                    if vertex[a] != vertex[b] && isValidDiagonal(a, b) {
                        var c = splitPolygon(a, b)
                        a = filterPoints(a, next[a])
                        c = filterPoints(c, next[c])
                        try earcutLinked(a, pass: 0)
                        try earcutLinked(c, pass: 0)
                        return
                    }
                    b = next[b]
                }
                a = next[a]
            } while a != start
        }
    }
}
