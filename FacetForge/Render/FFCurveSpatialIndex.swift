import CoreGraphics
import Foundation

/// A screen-space grid over the segments of a set of curves.
///
/// Phase 14's analytic picker walks every segment of every curve for each
/// query, which is the right answer for a handful of curves and the wrong one
/// for a curve with ten thousand spans: a hover trace pays the whole polyline
/// per pointer sample. This index projects each curve once, puts every segment
/// into the grid cells its screen bounds touch, and answers a query from the
/// cells within the pick tolerance plus a short list of segments too long to
/// bucket. The result is the same curve the linear picker returns, including on
/// ties, because both pick the nearest segment and the earliest curve wins at
/// equal distance.
///
/// Build it when the camera, viewport or curve set changes; pick many times
/// against it. A segment whose projected bounds are not finite is kept in the
/// always-tested list instead of being bucketed, so a far-off-screen span can
/// never make the integer cell math overflow.
struct FFCurveSpatialIndex {
    private struct Segment {
        let curve: Int
        let start: Vec2
        let end: Vec2
    }

    private struct Cell: Hashable {
        let x: Int
        let y: Int
    }

    let curves: [FFPickCurve]
    let cellSize: Double
    let indexBuildNanoseconds: UInt64
    /// The projected screen points per curve. Empty when that curve could not
    /// be projected, which is the same condition under which the linear picker
    /// skips it.
    let projected: [[Vec2]]

    private let segments: [Segment]
    private let cells: [Cell: [Int]]
    private let unbucketed: [Int]

    /// Cell extent beyond which a segment is simply always tested. A span that
    /// covers more screen than this is one straight edge, so testing it is
    /// cheaper than filling thousands of cells with it.
    private static let maximumCellExtent = 16
    /// Beyond this projected coordinate the cell arithmetic is not worth
    /// trusting; the segment goes to the always-tested list instead.
    private static let coordinateLimit = 1_000_000_000.0
    /// A query box covers at most this many cells before the index gives up on
    /// bucketing and tests every segment, which keeps a huge tolerance honest
    /// rather than silently missing hits.
    private static let maximumQueryExtent = 512

    init?(
        curves: [FFPickCurve],
        camera: FFCamera,
        viewport: Vec2,
        cellSize: Double = 16
    ) {
        guard viewport.x > FFMath.eps,
              viewport.y > FFMath.eps,
              cellSize.isFinite,
              cellSize >= 4
        else {
            return nil
        }

        let began = DispatchTime.now().uptimeNanoseconds
        var projected: [[Vec2]] = []
        projected.reserveCapacity(curves.count)
        var segments: [Segment] = []
        var cells: [Cell: [Int]] = [:]
        var unbucketed: [Int] = []

        for (curveIndex, curve) in curves.enumerated() {
            guard curve.points.count >= 2 else {
                projected.append([])
                continue
            }
            var screen: [Vec2] = []
            screen.reserveCapacity(curve.points.count)
            var projectable = true
            for world in curve.points {
                guard let point = camera.screenPoint(for: world, viewport: viewport),
                      point.x.isFinite,
                      point.y.isFinite,
                      abs(point.x) < Self.coordinateLimit,
                      abs(point.y) < Self.coordinateLimit
                else {
                    projectable = false
                    break
                }
                screen.append(point)
            }
            guard projectable else {
                projected.append([])
                continue
            }
            projected.append(screen)

            let edgeCount = curve.isClosed ? screen.count : screen.count - 1
            guard edgeCount > 0 else { continue }
            for edge in 0..<edgeCount {
                let start = screen[edge]
                let end = screen[(edge + 1) % screen.count]
                let segmentIndex = segments.count
                segments.append(Segment(curve: curveIndex, start: start, end: end))

                let minimumX = Int((min(start.x, end.x) / cellSize).rounded(.down))
                let maximumX = Int((max(start.x, end.x) / cellSize).rounded(.down))
                let minimumY = Int((min(start.y, end.y) / cellSize).rounded(.down))
                let maximumY = Int((max(start.y, end.y) / cellSize).rounded(.down))
                guard maximumX - minimumX <= Self.maximumCellExtent,
                      maximumY - minimumY <= Self.maximumCellExtent
                else {
                    unbucketed.append(segmentIndex)
                    continue
                }
                for x in minimumX...maximumX {
                    for y in minimumY...maximumY {
                        cells[Cell(x: x, y: y), default: []].append(segmentIndex)
                    }
                }
            }
        }

        self.curves = curves
        self.cellSize = cellSize
        self.projected = projected
        self.segments = segments
        self.cells = cells
        self.unbucketed = unbucketed
        self.indexBuildNanoseconds = DispatchTime.now().uptimeNanoseconds &- began
    }

    var segmentCount: Int { segments.count }

    /// The nearest curve within `tolerance` screen points, or nil. Ties go to
    /// the earlier curve in `curves`, which is what the linear picker does.
    func pick(at point: Vec2, tolerance: Double = 6) -> FFPickCurve? {
        guard tolerance >= 0, point.x.isFinite, point.y.isFinite else { return nil }

        let minimumX = Int(((point.x - tolerance) / cellSize).rounded(.down))
        let maximumX = Int(((point.x + tolerance) / cellSize).rounded(.down))
        let minimumY = Int(((point.y - tolerance) / cellSize).rounded(.down))
        let maximumY = Int(((point.y + tolerance) / cellSize).rounded(.down))
        let spansTooManyCells = maximumX - minimumX > Self.maximumQueryExtent
            || maximumY - minimumY > Self.maximumQueryExtent

        var bestDistance = Double.infinity
        var bestCurve: Int?
        var seen = Set<Int>()

        func consider(_ index: Int) {
            guard seen.insert(index).inserted else { return }
            let segment = segments[index]
            let distance = Self.distanceToSegment(point, segment.start, segment.end)
            guard distance <= tolerance else { return }
            if distance < bestDistance
                || (distance == bestDistance && segment.curve < (bestCurve ?? Int.max)) {
                bestDistance = distance
                bestCurve = segment.curve
            }
        }

        if spansTooManyCells {
            for index in segments.indices {
                consider(index)
            }
        } else {
            for x in minimumX...maximumX {
                for y in minimumY...maximumY {
                    for index in cells[Cell(x: x, y: y)] ?? [] {
                        consider(index)
                    }
                }
            }
            for index in unbucketed {
                consider(index)
            }
        }

        guard let bestCurve else { return nil }
        return curves[bestCurve]
    }

    private static func distanceToSegment(_ point: Vec2, _ start: Vec2, _ end: Vec2) -> Double {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > FFMath.eps else {
            return hypot(point.x - start.x, point.y - start.y)
        }
        let parameter = FFMath.clamp(
            ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared,
            to: 0...1
        )
        let x = start.x + parameter * dx
        let y = start.y + parameter * dy
        return hypot(point.x - x, point.y - y)
    }
}
