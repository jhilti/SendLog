import SwiftUI
import UIKit

struct WallLibraryView: View {
    @EnvironmentObject private var store: AppStore
    @State private var isShowingCreateWall = false
    @State private var selectedTab: LibraryTab = .walls
    @State private var previewTarget: BoulderPreviewTarget?
    @State private var searchText = ""
    @State private var selectedGradeFilter: ClimbingGrade?
    @State private var selectedProblemSort: ProblemSort = .date
    @State private var isShowingImportConfirmation = false
    @State private var isImportingBackup = false
    @State private var isExportingBackup = false
    @State private var backupDocument = BackupDocument(data: Data())
    @State private var wallPendingDeletion: Wall?
    @State private var expandedLogGroupIDs: Set<String> = []
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemBackground)
                    .ignoresSafeArea()

                VStack(spacing: 12) {
                    SessionTimerCard()
                        .padding(.horizontal)
                        .padding(.top, 8)

                    Picker("Library", selection: $selectedTab) {
                        ForEach(LibraryTab.allCases) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)

                    content
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .navigationTitle("SendLog")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: selectedTab.searchPrompt)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if selectedTab == .problems {
                        Menu {
                            Button("All Grades") {
                                selectedGradeFilter = nil
                            }
                            ForEach(ClimbingGrade.allCases) { grade in
                                Button(grade.rawValue) {
                                    selectedGradeFilter = grade
                                }
                            }
                        } label: {
                            Label(selectedGradeFilter?.rawValue ?? "All Grades", systemImage: "line.3.horizontal.decrease.circle")
                        }
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if selectedTab == .problems {
                        Menu {
                            ForEach(ProblemSort.allCases) { sort in
                                Button(sort.rawValue) {
                                    selectedProblemSort = sort
                                }
                            }
                        } label: {
                            Label(selectedProblemSort.rawValue, systemImage: "arrow.up.arrow.down.circle")
                        }
                    }

                    Menu {
                        Button {
                            prepareBackupExport()
                        } label: {
                            Label("Export Backup", systemImage: "square.and.arrow.up")
                        }

                        Button(role: .destructive) {
                            isShowingImportConfirmation = true
                        } label: {
                            Label("Import Backup", systemImage: "square.and.arrow.down")
                        }
                    } label: {
                        Label("Backup", systemImage: "externaldrive")
                    }

                    Button {
                        isShowingCreateWall = true
                    } label: {
                        Label("New Wall", systemImage: "plus")
                    }
                }
            }
            .navigationDestination(for: UUID.self) { wallID in
                WallDetailView(wallID: wallID)
            }
            .fullScreenCover(isPresented: $isShowingCreateWall) {
                CreateWallSheet()
            }
            .fullScreenCover(item: $previewTarget) { target in
                if let wall = store.wall(withID: target.wallID),
                   let image = store.image(for: wall) {
                    BoulderPreviewSheet(
                        wallID: target.wallID,
                        image: image,
                        initialBoulderID: target.boulderID
                    )
                } else {
                    ContentUnavailableView(
                        "Problem Not Available",
                        systemImage: "exclamationmark.triangle",
                        description: Text("Could not load this problem.")
                    )
                }
            }
            .confirmationDialog(
                "Import backup and replace current walls/problems?",
                isPresented: $isShowingImportConfirmation,
                titleVisibility: .visible
            ) {
                Button("Import and Replace", role: .destructive) {
                    isImportingBackup = true
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This cannot be undone.")
            }
            .fileExporter(
                isPresented: $isExportingBackup,
                document: backupDocument,
                contentType: .json,
                defaultFilename: backupFilename
            ) { result in
                if case .failure(let error) = result {
                    errorMessage = error.localizedDescription
                }
            }
            .fileImporter(
                isPresented: $isImportingBackup,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else {
                        return
                    }
                    importBackup(from: url)
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
            }
            .alert("Error", isPresented: Binding(
                get: { errorMessage != nil },
                set: { value in
                    if !value { errorMessage = nil }
                }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "Unknown error")
            }
        }
        .sessionTimerOverlay()
    }

    @ViewBuilder
    private var content: some View {
        if !store.hasLoaded {
            ProgressView("Loading library...")
        } else if selectedTab == .walls {
            if store.walls.isEmpty {
                ContentUnavailableView(
                    "No Walls Yet",
                    systemImage: "square.grid.3x3",
                    description: Text("Create your first wall by importing a photo.")
                )
            } else if filteredWalls.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                List(filteredWalls) { wall in
                    NavigationLink(value: wall.id) {
                        WallRow(wall: wall, image: store.image(for: wall))
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            wallPendingDeletion = wall
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
                .listStyle(.plain)
                .confirmationDialog(
                    "Delete Wall?",
                    isPresented: Binding(
                        get: { wallPendingDeletion != nil },
                        set: { value in
                            if !value { wallPendingDeletion = nil }
                        }
                    ),
                    titleVisibility: .visible,
                    presenting: wallPendingDeletion
                ) { wall in
                    Button("Delete", role: .destructive) {
                        deleteWall(wall)
                    }
                    Button("Cancel", role: .cancel) {}
                } message: { wall in
                    Text("Delete \"\(wall.name)\" and all of its holds and problems? This cannot be undone.")
                }
            }
        } else if selectedTab == .problems {
            if allProblems.isEmpty {
                ContentUnavailableView(
                    "No Problems Yet",
                    systemImage: "figure.climbing",
                    description: Text("Create problems on a wall to build your boulder library.")
                )
            } else if filteredProblems.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                List(filteredProblems) { entry in
                    Button {
                        previewTarget = BoulderPreviewTarget(
                            wallID: entry.wallID,
                            boulderID: entry.boulder.id
                        )
                    } label: {
                        ProblemLibraryRow(entry: entry)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        } else {
            if allLogGroups.isEmpty {
                ContentUnavailableView(
                    "No Log Entries Yet",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Log attempts or ticks on a problem to build your activity history.")
                )
            } else if filteredLogGroups.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                List(filteredLogGroups) { group in
                    SessionLogGroupRow(
                        group: group,
                        isExpanded: expansionBinding(for: group.id)
                    ) { target in
                        previewTarget = target
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private func expansionBinding(for groupID: String) -> Binding<Bool> {
        Binding(
            get: {
                !trimmedQuery.isEmpty || expandedLogGroupIDs.contains(groupID)
            },
            set: { isExpanded in
                if isExpanded {
                    expandedLogGroupIDs.insert(groupID)
                } else {
                    expandedLogGroupIDs.remove(groupID)
                }
            }
        )
    }

    private var filteredWalls: [Wall] {
        let query = trimmedQuery
        guard !query.isEmpty else {
            return store.walls
        }
        return store.walls.filter { wall in
            wall.name.localizedCaseInsensitiveContains(query)
        }
    }

    private var allProblems: [BoulderLibraryEntry] {
        store.walls
            .flatMap { wall in
                wall.boulders.map { boulder in
                    BoulderLibraryEntry(wallID: wall.id, wallName: wall.name, boulder: boulder)
                }
            }
    }

    private var filteredProblems: [BoulderLibraryEntry] {
        allProblems.filter { entry in
            let gradeMatches = selectedGradeFilter.map { $0.rawValue == entry.boulder.grade } ?? true

            let query = trimmedQuery
            let searchMatches: Bool
            if query.isEmpty {
                searchMatches = true
            } else {
                searchMatches =
                    entry.boulder.name.localizedCaseInsensitiveContains(query)
                    || entry.boulder.notes.localizedCaseInsensitiveContains(query)
                    || entry.boulder.grade.localizedCaseInsensitiveContains(query)
                    || entry.wallName.localizedCaseInsensitiveContains(query)
            }

            return gradeMatches && searchMatches
        }
        .sorted(by: problemSortComparator)
    }

    private func problemSortComparator(_ lhs: BoulderLibraryEntry, _ rhs: BoulderLibraryEntry) -> Bool {
        switch selectedProblemSort {
        case .difficulty:
            let lhsDifficulty = gradeRank(for: lhs.boulder.grade)
            let rhsDifficulty = gradeRank(for: rhs.boulder.grade)
            if lhsDifficulty != rhsDifficulty {
                return lhsDifficulty > rhsDifficulty
            }
            if lhs.boulder.tickCount != rhs.boulder.tickCount {
                return lhs.boulder.tickCount > rhs.boulder.tickCount
            }
            return lhs.boulder.createdAt > rhs.boulder.createdAt
        case .ticks:
            if lhs.boulder.tickCount != rhs.boulder.tickCount {
                return lhs.boulder.tickCount > rhs.boulder.tickCount
            }
            let lhsDifficulty = gradeRank(for: lhs.boulder.grade)
            let rhsDifficulty = gradeRank(for: rhs.boulder.grade)
            if lhsDifficulty != rhsDifficulty {
                return lhsDifficulty > rhsDifficulty
            }
            return lhs.boulder.createdAt > rhs.boulder.createdAt
        case .date:
            if lhs.boulder.createdAt != rhs.boulder.createdAt {
                return lhs.boulder.createdAt > rhs.boulder.createdAt
            }
            let lhsDifficulty = gradeRank(for: lhs.boulder.grade)
            let rhsDifficulty = gradeRank(for: rhs.boulder.grade)
            if lhsDifficulty != rhsDifficulty {
                return lhsDifficulty > rhsDifficulty
            }
            return lhs.boulder.tickCount > rhs.boulder.tickCount
        }
    }

    private func gradeRank(for rawGrade: String) -> Int {
        ClimbingGrade.allCases.firstIndex(where: { $0.rawValue == rawGrade }) ?? -1
    }

    private var allBoulderLogEntries: [BoulderLogLibraryEntry] {
        store.walls
            .flatMap { wall in
                wall.boulders.flatMap { boulder in
                    boulder.logEntries.map { logEntry in
                        BoulderLogLibraryEntry(
                            wallID: wall.id,
                            wallName: wall.name,
                            boulder: boulder,
                            logEntry: logEntry
                        )
                    }
                }
            }
            .sorted { $0.logEntry.recordedAt < $1.logEntry.recordedAt }
    }

    private var allLogGroups: [SessionLogGroup] {
        let sessions = store.sessionLogs.sorted { $0.recordedAt < $1.recordedAt }
        var assignedEntryIDs: Set<UUID> = []
        var groups = sessions.enumerated().map { index, session in
            let nextSessionStart = sessions.indices.contains(index + 1)
                ? sessions[index + 1].recordedAt
                : Date.distantFuture
            let candidateEntries = allBoulderLogEntries.filter { entry in
                !assignedEntryIDs.contains(entry.id)
                    && entry.logEntry.recordedAt >= session.recordedAt
                    && entry.logEntry.recordedAt < nextSessionStart
            }
            let detailEntries = reconstructedEntries(for: session, from: candidateEntries)
            assignedEntryIDs.formUnion(detailEntries.map(\.id))

            return SessionLogGroup(
                id: session.id.uuidString,
                title: "Session",
                recordedAt: session.recordedAt,
                duration: session.duration,
                attempts: session.attempts,
                ticks: session.ticks,
                detailEntries: detailEntries.sorted { $0.logEntry.recordedAt > $1.logEntry.recordedAt },
                isSession: true
            )
        }

        let ungroupedEntries = allBoulderLogEntries
            .filter { !assignedEntryIDs.contains($0.id) }
            .sorted { $0.logEntry.recordedAt > $1.logEntry.recordedAt }

        if let latestUngroupedEntry = ungroupedEntries.first {
            groups.append(
                SessionLogGroup(
                    id: "ungrouped-activity",
                    title: "Other Activity",
                    recordedAt: latestUngroupedEntry.logEntry.recordedAt,
                    duration: nil,
                    attempts: ungroupedEntries.reduce(0) { $0 + $1.logEntry.attempts },
                    ticks: ungroupedEntries.reduce(0) { $0 + $1.logEntry.ticks },
                    detailEntries: ungroupedEntries,
                    isSession: false
                )
            )
        }

        return groups.sorted { $0.recordedAt > $1.recordedAt }
    }

    private var filteredLogGroups: [SessionLogGroup] {
        let query = trimmedQuery
        guard !query.isEmpty else {
            return allLogGroups
        }

        return allLogGroups.filter { group in
            let timestamp = Self.logSearchDateFormatter.string(from: group.recordedAt)
            let durationText = group.duration.map(formattedSessionDuration) ?? ""
            let summaryMatches =
                group.title.localizedCaseInsensitiveContains(query)
                || timestamp.localizedCaseInsensitiveContains(query)
                || durationText.localizedCaseInsensitiveContains(query)
                || group.summaryText.localizedCaseInsensitiveContains(query)

            guard !summaryMatches else {
                return true
            }

            return group.detailEntries.contains { entry in
                let entryTimestamp = Self.logSearchDateFormatter.string(from: entry.logEntry.recordedAt)
                return entry.boulder.name.localizedCaseInsensitiveContains(query)
                    || entry.boulder.grade.localizedCaseInsensitiveContains(query)
                    || entry.wallName.localizedCaseInsensitiveContains(query)
                    || entryTimestamp.localizedCaseInsensitiveContains(query)
            }
        }
    }

    private func reconstructedEntries(
        for session: SessionLogEntry,
        from entries: [BoulderLogLibraryEntry]
    ) -> [BoulderLogLibraryEntry] {
        guard session.attempts > 0 || session.ticks > 0 else {
            return []
        }

        var matchedEntries: [BoulderLogLibraryEntry] = []
        var matchedAttempts = 0
        var matchedTicks = 0

        for entry in entries.sorted(by: { $0.logEntry.recordedAt < $1.logEntry.recordedAt }) {
            matchedEntries.append(entry)
            matchedAttempts += entry.logEntry.attempts
            matchedTicks += entry.logEntry.ticks

            if matchedAttempts == session.attempts && matchedTicks == session.ticks {
                return matchedEntries
            }

            if matchedAttempts > session.attempts || matchedTicks > session.ticks {
                return []
            }
        }

        return []
    }

    private func formattedSessionDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded(.down)))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var backupFilename: String {
        "sendlog-backup-\(Self.backupDateFormatter.string(from: Date()))"
    }

    private static let backupDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter
    }()

    private static let logSearchDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private func prepareBackupExport() {
        do {
            let data = try store.exportBackupData()
            backupDocument = BackupDocument(data: data)
            isExportingBackup = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func importBackup(from url: URL) {
        Task {
            do {
                let hasAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if hasAccess {
                        url.stopAccessingSecurityScopedResource()
                    }
                }

                let data = try Data(contentsOf: url)
                try await store.importBackupData(data)
                selectedTab = .walls
                searchText = ""
                selectedGradeFilter = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func deleteWall(_ wall: Wall) {
        wallPendingDeletion = nil

        Task {
            do {
                try await store.deleteWall(wallID: wall.id)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private enum LibraryTab: String, CaseIterable, Identifiable {
    case walls = "Walls"
    case problems = "Problems"
    case logs = "Log"

    var id: String { rawValue }

    var searchPrompt: String {
        switch self {
        case .walls:
            return "Search walls"
        case .problems:
            return "Search problems or wall"
        case .logs:
            return "Search sessions, problems, or wall"
        }
    }
}

private enum ProblemSort: String, CaseIterable, Identifiable {
    case difficulty = "Difficulty"
    case ticks = "Ticks"
    case date = "Date"

    var id: String { rawValue }
}

private struct BoulderLibraryEntry: Identifiable {
    let wallID: UUID
    let wallName: String
    let boulder: Boulder

    var id: UUID { boulder.id }
}

private struct BoulderLogLibraryEntry: Identifiable {
    let wallID: UUID
    let wallName: String
    let boulder: Boulder
    let logEntry: BoulderLogEntry

    var id: UUID { logEntry.id }
}

private struct SessionLogGroup: Identifiable {
    let id: String
    let title: String
    let recordedAt: Date
    let duration: TimeInterval?
    let attempts: Int
    let ticks: Int
    let detailEntries: [BoulderLogLibraryEntry]
    let isSession: Bool

    var summaryText: String {
        return "Attempts: \(attempts) • Ticks: \(ticks)"
    }
}

private struct BoulderPreviewTarget: Identifiable {
    let wallID: UUID
    let boulderID: UUID

    var id: UUID { boulderID }
}

private struct WallRow: View {
    let wall: Wall
    let image: UIImage?

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    var body: some View {
        HStack(spacing: 12) {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(.secondarySystemBackground))
                    .frame(width: 72, height: 72)
                    .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(wall.name)
                    .font(.headline)
                Text("\(wall.holds.count) holds • \(wall.boulders.count) problems")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Updated \(wall.updatedAt, formatter: Self.dateFormatter)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ProblemLibraryRow: View {
    let entry: BoulderLibraryEntry

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(entry.boulder.name)
                    .font(.headline)
                Spacer()
                Text(entry.boulder.grade)
                    .font(.subheadline.weight(.semibold))
            }
            Text("\(entry.boulder.holdIDs.count) holds • \(entry.boulder.attemptCount) attempts • \(entry.boulder.tickCount) ticks")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Wall: \(entry.wallName)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if !entry.boulder.notes.isEmpty {
                Text(entry.boulder.notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text("Created \(entry.boulder.createdAt, formatter: Self.dateFormatter)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

private struct SessionLogGroupRow: View {
    let group: SessionLogGroup
    @Binding var isExpanded: Bool
    let onOpen: (BoulderPreviewTarget?) -> Void

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if group.detailEntries.isEmpty {
                Text(group.isSession ? "No problem logs matched this session yet." : "No activity details available.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            } else {
                VStack(spacing: 12) {
                    ForEach(group.detailEntries) { entry in
                        SessionLogDetailRow(entry: entry, onOpen: onOpen)
                    }
                }
                .padding(.top, 8)
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(group.title)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(group.recordedAt, formatter: Self.dateFormatter)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let duration = group.duration {
                    Text(formattedDuration(duration))
                        .font(.headline)
                }

                Text("\(group.summaryText) • \(group.detailEntries.count) climbs")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded(.down)))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return "Duration: " + String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}

private struct SessionLogDetailRow: View {
    let entry: BoulderLogLibraryEntry
    let onOpen: (BoulderPreviewTarget?) -> Void

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    var body: some View {
        Button {
            onOpen(
                BoulderPreviewTarget(
                    wallID: entry.wallID,
                    boulderID: entry.boulder.id
                )
            )
        } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(entry.boulder.name)
                            .font(.headline)
                        Text(entry.boulder.grade)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }

                    Text(entry.wallName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text("Attempts: \(entry.logEntry.attempts) • Ticks: \(entry.logEntry.ticks)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(entry.logEntry.recordedAt, formatter: Self.timeFormatter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct SessionTimerCard: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = store.currentSessionDuration(at: context.date)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Session Timer")
                            .font(.headline)
                        Text(store.isSessionRunning ? "Running" : "Ready")
                            .font(.subheadline)
                            .foregroundStyle(store.isSessionRunning ? .green : .secondary)
                    }

                    Spacer()

                    Text(formatted(duration: elapsed))
                        .font(.system(.title2, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                }

                HStack(spacing: 10) {
                    Button {
                        if store.isSessionRunning {
                            store.pauseSession()
                        } else {
                            store.startSession()
                        }
                    } label: {
                        Label(store.isSessionRunning ? "Pause" : "Start", systemImage: store.isSessionRunning ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        store.resetSession()
                    } label: {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(elapsed < 1 && !store.isSessionRunning)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
        }
    }

    private func formatted(duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded(.down)))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}

struct SessionTimerOverlayModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { _ in
                    SessionTimerFloatingBadge()
                        .padding(.top, topPadding)
                        .padding(.leading, 12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
    }

    private var topPadding: CGFloat {
        let windowTopInset = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .safeAreaInsets.top ?? 0

        return windowTopInset + 18
    }
}

extension View {
    func sessionTimerOverlay() -> some View {
        modifier(SessionTimerOverlayModifier())
    }
}

private struct SessionTimerFloatingBadge: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        let hasStartedSession = store.isSessionRunning || store.currentSessionDuration() > 0

        Group {
            if hasStartedSession {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let elapsed = store.currentSessionDuration(at: context.date)

                    HStack(spacing: 8) {
                        Image(systemName: store.isSessionRunning ? "play.fill" : "pause.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(store.isSessionRunning ? .green : .secondary)

                        Text(formatted(duration: elapsed))
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.12), radius: 4, x: 0, y: 2)
                    .allowsHitTesting(false)
                }
            }
        }
    }

    private func formatted(duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded(.down)))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}
