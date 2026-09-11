import Foundation
import Observation
import SwiftData

/// Pulls graded comps from PPT onto cards and saves each one as it lands.
/// Fetched figures go in `fetchedCompCents`; what he typed stays untouched in
/// `gradedCompCents` and wins on display.
///
/// One card at a time with a pause between, because PPT allows 60 calls a
/// minute and a throttle stops the whole run.
@MainActor
@Observable
final class CompsFetcher {
    struct Report: Equatable {
        var fetched = 0
        var unknown = 0
        var skipped = 0
        var stoppedBy: String?

        var summary: String {
            var parts: [String] = []
            parts.append(fetched == 1 ? "1 card got comps" : "\(fetched) cards got comps")
            if unknown > 0 { parts.append(unknown == 1 ? "1 is not on PPT" : "\(unknown) are not on PPT") }
            if skipped > 0 { parts.append(skipped == 1 ? "1 has no catalog match" : "\(skipped) have no catalog match") }
            if let stoppedBy { parts.append("stopped: \(stoppedBy)") }
            return parts.joined(separator: ". ") + "."
        }
    }

    private(set) var isRunning = false
    private(set) var done = 0
    private(set) var total = 0
    private(set) var lastReport: Report?

    /// About what a run costs. An id lookup with eBay data is two credits.
    static func creditEstimate(for cards: [OwnedCard]) -> Int {
        cards.filter(\.isIdentified).count * 2
    }

    func fetch(_ cards: [OwnedCard], context: ModelContext, client: PPTClient, pause: Duration = .milliseconds(1_100)) async -> Report {
        var report = Report()
        isRunning = true
        total = cards.count
        done = 0
        defer { isRunning = false; lastReport = report }

        for card in cards {
            defer { done += 1 }
            guard card.isIdentified else { report.skipped += 1; continue }
            do {
                if let comps = try await client.gradedComps(tcgPlayerId: card.productId, language: card.language) {
                    card.fetchedCompCents = comps
                    card.compsFetchedAt = Date()
                    report.fetched += 1
                } else {
                    card.fetchedCompCents = [:]
                    card.compsFetchedAt = Date()
                    report.unknown += 1
                }
                try? context.save()
            } catch PPTClient.Failure.noKey {
                report.stoppedBy = "no PPT key in Settings"
                return report
            } catch PPTClient.Failure.throttled(let after) {
                report.stoppedBy = after.map { "PPT asked for a \($0)s pause" } ?? "PPT rate limit"
                return report
            } catch PPTClient.Failure.http(let code) {
                report.stoppedBy = "PPT answered \(code)"
                return report
            } catch {
                report.stoppedBy = error.localizedDescription
                return report
            }
            if done + 1 < total { try? await Task.sleep(for: pause) }
        }
        return report
    }
}
