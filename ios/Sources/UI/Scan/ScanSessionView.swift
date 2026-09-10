import SwiftData
import SwiftUI

/// The scan loop. Viewfinder on top, the running list of squares below, the
/// session defaults in one row. Nothing here blocks the scanner.
struct ScanSessionView: View {
    let session: ScanSession
    var onClose: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(CatalogController.self) private var catalog
    @State private var model: ScanSessionModel?
    @State private var correcting: OwnedCard?
    @State private var showReview = false
    @State private var showDiscard = false
    @State private var simulatedText = ""

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    content(model)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { onClose() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        showReview = true
                    } label: {
                        Text("Review")
                        if let model, !model.cards.isEmpty {
                            Text("\(model.cards.count)")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.tint, in: Capsule())
                                .foregroundStyle(.white)
                        }
                    }
                    .disabled(model?.cards.isEmpty ?? true)
                }
            }
            .navigationDestination(isPresented: $showReview) {
                if let model {
                    ReviewView(model: model, onCommitted: onClose)
                }
            }
        }
        .task {
            if model == nil {
                let m = ScanSessionModel(session: session, context: modelContext, catalog: catalog)
                model = m
                catalog.beginExclusiveUse()
                await m.loadRows()
                applyDebugScans(m)
            }
        }
        .onDisappear {
            catalog.endExclusiveUse()
        }
        .sheet(item: $correcting) { card in
            if let model {
                CardCorrectionView(card: card, model: model)
            }
        }
    }

    private func content(_ model: ScanSessionModel) -> some View {
        VStack(spacing: 0) {
            SessionDefaultsRow(model: model)
            Divider()
            viewfinder(model)
            Divider()
            squares(model)
        }
    }

    @ViewBuilder
    private func viewfinder(_ model: ScanSessionModel) -> some View {
        ZStack(alignment: .bottom) {
            #if os(iOS)
            if ScannerView.isSupported {
                ScannerView(isActive: correcting == nil && !showReview) { observation in
                    model.handle(observation)
                }
            } else {
                simulatorViewfinder(model)
            }
            #else
            simulatorViewfinder(model)
            #endif

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(model.cards.count) cards")
                        .font(.headline)
                    Text(model.sessionTotalCents.asCurrency)
                        .font(.subheadline.monospacedDigit())
                    if model.inFlight > 0 {
                        Text("matching…")
                            .font(.caption)
                    }
                }
                Spacer()
                Button {
                    model.duplicateLast()
                } label: {
                    Label("Same card again", systemImage: "plus.square.on.square")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
                .disabled(model.cards.isEmpty)
            }
            .padding(10)
            .background(.thinMaterial)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 300)
        .clipped()
    }

    /// The simulator has no camera. Type what the camera would read, so the
    /// matcher, the squares, review, and commit still run end to end.
    private func simulatorViewfinder(_ model: ScanSessionModel) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.metering.unknown")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No live scanner on this device.")
                .foregroundStyle(.secondary)
            #if DEBUG
            HStack {
                TextField("Name and number, e.g. Mega Zeraora ex 114/084", text: $simulatedText)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(feedSimulated)
                Button("Scan", action: feedSimulated)
                    .buttonStyle(.borderedProminent)
                    .disabled(simulatedText.isEmpty)
            }
            .padding(.horizontal)
            #endif
            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 24)
        .background(Color.black.opacity(0.04))
    }

    private func feedSimulated() {
        guard let model else { return }
        model.simulate(simulatedText)
        simulatedText = ""
    }

    /// `SIMCTL_CHILD_CT_SIMULATE_SCANS="Mega Zeraora ex 114/084;Charizard 4/102"`
    private func applyDebugScans(_ model: ScanSessionModel) {
        #if DEBUG
        guard let raw = ProcessInfo.processInfo.environment["CT_SIMULATE_SCANS"], model.cards.isEmpty else { return }
        for entry in raw.split(separator: ";") {
            model.simulate(String(entry))
        }
        if ProcessInfo.processInfo.environment["CT_OPEN_REVIEW"] == "1" {
            Task {
                while model.inFlight > 0 { try? await Task.sleep(for: .milliseconds(100)) }
                showReview = true
            }
        }
        #endif
    }

    private func squares(_ model: ScanSessionModel) -> some View {
        ScrollView {
            if model.cards.isEmpty {
                Text("Point the camera at a card. Each match appears here, newest first. Tap a square to correct it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(24)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(model.cards) { card in
                        Button {
                            correcting = card
                        } label: {
                            ScannedSquare(card: card, hit: model.hit(for: card), marketCents: model.marketCents(for: card))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
            }
        }
    }
}

/// Condition once per session, and an optional printing default for bulk runs.
struct SessionDefaultsRow: View {
    let model: ScanSessionModel

    private let printingDefaults = ["Normal", "Reverse Holofoil", "Holofoil"]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(CardCondition.allCases, id: \.self) { condition in
                    Chip(title: condition.short, isSelected: model.session.defaultCondition == condition.rawValue) {
                        model.setDefaultCondition(condition.rawValue)
                    }
                    .accessibilityLabel(condition.rawValue)
                }
                Divider().frame(height: 20)
                Chip(title: "Printing by rarity", isSelected: model.session.defaultPrinting == nil) {
                    model.setDefaultPrinting(nil)
                }
                ForEach(printingDefaults, id: \.self) { printing in
                    Chip(title: printing, isSelected: model.session.defaultPrinting == printing) {
                        model.setDefaultPrinting(printing)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
    }
}
