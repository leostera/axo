import AxoProtocol
import Foundation

/// A closed, bounded preferences format. Raw JSON is not a tree or command.
/// Parsing allocates identity-only leaves, never terminal surfaces or children.
@MainActor
enum AxodPaneLayoutPersistence {
    private enum Fault: Error { case invalid }
    typealias Layouts = AxodPaneLayouts

    static func read(_ data: Data, session: Layouts.Session) -> Layouts.Tree? {
        guard data.count <= 16384, let raw = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let fields) = raw, Set(fields.keys) == ["version", "machineId", "sessionId", "root"],
              fields["version"] == .number(1), uuid(fields["machineId"]) == session.machineID,
              uuid(fields["sessionId"]) == session.sessionID, let root = fields["root"] else { return nil }
        var seen = Set<UUID>()
        guard let node = try? parseNode(root, depth: 0, seen: &seen) else { return nil }
        return Layouts.Tree(root: node, zoomed: nil)
    }

    static func write(_ tree: Layouts.Tree, session: Layouts.Session) -> Data? {
        guard let root = tree.root else { return nil }
        return encode(.object([
            "version": .number(1), "machineId": .string(session.machineID.uuidString),
            "sessionId": .string(session.sessionID.uuidString), "root": encodeNode(root),
        ]))
    }

    private static func parseNode(_ raw: JSONValue, depth: Int, seen: inout Set<UUID>) throws -> Layouts.Tree.Node {
        guard depth < 32, case .object(let fields) = raw else { throw Fault.invalid }
        if fields["kind"] == .string("pane") {
            guard Set(fields.keys) == ["kind", "paneId"], let id = uuid(fields["paneId"]),
                  seen.count < Layouts.maximumPanes, seen.insert(id).inserted else { throw Fault.invalid }
            return .leaf(view: AxodPaneLayoutLeaf(id: id))
        }
        guard Set(fields.keys) == ["kind", "axis", "fraction", "first", "second"], fields["kind"] == .string("split"),
              case .string(let axis)? = fields["axis"], axis == "horizontal" || axis == "vertical",
              case .number(let fraction)? = fields["fraction"], fraction.isFinite, fraction > 0, fraction < 1,
              let first = fields["first"], let second = fields["second"] else { throw Fault.invalid }
        return .split(.init(direction: axis == "horizontal" ? .horizontal : .vertical, ratio: fraction,
            left: try parseNode(first, depth: depth + 1, seen: &seen),
            right: try parseNode(second, depth: depth + 1, seen: &seen)))
    }

    private static func encodeNode(_ node: Layouts.Tree.Node) -> JSONValue {
        switch node {
        case .leaf(let leaf): return .object(["kind": .string("pane"), "paneId": .string(leaf.id.uuidString)])
        case .split(let split): return .object([
            "kind": .string("split"), "axis": .string(split.direction == .horizontal ? "horizontal" : "vertical"),
            "fraction": .number(split.ratio), "first": encodeNode(split.left), "second": encodeNode(split.right),
        ])
        }
    }

    static func write(_ placement: Layouts.Placement) -> Data? {
        guard let parameters = try? JSONEncoder().encode(placement.parameters),
              let raw = try? JSONDecoder().decode(JSONValue.self, from: parameters) else { return nil }
        return encode(.object([
            "parameters": raw, "anchor": .string(placement.anchor.uuidString), "direction": .string(placement.direction.rawValue),
        ]))
    }

    static func readPlacement(_ data: Data, session: Layouts.Session) -> Layouts.Placement? {
        guard data.count <= 4096, let raw = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let fields) = raw, Set(fields.keys) == ["parameters", "anchor", "direction"],
              let anchor = uuid(fields["anchor"]), case .string(let direction)? = fields["direction"],
              let direction = AxodPaneSplitDirection(rawValue: direction),
              case .object(let parameters)? = fields["parameters"],
              Set(parameters.keys).isSubset(of: ["target", "commandId", "profileId"]),
              parameters["profileId"] == nil || parameters["profileId"] == .null,
              uuid(parameters["commandId"]) != nil, case .object(let target)? = parameters["target"],
              Set(target.keys).isSubset(of: ["machineId", "hostGeneration", "workspaceId", "sessionId"]),
              uuid(target["machineId"]) == session.machineID, uuid(target["sessionId"]) == session.sessionID,
              uuid(target["hostGeneration"]) != nil,
              target["workspaceId"] == nil || target["workspaceId"] == .null || uuid(target["workspaceId"]) != nil,
              let encoded = try? JSONEncoder().encode(JSONValue.object(parameters)),
              let parsed = try? JSONDecoder().decode(ShellPaneAddParameters.self, from: encoded) else { return nil }
        return Layouts.Placement(parameters: parsed, anchor: anchor, direction: direction)
    }

    private static func encode(_ value: JSONValue) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(value)
    }

    private static func uuid(_ raw: JSONValue?) -> UUID? {
        guard case .string(let value)? = raw else { return nil }
        return UUID(uuidString: value)
    }
}
