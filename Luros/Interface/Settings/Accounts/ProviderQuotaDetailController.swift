import LurosProtocol
import SnapKit
import SPIndicator
import Then
import UIKit

/// Settings ▸ Model Providers ▸ an account: detailed quota pools, rate windows,
/// passive/active telemetry metadata, manual refresh, and official billing link.
final class ProviderQuotaDetailController: TableController {
    private enum Section: Hashable {
        case overview
        case balances
        case windows
        case actions
        case management
    }

    private enum Row: Hashable {
        case status
        case plan
        case source
        case updatedAt
        case cooldown
        case errorSummary
        case balance(AgentQuotaBalance)
        case window(AgentQuotaWindow)
        case refresh
        case openBilling
        case editAccount
        case models
        case modelParameters
        case signOut
    }

    private var account: AgentAccount
    private var snapshot: AgentQuotaSnapshot?
    private let onAccountsChanged: () -> Void
    private var loader: Task<Void, Never>?
    @objc private dynamic var refreshing = false

    private lazy var dataSource = TableDataSource<Section, Row, Row>(
        tableView: tableView,
        identifier: { $0 },
    ) { [weak self] _, _, row in
        self?.cell(for: row)
    }

    init(
        account: AgentAccount,
        initialQuota: AgentQuotaSnapshot?,
        onAccountsChanged: @escaping () -> Void,
    ) {
        self.account = account
        snapshot = initialQuota
        self.onAccountsChanged = onAccountsChanged
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(account:initialQuota:onAccountsChanged:)")
    }

    deinit {
        loader?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = account.provider.displayName
        navigationItem.backButtonDisplayMode = .minimal
        navigationItem.largeTitleDisplayMode = .never
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 56
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "arrow.clockwise"),
            primaryAction: UIAction { [weak self] _ in self?.triggerManualRefresh() },
        ).then {
            $0.accessibilityLabel = String(localized: "Refresh Quota")
        }
        refreshControl = UIRefreshControl().then {
            $0.addAction(UIAction { [weak self] _ in self?.triggerManualRefresh() }, for: .valueChanged)
        }
        dataSource.headerTitle = { section in
            switch section {
            case .overview: String(localized: "Account")
            case .balances: String(localized: "Balances")
            case .windows: String(localized: "Usage Windows")
            case .actions: String(localized: "Quota")
            case .management: String(localized: "Configuration")
            }
        }
        dataSource.footerTitle = { [weak self] section in
            guard let self else { return nil }
            switch section {
            case .overview:
                if let accountLabel = snapshot?.accountLabel ?? account.account {
                    return accountLabel
                }
                return nil
            case .actions:
                return String(localized: "Manual refresh is limited to once every 30 seconds.")
            default:
                return nil
            }
        }
        rebuildSections()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        loadAttentionGated()
    }

    @objc(luros_loadAttentionGated) private dynamic func loadAttentionGated() {
        loader?.cancel()
        loader = Task { [weak self] in
            guard let self else { return }
            let response = try? await LurosService.app.agentProviderQuota(
                provider: account.provider,
                mode: .attentionGated,
                foreground: true,
                force: false,
            )
            guard !Task.isCancelled else { return }
            if let latest = matchingSnapshot(in: response?.quotas ?? []) {
                snapshot = latest
                rebuildSections()
            }
        }
    }

    @objc(luros_triggerManualRefresh) private dynamic func triggerManualRefresh() {
        guard !refreshing else {
            refreshControl?.endRefreshing()
            return
        }
        let now = Date()
        if let debounceUntil = snapshot?.manualDebounceUntil, debounceUntil > now {
            let seconds = max(1, Int(ceil(debounceUntil.timeIntervalSince(now))))
            refreshControl?.endRefreshing()
            SPIndicator.present(
                title: String(localized: "Try Again in \(seconds)s"),
                preset: .error,
                haptic: .warning,
            )
            return
        }
        refreshing = true
        updateRefreshControls()
        loader?.cancel()
        loader = Task { [weak self] in
            guard let self else { return }
            defer {
                refreshing = false
                refreshControl?.endRefreshing()
                updateRefreshControls()
            }
            do {
                let response = try await LurosService.app.agentProviderQuota(
                    provider: account.provider,
                    mode: .manualRefresh,
                    foreground: true,
                    force: true,
                )
                guard !Task.isCancelled else { return }
                if let latest = matchingSnapshot(in: response.quotas) {
                    snapshot = latest
                    rebuildSections()
                    if latest.status == .available || latest.status == .exhausted {
                        SPIndicator.present(
                            title: String(localized: "Quota Updated"),
                            preset: .done,
                            haptic: .success,
                        )
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                presentNotice(title: "Unable to Refresh Quota", message: error.readableMessage)
            }
        }
    }

    private func matchingSnapshot(in quotas: [AgentQuotaSnapshot]) -> AgentQuotaSnapshot? {
        if let poolID = account.poolID ?? snapshot?.poolID,
           let exact = quotas.first(where: { $0.poolID == poolID && $0.provider == account.provider })
           ?? quotas.first(where: { $0.poolID == poolID })
        {
            return exact
        }
        if let label = account.account,
           let labeled = quotas.first(where: { $0.provider == account.provider && $0.accountLabel == label })
        {
            return labeled
        }
        return quotas.first(where: { $0.provider == account.provider }) ?? quotas.first
    }

    @objc(luros_updateRefreshControls) private dynamic func updateRefreshControls() {
        navigationItem.rightBarButtonItem?.isEnabled = !refreshing
    }

    @objc(luros_rebuildSections) private dynamic func rebuildSections() {
        var sections: [(Section, [Row])] = []

        var overviewRows: [Row] = [.status]
        if let plan = snapshot?.planName, !plan.isEmpty {
            overviewRows.append(.plan)
        }
        overviewRows.append(.source)
        if snapshot?.updatedAt != nil {
            overviewRows.append(.updatedAt)
        }
        if let next = snapshot?.circuitBrokenUntil ?? snapshot?.cooldownUntil, next > Date() {
            overviewRows.append(.cooldown)
        }
        if let err = snapshot?.errorSummary, !err.isEmpty {
            overviewRows.append(.errorSummary)
        }
        sections.append((.overview, overviewRows))

        if let balances = snapshot?.balances, !balances.isEmpty {
            sections.append((.balances, balances.map(Row.balance)))
        }
        if let windows = snapshot?.windows, !windows.isEmpty {
            sections.append((.windows, windows.map(Row.window)))
        }

        var actionRows: [Row] = []
        if snapshot?.kind != .billingLink {
            actionRows.append(.refresh)
        }
        if snapshot?.billingURL != nil || QuotaBillingLinksHelper.url(for: account.provider) != nil {
            actionRows.append(.openBilling)
        }
        if !actionRows.isEmpty {
            sections.append((.actions, actionRows))
        }

        sections.append((.management, [.editAccount, .models, .modelParameters, .signOut]))
        dataSource.update(sections, reconfigure: true)
    }

    private func cell(for row: Row) -> UITableViewCell {
        switch row {
        case .status:
            let value = snapshot.map { QuotaFormatting.statusText(for: $0.status) } ?? String(localized: "Signed In")
            return valueCell(title: String(localized: "Status"), value: value)
        case .plan:
            return valueCell(title: String(localized: "Plan"), value: snapshot?.planName ?? "")
        case .source:
            let value = snapshot.map(QuotaFormatting.sourceText(for:)) ?? String(localized: "Cached")
            return valueCell(title: String(localized: "Source"), value: value)
        case .updatedAt:
            let dateText = snapshot?.updatedAt?.formatted(date: .abbreviated, time: .shortened) ?? ""
            return valueCell(title: String(localized: "Updated"), value: dateText)
        case .cooldown:
            let target = snapshot?.circuitBrokenUntil ?? snapshot?.cooldownUntil ?? Date()
            return valueCell(
                title: String(localized: "Next Automatic Check"),
                value: target.formatted(date: .abbreviated, time: .shortened),
            )
        case .errorSummary:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            var content = UIListContentConfiguration.explanatoryCell()
            content.text = String(localized: "Last Error")
            content.secondaryText = snapshot?.errorSummary
            content.secondaryTextProperties.color = .systemOrange
            content.secondaryTextProperties.numberOfLines = 0
            cell.contentConfiguration = content
            cell.selectionStyle = .none
            return cell
        case let .balance(balance):
            return balanceCell(balance)
        case let .window(window):
            return QuotaWindowCell(window: window)
        case .refresh:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            var content = cell.defaultContentConfiguration()
            content.text = refreshing ? String(localized: "Refreshing…") : String(localized: "Refresh Quota")
            content.image = UIImage(systemName: "arrow.clockwise")
            content.textProperties.color = refreshing ? .secondaryLabel : .tintColor
            cell.contentConfiguration = content
            cell.accessibilityTraits.insert(.button)
            return cell
        case .openBilling:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            var content = cell.defaultContentConfiguration()
            content.text = String(localized: "Open Official Billing Page")
            content.image = UIImage(systemName: "arrow.up.right.square")
            content.textProperties.color = .tintColor
            cell.contentConfiguration = content
            cell.accessibilityTraits.insert(.button)
            return cell
        case .editAccount:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            var content = cell.defaultContentConfiguration()
            content.text = account.isAPIKeyAccount ? String(localized: "Edit Configuration") : String(localized: "Sign In Again")
            content.image = UIImage(systemName: account.isAPIKeyAccount ? "pencil" : "arrow.clockwise")
            cell.contentConfiguration = content
            cell.accessoryType = .disclosureIndicator
            return cell
        case .models:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            var content = cell.defaultContentConfiguration()
            content.text = String(localized: "Models")
            content.image = UIImage(systemName: "checklist")
            cell.contentConfiguration = content
            cell.accessoryType = .disclosureIndicator
            return cell
        case .modelParameters:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            var content = cell.defaultContentConfiguration()
            content.text = String(localized: "Model Parameters")
            content.image = UIImage(systemName: "slider.horizontal.3")
            cell.contentConfiguration = content
            cell.accessoryType = .disclosureIndicator
            return cell
        case .signOut:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            var content = cell.defaultContentConfiguration()
            content.text = String(localized: "Sign Out")
            content.image = UIImage(systemName: "rectangle.portrait.and.arrow.right")
            content.textProperties.color = .systemRed
            content.imageProperties.tintColor = .systemRed
            cell.contentConfiguration = content
            cell.accessibilityTraits.insert(.button)
            return cell
        }
    }

    @objc(luros_valueCellWithTitle:value:) private dynamic func valueCell(title: String, value: String) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.text = title
        content.secondaryText = value
        content.secondaryTextProperties.color = .secondaryLabel
        content.secondaryTextProperties.numberOfLines = 0
        cell.contentConfiguration = content
        cell.selectionStyle = .none
        return cell
    }

    private func balanceCell(_ balance: AgentQuotaBalance) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = UIListContentConfiguration.stackedValueCell()
        let poolTitle = balance.currency ?? balance.unitLabel?.capitalized ?? balance.id
        let primaryAmount = balance.isUnlimited
            ? String(localized: "Unlimited")
            : QuotaFormatting.balanceAmountText(balance, amount: balance.remaining ?? balance.total)
        content.text = "\(poolTitle) · \(primaryAmount)"
        content.textProperties.numberOfLines = 0

        var details: [String] = []
        if !balance.isAvailable {
            details.append(String(localized: "Unavailable"))
        }
        if let total = balance.total, !balance.isUnlimited {
            details.append(String(localized: "Total \(QuotaFormatting.balanceAmountText(balance, amount: total))"))
        }
        if let granted = balance.granted {
            details.append(String(localized: "Granted \(QuotaFormatting.balanceAmountText(balance, amount: granted))"))
        }
        if let toppedUp = balance.toppedUp {
            details.append(String(localized: "Topped Up \(QuotaFormatting.balanceAmountText(balance, amount: toppedUp))"))
        }
        if let used = balance.used {
            details.append(String(localized: "Used \(QuotaFormatting.balanceAmountText(balance, amount: used))"))
        }
        content.secondaryText = details.joined(separator: " · ")
        content.secondaryTextProperties.color = balance.isAvailable ? .secondaryLabel : .systemOrange
        content.secondaryTextProperties.numberOfLines = 0
        cell.contentConfiguration = content
        cell.selectionStyle = .none
        return cell
    }

    override func tableView(_: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        guard let row = dataSource.value(at: indexPath) else { return false }
        switch row {
        case .refresh, .openBilling, .editAccount, .models, .modelParameters, .signOut:
            return true
        default:
            return false
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = dataSource.value(at: indexPath) else { return }
        switch row {
        case .refresh:
            triggerManualRefresh()
        case .openBilling:
            if let url = snapshot?.billingURL ?? QuotaBillingLinksHelper.url(for: account.provider) {
                UIApplication.shared.open(url)
            }
        case .editAccount:
            let page = ProviderLoginController(account: account)
            page.onFinish = { [weak self] in
                self?.onAccountsChanged()
                self?.loadAttentionGated()
            }
            page.isModalInPresentation = true
            presentPageAsFormSheet(page)
        case .models:
            presentPageAsFormSheet(ModelActivationController(account: account))
        case .modelParameters:
            presentPageAsFormSheet(ModelParametersController(account: account))
        case .signOut:
            confirmSignOut()
        default:
            break
        }
    }

    @objc(luros_confirmSignOut) private dynamic func confirmSignOut() {
        let provider = account.provider
        let name = provider.kind == .openAICompatible ? account.account ?? provider.displayName : provider.displayName
        presentConfirmation(
            title: "Sign Out of \(name)?",
            message: "Agent sessions that use it stop working until you sign in again.",
            confirmTitle: "Sign Out",
            destructive: true,
        ) { [weak self] in
            self?.performSignOut()
        }
    }

    @objc(luros_performSignOut) private dynamic func performSignOut() {
        let provider = account.provider
        Task { [weak self] in
            do {
                try await LurosService.app.agentSignOut(provider: provider)
                EnabledModels.remove(for: provider)
                guard let self else { return }
                onAccountsChanged()
                navigationController?.popViewController(animated: true)
            } catch {
                self?.presentNotice(title: "Unable to Sign Out", message: error.readableMessage)
            }
        }
    }
}

/// A progress-backed cell showing one subscription rate window (used %, reset time).
private final class QuotaWindowCell: UITableViewCell {
    private let titleLabel = UILabel().then {
        $0.font = .preferredFont(forTextStyle: .body)
        $0.adjustsFontForContentSizeCategory = true
        $0.numberOfLines = 0
    }

    private let percentLabel = UILabel().then {
        $0.font = .monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize, weight: .semibold)
        $0.adjustsFontForContentSizeCategory = true
        $0.textAlignment = .right
    }

    private let progressBar = UIProgressView(progressViewStyle: .default)

    private let subtitleLabel = UILabel().then {
        $0.font = .preferredFont(forTextStyle: .footnote)
        $0.adjustsFontForContentSizeCategory = true
        $0.textColor = .secondaryLabel
        $0.numberOfLines = 0
    }

    init(window: AgentQuotaWindow) {
        super.init(style: .default, reuseIdentifier: nil)
        selectionStyle = .none
        isAccessibilityElement = true

        let topRow = UIStackView(arrangedSubviews: [titleLabel, percentLabel]).then {
            $0.axis = .horizontal
            $0.alignment = .firstBaseline
            $0.spacing = 8
        }
        let stack = UIStackView(arrangedSubviews: [topRow, progressBar, subtitleLabel]).then {
            $0.axis = .vertical
            $0.spacing = 6
        }
        contentView.addSubview(stack)
        stack.snp.makeConstraints {
            $0.edges.equalTo(contentView.layoutMarginsGuide)
        }

        let usedFloat = NSDecimalNumber(decimal: window.usedPercent).floatValue / 100.0
        progressBar.progress = max(0, min(1, usedFloat))
        if window.usedPercent >= 95 {
            progressBar.progressTintColor = .systemRed
        } else if window.usedPercent >= 75 {
            progressBar.progressTintColor = .systemOrange
        } else {
            progressBar.progressTintColor = .tintColor
        }

        titleLabel.text = window.label
        let pctText = QuotaFormatting.percentText(window.usedPercent)
        percentLabel.text = pctText

        var subtitleParts: [String] = [
            String(localized: "\(QuotaFormatting.percentText(window.remainingPercent)) remaining"),
        ]
        if let reset = window.resetsAt {
            subtitleParts.append(QuotaFormatting.resetText(for: reset))
        }
        if let status = window.status, !status.isEmpty {
            subtitleParts.append(status)
        }
        let subtitle = subtitleParts.joined(separator: " · ")
        subtitleLabel.text = subtitle
        accessibilityLabel = window.label
        accessibilityValue = "\(pctText), \(subtitle)"
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(window:)")
    }
}

private enum QuotaBillingLinksHelper {
    static func url(for provider: AgentProvider) -> URL? {
        switch provider {
        case .openAI: URL(string: "https://platform.openai.com/settings/organization/billing/overview")
        case .anthropic: URL(string: "https://console.anthropic.com/settings/billing")
        case .anthropicOAuth: URL(string: "https://claude.ai/settings/usage")
        case .openAICodex: URL(string: "https://chatgpt.com/codex/settings/usage")
        case .google: URL(string: "https://aistudio.google.com/spend")
        case .deepSeek: URL(string: "https://platform.deepseek.com/usage")
        case .openRouter: URL(string: "https://openrouter.ai/settings/credits")
        case .githubCopilot: URL(string: "https://github.com/settings/copilot")
        case .cursor: URL(string: "https://cursor.com/dashboard?tab=billing")
        case .devin: URL(string: "https://app.devin.ai/settings/billing")
        case .kiro: URL(string: "https://app.kiro.dev/account")
        case .antigravity: URL(string: "https://antigravity.google")
        case .qoder: URL(string: "https://qoder.com/account")
        case .qoderCN: URL(string: "https://qoder.cn/account")
        case .workBuddy: URL(string: "https://copilot.tencent.com")
        case .workBuddyAI: URL(string: "https://www.codebuddy.ai")
        case .trae: URL(string: "https://www.trae.com.cn/account")
        case .traeIntl: URL(string: "https://www.trae.ai/account")
        case .raccoon: URL(string: "https://xiaohuanxiong.com")
        case .kimiCoding: URL(string: "https://www.kimi.com/code/console")
        case .kimiCodingGlobal: URL(string: "https://www.kimi.ai/code/console")
        case .xai: URL(string: "https://console.x.ai")
        case .zai: URL(string: "https://z.ai/manage-apikey/subscription")
        case .zaiCodingCN: URL(string: "https://bigmodel.cn/usercenter/proj-mgmt/rate-limits")
        case .openCodeGo, .openCodeZen: URL(string: "https://opencode.ai/auth")
        case .openAICompatible, .openAICompatibleEndpoint: nil
        }
    }
}
