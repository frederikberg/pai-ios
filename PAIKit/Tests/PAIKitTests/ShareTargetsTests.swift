import XCTest

@testable import PAIKit

/// The share sheet's Todo and Note: what was shared lands whole, and trying again after a
/// failure never makes a second todo or uploads a file twice.
@MainActor
final class ShareTargetsTests: XCTestCase {
    private func file(_ name: String, _ text: String, id: String? = nil) -> ShareItem {
        ShareItem(id: id ?? name, name: name) {
            PaiFileUpload(filename: name, mimeType: "image/jpeg", data: Data(text.utf8))
        }
    }

    // MARK: Todo

    func testASharedPhotoBecomesAFileOfTheNewTodo() async throws {
        let server = FakeTodosServer()
        let share = ShareTodoStore(sharedText: "Hand in the receipt", link: nil, files: [file("receipt.jpg", "bytes")])
        share.start(server)
        await share.add(timeout: 30)
        guard case .added = share.phase else { return XCTFail("\(share.phase)") }

        let created = await server.createdOps.values
        XCTAssertEqual(created.map { $0.string("title") }, ["Hand in the receipt"])
        let attached = await server.attached
        XCTAssertEqual(attached.map(\.name), ["receipt.jpg"])
        XCTAssertEqual(attached.first?.todo, created.first?.string("id"), "on the todo that was just made")
    }

    func testAPhotoAloneMakesATodoNamedAfterIt() async throws {
        let server = FakeTodosServer()
        let share = ShareTodoStore(sharedText: nil, link: nil, files: [file("receipt.jpg", "bytes")])
        share.start(server)
        XCTAssertTrue(share.canAdd)
        await share.add(timeout: 30)
        let created = await server.createdOps.values
        XCTAssertEqual(created.map { $0.string("title") }, ["receipt.jpg"])
        let attached = await server.attached
        XCTAssertEqual(attached.count, 1)
    }

    func testAFileThatDidNotArriveIsSentAgainWithoutASecondTodo() async throws {
        let server = FakeTodosServer()
        let unreadable = ShareItem(id: "broken", name: "broken.jpg") { throw URLError(.cannotOpenFile) }
        let share = ShareTodoStore(sharedText: "Two files", link: nil, files: [file("a.jpg", "a"), unreadable])
        share.start(server)
        await share.add(timeout: 30)
        guard case .filesMissing(_, let missing) = share.phase else { return XCTFail("\(share.phase)") }
        XCTAssertEqual(missing, 1)
        XCTAssertTrue(share.canAdd, "Try again is offered")
        XCTAssertNotNil(share.problem)

        // The words can no longer make another todo, whatever is typed now.
        share.text = "Other words"
        await share.add(timeout: 30)
        let created = await server.createdOps
        XCTAssertEqual(created.count, 1)
        let attached = await server.attached
        XCTAssertEqual(attached.map(\.name), ["a.jpg"], "the file that arrived is not sent twice")
    }

    // MARK: Note

    private actor FakeNotes: ShareNoteBackend {
        var containers: [NoteContainer] = []
        var uploads: [String] = []
        var created: [(name: String, body: String?, containerId: String?)] = []
        var failUploadsOf: Set<String> = []

        func setContainers(_ containers: [NoteContainer]) { self.containers = containers }
        func failUploads(of names: Set<String>) { failUploadsOf = names }

        func getNoteContainers() async throws -> [NoteContainer] { containers }

        func uploadNoteAttachment(containerId: String, filename: String, mimeType: String, data: Data) async throws
            -> NoteAttachmentUploaded
        {
            if failUploadsOf.contains(filename) { throw PaiError.transport("offline") }
            uploads.append(filename)
            return NoteAttachmentUploaded(relPath: "attachments/\(filename)", size: data.count)
        }

        func createNote(name: String, summary: String?, body: String?, containerId: String?) async throws -> NoteDetail {
            created.append((name, body, containerId))
            return NoteDetail(
                id: "n\(created.count)", name: name, summary: nil, containerId: containerId, favourite: false,
                tags: [], updatedAtMs: 0, pendingDelete: false, frontmatter: nil, body: body ?? "",
                contentHash: "h", createdAt: nil, createdAtMs: nil, lastWriteSource: "ui")
        }
    }

    private func container(_ id: String, isDefault: Bool) -> NoteContainer {
        NoteContainer(
            id: id, agentSlug: "vm", path: "/notes/\(id)", name: id, enabled: true, isDefault: isDefault,
            state: "active", pausedReason: nil, lastScanAtMs: nil, lastError: nil, noteCount: 0, breaker: nil,
            createdAt: nil, updatedAt: nil)
    }

    func testSharedTextAndAPhotoBecomeANoteWithThePhotoEmbeddedInTheDefaultFolder() async throws {
        let notes = FakeNotes()
        await notes.setContainers([container("other", isDefault: false), container("home", isDefault: true)])
        let share = ShareNoteStore(
            sharedText: "Hardware store run\nscrews, glue", link: "https://example.org/shop",
            files: [file("receipt.jpg", "bytes")])
        XCTAssertEqual(share.name, "Hardware store run")
        share.start(notes)
        await share.add()
        XCTAssertEqual(share.phase, .added(name: "Hardware store run"))

        let created = await notes.created
        XCTAssertEqual(created.count, 1)
        XCTAssertEqual(created.first?.containerId, "home")
        XCTAssertEqual(
            created.first?.body,
            "Hardware store run\nscrews, glue\n\nhttps://example.org/shop\n\n![[attachments/receipt.jpg]]")
    }

    func testAFailedUploadMakesNoNoteAndTryingAgainUploadsOnlyWhatIsMissing() async throws {
        let notes = FakeNotes()
        await notes.setContainers([container("home", isDefault: true)])
        await notes.failUploads(of: ["b.jpg"])
        let share = ShareNoteStore(sharedText: nil, link: nil, files: [file("a.jpg", "a"), file("b.jpg", "b")])
        share.start(notes)
        await share.add()
        guard case .failed = share.phase else { return XCTFail("\(share.phase)") }
        let none = await notes.created
        XCTAssertTrue(none.isEmpty, "a note is made only with everything that was shared")

        await notes.failUploads(of: [])
        await share.add()
        XCTAssertEqual(share.phase, .added(name: "a"))
        let uploads = await notes.uploads
        XCTAssertEqual(uploads, ["a.jpg", "b.jpg"])
        let created = await notes.created
        XCTAssertEqual(created.first?.body, "![[attachments/a.jpg]]\n![[attachments/b.jpg]]")
    }

    func testAFileWithNoFolderToGoToIsRefusedWithItsReasonAndTextAloneNeedsNone() async throws {
        let notes = FakeNotes()
        let withFile = ShareNoteStore(sharedText: "Words", link: nil, files: [file("a.jpg", "a")])
        withFile.start(notes)
        await withFile.add()
        guard case .failed(let message) = withFile.phase else { return XCTFail("\(withFile.phase)") }
        XCTAssertTrue(message.contains("folder"))

        let textOnly = ShareNoteStore(sharedText: "Words", link: nil)
        textOnly.start(notes)
        await textOnly.add()
        XCTAssertEqual(textOnly.phase, .added(name: "Words"))
    }

    // MARK: Who is offered what

    func testAGuestIsNotOfferedANoteAndAnUnknownPersonOnlyTheSession() {
        XCTAssertEqual(ShareTarget.offered(to: Capabilities(role: .owner)), [.todo, .note, .session])
        XCTAssertEqual(ShareTarget.offered(to: Capabilities(role: .guest)), [.todo, .session])
        XCTAssertEqual(ShareTarget.offered(to: .unknown), [.session])
    }
}
