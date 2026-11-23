import SwiftUI
import PhotosUI

struct ContentView: View {
    @State private var selectedItem: PhotosPickerItem?
    @State private var selectedImage: UIImage?
    @State private var errorMessage: String?
    @State private var showsError = false

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("Image Viewer")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        PhotosPicker(selection: $selectedItem, matching: .images) {
                            Label("Select an Image", systemImage: "photo.on.rectangle.angled")
                        }
                    }
                }
                .task(id: selectedItem) {
                    await loadSelection()
                }
                .alert("Could Not Load Image", isPresented: $showsError) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(errorMessage ?? "Unknown error.")
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let selectedImage {
            Image(uiImage: selectedImage)
                .resizable()
                .scaledToFit()
        } else {
            ContentUnavailableView(
                "No Image Selected",
                systemImage: "photo",
                description: Text("Use the button in the top right to pick a photo from your gallery.")
            )
        }
    }

    private func loadSelection() async {
        guard let selectedItem else { return }
        do {
            guard
                let data = try await selectedItem.loadTransferable(type: Data.self),
                let image = UIImage(data: data)
            else {
                throw LoadError.readFailed
            }
            selectedImage = image
        } catch {
            errorMessage = error.localizedDescription
            showsError = true
        }
    }

    private enum LoadError: LocalizedError {
        case readFailed

        var errorDescription: String? {
            "The selected file could not be read as an image."
        }
    }
}

#Preview {
    ContentView()
}
