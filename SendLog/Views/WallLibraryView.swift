import SwiftUI
import UIKit

struct WallLibraryView: View {
    @EnvironmentObject private var store: AppStore
    @State private var isShowingCreateWall = false

    var body: some View {
        NavigationStack {
            Group {
                if store.hasLoaded && store.walls.isEmpty {
                    ContentUnavailableView(
                        "No Walls Yet",
                        systemImage: "square.grid.3x3",
                        description: Text("Create your first wall by importing a photo.")
                    )
                } else if !store.hasLoaded {
                    ProgressView("Loading walls...")
                } else {
                    List(store.walls) { wall in
                        NavigationLink(value: wall.id) {
                            WallRow(wall: wall, image: store.image(for: wall))
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("SendLog")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
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
        }
    }
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
