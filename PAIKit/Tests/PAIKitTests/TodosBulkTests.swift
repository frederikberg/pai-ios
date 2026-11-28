import Foundation
import XCTest

@testable import PAIKit

/// One action on several todos, checked against what the web app's own `bulkChange` answers for
/// the same selection (`Resources/todos/web-bulk-vectors.json`).
final class TodosBulkTests: XCTestCase {

    private static let template: Todo = {
        let answer = try? TodosWireSamples.decode(TodosQueryAnswer.self, "query-open")
        return answer!.todos.first { $0.parentId == nil && $0.repeat == nil }!
    }()

    private func object(_ value: PaiJSONValue?) -> [String: PaiJSONValue] {
        if case .object(let fields) = value { return fields }
        return [:]
    }

    private func todos(_ rows: [String: PaiJSONValue]) throws -> [String: Todo] {
        var out: [String: Todo] = [:]
        for (id, value) in rows {
            let fields = object(value)
            var row = Self.template
            row.id = id
            row.listId = fields["list_id"]?.stringValue ?? ""
            row.parentId = fields["parent_id"]?.stringValue
            row.status = TodoStatus.knownValues[fields["status"]?.stringValue ?? ""] ?? .open
            row.onDesk = fields["on_desk"] == .bool(true)
            row.when = try model(TodoWhen?.self, fields["when"])
            row.deadline = try model(TodoDeadline?.self, fields["deadline"])
            out[id] = row
        }
        return out
    }

    private func model<T: Decodable>(_ type: T.Type, _ value: PaiJSONValue?) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value ?? .null))
    }

    private func action(_ fields: [String: PaiJSONValue]) throws -> TodoBulk.Action {
        switch fields["type"]?.stringValue {
        case "complete": return .complete
        case "desk": return .desk
        case "horizon": return .horizon(TodoHorizon.knownValues[fields["horizon"]?.stringValue ?? ""] ?? .whenever)
        case "tag": return .tag(fields["name"]?.stringValue ?? "")
        case "untag": return .untag(fields["name"]?.stringValue ?? "")
        case "when": return .when(try model(TodoWhen?.self, fields["when"]))
        case "deadline": return .deadline(date: object(fields["deadline"])["date"]?.stringValue)
        case "move": return .move(list: fields["list"]?.stringValue ?? "")
        case "delete": return .delete
        default: throw XCTSkip("an action the phone does not offer")
        }
    }

    /// The web leaves an empty `add` or `remove` off a tag op; the phone sends both. The server
    /// reads them the same.
    private func comparable(_ op: PaiJSONValue) -> PaiJSONValue {
        var fields = object(op)
        for key in ["add", "remove"] where fields[key] == .array([]) { fields[key] = nil }
        return .object(fields)
    }

    func testEveryActionSendsWhatTheWebSendsForTheSameSelection() throws {
        let file = try TodosWireSamples.decode([String: PaiJSONValue].self, "web-bulk-vectors")
        let todos = try todos(object(file["todos"]))
        guard case .array(let cases) = file["cases"] else { return XCTFail("no cases") }
        XCTAssertGreaterThan(cases.count, 10)
        for value in cases {
            let fields = object(value)
            let name = fields["name"]?.stringValue ?? ""
            guard case .array(let ids) = fields["ids"] else { return XCTFail(name) }
            let change = TodoBulk.change(
                try action(object(fields["action"])), ids: ids.compactMap(\.stringValue), todos: todos)
            guard fields["change"] != .null else {
                XCTAssertNil(change, name)
                continue
            }
            let expected = object(fields["change"])
            XCTAssertEqual(change?.toast, expected["toast"]?.stringValue, name)
            guard case .array(let ops) = expected["ops"] else { return XCTFail(name) }
            XCTAssertEqual((change?.ops ?? []).map { comparable(.object($0.fields)) }, ops.map(comparable), name)
        }
    }

    /// A todo in a list this person may only read is left out and said so; what belongs to the
    /// person (the desk) is not held back by the list.
    func testWhatThePersonMayNotChangeIsLeftOutAndSaid() throws {
        var lists = try TodosWireSamples.decode(TodosMeAnswer.self, "me").lists
        XCTAssertGreaterThan(lists.count, 0)
        var readOnly = object(try JSONDecoder().decode(PaiJSONValue.self, from: JSONEncoder().encode(lists[0])))
        readOnly["id"] = .string("read-only")
        readOnly["locked"] = .bool(true)
        lists.append(try model(TodoList.self, .object(readOnly)))
        var mine = Self.template
        mine.id = "mine"
        mine.listId = lists[0].id
        var theirs = Self.template
        theirs.id = "theirs"
        theirs.listId = "read-only"
        let todos = ["mine": mine, "theirs": theirs]

        let tagged = TodoBulk.plan(.tag("x"), ids: ["mine", "theirs"], todos: todos, lists: lists)
        XCTAssertEqual(tagged.change?.ops.map { $0.string("todo") }, ["mine"])
        XCTAssertEqual(tagged.leftOut?.hasPrefix("1 of 2 left out"), true)

        let none = TodoBulk.plan(.delete, ids: ["theirs"], todos: todos, lists: lists)
        XCTAssertNil(none.change)
        XCTAssertNotNil(none.leftOut)

        let desk = TodoBulk.plan(.desk, ids: ["mine", "theirs"], todos: todos, lists: lists)
        XCTAssertEqual(desk.change?.ops.count, 2)
        XCTAssertNil(desk.leftOut)
    }
}
