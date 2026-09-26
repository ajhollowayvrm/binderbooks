import PhotosUI
import QuickLook
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import VisionKit

/// The entry a receipt belongs to.
enum ReceiptOwner {
    case purchase(Purchase)
    case grading(GradingSubmission)
    case expense(BusinessExpense)

    /// Saves the files as receipts on the entry.
    @MainActor
    func attach(_ files: [ReceiptFile], context: ModelContext) {
        for file in files {
            let receipt = Receipt(kind: file.kind, data: file.data, fileName: file.fileName, text: file.text)
            context.insert(receipt)
            switch self {
            case .purchase(let purchase): receipt.purchase = purchase
            case .grading(let submission): receipt.grading = submission
            case .expense(let expense): receipt.expense = expense
            }
        }
        try? context.save()
    }
}

/// The three ways a receipt comes in: the document camera for paper, Photos
/// for a screenshot, and Files for a PDF.
///
/// Each file is read before `onAdd` gets it, so the caller has the text.
struct AddReceiptMenu<Label: View>: View {
    var onAdd: ([ReceiptFile]) -> Void
    @Binding var reading: Bool
    @ViewBuilder var label: () -> Label

    @State private var scanning = false
    @State private var pickingPhotos = false
    @State private var pickingFiles = false
    @State private var photos: [PhotosPickerItem] = []

    var body: some View {
        Menu {
            if VNDocumentCameraViewController.isSupported {
                Button { scanning = true } label: { SwiftUI.Label("Scan a paper receipt", systemImage: "doc.viewfinder") }
            }
            Button { pickingPhotos = true } label: { SwiftUI.Label("Screenshot or photo", systemImage: "photo") }
            Button { pickingFiles = true } label: { SwiftUI.Label("PDF or file", systemImage: "folder") }
        } label: {
            label()
        }
        .disabled(reading)
        .fullScreenCover(isPresented: $scanning) {
            DocumentCameraView { images in
                scanning = false
                guard !images.isEmpty else { return }
                read { await withOrderedResults(images) { await ReceiptReader.image($0) } }
            }
            .ignoresSafeArea()
        }
        .photosPicker(isPresented: $pickingPhotos, selection: $photos, maxSelectionCount: 10, matching: .images)
        .onChange(of: photos) { _, picked in
            guard !picked.isEmpty else { return }
            photos = []
            read {
                await withOrderedResults(picked) { item in
                    guard let data = try? await item.loadTransferable(type: Data.self) else { return nil }
                    return await ReceiptReader.image(data)
                }
            }
        }
        .fileImporter(isPresented: $pickingFiles, allowedContentTypes: [.pdf, .image], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            read { await withOrderedResults(urls) { await ReceiptReader.file(at: $0) } }
        }
    }

    private func read(_ work: @escaping () async -> [ReceiptFile]) {
        reading = true
        Task { @MainActor in
            let files = await work()
            reading = false
            if !files.isEmpty { onAdd(files) }
        }
    }

    /// One at a time, in order: the pages of a scan stay in page order.
    private func withOrderedResults<T>(_ inputs: [T], _ transform: (T) async -> ReceiptFile?) async -> [ReceiptFile] {
        var out: [ReceiptFile] = []
        for input in inputs {
            if let file = await transform(input) { out.append(file) }
        }
        return out
    }
}

/// VisionKit's document camera. It finds the edges of the paper, flattens it,
/// and takes several pages in one go.
struct DocumentCameraView: UIViewControllerRepresentable {
    var onFinish: ([UIImage]) -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onFinish: ([UIImage]) -> Void
        init(onFinish: @escaping ([UIImage]) -> Void) { self.onFinish = onFinish }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            onFinish((0..<scan.pageCount).map { scan.imageOfPage(at: $0) })
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onFinish([])
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            onFinish([])
        }
    }
}

/// One receipt in a list: a small picture and what it is.
struct ReceiptRow: View {
    var kind: Receipt.Kind
    var data: Data
    var fileName: String
    var index: Int

    @State private var thumbnail: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFill()
                } else {
                    Image(systemName: kind == .pdf ? "doc.richtext" : "doc.text.image")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 40, height: 56)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                Text(fileName.isEmpty ? "Receipt \(index + 1)" : fileName).lineLimit(1)
                Text(kind == .pdf ? "PDF" : "Image").font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: data.count) {
            thumbnail = ReceiptReader.thumbnail(kind: kind, data: data)
        }
    }
}

/// The receipts on a purchase, a grading charge, or an expense. Tap one to
/// open it. Swipe one to delete it.
struct ReceiptsSection: View {
    var receipts: [Receipt]
    var owner: ReceiptOwner

    @Environment(\.modelContext) private var modelContext
    @State private var previewURL: URL?
    @State private var reading = false

    private var sorted: [Receipt] { receipts.sorted { $0.addedAt < $1.addedAt } }

    var body: some View {
        Section {
            ForEach(Array(sorted.enumerated()), id: \.element.id) { index, receipt in
                Button {
                    previewURL = ReceiptReader.previewURL(kind: receipt.kind, data: receipt.data, id: receipt.id)
                } label: {
                    ReceiptRow(kind: receipt.kind, data: receipt.data, fileName: receipt.fileName, index: index)
                }
                .foregroundStyle(.primary)
            }
            .onDelete { offsets in
                let doomed = offsets.map { sorted[$0] }
                for receipt in doomed { modelContext.delete(receipt) }
                try? modelContext.save()
            }

            AddReceiptMenu(onAdd: { owner.attach($0, context: modelContext) }, reading: $reading) {
                if reading {
                    HStack { ProgressView(); Text("Reading the receipt…") }
                } else {
                    Label(receipts.isEmpty ? "Add a receipt" : "Add another receipt", systemImage: "paperclip")
                }
            }
        } header: {
            Text("Receipts")
        } footer: {
            if receipts.isEmpty {
                Text("A photo, a screenshot, or a PDF. The receipt is the record of what you paid.")
            }
        }
        .quickLookPreview($previewURL)
    }
}
