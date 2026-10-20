import SwiftUI

/// One cue in a list the user can edit: after recording, or saved in Prime.
struct CueListRow: Identifiable {
    let id: String
    let slide: Int
    let group: String
    let text: String
    let trailing: String
    var nudge = 0.0
    /// "New", "Removed", "Taken back"…
    var status: String?
    /// Removed or left out: dimmed and struck through, and can be put back.
    var isOut = false
}

struct CueActions {
    var nudge: (String, Double) -> Void
    var resetNudge: (String) -> Void
    var setSlide: (String, Int) -> Void
    /// Adds the next slide after this one and returns its id.
    var add: (String) -> String?
    var toggleRemove: (String) -> Void
}

/// The cue list on the review screen and in Saved Cues. Click a cue to edit it; ← → move it,
/// ↑ ↓ pick another, Delete removes it.
struct CueList: View {
    static let step = 0.25

    let rows: [CueListRow]
    @Binding var selected: String?
    /// The presentation's slide count, when known, as the highest slide number.
    var slideCount: Int?
    let actions: CueActions
    /// Scrolls on its own (review screen) rather than growing with the page (Saved Cues).
    var scrolls = false

    var body: some View {
        Group {
            if scrolls {
                ScrollViewReader { proxy in
                    ScrollView {
                        list.padding(10)
                    }
                    .onChange(of: selected) {
                        if let selected { withAnimation(.snappy) { proxy.scrollTo(selected) } }
                    }
                }
            } else {
                list
            }
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { nudgeSelected(-Self.step) }
        .onKeyPress(.rightArrow) { nudgeSelected(Self.step) }
        .onKeyPress(.upArrow) { moveSelection(-1) }
        .onKeyPress(.downArrow) { moveSelection(1) }
        .onKeyPress(.delete) { removeSelected() }
        .onKeyPress(.deleteForward) { removeSelected() }
    }

    private var list: some View {
        LazyVStack(spacing: 0) {
            ForEach(rows) { row in
                CueListRowView(row: row, isSelected: selected == row.id, slideCount: slideCount,
                               actions: actions, select: { selected = $0 })
                    .id(row.id)
                if row.id != rows.last?.id { Divider().padding(.leading, 48) }
            }
        }
    }

    private func nudgeSelected(_ seconds: Double) -> KeyPress.Result {
        guard let selected, let row = rows.first(where: { $0.id == selected }), !row.isOut else { return .ignored }
        actions.nudge(selected, seconds)
        return .handled
    }

    private func moveSelection(_ by: Int) -> KeyPress.Result {
        guard !rows.isEmpty else { return .ignored }
        let i = selected.flatMap { s in rows.firstIndex { $0.id == s } }
        let next = i.map { min(max($0 + by, 0), rows.count - 1) } ?? (by > 0 ? 0 : rows.count - 1)
        selected = rows[next].id
        return .handled
    }

    private func removeSelected() -> KeyPress.Result {
        guard let selected else { return .ignored }
        actions.toggleRemove(selected)
        return .handled
    }
}

private struct CueListRowView: View {
    let row: CueListRow
    let isSelected: Bool
    let slideCount: Int?
    let actions: CueActions
    let select: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("\(row.slide)")
                    .font(.callout.weight(.semibold)).monospacedDigit()
                    .frame(minWidth: 28)
                    .padding(.vertical, 3)
                    .background(.tint.opacity(0.18), in: Capsule())
                VStack(alignment: .leading, spacing: 2) {
                    Text(firstLine(row.text))
                        .strikethrough(row.isOut)
                        .foregroundStyle(row.text.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                    if !row.group.isEmpty {
                        Text(row.group).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let status = row.status {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                if row.nudge != 0 && !row.isOut {
                    Text(row.nudge.formatted(.number.precision(.fractionLength(0...2)).sign(strategy: .always())) + "s")
                        .font(.caption.weight(.semibold)).monospacedDigit()
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.orange.opacity(0.2), in: Capsule())
                        .help("Moved \(abs(row.nudge).formatted()) s \(row.nudge > 0 ? "later" : "earlier")")
                }
                Text(row.trailing).font(.callout).monospacedDigit().foregroundStyle(.secondary)
            }
            .opacity(row.isOut ? 0.55 : 1)
            if isSelected {
                editBar.padding(.leading, 40)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(isSelected ? AnyShapeStyle(.tint.opacity(0.08)) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.tint.opacity(0.5))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { select(isSelected ? nil : row.id) }
    }

    private var editBar: some View {
        HStack(spacing: 8) {
            if !row.isOut {
                Stepper(value: Binding(get: { row.slide }, set: { actions.setSlide(row.id, $0) }),
                        in: 1...max(slideCount ?? 999, row.slide)) {
                    Text("Slide \(row.slide)").monospacedDigit()
                }
                .help("Which slide this cue shows")
                Divider().frame(height: 16)
                Button { actions.nudge(row.id, -CueList.step) } label: {
                    Label("Earlier", systemImage: "minus")
                }
                .help("Fire a quarter second earlier (←)")
                Button { actions.nudge(row.id, CueList.step) } label: {
                    Label("Later", systemImage: "plus")
                }
                .help("Fire a quarter second later (→)")
                if row.nudge != 0 {
                    Button("Reset") { actions.resetNudge(row.id) }
                }
                Spacer(minLength: 8)
                Button("Add Next Slide", systemImage: "plus.rectangle.on.rectangle") {
                    if let id = actions.add(row.id) { select(id) }
                }
                .help("Adds a cue for the next slide, halfway to the cue after this one")
            } else {
                Spacer(minLength: 8)
            }
            Button(row.isOut ? "Put Back" : "Remove", systemImage: row.isOut ? "arrow.uturn.backward" : "trash") {
                actions.toggleRemove(row.id)
            }
            .help(row.isOut ? "Use this cue again" : "Leave this cue out (Delete)")
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

func firstLine(_ text: String) -> String {
    let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    return line.isEmpty ? "Blank" : line
}
