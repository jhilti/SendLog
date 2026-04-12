import SwiftUI
import UIKit

struct WallLibraryView: View {
    @EnvironmentObject private var store: AppStore
    @State private var isShowingCreateWall = false
    @State private var selectedTab: LibraryTab = .walls
    @State private var selectedLogFilter: LogFilter = .all
    @State private var previewTarget: BoulderPreviewTarget?
    @State private var searchText = ""
    @State private var selectedGradeFilter: ClimbingGrade?
    @State private var isShowingImportConfirmation = false
    @State private var isImportingBackup = false
    @State private var isExportingBackup = false
    @State private var backupDocument = BackupDocument(data: Data())
    @State private var wallPendingDeletion: Wall?
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
                    NavigationLink(value: entry.wallID) {
                        ProblemLibraryRow(entry: entry)
                    }
                }
                .listStyle(.plain)
            }
        } else {
            if allLogEntries.isEmpty {
                ContentUnavailableView(
                    "No Log Entries Yet",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Log attempts or ticks on a problem to build your activity history.")
                )
            } else if filteredLogEntries.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                VStack(spacing: 0) {
                    Picker("Log Filter", selection: $selectedLogFilter) {
                        ForEach(LogFilter.allCases) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.top, 4)

                    List(filteredLogEntries) { entry in
                        LogLibraryRow(entry: entry) { target in
                            previewTarget = target
                        }
                    }
                    .listStyle(.plain)
                }
            }
        }
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
            .sorted { $0.boulder.createdAt > $1.boulder.createdAt }
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
    }

    private var allLogEntries: [LibraryLogEntry] {
        let boulderEntries = store.walls
            .flatMap { wall in
                wall.boulders.flatMap { boulder in
                    boulder.logEntries.map { logEntry in
                        LibraryLogEntry.boulder(
                            BoulderLogLibraryEntry(
                                wallID: wall.id,
                                wallName: wall.name,
                                boulder: boulder,
                                logEntry: logEntry
                            )
                        )
                    }
                }
            }

        let sessionEntries = store.sessionLogs.map { sessionLog in
            LibraryLogEntry.session(sessionLog)
        }

        return (boulderEntries + sessionEntries)
            .sorted { $0.recordedAt > $1.recordedAt }
    }

    private var filteredLogEntries: [LibraryLogEntry] {
        let query = trimmedQuery

        return allLogEntries.filter { entry in
            let filterMatches: Bool
            switch selectedLogFilter {
            case .all:
                filterMatches = true
            case .sessions:
                if case .session = entry {
                    filterMatches = true
                } else {
                    filterMatches = false
                }
            }

            guard filterMatches else {
                return false
            }

            guard !query.isEmpty else {
                return true
            }

            let timestamp = Self.logSearchDateFormatter.string(from: entry.recordedAt)
            switch entry {
            case .boulder(let boulderEntry):
                return boulderEntry.boulder.name.localizedCaseInsensitiveContains(query)
                    || boulderEntry.boulder.grade.localizedCaseInsensitiveContains(query)
                    || boulderEntry.wallName.localizedCaseInsensitiveContains(query)
                    || timestamp.localizedCaseInsensitiveContains(query)
            case .session(let sessionEntry):
                return "session".localizedCaseInsensitiveContains(query)
                    || formattedSessionDuration(sessionEntry.duration).localizedCaseInsensitiveContains(query)
                    || timestamp.localizedCaseInsensitiveContains(query)
            }
        }
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
            return "Search log entries"
        }
    }
}

private enum LogFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case sessions = "Sessions"

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

private enum LibraryLogEntry: Identifiable {
    case boulder(BoulderLogLibraryEntry)
    case session(SessionLogEntry)

    var id: UUID {
        switch self {
        case .boulder(let entry):
            return entry.id
        case .session(let entry):
            return entry.id
        }
    }

    var recordedAt: Date {
        switch self {
        case .boulder(let entry):
            return entry.logEntry.recordedAt
        case .session(let entry):
            return entry.recordedAt
        }
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

private struct LogLibraryRow: View {
    let entry: LibraryLogEntry
    let onOpen: (BoulderPreviewTarget?) -> Void

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        switch entry {
        case .boulder(let boulderEntry):
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(boulderEntry.wallName)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(boulderEntry.logEntry.recordedAt, formatter: Self.dateFormatter)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button {
                    onOpen(
                        BoulderPreviewTarget(
                            wallID: boulderEntry.wallID,
                            boulderID: boulderEntry.boulder.id
                        )
                    )
                } label: {
                    HStack(spacing: 6) {
                        Text(boulderEntry.boulder.name)
                            .font(.headline)
                        Text(boulderEntry.boulder.grade)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Image(systemName: "arrow.up.forward.square")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)

                Text("Attempts: \(boulderEntry.logEntry.attempts) • Ticks: \(boulderEntry.logEntry.ticks)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onTapGesture {
                onOpen(
                    BoulderPreviewTarget(
                        wallID: boulderEntry.wallID,
                        boulderID: boulderEntry.boulder.id
                    )
                )
            }
        case .session(let sessionEntry):
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Session")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(sessionEntry.recordedAt, formatter: Self.dateFormatter)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(formattedDuration(sessionEntry.duration))
                    .font(.headline)

                Text("Attempts: \(sessionEntry.attempts) • Ticks: \(sessionEntry.ticks)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded(.down)))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return "Duration: " + String(format: "%02d:%02d:%02d", hours, minutes, seconds)
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
                GeometryReader { geometry in
                    SessionTimerFloatingBadge()
                        .padding(.top, geometry.safeAreaInsets.top + 8)
                        .padding(.leading, 12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
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
