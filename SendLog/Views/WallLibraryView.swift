import SwiftUI
import UIKit

struct WallLibraryView: View {
    @EnvironmentObject private var store: AppStore
    @State private var isShowingCreateWall = false
    @State private var selectedTab: LibraryTab = .walls
    @State private var searchText = ""
    @State private var selectedGradeFilter: ClimbingGrade?
    @State private var isShowingImportConfirmation = false
    @State private var isImportingBackup = false
    @State private var isExportingBackup = false
    @State private var backupDocument = BackupDocument(data: Data())
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Picker("Library", selection: $selectedTab) {
                    ForEach(LibraryTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                content
            }
            .navigationTitle("SendLog")
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
            .sheet(isPresented: $isShowingCreateWall) {
                CreateWallSheet()
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
                }
                .listStyle(.plain)
            }
        } else {
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
}

private enum LibraryTab: String, CaseIterable, Identifiable {
    case walls = "Walls"
    case problems = "Problems"

    var id: String { rawValue }

    var searchPrompt: String {
        switch self {
        case .walls:
            return "Search walls"
        case .problems:
            return "Search problems or wall"
        }
    }
}

private struct BoulderLibraryEntry: Identifiable {
    let wallID: UUID
    let wallName: String
    let boulder: Boulder

    var id: UUID { boulder.id }
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
