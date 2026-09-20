import SwiftUI

/// One line under the viewfinder that is never empty.
///
/// The scanner had no way to say what it was doing. A dead loop, an empty
/// chute, a card held too close, a denied camera permission and a closed
/// catalog all looked the same: a picture with nothing happening under it. The
/// bar always shows something, so "nothing is happening" is itself a reading he
/// can act on rather than a silence he has to guess at.
struct ScanStatusBar: View {
    let fault: ScannerFault?
    /// What the loop is doing when nothing is wrong.
    let activity: String
    /// Cards waiting on the matcher.
    var inFlight: Int = 0
    var onRepair: (ScannerFault.Repair) -> Void = { _ in }
    var onDismiss: () -> Void = {}

    var body: some View {
        if let fault {
            faultRow(fault)
        } else {
            activityRow
        }
    }

    private func faultRow(_ fault: ScannerFault) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.white)
            Text(fault.message)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let repair = fault.repair {
                Button(repair.title) { onRepair(repair) }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.bordered)
                    .tint(.white)
            } else {
                Button("Dismiss", action: onDismiss)
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.bordered)
                    .tint(.white)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.9))
        .accessibilityElement(children: .combine)
    }

    private var activityRow: some View {
        HStack(spacing: 8) {
            if inFlight > 0 {
                ProgressView().controlSize(.mini)
            }
            Text(inFlight > 0 ? "Looking up \(inFlight)…" : activity)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }
}
