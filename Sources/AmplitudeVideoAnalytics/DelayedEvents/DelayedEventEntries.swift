import AmplitudeSwift
import Foundation

extension DelayedEventTracker {
    struct Entry {
        enum Kind {
            case instant
            case delayed
        }

        let event: BaseEvent
        let kind: Kind
        /// Bytes of the event encoded alone, so admission stays O(1).
        let encodedSize: Int

        init?(event: BaseEvent, kind: Kind) {
            guard let data = try? JSONEncoder().encode(event) else { return nil }
            self.event = event
            self.kind = kind
            self.encodedSize = data.count
        }
    }

    struct OrderedEntries {
        enum Rejection: Error {
            case unencodable
            case wouldExceedSizeLimit
        }

        private var order: [String] = []
        private var byId: [String: Entry] = [:]
        private var totalEventBytes = 0

        var isEmpty: Bool { order.isEmpty }

        var inOrder: [(insertId: String, entry: Entry)] {
            order.compactMap { id in byId[id].map { (id, $0) } }
        }

        subscript(insertId: String) -> Entry? { byId[insertId] }

        /// Decides only — storing a `.success` entry stays a separate `upsert` call.
        func admissibleEntry(_ event: BaseEvent, kind: Entry.Kind, for insertId: String) -> Result<Entry, Rejection> {
            guard let entry = Entry(event: event, kind: kind) else {
                return .failure(.unencodable)
            }
            guard encodedSetSize(upserting: entry, for: insertId) <= DelayedEventsDefaults.eventsSizeLimit else {
                return .failure(.wouldExceedSizeLimit)
            }
            return .success(entry)
        }

        /// Encoded size of the set as a JSON array (elements, commas, brackets) if `entry` were upserted.
        private func encodedSetSize(upserting entry: Entry, for insertId: String) -> Int {
            let replaced = byId[insertId]
            let elementBytes = totalEventBytes - (replaced?.encodedSize ?? 0) + entry.encodedSize
            let count = order.count + (replaced == nil ? 1 : 0)
            return elementBytes + (count - 1) + 2
        }

        mutating func upsert(_ entry: Entry, for insertId: String) {
            if let replaced = byId.updateValue(entry, forKey: insertId) {
                totalEventBytes -= replaced.encodedSize
            } else {
                order.append(insertId)
            }
            totalEventBytes += entry.encodedSize
        }

        mutating func remove(_ insertId: String) {
            guard let removed = byId.removeValue(forKey: insertId) else { return }
            totalEventBytes -= removed.encodedSize
            order.removeAll { $0 == insertId }
        }

        mutating func removeAll() {
            order.removeAll()
            byId.removeAll()
            totalEventBytes = 0
        }
    }
}
