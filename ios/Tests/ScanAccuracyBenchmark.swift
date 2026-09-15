import Foundation
import GRDB
import Testing
@testable import BinderBooks

/// End-to-end scanner accuracy, against the real catalog.
///
/// Every other test in this project asks "does this case behave". This one asks
/// "how often is the scanner right", which is the only question that can settle
/// an argument about where artwork belongs in the order of authority.
///
/// The fixture is built on the Mac by `scratchpad/makefixture.swift`: 150 real
/// cards sampled from the main English sets, each rendered as the camera would
/// see it — downscaled, blurred and dimmed — then read with the same Vision
/// text request the scanner uses and signed with the same arithmetic. What this
/// file stores is the *output of the camera*, so the matcher runs here on real
/// readings with real misreads in them.
///
/// It measures optimistically in one way that cannot be helped: the catalog's
/// reference signature was built from the same photograph the degraded look is
/// made from, so a real card under a real lamp is harder than this. Treat the
/// figures as a comparison between two versions of the matcher, not as a
/// promise about the phone.
///
/// Skipped unless the fixture is present, which it is only on the machine that
/// built it.
@Suite struct ScanAccuracyBenchmark {
    struct Item: Codable { var transcript: String; var top: Double; var height: Double }
    struct Row: Codable { var productId: Int; var condition: String; var items: [Item]; var art: [Int8] }

    static var fixturePath: String {
        ProcessInfo.processInfo.environment["SCAN_FIXTURE"] ?? ""
    }

    @Test func measure() throws {
        let path = Self.fixturePath
        try #require(!path.isEmpty && FileManager.default.fileExists(atPath: path), "no SCAN_FIXTURE; build it with scratchpad/makefixture.swift")
        let rows = try JSONDecoder().decode([Row].self, from: Data(contentsOf: URL(fileURLWithPath: path)))

        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: RealCatalogMatchTests.catalogPath, configuration: configuration)
        let index = try queue.read { try ArtIndex.load($0) }

        struct Tally { var right = 0; var wrong = 0; var unassigned = 0; var inChip = 0; var total = 0 }
        var byCondition: [String: Tally] = [:]
        var wrongExamples: [String] = []

        for row in rows {
            let items = row.items.map {
                RecognizedText(id: UUID(), transcript: $0.transcript, top: $0.top, height: $0.height)
            }
            var observation = FrameInterpreter.interpret(items).observation
            observation.artDescriptor = row.art
            observation.sawCard = true
            let result = try queue.read { db in
                try CardMatcher.match(
                    db, observation: observation, bias: [], defaultPrinting: nil,
                    art: index, language: .english
                )
            }
            var tally = byCondition[row.condition] ?? Tally()
            tally.total += 1
            if result.candidates.contains(where: { $0.productId == row.productId }) { tally.inChip += 1 }
            switch result.productId {
            case nil: tally.unassigned += 1
            case row.productId: tally.right += 1
            default:
                tally.wrong += 1
                if wrongExamples.count < 12 {
                    let got = result.candidates.first { $0.productId == result.productId }
                    wrongExamples.append("\(row.condition) \(row.productId) -> \(result.productId!) \(got?.name ?? "?") [read '\(observation.name ?? "no name")' \(observation.number ?? "no number")]")
                }
            }
            byCondition[row.condition] = tally
        }

        for (condition, tally) in byCondition.sorted(by: { $0.key < $1.key }) {
            let pct = { (n: Int) in String(format: "%.1f%%", 100.0 * Double(n) / Double(tally.total)) }
            print("== \(condition): \(tally.total) cards")
            print("   right      \(tally.right)  \(pct(tally.right))")
            print("   WRONG      \(tally.wrong)  \(pct(tally.wrong))")
            print("   unassigned \(tally.unassigned)  \(pct(tally.unassigned))")
            print("   in the chip \(tally.inChip)  \(pct(tally.inChip))")
        }
        print("-- wrong examples")
        for line in wrongExamples { print("   \(line)") }
    }
}
