import ImageIO
import LurosCore
import PhotosUI
import UIKit
import UniformTypeIdentifiers
import os

/// Settings ▸ Preferences ▸ Chat Background: the app's own background, one of
/// the papers Luros draws, or a picture of the reader's that the chat shows
/// through by the opacity they pick.
///
/// A paper is drawn, so it is shown in full and has no opacity of its own;
/// only the reader's picture can be faded, which is the whole point of a
/// picture — the app's colours show behind it.
final class ChatBackgroundController: TableController {
    private enum Section: Hashable {
        case plain
        case papers
        case picture
    }

    private enum Row: Hashable {
        case none
        case paper(ChatBackground.Paper)
        case choose
        case opacity
        case remove
    }

    private struct RowContent: Equatable {
        let row: Row
        let title: String
        let detail: String?
        let selected: Bool
        let preview: UIImage?
    }

    private lazy var dataSource = TableDataSource<Section, Row, RowContent>(
        tableView: tableView,
        identifier: { $0.row },
    ) { [weak self] table, _, row in
        self?.cell(in: table, content: row)
    }

    init() {
        super.init(style: .insetGrouped)
        title = String(localized: "Chat Background")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.backButtonDisplayMode = .minimal
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 60
        tableView.register(OpacityCell.self, forCellReuseIdentifier: "opacity")
        dataSource.headerTitle = { section in
            section == .papers ? String(localized: "Papers") : nil
        }
        dataSource.footerTitle = { section in
            switch section {
            case .plain:
                return nil
            case .papers:
                return String(localized: "A paper is drawn by Luros and fills the chat as it is; only a picture of your own can be made see-through.")
            case .picture:
                return ChatBackground.hasImage
                    ? String(localized: "Opacity lets the app's colours show through the picture. The picture is copied into Luros's folder and scaled down when it is very large, so it stays after the photo app's temporary file is gone.")
                    : String(localized: "Choose a picture from your photo library. It is copied into Luros's folder and scaled down when it is very large, so it stays after the photo app's temporary file is gone.")
            }
        }
        updateRows()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateRows()
    }

    private func updateRows() {
        let current = ChatBackground.current
        let chosen: ChatBackground.Paper? = {
            if case let .paper(paper) = current { return paper }
            return nil
        }()
        var sections: [(Section, [RowContent])] = [
            (.plain, [
                RowContent(row: .none, title: String(localized: "None"), detail: nil, selected: current == .none, preview: nil),
            ]),
            (.papers, ChatBackground.Paper.allCases.map { paper in
                RowContent(
                    row: .paper(paper),
                    title: paper.title,
                    detail: nil,
                    selected: chosen == paper,
                    preview: ChatBackgroundView.preview(paper, size: CGSize(width: 44, height: 44), traits: traitCollection),
                )
            }),
        ]
        var picture: [RowContent] = [
            RowContent(
                row: .choose,
                title: ChatBackground.hasImage
                    ? String(localized: "Replace Image")
                    : String(localized: "Choose Image"),
                detail: nil,
                selected: false,
                preview: ChatBackground.hasImage
                    ? ChatBackgroundView.picturePreview(size: CGSize(width: 44, height: 44))
                    : nil,
            ),
        ]
        if ChatBackground.hasImage {
            picture.append(RowContent(
                row: .opacity,
                title: String(localized: "Opacity"),
                detail: nil,
                selected: false,
                preview: nil,
            ))
            picture.append(RowContent(
                row: .remove,
                title: String(localized: "Remove Image"),
                detail: nil,
                selected: false,
                preview: nil,
            ))
        }
        sections.append((.picture, picture))
        dataSource.update(sections, reconfigure: true)
    }

    private func cell(in tableView: UITableView, content value: RowContent) -> UITableViewCell {
        if case .opacity = value.row {
            let cell = tableView.dequeueReusableCell(withIdentifier: "opacity") as? OpacityCell
                ?? OpacityCell(style: .default, reuseIdentifier: "opacity")
            cell.configure(ChatBackground.opacity)
            cell.onChange = { opacity in ChatBackground.opacity = opacity }
            return cell
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: "background")
            ?? UITableViewCell(style: .value1, reuseIdentifier: "background")
        var content = UIListContentConfiguration.valueCell()
        content.text = value.title
        content.secondaryText = value.detail
        if let preview = value.preview {
            content.image = preview
            content.imageProperties.maximumSize = CGSize(width: 44, height: 44)
            content.imageProperties.cornerRadius = 4
        }
        cell.contentConfiguration = content
        switch value.row {
        case .none, .paper:
            cell.accessoryType = value.selected ? .checkmark : .none
            cell.selectionStyle = .default
            cell.accessibilityTraits = value.selected ? [.button, .selected] : [.button]
        case .choose:
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
            cell.accessibilityTraits = [.button]
        case .remove:
            cell.accessoryType = .none
            cell.selectionStyle = .default
            cell.accessibilityTraits = [.button]
            content.textProperties.color = .systemRed
            cell.contentConfiguration = content
        case .opacity:
            break
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = dataSource.value(at: indexPath)?.row else { return }
        switch row {
        case .none:
            ChatBackground.current = .none
            updateRows()
        case let .paper(paper):
            ChatBackground.current = .paper(paper)
            updateRows()
        case .choose:
            choosePicture()
        case .opacity:
            break
        case .remove:
            confirmRemoval()
        }
    }

    // MARK: - The reader's own picture

    private func choosePicture() {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        present(picker, animated: true)
    }

    private func confirmRemoval() {
        let alert = UIAlertController(
            title: String(localized: "Remove Image"),
            message: String(localized: "The picture is deleted from Luros's folder. The chat goes back to the app's own background."),
            preferredStyle: .alert,
        )
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Remove"), style: .destructive) { [weak self] _ in
            do {
                try ChatBackground.removeImage()
            } catch {
                log.error("removing the picture failed: \(error.localizedDescription, privacy: .public)")
                self?.notice(String(localized: "The picture could not be removed."), detail: error.localizedDescription)
            }
            self?.updateRows()
        })
        present(alert, animated: true)
    }

    private nonisolated static func store(_ jpeg: Data) throws {
        let folder = ChatBackground.imageURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try jpeg.write(to: ChatBackground.imageURL, options: .atomic)
    }

    private func notice(_ title: String, detail: String? = nil) {
        let alert = UIAlertController(
            title: title,
            message: detail,
            preferredStyle: .alert,
        )
        alert.addAction(UIAlertAction(title: String(localized: "Done"), style: .default))
        present(alert, animated: true)
    }
}

extension ChatBackgroundController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider else { return }
        let types = provider.registeredTypeIdentifiers.joined(separator: ", ")
        log.info("picture picked, types: \(types, privacy: .public)")
        Task { @MainActor in
            guard let jpeg = await Self.jpeg(from: provider) else {
                self.notice(String(localized: "That picture could not be read."))
                return
            }
            do {
                try Self.store(jpeg)
                ChatBackground.current = .image
                self.updateRows()
            } catch {
                log.error("saving the picture failed: \(error.localizedDescription, privacy: .public)")
                self.notice(
                    String(localized: "The picture could not be saved."),
                    detail: error.localizedDescription,
                )
            }
        }
    }

    /// The picture the provider holds, as a JPEG: its own bytes first, and
    /// the image itself when it will not hand them over.
    private static func jpeg(from provider: NSItemProvider) async -> Data? {
        if let data = await rawData(from: provider) {
            let jpeg = await Task.detached(priority: .userInitiated) {
                ChatBackgroundPicture.storedJPEG(data)
            }.value
            if let jpeg { return jpeg }
        }
        guard let image = await picture(from: provider) else { return nil }
        log.info("picture handed over as an image, not as bytes")
        return ChatBackgroundPicture.storedJPEG(image)
    }

    /// The picture's bytes, under the type the provider actually registered.
    /// A camera photo is usually HEIC — `public.heic`, not `public.image` — and
    /// a provider that lists a concrete type is not promised to answer for the
    /// general one.
    private static func rawData(from provider: NSItemProvider) async -> Data? {
        for type in provider.registeredTypeIdentifiers
        where UTType(type)?.conforms(to: .image) ?? false {
            let data: Data? = await withCheckedContinuation { continuation in
                provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                    if let error {
                        log.error("loading \(type, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                    }
                    continuation.resume(returning: data)
                }
            }
            if let data { return data }
        }
        return nil
    }

    private static func picture(from provider: NSItemProvider) async -> UIImage? {
        await withCheckedContinuation { continuation in
            provider.loadObject(ofClass: UIImage.self) { object, error in
                if let error {
                    log.error("loading as UIImage failed: \(error.localizedDescription, privacy: .public)")
                }
                continuation.resume(returning: object as? UIImage)
            }
        }
    }
}

/// The picture's opacity, a whole percent at a time: the slider moves freely
/// and the value it reports is rounded, so a drag never leaves 83.7% behind.
private final class OpacityCell: UITableViewCell {
    private let title = UILabel()
    private let value = UILabel()
    private let slider = UISlider()
    /// Called with the stepped value (0.01 ... 1) while the slider moves.
    var onChange: ((Double) -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        title.text = String(localized: "Opacity")
        title.font = .preferredFont(forTextStyle: .body)
        title.adjustsFontForContentSizeCategory = true
        title.isAccessibilityElement = false
        value.font = .preferredFont(forTextStyle: .body)
        value.adjustsFontForContentSizeCategory = true
        value.textColor = .secondaryLabel
        value.textAlignment = .right
        value.isAccessibilityElement = false
        value.setContentCompressionResistancePriority(.required, for: .horizontal)
        slider.minimumValue = 0.01
        slider.maximumValue = 1
        slider.isContinuous = true
        slider.addTarget(self, action: #selector(sliderChanged), for: .valueChanged)
        for view in [title, value, slider] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            title.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            title.trailingAnchor.constraint(lessThanOrEqualTo: value.leadingAnchor, constant: -8),
            value.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            value.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            slider.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            slider.trailingAnchor.constraint(equalTo: value.trailingAnchor),
            slider.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            slider.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func configure(_ opacity: Double) {
        slider.value = Float(opacity)
        slider.accessibilityLabel = title.text
        value.text = Preferences.percentText(opacity)
        slider.accessibilityValue = value.text
    }

    @objc private func sliderChanged() {
        let stepped = (Double(slider.value) * 100).rounded() / 100
        value.text = Preferences.percentText(stepped)
        slider.accessibilityValue = value.text
        onChange?(stepped)
    }
}

/// One place for what the picker and ImageIO say, so a picture that will not
/// load can be read back out of the device log.
private let log = Logger(subsystem: "com.fluoxetine.luros", category: "ChatBackground")
