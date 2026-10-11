import Foundation

@main
struct SidebarSelectionChecks {
    static func main() {
        let machine = UUID(), otherMachine = UUID()
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        var selection = AxodSidebarSelection()
        precondition(selection.order(machineID: machine, incoming: [a, b, c]) == [a, b, c])
        precondition(selection.order(machineID: machine, incoming: [c, b, a, d]) == [a, b, c, d], "Catalog reordered existing visible rows")
        precondition(selection.order(machineID: machine, incoming: [c, b, d]) == [b, c, d])
        selection.observe(machineID: machine, available: [a, b, c, d], displayedSessionID: a)
        precondition(selection.sessionIDs == [a])
        selection.select([a, b, c])
        selection.observe(machineID: machine, available: [a, b, c, d], displayedSessionID: a)
        precondition(selection.sessionIDs == [a, b, c], "Metadata refresh replaced the native selection")
        precondition(selection.targets(clickedSessionID: b) == [a, b, c])
        precondition(selection.targets(clickedSessionID: d) == [d], "Context menu fell back to displayed/selected sessions")
        selection.observe(machineID: machine, available: [a, b, c, d], displayedSessionID: b)
        precondition(selection.sessionIDs == [a, b, c], "Changing detail within selection collapsed selection")
        selection.observe(machineID: machine, available: [a, b, c, d], displayedSessionID: d)
        precondition(selection.sessionIDs == [d], "External navigation failed to replace selection")
        selection.select([])
        selection.observe(machineID: machine, available: [a, b, c, d], displayedSessionID: d)
        precondition(selection.sessionIDs.isEmpty, "Deselecting the last row was undone by observation")
        selection.select([a, b, c])
        selection.observe(machineID: machine, available: [b, c, d], displayedSessionID: d)
        precondition(selection.sessionIDs == [b, c], "Removed identities survived catalog refresh")
        selection.observe(machineID: otherMachine, available: [b, c, d], displayedSessionID: d)
        precondition(selection.sessionIDs == [d], "Selection transferred to another machine")
        selection.observe(machineID: otherMachine, available: [b, c, d], displayedSessionID: nil)
        precondition(selection.sessionIDs.isEmpty)
        print("PASS: sidebar multi-selection identities, metadata retention, external navigation, empty selection, removed rows, machine change and exact context targets")
    }
}
