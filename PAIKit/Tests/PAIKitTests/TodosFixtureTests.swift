#if DEBUG
    import Foundation
    import XCTest

    @testable import PAIKit

    /// Every answer fixture mode gives the Todos screens reads into its model, so a screenshot
    /// never shows an error screen for a fixture key the wire does not have.
    final class TodosFixtureTests: XCTestCase {

        private func answer<T: Decodable>(_ type: T.Type, _ method: String, _ path: String, body: String? = nil) throws
            -> T
        {
            let route = PaiFixtureURLProtocol.route(method: method, path: path, body: body.map { Data($0.utf8) })
            XCTAssertEqual(route.status, 200, "\(method) \(path)")
            return try JSONDecoder().decode(T.self, from: route.body())
        }

        func testTheTodosCorpusDecodesAndHasTheShapesTheScreensDraw() throws {
            let me = try answer(TodosMeAnswer.self, "GET", "/api/todos/me")
            XCTAssertEqual(me.lists.count, 3)
            let today = try answer(TodosTodayAnswer.self, "GET", "/api/todos/today")
            XCTAssertTrue(today.desk.contains { $0.kind == .divider })
            XCTAssertGreaterThan(today.desk.filter { $0.kind == .todo }.count, 3)
            let counts = try answer(TodosViewCountsAnswer.self, "GET", "/api/todos/views/counts")
            XCTAssertEqual(counts.views.count, me.views.count)
            for view in me.views {
                let run = try answer(TodosQueryAnswer.self, "GET", "/api/todos/views/\(view.id)/run")
                if view.builtin == "today" { XCTAssertFalse(run.todos.isEmpty) }
                if view.builtin == "all" { XCTAssertGreaterThan(run.groups.count, 1) }
            }
            let groceries = try answer(
                TodosQueryAnswer.self, "POST", "/api/todos/query",
                body: #"{"q":"list:\#(PaiFixtures.todosGroceriesList)"}"#)
            XCTAssertGreaterThan(groceries.todos.count, 3)
            let parent = try answer(TodosDetailAnswer.self, "GET", "/api/todos/todos/\(PaiFixtures.todosParent)")
            XCTAssertEqual(parent.children?.count, 3)
            let parsed = try answer(
                TodosParseAnswer.self, "POST", "/api/todos/parse", body: #"{"text":"Buy stamps tomorrow #errand"}"#)
            XCTAssertEqual(parsed.title, "Buy stamps")
            XCTAssertEqual(parsed.tokens.count, 2)
            let applied = try answer(
                TodosApplyResult.self, "POST", "/api/todos/apply",
                body: #"{"change_id":"c1","ops":[{"op":"todo.complete","todo":"T-1"}]}"#)
            XCTAssertEqual(applied.applied, 1)
            _ = try answer(TodosEventsAnswer.self, "GET", "/api/todos/events")
        }
    }
#endif
