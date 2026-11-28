import LurosProtocol
import SnapKit
import UIKit

/// A picker's choices in a sheet of the system's own: on iOS 26 its Liquid
/// Glass shows through, the page's background being clear, and before that the
/// grouped background, as the message's sheet does. Every picker opens at one
/// height (owner, 2026-11-06) and the choices scroll inside it, so a provider
/// listing twenty models opens the card a provider listing two does, and the
/// row above the keyboard does not jump from one picker to the next.
///
/// A choice closes the sheet, then runs. Its rows are the composer's own: a
/// label over its detail with the circle that says which one is set, on the
/// fill the question's options use, so choosing a model reads like answering
/// a question.
final class ComposerChoiceSheet: UIViewController {
    struct Choice {
        var title: String
        var subtitle: String?
        /// The one the row is set to, marked with a filled circle and spoken
        /// as selected.
        var isSelected: Bool
        /// Present a test without choosing the model or closing this picker.
        var modelTest: AgentModelTestRequest? = nil
        var handler: () -> Void
    }

    /// Choices under a heading of their own, such as one provider's models.
    struct Group {
        var title: String?
        /// The usage icon at the right of the heading, which opens that
        /// account's quota: the heading says which endpoint, the icon says
        /// what it has left (owner, 2026-11-28).
        var quota: (() -> Void)?
        var choices: [Choice]

        init(title: String? = nil, quota: (() -> Void)? = nil, choices: [Choice]) {
            self.title = title
            self.quota = quota
            self.choices = choices
        }
    }

    /// The height the connectivity report opens at, on a phone and on a card
    /// alike. It is a grouped page of its own — the verdict, the stages it
    /// stopped in the middle of, the reply and what was sent — so it stands
    /// taller than the rows the picker itself draws.
    static let height: CGFloat = 620

    private let heading: String
    private var groups: [Group]
    @objc private dynamic var loading = false
    @objc private dynamic var failure: String?
    @objc dynamic var onRetry: (() -> Void)?
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let retryButton = UIButton(type: .system)
    private let statusStack = UIStackView()
    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    /// Each row with the height it asks for: a row sizes itself to its text,
    /// which needs the width it is given, and the stack asks before it has one.
    private var rows: [(row: ChoiceRow, height: NSLayoutConstraint)] = []
    private static let margin: CGFloat = 16

    init(heading: String, groups: [Group]) {
        self.heading = heading
        self.groups = groups
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(heading:groups:)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        if #available(iOS 26, *) {
            view.backgroundColor = .clear
        } else {
            view.backgroundColor = .systemGroupedBackground
        }

        let titleLabel = UILabel()
        titleLabel.text = heading
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 0
        titleLabel.accessibilityTraits = .header
        view.addSubview(titleLabel)

        stack.axis = .vertical
        stack.spacing = 8
        renderChoices()

        scrollView.alwaysBounceVertical = false
        view.addSubview(scrollView)
        scrollView.addSubview(stack)
        statusStack.axis = .vertical
        statusStack.alignment = .center
        statusStack.spacing = 8
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        retryButton.setTitle(String(localized: "Retry"), for: .normal)
        retryButton.addAction(UIAction { [weak self] _ in self?.onRetry?() }, for: .touchUpInside)
        for item in [spinner, statusLabel, retryButton] { statusStack.addArrangedSubview(item) }
        view.addSubview(statusStack)
        updateStatus()

        titleLabel.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide).offset(Self.margin)
            make.leading.trailing.equalTo(view.safeAreaLayoutGuide).inset(Self.margin)
        }
        statusStack.snp.makeConstraints { make in
            make.top.equalTo(titleLabel.snp.bottom)
            make.leading.trailing.equalTo(view.safeAreaLayoutGuide).inset(Self.margin)
        }
        scrollView.snp.makeConstraints { make in
            make.top.equalTo(statusStack.snp.bottom).offset(12)
            make.leading.trailing.bottom.equalTo(view.safeAreaLayoutGuide)
        }
        stack.snp.makeConstraints { make in
            make.top.equalTo(scrollView.contentLayoutGuide)
            make.bottom.equalTo(scrollView.contentLayoutGuide).offset(-Self.margin)
            make.leading.trailing.equalTo(scrollView.frameLayoutGuide).inset(Self.margin)
        }
    }

    /// Provisional rows stay read-only until their account and context window
    /// have been checked. Updating this sheet never presents another one.
    func update(groups: [Group], loading: Bool = false, failure: String? = nil) {
        self.groups = groups
        self.loading = loading
        self.failure = failure
        guard isViewLoaded else { return }
        renderChoices()
        updateStatus()
        view.setNeedsLayout()
    }

    @objc private dynamic func updateStatus() {
        statusLabel.text = failure ?? (loading ? String(localized: "Loading…") : nil)
        statusLabel.isHidden = statusLabel.text == nil
        retryButton.isHidden = failure == nil
        if loading { spinner.startAnimating() } else { spinner.stopAnimating() }
        spinner.isHidden = !loading
    }

    @objc private dynamic func renderChoices() {
        for child in stack.arrangedSubviews {
            stack.removeArrangedSubview(child)
            child.removeFromSuperview()
        }
        rows.removeAll()
        for group in groups {
            // A heading stands closer to the choices it names than to the ones
            // above it, so a provider's list reads as one block.
            if let title = group.title, !title.isEmpty {
                let label = UILabel()
                label.text = title
                label.font = .preferredFont(forTextStyle: .footnote)
                label.adjustsFontForContentSizeCategory = true
                label.textColor = .secondaryLabel
                label.numberOfLines = 0
                label.accessibilityTraits = .header
                // No figure here: a chart icon at the right opens that
                // account's quota sheet, which asks afresh each time.
                let row = UIStackView(arrangedSubviews: [label])
                row.axis = .horizontal
                row.alignment = .center
                row.spacing = 8
                if let open = group.quota {
                    let icon = UIButton(type: .system)
                    icon.setImage(
                        UIImage(
                            systemName: "chart.bar",
                            withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold),
                        ),
                        for: .normal,
                    )
                    icon.tintColor = .tertiaryLabel
                    icon.accessibilityLabel = String(localized: "Provider Quota")
                    icon.setContentHuggingPriority(.required, for: .horizontal)
                    icon.setContentCompressionResistancePriority(.required, for: .horizontal)
                    icon.addAction(UIAction { _ in open() }, for: .primaryActionTriggered)
                    row.addArrangedSubview(icon)
                }
                if let previous = stack.arrangedSubviews.last {
                    stack.setCustomSpacing(16, after: previous)
                }
                stack.addArrangedSubview(row)
                stack.setCustomSpacing(4, after: row)
            }
            for choice in group.choices {
                let row = ChoiceRow(title: choice.title, detail: choice.subtitle, chosen: choice.isSelected)
                row.isEnabled = !loading && failure == nil
                if !row.isEnabled {
                    row.alpha = 0.55
                    row.accessibilityTraits.insert(.notEnabled)
                }
                if row.isEnabled, let request = choice.modelTest {
                    row.configureTestAction { [weak self] in
                        guard let self, presentedViewController == nil else { return }
                        let report = SheetNavigationController(
                            rootViewController: ModelConnectivityController(request: request),
                        )
                        // A page of this list rather than a place of its own:
                        // a card over it, so the leading button or a pull down
                        // goes back to the models rather than out of
                        // everything.
                        if view.window?.traitCollection.horizontalSizeClass == .compact {
                            report.modalPresentationStyle = .pageSheet
                            if let controller = report.sheetPresentationController {
                                controller.detents = [.custom(identifier: .init("model-test")) { context in
                                    min(context.maximumDetentValue, Self.height)
                                }]
                                controller.prefersGrabberVisible = true
                                controller.prefersEdgeAttachedInCompactHeight = true
                            }
                        } else {
                            report.modalPresentationStyle = .formSheet
                            report.preferredContentSize = CGSize(width: 480, height: Self.height)
                        }
                        present(report, animated: true)
                    }
                }
                let handler = choice.handler
                row.addAction(UIAction { [weak self] _ in
                    self?.dismiss(animated: true) { handler() }
                }, for: .touchUpInside)
                rows.append((row, fit(row)))
                stack.addArrangedSubview(row)
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // The width a row is given is the scroll view's less the margins, and
        // only the layout knows it.
        let width = scrollView.bounds.width - Self.margin * 2
        guard width > 0 else { return }
        for entry in rows {
            let height = ceil(entry.row.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
            if abs(entry.height.constant - height) > 0.5 {
                entry.height.constant = height
            }
        }
    }

    /// The height `row` is held to, which `viewDidLayoutSubviews` keeps up to
    /// date: the stack asks for one before the row has a width to measure with.
    private func fit(_ row: ChoiceRow) -> NSLayoutConstraint {
        let height = row.heightAnchor.constraint(equalToConstant: 44)
        height.priority = .required
        height.isActive = true
        return height
    }

    /// Presents `sheet` from `presenter`: a card of the sheet's own height on a
    /// phone, a form sheet of it on a window wide enough for one.
    static func present(_ sheet: ComposerChoiceSheet, from presenter: UIViewController) {
        // The card needs the bottom of the screen, which the keyboard is on.
        presenter.view.endEditing(true)
        if presenter.viewIfLoaded?.window?.traitCollection.horizontalSizeClass == .compact {
            sheet.modalPresentationStyle = .pageSheet
            if let controller = sheet.sheetPresentationController {
                controller.detents = [.custom(identifier: .init("choices")) { context in
                    min(context.maximumDetentValue, height)
                }]
                controller.prefersGrabberVisible = true
                controller.prefersEdgeAttachedInCompactHeight = true
            }
        } else {
            sheet.modalPresentationStyle = .formSheet
            sheet.preferredContentSize = CGSize(width: 480, height: height)
        }
        presenter.present(sheet, animated: true)
    }
}

/// One choice of the sheet: its label over its detail, with the circle that
/// says which one is set. A single element, read as its label and detail, a
/// button, selected while chosen.
private final class ChoiceRow: UIControl {
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let check = UIImageView()
    private let testButton = UIButton(type: .system)
    @objc private dynamic var testAction: (() -> Void)?
    private static let inset = UIEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
    private static let checkSize: CGFloat = 22

    init(title: String, detail: String?, chosen: Bool) {
        super.init(frame: .zero)
        backgroundColor = .tertiarySystemFill
        layer.cornerRadius = 10
        layer.cornerCurve = .continuous

        titleLabel.text = title
        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 0
        detailLabel.text = detail
        detailLabel.font = .preferredFont(forTextStyle: .footnote)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = .secondaryLabel
        detailLabel.numberOfLines = 0
        detailLabel.isHidden = detail?.isEmpty ?? true
        check.image = UIImage(systemName: chosen ? "checkmark.circle.fill" : "circle")
        check.tintColor = chosen ? .label : .tertiaryLabel
        check.contentMode = .scaleAspectFit
        for view in [check, titleLabel, detailLabel] {
            view.isUserInteractionEnabled = false
            addSubview(view)
        }

        isAccessibilityElement = true
        accessibilityLabel = [title, detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        accessibilityTraits = chosen ? [.button, .selected] : .button
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(title:detail:chosen:)")
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1 }
    }

    /// The parent is one spoken choice. VoiceOver reaches the secondary
    /// button through a custom action instead of hiding it behind that label.
    @objc dynamic func configureTestAction(_ action: @escaping () -> Void) {
        testAction = action
        // An icon rather than a word: the row's own label is the model, and a
        // word beside it read as a second choice. The antenna says "try this
        // one", and the label names it for VoiceOver.
        testButton.setImage(UIImage(systemName: "antenna.radiowaves.left.and.right"), for: .normal)
        testButton.tintColor = .secondaryLabel
        testButton.accessibilityLabel = String(localized: "Test Connectivity")
        testButton.accessibilityElementsHidden = true
        testButton.addAction(UIAction { [weak self] _ in self?.performTest() }, for: .touchUpInside)
        addSubview(testButton)
        accessibilityCustomActions = [UIAccessibilityCustomAction(
            name: String(localized: "Test Connectivity"),
            actionHandler: { [weak self] _ in
                guard let self else { return false }
                performTest()
                return true
            },
        )]
        setNeedsLayout()
    }

    @objc private dynamic func performTest() {
        testAction?()
    }

    @objc private dynamic func testWidth(for width: CGFloat) -> CGFloat {
        guard testAction != nil else { return 0 }
        return max(44, min(width * 0.4, ceil(testButton.intrinsicContentSize.width) + 12))
    }

    @objc private dynamic func textWidth(for width: CGFloat) -> CGFloat {
        let test = testWidth(for: width)
        return max(1, width - Self.inset.left - Self.inset.right - Self.checkSize - 10 - (test > 0 ? test + 8 : 0))
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let width = textWidth(for: size.width)
        var height = ceil(titleLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
        if !detailLabel.isHidden {
            height += 2 + ceil(detailLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
        }
        let testHeight = testAction == nil ? 0 : testButton.intrinsicContentSize.height + 16
        return CGSize(width: size.width, height: max(44, testHeight, height + Self.inset.top + Self.inset.bottom))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = textWidth(for: bounds.width)
        var y = Self.inset.top
        let titleHeight = ceil(titleLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
        titleLabel.frame = CGRect(x: Self.inset.left + Self.checkSize + 10, y: y, width: width, height: titleHeight)
        check.frame = CGRect(
            x: Self.inset.left,
            y: y + (titleHeight - Self.checkSize) / 2,
            width: Self.checkSize,
            height: Self.checkSize,
        )
        let testWidth = testWidth(for: bounds.width)
        testButton.frame = CGRect(
            x: bounds.width - Self.inset.right - testWidth,
            y: 0, width: testWidth, height: bounds.height,
        )
        y += titleHeight
        if !detailLabel.isHidden {
            let detailHeight = ceil(detailLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
            y += 2
            detailLabel.frame = CGRect(x: titleLabel.frame.minX, y: y, width: width, height: detailHeight)
        }
        if effectiveUserInterfaceLayoutDirection == .rightToLeft {
            for view in [check, titleLabel, detailLabel, testButton] {
                view.frame.origin.x = bounds.width - view.frame.maxX
            }
        }
    }
}

/// One account's quota, opened from the model picker's usage icon (owner,
/// 2026-11-28): asked afresh each time it opens, pulled down, or refreshed from
/// the top right; a figure where the provider gives one, and "Unable to Query
/// Usage" where it does not. Back puts the picker back.
final class QuotaSheetController: UITableViewController {
    private struct Row {
        var title: String
        var value: String? = nil
        var detail: String? = nil
    }

    private struct Section {
        var title: String?
        var rows: [Row]
    }

    private let provider: AgentProvider
    private let accountLabel: String?
    private let poolID: String?
    private var sections: [Section] = []
    private var failure: String?
    private var isLoading = true
    private var currentSnapshot: AgentQuotaSnapshot?
    private var loader: Task<Void, Never>?

    init(provider: AgentProvider, accountLabel: String?, poolID: String?) {
        self.provider = provider
        self.accountLabel = accountLabel
        self.poolID = poolID
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(provider:accountLabel:poolID:)")
    }

    deinit {
        loader?.cancel()
    }


    override func viewDidLoad() {
        super.viewDidLoad()
        title = accountLabel ?? provider.displayName
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: String(localized: "Back"),
            style: .plain,
            target: self,
            action: #selector(luros_back),
        )
        let refresh = UIBarButtonItem(
            image: UIImage(systemName: "arrow.clockwise"),
            style: .plain,
            target: self,
            action: #selector(luros_refresh),
        )
        refresh.accessibilityLabel = String(localized: "Refresh Quota")
        navigationItem.rightBarButtonItem = refresh
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(luros_pulled), for: .valueChanged)
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 52
        reload()
    }

    @objc private dynamic func luros_back() {
        dismiss(animated: true)
    }

    @objc private dynamic func luros_refresh() {
        reload()
    }

    @objc private dynamic func luros_pulled() {
        reload()
    }

    // MARK: - Asking

    /// One live read: `force` skips the coordinator's debounce, so the sheet
    /// shows what the provider answers now, not what it answered before.
    @objc private dynamic func reload() {
        loader?.cancel()
        isLoading = true
        failure = nil
        render()
        loader = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await LurosService.app.agentProviderQuota(
                    provider: provider,
                    mode: .manualRefresh,
                    foreground: true,
                    force: true,
                )
                guard !Task.isCancelled else { return }
                let snapshot = response.quotas.first { $0.poolID == poolID } ?? response.quotas.first
                isLoading = false
                currentSnapshot = snapshot
                refreshControl?.endRefreshing()
                render()
            } catch {
                guard !Task.isCancelled else { return }
                isLoading = false
                failure = error.readableMessage
                refreshControl?.endRefreshing()
                render()
            }
        }
    }

    private func render() {
        var sections: [Section] = []
        if isLoading, currentSnapshot == nil {
            sections.append(Section(title: nil, rows: [Row(title: String(localized: "Loading…"))]))
        } else if let snapshot = currentSnapshot {
            var facts: [Row] = [
                Row(title: String(localized: "Status"), value: QuotaFormatting.statusText(for: snapshot.status)),
            ]
            if let plan = snapshot.planName, !plan.isEmpty {
                facts.append(Row(title: String(localized: "Plan"), value: plan))
            }
            if let account = snapshot.accountLabel, !account.isEmpty {
                facts.append(Row(title: String(localized: "Account"), value: account))
            }
            facts.append(Row(title: String(localized: "Source"), value: QuotaFormatting.sourceText(for: snapshot)))
            sections.append(Section(title: nil, rows: facts))
            if !snapshot.balances.isEmpty {
                let rows = snapshot.balances.map { balance in
                    Row(
                        title: balance.currency ?? balance.unitLabel ?? String(localized: "Balances"),
                        value: QuotaFormatting.balanceAmountText(balance, amount: balance.remaining ?? balance.total),
                    )
                }
                sections.append(Section(title: String(localized: "Balances"), rows: rows))
            }
            if !snapshot.windows.isEmpty {
                let rows = snapshot.windows.map { window in
                    var detail = String(localized: "\(QuotaFormatting.percentText(window.remainingPercent)) remaining")
                    if let reset = window.resetsAt {
                        detail += " · " + QuotaFormatting.resetText(for: reset)
                    }
                    if let status = window.status, !status.isEmpty {
                        detail += " · " + status
                    }
                    return Row(
                        title: window.label,
                        value: QuotaFormatting.percentText(window.usedPercent),
                        detail: detail,
                    )
                }
                sections.append(Section(title: String(localized: "Usage Windows"), rows: rows))
            }
            if snapshot.balances.isEmpty, snapshot.windows.isEmpty {
                sections.append(Section(title: nil, rows: [
                    Row(
                        title: String(localized: "Unable to Query Usage"),
                        detail: snapshot.errorSummary,
                    ),
                ]))
            }
        } else {
            sections.append(Section(title: nil, rows: [
                Row(title: String(localized: "Unable to Query Usage"), detail: failure),
            ]))
        }
        self.sections = sections
        tableView.reloadData()
    }

    // MARK: - Table

    override func numberOfSections(in _: UITableView) -> Int {
        sections.count
    }

    override func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].rows.count
    }

    override func tableView(_: UITableView, titleForHeaderInSection section: Int) -> String? {
        sections[section].title
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = sections[indexPath.section].rows[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "row")
            ?? UITableViewCell(style: row.detail == nil ? .value1 : .subtitle, reuseIdentifier: "row")
        var content = row.detail == nil
            ? UIListContentConfiguration.valueCell()
            : UIListContentConfiguration.subtitleCell()
        content.text = row.title
        content.secondaryText = [row.value, row.detail].compactMap { $0 }.joined(separator: " · ")
        cell.contentConfiguration = content
        cell.selectionStyle = .none
        return cell
    }
}
