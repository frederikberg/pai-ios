import Foundation
import XCTest

@testable import PAIKit

/// `Resources/todos-parse-vectors.json` is a byte-identical copy of pai-cloud's
/// `shared/todos-parse-vectors.json`, the cases the server's capture parser and the web's quick
/// add run too. The phone does not parse; it reads the parser's answer, so each case is run as
/// the answer the server gives for it: decoded, shown as chips, handed on to the create op.
final class TodosParseVectorsTests: XCTestCase {

    private struct Vector {
        let name: String
        let fields: [String: PaiJSONValue]

        func string(_ key: String) -> String? { fields[key]?.stringValue }
        func has(_ key: String) -> Bool { fields[key].map { $0 != .null } ?? false }
        var flag: (String) -> Bool { { key in fields[key] == .bool(true) } }
        var tags: [String] {
            if case .array(let items) = fields["tags"] { return items.compactMap(\.stringValue) }
            return []
        }
        var clears: [PaiJSONValue] {
            if case .array(let items) = fields["clears"] { return items }
            return []
        }
    }

    private func vectors() throws -> [Vector] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Resources/todos-parse-vectors.json")
        let file = try JSONDecoder().decode([String: PaiJSONValue].self, from: Data(contentsOf: url))
        guard case .array(let cases) = file["vectors"] else { return [] }
        return cases.compactMap { value in
            guard case .object(let fields) = value, let name = fields["name"]?.stringValue else { return nil }
            return Vector(name: name, fields: fields)
        }
    }

    /// What the server's `/parse` answers for a case: its fields, and its tokens placed at the
    /// offsets of their text.
    private func answer(_ vector: Vector) throws -> TodosParseAnswer {
        let text = vector.string("text") ?? ""
        var from = text.startIndex
        var tokens: [PaiJSONValue] = []
        if case .array(let listed) = vector.fields["tokens"] {
            for case .object(let token) in listed {
                let words = token["text"]?.stringValue ?? ""
                let found = text.range(of: words, range: from..<text.endIndex)
                let start = found.map { text.utf16.distance(from: text.startIndex, to: $0.lowerBound) } ?? 0
                if let found { from = found.upperBound }
                tokens.append(
                    .object([
                        "kind": token["kind"] ?? .null, "start": .number(Decimal(start)),
                        "end": .number(Decimal(start + words.utf16.count)), "display": .string(words), "value": .null,
                    ]))
            }
        }
        let title = vector.string("title") ?? ""
        var create: [String: PaiJSONValue] = [
            "op": .string("todo.create"), "id": .string("x"), "title": .string(title.isEmpty ? text : title),
        ]
        if vector.has("list") { create["list"] = .string("LIST-ID") }
        if vector.has("parent") { create["parent"] = .string("PARENT-ID") }
        if vector.has("repeat") { create["repeat"] = vector.fields["repeat"] }
        let fields: [String: PaiJSONValue] = [
            "tags": vector.fields["tags"] ?? .array([]), "horizon": vector.fields["horizon"] ?? .null,
            "when": vector.fields["when"] ?? .null, "someday": .bool(vector.flag("someday")),
            "deadline": vector.string("deadline").map { .object(["date": .string($0), "lead_days": .null]) } ?? .null,
            "repeat": vector.fields["repeat"] ?? .null, "parent": vector.fields["parent"] ?? .null,
            "list": vector.fields["list"] ?? .null, "desk": .bool(vector.flag("desk")),
            "nudges": vector.has("nudge")
                ? .array([.object(["id": .string("n1"), "at": vector.fields["nudge"] ?? .null])]) : .array([]),
        ]
        let whole: PaiJSONValue = .object([
            "title": .string(title), "clears": .array(vector.clears), "fields": .object(fields),
            "tokens": .array(tokens), "create_op": .object(create),
        ])
        return try JSONDecoder().decode(TodosParseAnswer.self, from: JSONEncoder().encode(whole))
    }

    func testEveryCaseShowsOneChipPerFieldTheLineSpokeAbout() throws {
        let vectors = try vectors()
        XCTAssertGreaterThan(vectors.count, 50)
        for vector in vectors {
            let chips = TodoAddChip.read(try answer(vector), today: vector.string("today") ?? "")
            func count(_ kind: String) -> Int { chips.filter { $0.kind == kind }.count }
            let someday = vector.flag("someday")
            // Someday is said by the day chip, in place of "No date".
            XCTAssertEqual(count("when"), vector.has("when") || someday ? 1 : 0, vector.name)
            XCTAssertEqual(count("clear"), !vector.clears.isEmpty && !someday ? 1 : 0, vector.name)
            XCTAssertEqual(count("deadline"), vector.has("deadline") ? 1 : 0, vector.name)
            XCTAssertEqual(count("repeat"), vector.has("repeat") ? 1 : 0, vector.name)
            XCTAssertEqual(count("horizon"), vector.has("horizon") ? 1 : 0, vector.name)
            XCTAssertEqual(count("tag"), vector.tags.count, vector.name)
            XCTAssertEqual(count("list"), vector.has("list") ? 1 : 0, vector.name)
            XCTAssertEqual(count("parent"), vector.has("parent") ? 1 : 0, vector.name)
            XCTAssertEqual(count("desk"), vector.flag("desk") ? 1 : 0, vector.name)
            XCTAssertEqual(count("nudge"), vector.has("nudge") ? 1 : 0, vector.name)
            XCTAssertTrue(chips.allSatisfy { !$0.label.isEmpty }, vector.name)
        }
    }

    func testEveryCaseHandsItsFieldsToTheCreateOpWithoutInventingAny() throws {
        for vector in try vectors() {
            let typed = TodoCreate.typed(from: try answer(vector))
            let title = vector.string("title") ?? ""
            XCTAssertEqual(typed["title"], .string(title.isEmpty ? vector.string("text") ?? "" : title), vector.name)
            XCTAssertEqual(typed["tags"] ?? .array([]), vector.fields["tags"], vector.name)
            XCTAssertEqual(typed["when"] ?? .null, vector.fields["when"], vector.name)
            XCTAssertEqual(typed["someday"] == .bool(true), vector.flag("someday"), vector.name)
            XCTAssertEqual(typed["horizon"] ?? .null, vector.fields["horizon"], vector.name)
            XCTAssertEqual(typed["desk"] == .bool(true), vector.flag("desk"), vector.name)
            XCTAssertEqual(typed["repeat"] != nil, vector.has("repeat"), vector.name)
            XCTAssertEqual(typed["deadline"] != nil, vector.has("deadline"), vector.name)
            XCTAssertEqual(typed["nudges"] != nil, vector.has("nudge"), vector.name)
        }
    }

    /// A line with a someday word, added on a view that gives its todos today, is made someday
    /// and without the view's day.
    func testASomedayLineOnATodayViewIsAddedAsSomedayWithoutADay() throws {
        let vector = try XCTUnwrap(try vectors().first { $0.flag("someday") })
        let answer = try answer(vector)
        let today = try JSONDecoder().decode(TodoViewDefaults.self, from: Data(#"{"when": "today"}"#.utf8))
        let op = TodoCreate.op(
            id: "x", title: answer.title, place: TodoCreatePlace(defaults: today, listId: nil), today: "2026-11-25",
            typed: TodoCreate.typed(from: answer), dismissed: TodoCreate.cleared([], answer: answer))
        XCTAssertEqual(op.bool("someday"), true)
        XCTAssertNil(op.fields["when"])
    }
}
