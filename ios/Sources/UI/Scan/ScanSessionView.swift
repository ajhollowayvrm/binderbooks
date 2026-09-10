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
    @State private var captureCount = 0
    @State private var capturing = false
    /// Bumped after every still. Changing the id rebuilds the scanner, which
    /// is the only thing that unfreezes the preview after `capturePhoto()`.
    @State private var scannerGeneration = 0
    @State private var numberHint = false
    @State private var numberHintTask: Task<Void, Never>?
    @State private var nothingToCapture = false
    @AppStorage("scanMode") private var scanModeRaw = ScanMode.automatic.rawValue

    private var scanMode: ScanMode { ScanMode(rawValue: scanModeRaw) ?? .automatic }

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
                    Button("Close") { close() }
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

    /// The viewfinder takes three quarters of the height. The squares run in
    /// one row along the bottom, newest first.
    /// An empty session has nothing to resume. Delete it on the way out.
    private func close() {
        if let model, model.cards.isEmpty {
            model.discard()
        }
        onClose()
    }

    private func content(_ model: ScanSessionModel) -> some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                SessionDefaultsRow(model: model, scanModeRaw: $scanModeRaw)
                Divider()
                viewfinder(model)
                    .frame(height: geometry.size.height * 0.75)
                Divider()
                squares(model)
            }
        }
    }

    @ViewBuilder
    private func viewfinder(_ model: ScanSessionModel) -> some View {
        ZStack(alignment: .bottom) {
            #if os(iOS)
            if ScannerView.isSupported {
                ScannerView(
                    isActive: correcting == nil && !showReview,
                    mode: scanMode,
                    captureCount: captureCount,
                    onObservation: { observation in model.handle(observation) },
                    onNothingToCapture: { nothingToCapture = true },
                    onCaptureBegan: { capturing = true },
                    onCaptureEnded: { usedStill in
                        capturing = false
                        // Only a still kills the preview, and a still is now
                        // the rare fallback rather than every capture.
                        if usedStill { scannerGeneration += 1 }
                    },
                    onCapturedWithoutNumber: { showNumberHint() }
                )
                .id(scannerGeneration)
                if scanMode == .manual {
                    shutter
                }
                numberHintBanner
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
        .clipped()
    }

    /// The card logged from its name alone. Say so and move on: docs/03 says
    /// the loop never blocks, so this is a banner and not an alert.
    @ViewBuilder private var numberHintBanner: some View {
        if numberHint {
            VStack {
                Label("Read the name only. Show the number for the right set.", systemImage: "number")
                    .font(.footnote)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.top, 8)
                Spacer()
            }
            .transition(.move(edge: .top).combined(with: .opacity))
            .allowsHitTesting(false)
        }
    }

    private func showNumberHint() {
        numberHintTask?.cancel()
        withAnimation(.snappy) { numberHint = true }
        numberHintTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.snappy) { numberHint = false }
        }
    }

    /// Manual mode's shutter. Sits above the count bar, centered.
    private var shutter: some View {
        VStack {
            Spacer()
            Button {
                captureCount += 1
            } label: {
                ZStack {
                    Circle().fill(.white).frame(width: 72, height: 72)
                    Circle().stroke(.white, lineWidth: 4).frame(width: 84, height: 84)
                    if capturing {
                        ProgressView().tint(.black)
                    } else {
                        Image(systemName: "camera.viewfinder")
                            .font(.title2)
                            .foregroundStyle(.black)
                    }
                }
                .shadow(radius: 6)
            }
            .buttonStyle(.plain)
            // A second tap while the first is still reading photographs the
            // card twice and logs it twice.
            .disabled(capturing)
            .accessibilityLabel(capturing ? "Reading the card" : "Scan the card in view")
            .padding(.bottom, 84)
        }
        .frame(maxWidth: .infinity)
        .alert("Nothing to scan", isPresented: $nothingToCapture) {
            Button("OK") {}
        } message: {
            Text("No card name or number is in view. Move closer or hold still, then tap again.")
        }
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
        let env = ProcessInfo.processInfo.environment
        // Only the scans check for an open session. The other hooks must run on
        // their own, or a session left open blocks every one of them.
        if let raw = env["CT_SIMULATE_SCANS"], model.cards.isEmpty {
            for entry in raw.split(separator: ";") {
                model.simulate(String(entry))
            }
        }
        // `CT_SET_COST=3000` prices the whole simulated session at $30.00, the
        // way the Cost button does for a selection. simctl cannot tap.
        if let cents = env["CT_SET_COST"].flatMap(Int.init) {
            Task {
                while model.inFlight > 0 { try? await Task.sleep(for: .milliseconds(100)) }
                model.setBasis(totalCents: cents, for: model.cards)
            }
        }
        if env["CT_OPEN_REVIEW"] == "1" {
            Task {
                while model.inFlight > 0 { try? await Task.sleep(for: .milliseconds(100)) }
                showReview = true
            }
        }
        // `CT_AUTO_COMMIT="Walmart|4997"` commits the simulated session to a new
        // purchase with that vendor and total in cents, then closes the scanner.
        if let spec = env["CT_AUTO_COMMIT"] {
            let parts = spec.split(separator: "|")
            Task {
                while model.inFlight > 0 { try? await Task.sleep(for: .milliseconds(100)) }
                try? await Task.sleep(for: .milliseconds(500))
                let purchase = Purchase(vendor: String(parts.first ?? "Debug"), itemCostCents: parts.count > 1 ? Int(parts[1]) ?? 0 : 0)
                modelContext.insert(purchase)
                model.commit(to: purchase)
                onClose()
            }
        }
        #endif
    }

    private func squares(_ model: ScanSessionModel) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            if model.cards.isEmpty {
                Text("Point the camera at a card. Each match appears here, newest first. Tap one to correct it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            } else {
                LazyHStack(alignment: .top, spacing: 8) {
                    ForEach(model.cards) { card in
                        Button {
                            correcting = card
                        } label: {
                            ScannedSquare(card: card, hit: model.hit(for: card), marketCents: model.marketCents(for: card))
                                .frame(width: 88)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// Scan mode, condition once per session, and an optional printing default.
struct SessionDefaultsRow: View {
    let model: ScanSessionModel
    @Binding var scanModeRaw: String

    private let printingDefaults = ["Normal", "Reverse Holofoil", "Holofoil"]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ScanMode.allCases, id: \.self) { mode in
                    Chip(title: mode.title, systemImage: mode == .automatic ? "bolt" : "hand.tap", isSelected: scanModeRaw == mode.rawValue) {
                        scanModeRaw = mode.rawValue
                    }
                }
                Divider().frame(height: 20)
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
