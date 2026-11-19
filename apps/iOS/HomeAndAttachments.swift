import SwiftUI
import PhotosUI
import UIKit
import AgentRuntime

/// Empty-conversation brand mark. Quiet on purpose: the content is the composer, not the logo.
struct HomeWordmark: View {
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 0) {
                Text("i").foregroundStyle(.tint)
                Text("Talk").foregroundStyle(.primary)
            }
            .font(.system(size: 46, weight: .semibold, design: .rounded)).tracking(-0.8)
            Text("想到什么，就说给我听").font(.subheadline).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore).accessibilityLabel("iTalk").accessibilityIdentifier("assistant.wordmark")
        .frame(maxWidth: .infinity, maxHeight: .infinity).offset(y: -24)
    }
}

/// Compact horizontally scrolling prompts that sit directly above the composer. They never auto-scroll.
struct SuggestionCapsules: View {
    let suggestions: [PromptSuggestion]
    let icon: (PromptSuggestion) -> String
    let choose: (PromptSuggestion) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(suggestions) { suggestion in
                    Button { choose(suggestion) } label: {
                        Label(suggestion.title, systemImage: icon(suggestion))
                            .font(.subheadline).lineLimit(1).labelStyle(CapsuleLabelStyle())
                            .padding(.horizontal, 14).frame(height: 36).contentShape(Capsule())
                    }
                    .buttonStyle(.plain).glassEffect(.regular.interactive(), in: .capsule)
                    .accessibilityIdentifier("assistant.suggestion.\(suggestion.kind.rawValue)")
                }
            }.padding(.horizontal, 12)
        }
        .scrollIndicators(.hidden).scrollClipDisabled()
    }
}

struct ActionCapsule: Identifiable {
    let id: String
    let title: String
    let icon: String
    var enabled = true
    let action: () -> Void
}

/// Compact row of working shortcuts above the composer once a conversation exists.
struct ActionCapsules: View {
    let actions: [ActionCapsule]
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(actions) { item in
                    Button(action: item.action) {
                        Label(item.title, systemImage: item.icon)
                            .font(.subheadline).lineLimit(1).labelStyle(CapsuleLabelStyle())
                            .padding(.horizontal, 14).frame(height: 36).contentShape(Capsule())
                    }
                    .buttonStyle(.plain).glassEffect(.regular.interactive(), in: .capsule).disabled(!item.enabled).opacity(item.enabled ? 1 : 0.45)
                    .accessibilityIdentifier("conversation.action.\(item.id)")
                }
            }.padding(.horizontal, 12)
        }
        .scrollIndicators(.hidden).scrollClipDisabled()
    }
}

private struct CapsuleLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.footnote.weight(.medium)).foregroundStyle(.tint)
            configuration.title.foregroundStyle(.primary)
        }
    }
}

enum AttachmentChoice { case skills }

/// Bottom sheet opened by the composer's plus button. Add a tile here when a new attachment type really exists.
struct AttachmentSheet: View {
    @Binding var photos: [PhotosPickerItem]
    let cameraAvailable: Bool
    let pick: (AttachmentChoice?, _ camera: Bool) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 12) {
            tile("相机", "camera.fill") { pick(nil, true); dismiss() }
                .disabled(!cameraAvailable).opacity(cameraAvailable ? 1 : 0.4)
                .accessibilityIdentifier("attachment.camera")
            PhotosPicker(selection: $photos, maxSelectionCount: 3, matching: .images, photoLibrary: .shared()) {
                AttachmentTile(title: "照片", symbol: "photo.on.rectangle")
            }.buttonStyle(.plain).accessibilityIdentifier("attachment.photos")
                .simultaneousGesture(TapGesture().onEnded { })
            tile("技能", "sparkles") { pick(.skills, false); dismiss() }
                .accessibilityIdentifier("attachment.skills")
        }
        .padding(.horizontal, 16).padding(.top, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: photos) { _, items in if !items.isEmpty { dismiss() } }
        .presentationDetents([.height(168)]).presentationDragIndicator(.visible)
    }

    private func tile(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { AttachmentTile(title: title, symbol: symbol) }.buttonStyle(.plain)
    }
}

private struct AttachmentTile: View {
    let title: String
    let symbol: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 24)).foregroundStyle(.primary).frame(height: 28)
            Text(title).font(.footnote).foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, minHeight: 84)
        .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// Thin wrapper over the system camera. The captured frame goes through the same preparation as library photos.
struct CameraPicker: UIViewControllerRepresentable {
    let captured: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = .camera; controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.captured(image) }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
