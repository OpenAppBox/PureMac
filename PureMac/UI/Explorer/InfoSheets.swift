import PureMacKit
import SwiftUI

/// File information for one index record, plus live metadata read with `lstat`.
struct FileInfoSheet: View {
    let record: FileRecord
    @Environment(\.dismiss) private var dismiss
    @Environment(\.byteStyle) private var byteStyle

    var body: some View {
        let live = try? FileStat.lstat(record.path).get()
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                FileIcon(path: record.path, size: 48)
                VStack(alignment: .leading) {
                    Text(record.name).font(.title3.weight(.semibold)).lineLimit(2)
                    Text(record.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(3)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                row("Kind", record.isContainer ? (record.kind == .package ? "Package" : "Folder") : "File")
                row("Category", record.category.displayName)
                row("On disk (at scan)", ByteFormat.string(record.allocatedSize, style: byteStyle))
                row("Logical size (at scan)", ByteFormat.string(record.logicalSize, style: byteStyle))
                if record.isContainer {
                    row("Contains", "\(record.fileCount.formatted()) files, \(record.directoryCount.formatted()) folders")
                }
                if let modified = record.modified { row("Modified", modified.formatted(date: .long, time: .shortened)) }
                if let created = record.created { row("Created", created.formatted(date: .long, time: .shortened)) }
                if let live {
                    row("Still present", live.identity.inode == record.inode ? "Yes, unchanged identity" : "Yes, but replaced since the scan")
                } else {
                    row("Still present", "No — removed or moved since the scan")
                }
            }
            .font(.callout)
            if record.flags.contains(.hardLinkDuplicate) {
                NoticeView(tone: .info, title: "Hard link", message: "Another path points to the same data. Removing this path alone frees no space.")
            }
            if record.flags.contains(.sparseOrDataless) {
                NoticeView(tone: .info, title: "Sparse, compressed or cloud file", message: "Its logical size is much larger than the space it uses on disk.")
            }
            if record.flags.contains(.unreadable) || record.flags.contains(.partial) {
                NoticeView(tone: .warning, title: "Incomplete", message: "Some contents could not be read, so the size shown is a lower bound.")
            }
            Text("APFS clones and snapshots may share blocks with other files; the space actually freed by removing an item can be smaller than its size.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Reveal in Finder") { SystemActions.revealInFinder([record.path]) }
                Button("Copy Path") { SystemActions.copyToPasteboard(record.path) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func row(_ label: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}

/// Lists the coverage gaps of a scan (unreadable, excluded, vanished, other volumes).
struct IssuesSheet: View {
    let session: ScanSession
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var issues: [ScanIssue] = []
    @State private var kind: ScanIssueKind?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Scan Coverage Gaps").font(.title3.weight(.semibold))
            Text("These locations were not measured. Their sizes are not part of any total.")
                .foregroundStyle(.secondary)
            Picker("Show", selection: $kind) {
                Text("All").tag(ScanIssueKind?.none)
                ForEach(ScanIssueKind.allCases, id: \.self) { Text($0.displayName).tag(Optional($0)) }
            }
            .frame(maxWidth: 260)
            Table(issues) {
                TableColumn("Location") { issue in
                    Text(abbreviate(issue.path)).lineLimit(1).truncationMode(.middle).help(issue.path)
                }
                TableColumn("Reason") { issue in Text(issue.kind.displayName) }.width(140)
                TableColumn("Detail") { issue in Text(issue.message).foregroundStyle(.secondary) }.width(180)
            }
            .contextMenu(forSelectionType: ScanIssue.ID.self) { ids in
                let paths = issues.filter { ids.contains($0.id) }.map(\.path)
                Button("Reveal in Finder") { SystemActions.revealInFinder(paths) }
                Button("Copy Path") { SystemActions.copyToPasteboard(paths.joined(separator: "\n")) }
            }
            if session.issueCount > Int64(issues.count) && kind == nil {
                Text("Showing the first \(issues.count) of \(session.issueCount) gaps.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Open Full Disk Access Settings") { SystemActions.openFullDiskAccessSettings() }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 720, height: 480)
        .task(id: kind) {
            issues = (try? await app.store?.issues(sessionID: session.id, kind: kind, limit: 2_000)) ?? []
        }
    }
}
