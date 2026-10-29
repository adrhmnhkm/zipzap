import SwiftUI
import PhotosUI

/// Picker screen allowing users to select media from gallery or document storage.
public struct SendView: View {
    public let targetDevice: DiscoveredPeer
    public var onStartTransfer: (String, Int64) -> Void

    @Environment(\.presentationMode) var presentationMode
    @State private var selectedItem: PhotosPickerItem?

    public var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                // Target banner
                HStack {
                    Image(systemName: "paperplane.fill")
                        .foregroundColor(.accentColor)
                    Text("Tujuan: **\(targetDevice.alias)**")
                        .font(.subheadline)
                    Spacer()
                }
                .padding()
                .background(Color(UIColor.secondarySystemBackground))
                .cornerRadius(12)

                // Pickers
                VStack(spacing: 16) {
                    PhotosPicker(selection: $selectedItem, matching: .any(of: [.images, .videos])) {
                        HStack {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.title2)
                            Text("Pilih Foto atau Video dari Galeri")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }
                    .onChange(of: selectedItem) { newItem in
                        if newItem != nil {
                            // Mock photo selection metadata
                            onStartTransfer("IMG_Liburan_4K.MOV", 1_850_000_000)
                        }
                    }

                    Button(action: {
                        onStartTransfer("Dokumen_Penting.pdf", 45_000_000)
                    }) {
                        HStack {
                            Image(systemName: "folder")
                                .font(.title2)
                            Text("Pilih Berkas File (Files App)")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color(UIColor.secondarySystemBackground))
                        .foregroundColor(.primary)
                        .cornerRadius(12)
                    }
                }
                .padding(.horizontal)

                Spacer()
            }
            .padding(.top)
            .navigationTitle("Kirim File")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Tutup") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
    }
}
