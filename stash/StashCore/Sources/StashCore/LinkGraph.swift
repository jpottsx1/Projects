import Foundation

/// Where to draw each item in a graph of how items link: linked items
/// pulled together, all of them pushed apart, as a force-directed layout.
/// The same links always give the same picture.
public enum LinkGraph {
    public struct Point: Equatable {
        public var x: Double
        public var y: Double
    }

    /// Positions in a unit square (0...1 each way) for `count` nodes joined
    /// by `edges` (pairs of node indices).
    public static func layout(count: Int, edges: [(Int, Int)], iterations: Int = 300) -> [Point] {
        guard count > 0 else { return [] }
        guard count > 1 else { return [Point(x: 0.5, y: 0.5)] }
        // Start on a circle, so the result doesn't depend on chance.
        var positions = (0..<count).map { index -> (Double, Double) in
            let angle = Double(index) / Double(count) * 2 * .pi
            return (0.5 + 0.4 * cos(angle), 0.5 + 0.4 * sin(angle))
        }
        let ideal = 0.9 / sqrt(Double(count))
        var temperature = 0.1
        let links = edges.filter { $0.0 != $0.1 && $0.0 < count && $0.1 < count && $0.0 >= 0 && $0.1 >= 0 }
        for _ in 0..<iterations {
            var moves = Array(repeating: (0.0, 0.0), count: count)
            for a in 0..<count {
                for b in (a + 1)..<count {
                    var dx = positions[a].0 - positions[b].0, dy = positions[a].1 - positions[b].1
                    var distance = sqrt(dx * dx + dy * dy)
                    if distance < 1e-6 { dx = 1e-3; dy = 0; distance = 1e-3 }
                    let push = ideal * ideal / distance
                    moves[a].0 += dx / distance * push; moves[a].1 += dy / distance * push
                    moves[b].0 -= dx / distance * push; moves[b].1 -= dy / distance * push
                }
            }
            for (a, b) in links {
                let dx = positions[a].0 - positions[b].0, dy = positions[a].1 - positions[b].1
                let distance = max(sqrt(dx * dx + dy * dy), 1e-6)
                let pull = distance * distance / ideal
                moves[a].0 -= dx / distance * pull; moves[a].1 -= dy / distance * pull
                moves[b].0 += dx / distance * pull; moves[b].1 += dy / distance * pull
            }
            for index in 0..<count {
                // A gentle pull to the middle keeps unlinked items from drifting off.
                moves[index].0 += (0.5 - positions[index].0) * 0.05
                moves[index].1 += (0.5 - positions[index].1) * 0.05
                let length = max(sqrt(moves[index].0 * moves[index].0 + moves[index].1 * moves[index].1), 1e-9)
                let step = min(length, temperature)
                positions[index].0 += moves[index].0 / length * step
                positions[index].1 += moves[index].1 / length * step
            }
            temperature = max(temperature * 0.97, 0.002)
        }
        // Fit into the square with a margin.
        let xs = positions.map(\.0), ys = positions.map(\.1)
        let minX = xs.min()!, maxX = xs.max()!, minY = ys.min()!, maxY = ys.max()!
        let scale = 0.9 / max(maxX - minX, maxY - minY, 1e-6)
        return positions.map { position in
            Point(x: 0.05 + (position.0 - minX) * scale + (0.9 - (maxX - minX) * scale) / 2,
                  y: 0.05 + (position.1 - minY) * scale + (0.9 - (maxY - minY) * scale) / 2)
        }
    }
}
