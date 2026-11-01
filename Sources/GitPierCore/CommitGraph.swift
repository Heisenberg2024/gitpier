import Foundation

public struct GraphEdge: Sendable {
  public let from: Int
  public let to: Int
  public let color: Int
  public let startsAtNode: Bool
  public let endsAtNode: Bool
}
public struct GraphRow: Sendable {
  public let node: Int
  public let edges: [GraphEdge]
  public let width: Int
}
public enum CommitGraph {
  public static func layout(_ records: [CommitRecord]) -> [GraphRow] {
    var lanes: [String] = []
    var rows: [GraphRow] = []
    rows.reserveCapacity(records.count)
    for commit in records {
      if !lanes.contains(commit.hash) { lanes.append(commit.hash) }
      let node = lanes.firstIndex(of: commit.hash)!
      let incoming = lanes
      lanes.remove(at: node)
      var active = Set(lanes)
      for (offset, parent) in commit.parents.enumerated() where active.insert(parent).inserted {
        lanes.insert(parent, at: min(node + offset, lanes.count))
      }
      let destinations = Dictionary(uniqueKeysWithValues: lanes.enumerated().map { ($0.element, $0.offset) })
      var edges: [GraphEdge] = []
      for (index, hash) in incoming.enumerated() {
        if hash == commit.hash {
          edges.append(
            GraphEdge(from: index, to: node, color: index, startsAtNode: false, endsAtNode: true))
        } else if let destination = destinations[hash] {
          edges.append(
            GraphEdge(
              from: index, to: destination, color: index, startsAtNode: false, endsAtNode: false))
        }
      }
      for parent in commit.parents {
        if let index = destinations[parent] {
          edges.append(
            GraphEdge(from: node, to: index, color: index, startsAtNode: true, endsAtNode: false))
        }
      }
      rows.append(GraphRow(node: node, edges: edges, width: max(incoming.count, lanes.count)))
    }
    return rows
  }
}
