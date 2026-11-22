// Lakr233's Inhouse Code, from FlowDown.
// I CAN DO WHAT THE FUCK I WANT.

import LurosCore
import LurosProtocol
import PDFKit
import ImageIO
import PhotosUI
import ScrubberKit
import UIKit
import UniformTypeIdentifiers

/// FlowDown's camera, photo, file, webpage and drop imports. Each instance
/// keeps the callback for the draft that opened it, including after a chat
/// switch.
final class ComposerAttachmentImport: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate,
    PHPickerViewControllerDelegate, UIDocumentPickerDelegate
{
    @objc dynamic private weak var presenter: UIViewController?
    private let receive: (ComposerAttachment) -> Void

    func accept(_ item: ComposerAttachment) { receive(item) }

    init(presenter: UIViewController, receive: @escaping (ComposerAttachment) -> Void) {
        self.presenter = presenter
        self.receive = receive
    }

    @objc dynamic func camera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            presenter?.presentNotice(
                title: "Camera Unavailable",
                message: String(localized: "This device does not have an available camera."),
            )
            return
        }
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier]
        picker.delegate = self
        presenter?.present(picker, animated: true)
    }

    @objc dynamic func photos() {
        var configuration = PHPickerConfiguration()
        configuration.selectionLimit = 4
        configuration.filter = .images
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        presenter?.present(picker, animated: true)
    }

    @objc dynamic func files() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = self
        presenter?.present(picker, animated: true)
    }

    @objc dynamic func imagePickerController(
        _ picker: UIImagePickerController,
        didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any],
    ) {
        picker.dismiss(animated: true)
        if let image = info[.originalImage] as? UIImage {
            importImage(image)
        }
    }

    @objc dynamic func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        for result in results {
            result.itemProvider.loadObject(ofClass: UIImage.self) { [self] reading, _ in
                Task { @MainActor in
                    guard let image = reading as? UIImage else { return }
                    importImage(image)
                }
            }
        }
    }

    @objc dynamic func documentPicker(_: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        importFiles(urls)
    }

    func importFiles(_ urls: [URL]) {
        Task { @MainActor [self] in
            for url in urls {
                do {
                    let attachment = try await Task.detached(priority: .userInitiated) {
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer {
                            if scoped {
                                url.stopAccessingSecurityScopedResource()
                            }
                        }
                        var coordinationError: NSError?
                        var result: Result<ComposerAttachment, Error>?
                        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { local in
                            result = Result { try Self.readAttachment(at: local, name: url.lastPathComponent) }
                        }
                        if let coordinationError { throw coordinationError }
                        guard let result else { throw CocoaError(.fileReadUnknown) }
                        return try result.get()
                    }.value
                    receive(attachment)
                } catch {
                    presenter?.presentNotice(title: "Unable to Import File", message: error.readableMessage)
                }
            }
        }
    }

    /// FlowDown's drop: each item's file, read as a pick from Files is,
    /// except that an image goes in as a photo does (`importImage`), as
    /// FlowDown's own import treats one. Bound to the draft that took the
    /// drop, as a picker is.
    @objc dynamic func drop(_ providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadFileRepresentation(forTypeIdentifier: UTType.item.identifier) { [self] url, error in
                // the system deletes its copy once this returns
                let read = Result { () throws -> ComposerAttachment in
                    guard let url else {
                        throw error ?? LurosError(
                            .badRequest,
                            String(localized: "The dropped item could not be read."),
                        )
                    }
                    return try Self.readAttachment(at: url, name: url.lastPathComponent)
                }
                Task { @MainActor in
                    do {
                        receive(try read.get())
                    } catch {
                        presenter?.presentNotice(title: "Unable to Import File", message: error.readableMessage)
                    }
                }
            }
        }
    }

    enum Origin {
        case provider, history, shareInbox(UUID)
    }

    /// Only a short preview enters the draft JSON. A share keeps its inbox ID as its receipt.
    nonisolated static func readAttachment(at url: URL, name: String, origin: Origin = .provider, mimeType: String? = nil) throws -> ComposerAttachment {
        guard let path = CanonicalPath.resolve(url.path) else {
            throw LurosError(.badRequest, String(localized: "The selected file could not be read."))
        }
        let source = URL(fileURLWithPath: path)
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let key: UUID
        if case let .shareInbox(id) = origin { key = id } else { key = UUID() }
        try DataFolder.app.makeLevels(to: ComposerAttachment.storage)
        let dest = ComposerAttachment.storage.appendingPathComponent(key.uuidString)
        // An interrupted copy is an unreferenced UUID, reclaimed by the store at cold launch.
        let stage = ComposerAttachment.storage.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: stage) }
        // History is immutable and normally local. Inbox and provider files are always copied.
        switch origin {
        case .history where link(source.path, stage.path) == 0: break
        default: try FileManager.default.copyItem(at: source, to: stage)
        }
        let type = mimeType.flatMap { UTType(mimeType: $0) } ?? UTType(filenameExtension: (name as NSString).pathExtension)
            ?? CGImageSourceCreateWithURL(stage as CFURL, nil).flatMap(CGImageSourceGetType).flatMap { UTType($0 as String) }
        let handle = try FileHandle(forReadingFrom: stage)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 8192) ?? Data()
        let image = type?.conforms(to: .image) == true
        let text = image || prefix.contains(0) ? nil : String(data: prefix, encoding: .utf8)
        guard rename(stage.path, dest.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return ComposerAttachment(name: name, text: text, isImage: image, storedFile: key, storedBytes: size, mimeType: type?.preferredMIMEType)
    }

    @objc dynamic func importImage(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.85) else {
            presenter?.presentNotice(
                title: "Unable to Import Image",
                message: String(localized: "The image could not be read."),
            )
            return
        }
        receive(ComposerAttachment(name: String(localized: "Image") + ".jpeg", data: data, text: nil, isImage: true))
    }

    @objc dynamic func importText(_ text: String, name: String = String(localized: "Pasted Text")) {
        guard !text.isEmpty else { return }
        receive(ComposerAttachment(name: name + ".txt", data: Data(text.utf8), text: text))
    }

    @objc dynamic func paste() {
        let pasteboard = UIPasteboard.general
        if let image = pasteboard.image {
            importImage(image)
        } else if let text = pasteboard.string {
            importText(text)
        }
    }

    @objc dynamic func web() {
        askWebAddress(typed: "")
    }

    /// Asks for the page to capture, the field holding `typed`: an address
    /// that names no page is said so and asked for again as it was typed.
    @objc dynamic private func askWebAddress(typed: String) {
        let alert = UIAlertController(
            title: String(localized: "Capture Web Content"),
            message: String(localized: "Enter the webpage address to attach its text."),
            preferredStyle: .alert,
        )
        alert.addTextField {
            $0.text = typed
            $0.placeholder = "example.com"
            $0.keyboardType = .URL
            $0.autocapitalizationType = .none
            $0.autocorrectionType = .no
            $0.accessibilityLabel = String(localized: "Web Address")
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Capture"), style: .default) { [self, weak alert] _ in
            let value = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let url = WebAddress.url(from: value) else {
                presentInvalidWebAddress(typed: value)
                return
            }
            captureWebpage(at: url)
        })
        presenter?.present(alert, animated: true)
    }

    @objc dynamic private func presentInvalidWebAddress(typed: String) {
        presenter?.presentNotice(
            title: "Invalid Web Address",
            message: String(localized: "Enter a web address, such as example.com."),
            onDismiss: { [weak self] in
                guard !typed.isEmpty else { return }
                self?.askWebAddress(typed: typed)
            },
        )
    }

    @objc dynamic private func captureWebpage(at url: URL) {
        Task { @MainActor [self] in
            guard let presenter else { return }
            do {
                let document: Scrubber.Document? = try await ProgressCard.run(
                    title: String(localized: "Fetching Content"),
                    message: url.absoluteString,
                    cancellable: false,
                    from: presenter,
                ) { _ in
                    await withCheckedContinuation { continuation in
                        Scrubber.document(for: url) { continuation.resume(returning: $0) }
                    }
                }
                guard let document, !document.textDocument.isEmpty else {
                    throw LurosError(
                        .unavailable,
                        String(localized: "The webpage did not return readable content."),
                    )
                }
                importText(document.textDocument, name: document.title)
            } catch {
                presenter.presentNotice(title: "Unable to Capture Webpage", message: error.readableMessage)
            }
        }
    }
}

extension ComposerAttachment {
    static var storage: URL { DataFolder.app.root.appendingPathComponent("Chats/AttachmentFiles", isDirectory: true) }
    var fileURL: URL? { storedFile.map { Self.storage.appendingPathComponent($0.uuidString) } }

    func imageSource() -> CGImageSource? {
        if let fileURL { return CGImageSourceCreateWithURL(fileURL as CFURL, nil) }
        return CGImageSourceCreateWithData(data as CFData, nil)
    }

    func export(to url: URL) throws {
        if let fileURL {
            do { try FileManager.default.linkItem(at: fileURL, to: url) }
            catch { try FileManager.default.copyItem(at: fileURL, to: url) }
        } else {
            try data.write(to: url, options: .atomic)
        }
    }
}
