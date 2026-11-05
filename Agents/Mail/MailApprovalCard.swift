import SwiftUI

/// The tap path for the same approval voice uses. Shows exactly what will
/// happen, built only from the hashed fields: for an email every recipient,
/// the subject and the whole body; for a text who gets it and the whole text;
/// for a calendar change the event as it is and each field that changes.
struct MailApprovalCard: View {
    let item: Approval
    @State private var result: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.sp2) {
            Text("\(item.noun.prefix(1).uppercased())\(item.noun.dropFirst()) waiting for your OK").deckLabel()
            content
            if !item.isIntact {
                Text("This \(item.noun) changed on its way to the phone. It can't be approved.")
                    .font(Deck.small).foregroundStyle(Deck.critInk)
            }
            if let result { Text(result).font(Deck.small).foregroundStyle(Deck.muted) }
            HStack {
                Button("Cancel") { act { await MailApprovals.shared.cancel(item) } }
                    .buttonStyle(DeckButtonStyle(.ghost, small: true))
                Spacer()
                Button(item.actionTitle) { act { await MailApprovals.shared.approve(item) } }
                    .buttonStyle(DeckButtonStyle(.primary, small: true))
                    .disabled(!item.isIntact)
            }
            .disabled(busy)
        }
        .padding(Theme.sp3)
        .deckCard()
    }

    @ViewBuilder private var content: some View {
        switch item.payload {
        case .mail(let m):
            line("To", m.to.joined(separator: ", "))
            if !m.cc.isEmpty { line("Cc", m.cc.joined(separator: ", ")) }
            if !m.bcc.isEmpty { line("Bcc", m.bcc.joined(separator: ", ")) }
            Text(m.subject.isEmpty ? "(no subject)" : m.subject).font(Deck.heading).foregroundStyle(Deck.ink)
            scroll(m.body)
            if m.in_reply_to != nil {
                Text("Reply in an existing thread").font(Deck.small).foregroundStyle(Deck.muted)
            }
        case .text(let t):
            line("To", t.recipients.joined(separator: ", "))
            // Shown last and labelled: a group's name is set by any member.
            if !t.chat_name.isEmpty { line("Group name (set by a member)", t.chat_name) }
            scroll(t.text)
        case .eventUpdate(let c, let after):
            event(c)
            ForEach(Approval.changes(from: c.before, to: after), id: \.self) {
                Text($0).font(Deck.body).foregroundStyle(Deck.ink)
            }
        case .eventDelete(let c):
            event(c)
            Text("Delete this event.").font(Deck.body).foregroundStyle(Deck.critInk)
        case .seriesDelete(let c, let scope, _):
            event(c)
            Text("Repeating event").font(Deck.small).foregroundStyle(Deck.muted)
            Text(Approval.scopeLine(scope)).font(Deck.body).foregroundStyle(Deck.critInk)
        case .calendarCreate(let name):
            Text(name).font(Deck.heading).foregroundStyle(Deck.ink)
            Text("Create this calendar.").font(Deck.body).foregroundStyle(Deck.ink)
        case .calendarRename(let c, let newName):
            Text(c.name).font(Deck.heading).foregroundStyle(Deck.ink)
            Text("Rename this calendar to \(newName). Its events stay.").font(Deck.body).foregroundStyle(Deck.ink)
        case .calendarDelete(let c, let events):
            Text(c.name).font(Deck.heading).foregroundStyle(Deck.ink)
            Text("Delete this whole calendar, \(Approval.eventCount(events)).").font(Deck.body).foregroundStyle(Deck.critInk)
        }
    }

    @ViewBuilder private func event(_ c: Approval.EventChange) -> some View {
        Text(c.before.title).font(Deck.heading).foregroundStyle(Deck.ink)
        line("When", Approval.spoken(c.before))
        if !c.before.location.isEmpty { line("Where", c.before.location) }
        line("Calendar", c.calendar)
        if !c.organizer.isEmpty || c.attendees != "0" {
            line("Invitation", "\(c.organizer.isEmpty ? "" : "from \(c.organizer), ")\(c.attendees) attendees; they may be notified")
        }
    }

    private func scroll(_ text: String) -> some View {
        ScrollView {
            Text(text).font(Deck.body).foregroundStyle(Deck.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 160)
    }

    private func line(_ label: String, _ value: String) -> some View {
        Text("\(label): \(value)").font(Deck.small).foregroundStyle(Deck.muted)
    }

    private func act(_ f: @escaping @MainActor () async -> String) {
        busy = true
        Task {
            result = await f()
            busy = false
        }
    }
}

/// Every pending approval, over the top of the chat, refreshed while the chat
/// is on screen. Empty (and so invisible) when nothing is waiting or mailgate
/// isn't set up.
struct MailApprovalStack: View {
    private let approvals = MailApprovals.shared

    var body: some View {
        VStack(spacing: Theme.sp2) {
            ForEach(approvals.pending) { MailApprovalCard(item: $0) }
        }
        .padding(.horizontal, Theme.sp3)
        .padding(.top, Theme.sp2)
        .task {
            while !Task.isCancelled {
                await approvals.refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}
