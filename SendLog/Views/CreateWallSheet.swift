import PhotosUI
import SwiftUI
import UIKit

struct CreateWallSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var wallName = ""
    @State private var selectedItem: PhotosPickerItem?
    @State private var selectedImageData: Data?
    @State private var previewImage: UIImage?
    @State private var errorMessage: String?
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Wall") {
                    TextField("Wall name", text: $wallName)
                }

                Section("Photo") {
                    PhotosPicker(selection: $selectedItem, matching: .images, photoLibrary: .shared()) {
                        Label(previewImage == nil ? "Pick Wall Image" : "Change Wall Image", systemImage: "photo")
                    }

                    if let previewImage {
                        Image(uiImage: previewImage)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .frame(maxHeight: 220)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("New Wall")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving..." : "Save") {
                        saveWall()
                    }
                    .disabled(!canSave)
                }
            }
            .onChange(of: selectedItem) { _, item in
                guard let item else { return }
                Task {
                    await loadImage(from: item)
                }
            }
        }
    }

    private var canSave: Bool {
        !isSaving
            && !wallName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && selectedImageData != nil
    }

    private func loadImage(from item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else {
                errorMessage = "Could not load the selected image."
                return
            }
            selectedImageData = data
            previewImage = image
            errorMessage = nil
        } catch {
            errorMessage = "Image import failed: \(error.localizedDescription)"
        }
    }

    private func saveWall() {
        guard let data = selectedImageData else {
            return
        }
        isSaving = true

        Task {
            do {
                try await store.createWall(name: wallName, imageData: data)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}
