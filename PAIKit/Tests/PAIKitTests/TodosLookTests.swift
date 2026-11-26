import Foundation
import XCTest

@testable import PAIKit

/// The phone draws what the web draws: every expectation here was produced by running the web
/// app's own functions (`shell/palette.ts`, `shell/identity.ts`, `shell/dates.ts`,
/// `shell/viewMeta.ts`, `quickadd/chips.ts`) on the same inputs, `Resources/todos/web-*.json`.
final class TodosLookTests: XCTestCase {

    private struct Vectors: Decodable {
        struct Derived: Decodable {
            let name: String
            let hash: UInt32
            let color: String
        }
        struct Stored: Decodable {
            let value: String
            let color: String?
        }
        struct TagCase: Decodable {
            let name: String
            let color: String
        }
        struct Tags: Decodable {
            let tags: [PaiJSONValue]
            let cases: [TagCase]
        }
        struct Identity: Decodable, Equatable {
            let icon: String
            let color: String
        }
        struct ViewCase: Decodable {
            let view: PaiJSONValue
            let identity: Identity
        }
        struct ListCase: Decodable {
            let list: PaiJSONValue
            let identity: Identity
        }
        struct DateCase: Decodable {
            let todo: PaiJSONValue
            let today: String
            let lead: Int
            let chip: PaiJSONValue
        }
        struct CreateCase: Decodable {
            let input: PaiJSONValue
            let op: PaiJSONValue
        }
        let keys: [String]
        let icons: [String]
        let derived: [Derived]
        let stored: [Stored]
        let tags: Tags
        let views: [ViewCase]
        let lists: [ListCase]
        let dates: [DateCase]
        let creates: [CreateCase]
    }

    private func vectors() throws -> Vectors {
        try TodosWireSamples.decode(Vectors.self, "web-look-vectors")
    }

    /// Decodes a JSON fragment the way a wire model would arrive.
    private func model<T: Decodable>(_ type: T.Type, _ value: PaiJSONValue) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    private func tag(_ value: PaiJSONValue) throws -> TodoTag {
        guard case .object(var fields) = value else { throw XCTSkip("not a tag") }
        fields["list_id"] = .string("L")
        fields["icon"] = .null
        fields["quiet"] = .bool(false)
        fields["open_count"] = .number(0)
        return try model(TodoTag.self, .object(fields))
    }

    func testThePaletteAndTheSymbolsAreTheWebsKeys() throws {
        let vectors = try vectors()
        XCTAssertEqual(TodoColor.allCases.map(\.rawValue), vectors.keys)
        XCTAssertEqual(Set(TodoIcon.allCases.map(\.rawValue)), Set(vectors.icons))
    }

    /// A colour nobody chose comes from the name exactly as in the browser, accents, other
    /// scripts and emoji included (UTF-16 code units).
    func testANameDerivesTheWebsColour() throws {
        let vectors = try vectors()
        XCTAssertGreaterThan(vectors.derived.count, 10)
        for case_ in vectors.derived {
            XCTAssertEqual(
                TodoColor.nameHash(case_.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()), case_.hash,
                case_.name)
            XCTAssertEqual(TodoColor.derived(case_.name).rawValue, case_.color, case_.name)
        }
        for case_ in vectors.stored {
            XCTAssertEqual(TodoColor.stored(case_.value)?.rawValue, case_.color, case_.value)
        }
    }

    func testTagsViewsAndListsWearTheWebsColoursAndSymbols() throws {
        let vectors = try vectors()
        let chosen = TodoIdentity.chosenTagColors(try vectors.tags.tags.map(tag))
        for case_ in vectors.tags.cases {
            XCTAssertEqual(TodoIdentity.tagColor(case_.name, chosen: chosen).rawValue, case_.color, case_.name)
        }
        let tagColor = { TodoIdentity.tagColor($0, chosen: chosen) }
        for case_ in vectors.views {
            guard case .object(var fields) = case_.view else { return XCTFail("view") }
            for (key, value) in [
                "id": PaiJSONValue.string("v"), "layout": .string("list"), "group_by": .string("none"),
                "sort": .string("hand"), "tree": .string("fold"), "pinned": .bool(false), "rank": .string("a"),
                "defaults": .object([:]),
            ] {
                fields[key] = value
            }
            let view = try model(TodoView.self, .object(fields))
            let identity = TodoIdentity.of(view: view, tagColor: tagColor)
            XCTAssertEqual(
                Vectors.Identity(icon: identity.icon.rawValue, color: identity.color.rawValue), case_.identity,
                view.name)
        }
        for case_ in vectors.lists {
            guard case .object(var fields) = case_.list else { return XCTFail("list") }
            for (key, value) in [
                "id": PaiJSONValue.string("l"), "layout": .string("list"), "locked": .bool(false),
                "archived": .bool(false), "role": .string("owner"), "members": .array([]),
                "counts": .object(["open": .number(0)]),
            ] {
                fields[key] = value
            }
            let list = try model(TodoList.self, .object(fields))
            let identity = TodoIdentity.of(list: list)
            XCTAssertEqual(
                Vectors.Identity(icon: identity.icon.rawValue, color: identity.color.rawValue), case_.identity,
                list.name)
        }
    }

    /// A row's date chip says what the web's says: day-month, a weekday this week, 24 h.
    func testADateChipReadsAsOnTheWeb() throws {
        struct Dated: Decodable {
            let when: TodoWhen?
            let deadline: TodoDeadline?
        }
        let vectors = try vectors()
        for case_ in vectors.dates {
            let todo = try model(Dated.self, case_.todo)
            let chip = TodosLookTests.chip(
                TodoDates.chip(when: todo.when, deadline: todo.deadline, today: case_.today, leadDays: case_.lead))
            let expected = case_.chip == .null ? nil : try model([String: String].self, case_.chip)
            XCTAssertEqual(chip, expected, "\(case_.todo)")
        }
    }

    private static func chip(_ chip: TodoDates.Chip?) -> [String: String]? {
        chip.map { ["kind": $0.isDeadline ? "deadline" : "when", "label": $0.label, "tone": $0.tone.rawValue] }
    }

    /// A todo made on a page gets the page's defaults overlaid by what was typed, field by field,
    /// as the web builds it.
    func testAPageDefaultsAndATypedLineMakeTheWebsOp() throws {
        struct Input: Decodable {
            let id: String
            let title: String
            let listId: String?
            let today: String
            let defaults: TodoViewDefaults?
            let typed: [String: PaiJSONValue]?
        }
        let vectors = try vectors()
        XCTAssertGreaterThanOrEqual(vectors.creates.count, 4)
        for case_ in vectors.creates {
            let input = try model(Input.self, case_.input)
            let op = TodoCreate.op(
                id: input.id, title: input.title,
                place: TodoCreatePlace(defaults: input.defaults, listId: input.listId),
                today: input.today, typed: input.typed ?? [:])
            XCTAssertEqual(PaiJSONValue.object(op.fields), case_.op, "\(case_.input)")
        }
    }
}
