import Charts
import PureMacKit
import SwiftUI

/// Local scan history and growth trend (summaries are kept even after detailed indexes are pruned).
struct ScanHistoryView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.byteStyle) private var byteStyle
    @State private var sessions: [ScanSession] = []

    var body: some View {
        let completed = sessions.filter { $0.status == .completed }.reversed()
        VStack(alignment: .leading, spacing: 12) {
            if sessions.isEmpty {
                ContentUnavailableView("No scans yet", systemImage: "chart.line.uptrend.xyaxis",
                                       description: Text("Each completed scan adds a point here so you can see how your storage changes over time."))
            } else {
                if completed.count >= 2 {
                    Chart(Array(completed)) { session in
                        LineMark(x: .value("Date", session.startedAt), y: .value("Size", session.allocatedSize))
                        PointMark(x: .value("Date", session.startedAt), y: .value("Size", session.allocatedSize))
                    }
                    .chartYAxis {
                        AxisMarks { value in
                            AxisGridLine()
                            AxisValueLabel { if let bytes = value.as(Int64.self) { Text(ByteFormat.string(bytes, style: byteStyle)) } }
                        }
                    }
                    .frame(height: 180)
                    .accessibilityLabel("Scanned size over time")
                    Text("Compares completed scans of the locations chosen at the time; changing scan locations changes the totals.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Table(sessions) {
                    TableColumn("Date") { s in Text(s.startedAt.formatted(date: .abbreviated, time: .shortened)) }
                    TableColumn("Status") { s in Text(s.status.rawValue.capitalized) }.width(100)
                    TableColumn("Files") { s in Text(s.fileCount.formatted()).monospacedDigit() }.width(90)
                    TableColumn("On disk") { s in SizeText(s.allocatedSize) }.width(100)
                    TableColumn("Gaps") { s in Text(s.issueCount.formatted()).monospacedDigit() }.width(60)
                    TableColumn("Details") { s in Text(s.hasIndex ? "Browsable" : "Summary only").foregroundStyle(.secondary) }.width(110)
                }
            }
        }
        .padding(16)
        .task { sessions = (try? await app.store?.sessions(limit: 100)) ?? [] }
    }
}

/// Plain-language explanation of how PureMac measures space.
struct MeasurementExplanationView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How PureMac measures storage").font(.title2.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    item("On disk vs. logical size", "“On disk” is the space a file’s blocks actually occupy. “Logical” is the size apps report. They differ for sparse files (disk images, VMs), compressed files and iCloud files whose contents are not downloaded.")
                    item("Hard links", "Several paths can point to one file. PureMac counts its space once and marks the extra paths; removing one path frees nothing.")
                    item("APFS clones", "Copies made on APFS can share the same blocks until one changes. macOS does not reveal this sharing reliably, so two “duplicates” may use the space of one. Freed space can be smaller than the files’ sizes.")
                    item("Local snapshots", "Time Machine and system updates can keep local APFS snapshots. Space from deleted files stays in use until macOS removes the snapshot. PureMac never touches snapshots.")
                    item("Purgeable space", "macOS can free some space automatically (caches it manages, iCloud files). It is shown separately and never counted as cleanup.")
                    item("The Trash", "Moving items to the Trash does not free space. Space is released when you empty the Trash — PureMac never does that for you.")
                    item("What is not scanned", "Without Full Disk Access, macOS blocks some folders (Mail, Messages, Safari, other apps’ data). PureMac lists them as gaps. Space used by macOS itself, other users and snapshots appears as “outside the scanned locations”; PureMac does not guess what it contains.")
                    item("Three different numbers", "Identified size: what the selected files occupy now. Moved to Trash: what was moved. Observed change: the difference in free space PureMac measured before and after, which also reflects everything else happening on your Mac.")
                }
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 560, height: 520)
    }

    private func item(_ title: LocalizedStringKey, _ text: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.headline)
            Text(text).foregroundStyle(.secondary).lineLimit(8)
        }
    }
}
