import SwiftUI
import PhotosUI

struct ContentView: View {
    @StateObject private var sketcher = SketcherService()
    @State private var selectedItem: PhotosPickerItem?
    @State private var selectedImage: UIImage?
    @State private var showsLoadError = false
    @State private var showsSketcherError = false
    @State private var showsDone = false
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    imageSection
                    deviceSection
                    sendSection
                }
                .padding()
            }
            .navigationTitle("Image Viewer")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if sketcher.isBusy {
                        ProgressView()
                    } else {
                        PhotosPicker(selection: $selectedItem, matching: .images) {
                            Label("Select Image", systemImage: "photo.on.rectangle.angled")
                        }
                    }
                }
            }
            .task(id: selectedItem) {
                await loadSelection()
            }
            .onChange(of: sketcher.status) { _, newStatus in
                switch newStatus {
                case .done:
                    showsDone = true
                case .failed:
                    showsSketcherError = true
                default:
                    break
                }
            }
            .alert("Could Not Load Image", isPresented: $showsLoadError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(loadError ?? "Unknown error.")
            }
            .alert("Sketcher Error", isPresented: $showsSketcherError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(sketcher.errorMessage ?? "Unknown error.")
            }
            .alert("Sent!", isPresented: $showsDone) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("The image was sent to your sketcher device.")
            }
        }
    }

    @ViewBuilder
    private var imageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Image")
                .font(.headline)
            if let selectedImage {
                Image(uiImage: selectedImage)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                ContentUnavailableView(
                    "No Image Selected",
                    systemImage: "photo",
                    description: Text("Use the button in the top right to pick a photo from your gallery.")
                )
            }
        }
    }

    @ViewBuilder
    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sketcher Device")
                .font(.headline)

            if sketcher.status == .scanning {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        ProgressView()
                        Text("Scanning for devices...")
                    }
                    ForEach(sketcher.discovered) { device in
                        Button {
                            sketcher.select(device)
                        } label: {
                            HStack {
                                Image(systemName: "wave.3.right")
                                Text(device.name)
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(.secondarySystemBackground)))
            } else if let name = sketcher.rememberedName {
                HStack {
                    Image(systemName: "pencil.and.outline")
                    Text(name)
                    Spacer()
                    Menu {
                        Button("Scan for a different device") {
                            sketcher.startScan()
                        }
                        Button("Forget this device", role: .destructive) {
                            sketcher.forgetDevice()
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                .padding()
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(.secondarySystemBackground)))
            } else {
                Button {
                    sketcher.startScan()
                } label: {
                    Label("Scan for Sketcher Device", systemImage: "antenna.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    @ViewBuilder
    private var sendSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                guard let image = selectedImage else { return }
                Task {
                    await sketcher.send(image)
                }
            } label: {
                Group {
                    if sketcher.isBusy {
                        HStack {
                            ProgressView()
                            Text(sketcher.step)
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        Label("Send to Sketcher", systemImage: "antenna.radiowaves.left.and.right")
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSend)

            if sketcher.status == .sending {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: sketcher.progress)
                    Text(statusLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var statusLine: String {
        let line = Int((sketcher.progress * 128).rounded())
        var text = "Line \(line) / 128"
        if sketcher.notifications > 0 {
            text += " • device \"ok\"s received: \(sketcher.notifications)"
        }
        return text
    }

    private var canSend: Bool {
        selectedImage != nil
            && sketcher.rememberedName != nil
            && !sketcher.isBusy
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
            withAnimation {
                selectedImage = image
            }
            loadError = nil
        } catch {
            loadError = error.localizedDescription
            showsLoadError = true
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
