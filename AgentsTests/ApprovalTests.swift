import XCTest

@testable import Agents

/// Vectors computed with mailgate's canonical hash over these fixtures.
final class ApprovalTests: XCTestCase {
    static let ev = Approval.Event(
        title: "Dentist", start: "2026-09-25T14:00:00-06:00", end: "2026-09-25T15:00:00-06:00",
        all_day: "0", location: "Main St", notes: "")
    static let moved = Approval.Event(
        title: "Dentist", start: "2026-09-25T16:00:00-06:00", end: "2026-09-25T17:00:00-06:00",
        all_day: "0", location: "Main St", notes: "")
    static let change = Approval.EventChange(
        calendar: "Home", event_id: "https://caldav.example.com/calendars/user/item-1/",
        etag: "\"e1\"", organizer: "", attendees: "0", before: ev, after: moved)
    static let text = Approval.Text(
        chat_guid: "any;-;+15555550100", chat_name: "",
        recipients: ["Sam (+15555550100)"], text: "On my way \u{2014} 10 min")

    func testTextHashMatchesMailgate() {
        let a = Approval(id: "i_1", hash: "7056027b4b0066725eb1618ce9607be39025d4369fe2f89f364088a2e483db3e", expiresAt: 1, payload: .text(Self.text))
        XCTAssertEqual(a.computedHash, a.hash)
        XCTAssertTrue(a.isIntact)
    }

    func testCalendarUpdateHashMatchesMailgate() {
        let a = Approval(
            id: "c_1", hash: "d00053c5dd2fc9f1c160e960d90c976f4ea07a2cd392192836595afa3a1817ed", expiresAt: 1,
            payload: .eventUpdate(Self.change, after: Self.moved))
        XCTAssertEqual(a.computedHash, a.hash)
    }

    func testCalendarDeleteHashMatchesMailgate() {
        let a = Approval(
            id: "c_2", hash: "0e86b7e0cff5e49006c7b11f9a382db25c4e6a8af0f468e24b1ac31cf692bd59", expiresAt: 1,
            payload: .eventDelete(Self.change))
        XCTAssertEqual(a.computedHash, a.hash)
    }

    func testSeriesDeleteHashMatchesMailgate() {
        let a = Approval(
            id: "c_3", hash: "1dd359482c7e7f941105111faa91884bc4a2f9bb0b86f21dc5a9f93dcb9787f0", expiresAt: 1,
            payload: .seriesDelete(Self.change, scope: .one, occurrence: "2026-09-25T14:00:00-06:00"))
        XCTAssertEqual(a.computedHash, a.hash)
        // Which occurrences go is signed: another scope or occurrence never verifies.
        let future = Approval(id: "c_3", hash: a.hash, expiresAt: 1, payload: .seriesDelete(Self.change, scope: .future, occurrence: "2026-09-25T14:00:00-06:00"))
        XCTAssertFalse(future.isIntact)
        let other = Approval(id: "c_3", hash: a.hash, expiresAt: 1, payload: .seriesDelete(Self.change, scope: .one, occurrence: "2026-10-02T14:00:00-06:00"))
        XCTAssertFalse(other.isIntact)
    }

    func testSeriesDeleteReadBackSaysHowMuchGoes() {
        let one = Approval(id: "c", hash: "h", expiresAt: 1, payload: .seriesDelete(Self.change, scope: .one, occurrence: "x"))
        XCTAssertEqual(
            one.readBack,
            "Delete just one time of the repeating event Dentist: Friday, September 25, 2:00 PM to 3:00 PM, at Main St. The others stay. Say send to delete it, or cancel."
        )
        let future = Approval(id: "c", hash: "h", expiresAt: 1, payload: .seriesDelete(Self.change, scope: .future, occurrence: "x"))
        XCTAssertEqual(
            future.readBack,
            "Delete the repeating event Dentist from Friday, September 25, 2:00 PM to 3:00 PM on, at Main St. That one and every later one go; earlier ones stay. Say send to delete them, or cancel."
        )
        let all = Approval(id: "c", hash: "h", expiresAt: 1, payload: .seriesDelete(Self.change, scope: .all, occurrence: ""))
        XCTAssertEqual(
            all.readBack,
            "Delete the whole repeating event Dentist, every time it happens, starting Friday, September 25, 2:00 PM to 3:00 PM, at Main St. Say send to delete them, or cancel."
        )
    }

    /// Vectors computed with mailgate's canonical hash over these fixtures.
    func testCalendarLevelHashesMatchMailgate() {
        let create = Approval(
            id: "c", hash: "f7af9b3284f6917eb16f6055af5e83aa11c390d2af4aa6ed90061c12b88687db", expiresAt: 1,
            payload: .calendarCreate(name: "Subscriptions"))
        XCTAssertTrue(create.isIntact)
        let atlas = Approval.CalendarRef(calendar_id: "https://caldav.example.com/calendars/user/item-2/", name: "Atlas")
        let rename = Approval(
            id: "c", hash: "4762842cb6132cf4ebf28cb4b328697a4fabbfdd0158b5b42dabcbb151468ca2", expiresAt: 1,
            payload: .calendarRename(atlas, newName: "Home"))
        XCTAssertTrue(rename.isIntact)
        let shared = Approval.CalendarRef(calendar_id: "https://caldav.example.com/calendars/user/item-3/", name: "Shared ⚠️")
        let delete = Approval(
            id: "c", hash: "dc767723665ec3fa8e46ec38025cdef41ca3f8092366e6d57759d747867c150a", expiresAt: 1,
            payload: .calendarDelete(shared, events: "3"))
        XCTAssertTrue(delete.isIntact)
        // How many events go is signed.
        XCTAssertFalse(Approval(id: "c", hash: delete.hash, expiresAt: 1, payload: .calendarDelete(shared, events: "0")).isIntact)
        XCTAssertFalse(Approval(id: "c", hash: rename.hash, expiresAt: 1, payload: .calendarRename(atlas, newName: "Work")).isIntact)
    }

    func testCalendarLevelReadBack() {
        let ref = Approval.CalendarRef(calendar_id: "x", name: "Untitled")
        XCTAssertEqual(
            Approval(id: "c", hash: "h", expiresAt: 1, payload: .calendarCreate(name: "Subscriptions")).readBack,
            "Create a new calendar called Subscriptions. Say send to create it, or cancel.")
        XCTAssertEqual(
            Approval(id: "c", hash: "h", expiresAt: 1, payload: .calendarRename(ref, newName: "Home")).readBack,
            "Rename the calendar Untitled to Home. Its events stay. Say send to rename it, or cancel.")
        XCTAssertEqual(
            Approval(id: "c", hash: "h", expiresAt: 1, payload: .calendarDelete(ref, events: "0")).readBack,
            "Delete the whole calendar Untitled, which is empty. Say send to delete it, or cancel.")
        XCTAssertEqual(
            Approval(id: "c", hash: "h", expiresAt: 1, payload: .calendarDelete(ref, events: "12")).readBack,
            "Delete the whole calendar Untitled, and all 12 events on it. Say send to delete it, or cancel.")
    }

    func testCalendarLevelKindsDecode() throws {
        let json = """
            {"pending":[
              {"id":"c_1","kind":"calendar_create_calendar","hash":"h","expiresAt":1,"message":{"name":"Subscriptions"}},
              {"id":"c_2","kind":"calendar_rename_calendar","hash":"h","expiresAt":1,"message":{"calendar_id":"u","name":"Atlas","new_name":"Home"}},
              {"id":"c_3","kind":"calendar_delete_calendar","hash":"h","expiresAt":1,"message":{"calendar_id":"u","name":"Untitled","events":"0"}},
              {"id":"c_4","kind":"calendar_delete_calendar","hash":"h","expiresAt":1,"message":{"calendar_id":"u","name":"Untitled"}}
            ]}
            """.data(using: .utf8)!
        let page = try JSONDecoder().decode(ApprovalPage.self, from: json)
        XCTAssertEqual(page.pending.map(\.id), ["c_1", "c_2", "c_3"], "a delete without its event count is skipped")
        XCTAssertEqual(page.pending[0].payload, .calendarCreate(name: "Subscriptions"))
        XCTAssertEqual(page.pending[1].payload, .calendarRename(.init(calendar_id: "u", name: "Atlas"), newName: "Home"))
        XCTAssertEqual(page.pending[2].actionTitle, "Delete")
    }

    /// The kind is inside the hash: the same fields shown as another kind never verify.
    func testRelabelledKindFailsTheCheck() {
        let del = Approval(
            id: "c", hash: "0e86b7e0cff5e49006c7b11f9a382db25c4e6a8af0f468e24b1ac31cf692bd59", expiresAt: 1,
            payload: .eventDelete(Self.change))
        let asUpdate = Approval(id: "c", hash: del.hash, expiresAt: 1, payload: .eventUpdate(Self.change, after: Self.ev))
        XCTAssertTrue(del.isIntact)
        XCTAssertFalse(asUpdate.isIntact)
    }

    func testPageDecodesEveryKindAndSkipsUnknownOnes() throws {
        let json = """
            {"pending":[
              {"id":"p_1","kind":"mail","hash":"h","expiresAt":1,"message":{"to":["user@example.com"],"cc":[],"bcc":[],"subject":"s","body":"b","in_reply_to":null}},
              {"id":"i_1","kind":"imessage","hash":"h","expiresAt":1,"message":{"chat_guid":"any;-;+15555550100","chat_name":"","recipients":["Sam (+15555550100)"],"text":"hi"}},
              {"id":"x_1","kind":"reminder","hash":"h","expiresAt":1,"message":{}},
              {"id":"c_1","kind":"calendar_update","hash":"h","expiresAt":1,"message":{"calendar":"Home","event_id":"e","etag":"t","organizer":"","attendees":"0",
                "before":{"title":"a","start":"2026-09-25","end":"2026-09-25","all_day":"1","location":"","notes":""},
                "after":{"title":"b","start":"2026-09-25","end":"2026-09-25","all_day":"1","location":"","notes":""}}},
              {"id":"c_2","kind":"calendar_update","hash":"h","expiresAt":1,"message":{"calendar":"Home","event_id":"e","etag":"t","organizer":"","attendees":"0",
                "before":{"title":"a","start":"2026-09-25","end":"2026-09-25","all_day":"1","location":"","notes":""}}},
              {"id":"c_3","kind":"calendar_delete","hash":"h","expiresAt":1,"message":{"calendar":"Home","event_id":"e","etag":"t","organizer":"x@y.z","attendees":"3",
                "before":{"title":"Gym","start":"2026-09-25","end":"2026-09-26","all_day":"1","location":"","notes":""}}},
              {"id":"c_4","kind":"calendar_delete_series","hash":"h","expiresAt":1,"message":{"calendar":"Home","event_id":"e","etag":"t","organizer":"","attendees":"0",
                "scope":"future","occurrence":"2026-10-14T17:00:00-06:00",
                "before":{"title":"Practice","start":"2026-10-14T17:00:00-06:00","end":"2026-10-14T18:30:00-06:00","all_day":"0","location":"","notes":""}}},
              {"id":"c_5","kind":"calendar_delete_series","hash":"h","expiresAt":1,"message":{"calendar":"Home","event_id":"e","etag":"t","organizer":"","attendees":"0",
                "scope":"everything","occurrence":"",
                "before":{"title":"Practice","start":"2026-10-14T17:00:00-06:00","end":"2026-10-14T18:30:00-06:00","all_day":"0","location":"","notes":""}}}
            ]}
            """.data(using: .utf8)!
        let page = try JSONDecoder().decode(ApprovalPage.self, from: json)
        XCTAssertEqual(
            page.pending.map(\.id), ["p_1", "i_1", "c_1", "c_3", "c_4"],
            "unknown kind, an update without `after` and an unknown scope are skipped, not fatal")
        guard case .seriesDelete(_, .future, "2026-10-14T17:00:00-06:00") = page.pending.last?.payload else {
            return XCTFail("series delete not decoded")
        }
    }

    func testOldHubItemsWithoutKindAreMail() throws {
        let json = """
            {"pending":[{"id":"p_1","hash":"h","expiresAt":1,"message":{"to":["user@example.com"],"cc":[],"bcc":[],"subject":"s","body":"b","in_reply_to":null}}]}
            """.data(using: .utf8)!
        let page = try JSONDecoder().decode(ApprovalPage.self, from: json)
        guard case .mail = page.pending.first?.payload else { return XCTFail("not mail") }
    }

    func testTextReadBack() {
        let a = Approval(id: "i", hash: "h", expiresAt: 1, payload: .text(Self.text))
        XCTAssertEqual(a.readBack, "It says: On my way \u{2014} 10 min. Send it?")
    }

    func testGroupReadBackNeverSpeaksTheMemberSetName() {
        let g = Approval.Text(chat_guid: "any;+;chat1", chat_name: "Sam", recipients: ["+15555550101", "Chris X (user4@example.com)"], text: "hi")
        let a = Approval(id: "i", hash: "h", expiresAt: 1, payload: .text(g))
        XCTAssertEqual(a.readBack, "It says: hi. Send it?")
        XCTAssertFalse(a.readBack.contains("Sam"))
    }

    func testUpdateReadBackSaysWhatChangesInTheEventsZone() {
        let a = Approval(id: "c", hash: "h", expiresAt: 1, payload: .eventUpdate(Self.change, after: Self.moved))
        XCTAssertEqual(
            a.readBack,
            "Change the calendar event Dentist, Friday, September 25, 2:00 PM to 3:00 PM. Move it to Friday, September 25, 4:00 PM to 5:00 PM. Say send to change it, or cancel."
        )
    }

    func testDeleteReadBackWarnsAboutInvitations() {
        let inv = Approval.EventChange(
            calendar: "Home", event_id: "e", etag: "t", organizer: "user5@example.com", attendees: "4",
            before: .init(title: "Offsite", start: "2026-09-25", end: "2026-09-26", all_day: "1", location: "HQ", notes: ""), after: nil)
        let a = Approval(id: "c", hash: "h", expiresAt: 1, payload: .eventDelete(inv))
        XCTAssertEqual(
            a.readBack,
            "Delete the calendar event Offsite, Friday, September 25 through Saturday, September 26, all day, at HQ. It's an invitation from user5@example.com with 4 people; they may be notified. Say send to delete it, or cancel."
        )
    }
}
