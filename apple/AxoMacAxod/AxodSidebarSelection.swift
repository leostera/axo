import Foundation

/// Sidebar membership is distinct from the one session displayed in the detail.
/// Native NSOutlineView owns modifier-key/range behavior; this preserves identities
/// across catalog/title refreshes instead of preserving fragile row indexes.
struct AxodSidebarSelection {
    private(set) var sessionIDs: Set<UUID> = []
    private var displayedSessionID: UUID?
    private var machineID: UUID?
    private var orderedSessionIDs: [UUID] = []

    /// Catalogs may arrive in UUID order after creation appended a new row. Keep
    /// existing visible rows in place; metadata refresh is not reorder intent.
    mutating func order(machineID: UUID?, incoming: [UUID]) -> [UUID] {
        if self.machineID != machineID {
            orderedSessionIDs = []
            sessionIDs = []
            displayedSessionID = nil
            self.machineID = machineID
        }
        let available = Set(incoming)
        orderedSessionIDs.removeAll { !available.contains($0) }
        var known = Set(orderedSessionIDs)
        for id in incoming where known.insert(id).inserted { orderedSessionIDs.append(id) }
        return orderedSessionIDs
    }

    mutating func observe(machineID: UUID?, available: Set<UUID>, displayedSessionID: UUID?) {
        if self.machineID != machineID {
            sessionIDs = []
            orderedSessionIDs = []
            self.displayedSessionID = nil
            self.machineID = machineID
        }
        if self.displayedSessionID != displayedSessionID {
            if let displayedSessionID {
                if !sessionIDs.contains(displayedSessionID) { sessionIDs = [displayedSessionID] }
            } else {
                sessionIDs = []
            }
        }
        self.displayedSessionID = displayedSessionID
        sessionIDs.formIntersection(available)
    }

    mutating func select(_ ids: Set<UUID>) { sessionIDs = ids }

    /// Right-click outside a selection addresses only that row, never the detail.
    func targets(clickedSessionID: UUID) -> Set<UUID> {
        sessionIDs.contains(clickedSessionID) ? sessionIDs : [clickedSessionID]
    }
}
