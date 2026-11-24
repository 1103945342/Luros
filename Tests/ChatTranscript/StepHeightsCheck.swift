import Foundation

/// The two pieces a long conversation's event goes through before the list
/// sees it: the heights a row keeps for its steps, and the rows an event
/// changed. Both decide what a streamed token costs, and both are pure.
func checkStepHeights() {
    var heights = ChatStepHeights<Int>()
    var measured: [UUID] = []
    let first = UUID()
    let second = UUID()

    func height(_ id: UUID, _ stamp: Int) -> CGFloat {
        heights.height(for: id, stamp: stamp) {
            measured.append(id)
            return CGFloat(stamp)
        }
    }

    precondition(height(first, 1) == 1)
    precondition(measured == [first], "a step is measured the first time it is asked for")
    precondition(height(first, 1) == 1)
    precondition(measured == [first], "the same stamp is answered without laying the step out")
    precondition(height(first, 2) == 2)
    precondition(measured == [first, first], "a step in a new stamp is measured again")
    precondition(height(second, 2) == 2)
    precondition(measured == [first, first, second], "another step has its own entry")
    precondition(heights.count == 2)

    heights.forget()
    precondition(heights.count == 0)
    precondition(height(first, 2) == 2)
    precondition(measured == [first, first, second, first], "forgetting measures again")

    // Past its cap the cache starts over rather than growing with the reads.
    var small = ChatStepHeights<Int>(capacity: 2)
    let ids = (0 ..< 4).map { _ in UUID() }
    for id in ids {
        _ = small.height(for: id, stamp: 0) { 10 }
    }
    precondition(small.count == 2, "the third step cleared what the cap held, so two are kept")
    var remeasured = false
    _ = small.height(for: ids[0], stamp: 0) {
        remeasured = true
        return 10
    }
    precondition(remeasured, "a step the cap cleared is measured again")

    print("ok: step heights are kept by shape and state, forgotten on request and capped")
}

/// What the list is handed after an event: the rows that changed, one at a
/// time, or nothing when it has to diff the whole projection.
func checkRowDelta() {
    func row(_ id: UUID, _ text: String) -> ChatMessage {
        ChatMessage(id: id, role: .assistant, text: text)
    }

    let first = UUID(), second = UUID(), third = UUID()
    let rows = [row(first, "a"), row(second, "b"), row(third, "c")]

    precondition(ChatRowDelta.changed(rows, rows) == [], "an event that changed nothing updates nothing")
    precondition(ChatRowDelta.changed([], []) == [])

    var tail = rows
    tail[2].text = "c, still growing"
    precondition(ChatRowDelta.changed(rows, tail) == [2], "a stream changes the turn's last row")

    var head = rows
    head[0].text = "a, edited"
    precondition(ChatRowDelta.changed(rows, head) == [0], "a row that changed before the end is found")

    var both = rows
    both[1].text = "b, edited"
    both[2].text = "c, edited"
    precondition(ChatRowDelta.changed(rows, both) == [1, 2])

    var all = rows
    for index in all.indices { all[index].text += "!" }
    precondition(ChatRowDelta.changed(rows, all) == [0, 1, 2], "past the default limit four rows still update")
    precondition(ChatRowDelta.changed(rows, all, limit: 2) == nil, "more rows than the limit is the list's diff")

    let moved = [row(second, "b"), row(first, "a"), row(third, "c")]
    precondition(ChatRowDelta.changed(rows, moved) == nil, "a row that moved is the list's diff")
    precondition(ChatRowDelta.changed(rows, Array(rows.prefix(2))) == nil, "a row that went is the list's diff")
    precondition(ChatRowDelta.changed(rows, rows + [row(UUID(), "d")]) == nil, "a row that came is the list's diff")

    print("ok: one row's change is handed to the list on its own, anything structural diffs")
}