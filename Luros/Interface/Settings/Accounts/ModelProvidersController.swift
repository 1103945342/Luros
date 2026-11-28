import LurosProtocol
import SPIndicator
import Then
import UIKit

/// Settings ▸ Model Providers: every provider luros-agent can sign in to,
/// in Luros's display order. Signed-in ones first, each with who
/// it is signed in as under its name and a `…` menu (Edit Configuration or Sign In Again, Sign
/// Out); then the rest, those signed in to with an account apart from those
/// that take a typed key. A search field narrows the list by name. The
/// OpenAI-compatible login is there once for each endpoint signed in to,
/// told apart by its host, and once more among the keys to add another.
final class ModelProvidersController: TableController, UISearchResultsUpdating {
    private enum Group: Hashable {
        case signedIn
        case accounts
        case keys

        var title: String {
            switch self {
            case .signedIn: String(localized: "Signed In")
            case .accounts: String(localized: "Sign In with an Account")
            case .keys: String(localized: "API Keys")
            }
        }
    }

    private enum Status: Equatable {
        case loading
        case unavailable(String)
        case noResults
    }

    private enum Section: Hashable {
        case group(Group)
        case status
    }

    private enum Row: Equatable {
        case account(AgentAccount, AgentQuotaSnapshot?)
        case status(Status)
        var id: String {
            switch self {
            case let .account(account, _): account.provider.rawValue
            case .status: "status"
            }
        }
    }

    private lazy var dataSource = TableDataSource<Section, String, Row>(
        tableView: tableView,
        identifier: { $0.id },
    ) { [weak self] _, _, row in
        guard let self else { return nil }
        switch row {
        case let .account(account, quota): return accountCell(account, quota: quota)
        case let .status(status): return statusCell(status)
        }
    }

    private struct QuotaKey: Hashable {
        let provider: AgentProvider
        let poolID: String
    }

    /// The accounts as luros-agent last listed them.
    private var accounts: [AgentAccount] = []
    private var quotas: [QuotaKey: AgentQuotaSnapshot] = [:]
    @objc private dynamic var loaded = false
    @objc private dynamic var refreshingQuotas = false
    @objc private dynamic var failure: Error?
    @objc private dynamic var query = ""
    private var sections: [(Section, [Row])] = [(.status, [.status(.loading)])]
    private var loader: Task<Void, Never>?
    private var quotaLoader: Task<Void, Never>?
    private let search = UISearchController(searchResultsController: nil)

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    deinit {
        loader?.cancel()
        quotaLoader?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Model Providers")
        navigationItem.backButtonDisplayMode = .minimal
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "arrow.clockwise"),
            primaryAction: UIAction { [weak self] _ in self?.refreshQuotasManually() },
        ).then {
            $0.accessibilityLabel = String(localized: "Refresh Quotas")
        }
        refreshControl = UIRefreshControl().then {
            $0.addAction(UIAction { [weak self] _ in self?.refreshQuotasManually() }, for: .valueChanged)
        }
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = String(localized: "Search")
        search.searchBar.autocapitalizationType = .none
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
        dataSource.headerTitle = { section in
            if case let .group(group) = section {
                return group.title
            }
            return nil
        }
        dataSource.footerTitle = { [weak self] section in
            guard let self, section == sections.last?.0, case .group = section else { return nil }
            // kwwk signs in and talks to every provider here: its version
            // is what a report about one needs.
            guard let kwwk = LinkedPackage.kwwkVersion else {
                return String(localized: "Credentials stay in this device’s keychain.")
            }
            return String(localized: "Credentials stay in this device’s keychain. Currently using kwwk \(kwwk).")
        }
        dataSource.update(sections)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        load()
    }

    @objc(luros_load) private dynamic func load() {
        loader?.cancel()
        dataSource.beginLoad()
        loader = Task { [weak self] in
            do {
                let accounts = try await LurosService.app.agentAccountsWithKnownModels()
                guard !Task.isCancelled, let self else { return }
                self.accounts = accounts
                failure = nil
            } catch {
                guard !Task.isCancelled, let self else { return }
                failure = error
            }
            guard let self else { return }
            loaded = true
            regroup()
            loadQuotas(mode: .attentionGated, force: false)
        }
    }

    private func loadQuotas(mode: AgentQuotaFetchMode, force: Bool) {
        guard accounts.contains(where: \.signedIn) else {
            refreshControl?.endRefreshing()
            return
        }
        quotaLoader?.cancel()
        quotaLoader = Task { [weak self] in
            guard let self else { return }
            defer {
                refreshingQuotas = false
                refreshControl?.endRefreshing()
                navigationItem.rightBarButtonItem?.isEnabled = true
            }
            let response = try? await LurosService.app.agentProviderQuota(
                provider: nil,
                mode: mode,
                foreground: true,
                force: force,
            )
            guard !Task.isCancelled, let response else { return }
            var next: [QuotaKey: AgentQuotaSnapshot] = [:]
            for snap in response.quotas {
                next[QuotaKey(provider: snap.provider, poolID: snap.poolID)] = snap
            }
            quotas = next
            regroup()
            if mode == .manualRefresh, !response.quotas.isEmpty {
                SPIndicator.present(
                    title: String(localized: "Quotas Updated"),
                    preset: .done,
                    haptic: .success,
                )
            }
        }
    }

    @objc(luros_refreshQuotasManually) private dynamic func refreshQuotasManually() {
        guard !refreshingQuotas else {
            refreshControl?.endRefreshing()
            return
        }
        let now = Date()
        let queryable = quotas.values.filter { $0.kind != .billingLink }
        let debounces = queryable.compactMap(\.manualDebounceUntil).filter { $0 > now }
        if !queryable.isEmpty, debounces.count == queryable.count, let earliestDebounce = debounces.min() {
            let seconds = max(1, Int(ceil(earliestDebounce.timeIntervalSince(now))))
            refreshControl?.endRefreshing()
            SPIndicator.present(
                title: String(localized: "Try Again in \(seconds)s"),
                preset: .error,
                haptic: .warning,
            )
            return
        }
        refreshingQuotas = true
        navigationItem.rightBarButtonItem?.isEnabled = false
        loadQuotas(mode: .manualRefresh, force: true)
    }

    private func quota(for account: AgentAccount) -> AgentQuotaSnapshot? {
        if let poolID = account.poolID,
           let exact = quotas[QuotaKey(provider: account.provider, poolID: poolID)]
        {
            return exact
        }
        let matches = quotas.values.filter { $0.provider == account.provider }
        if let label = account.account,
           let labeled = matches.first(where: { $0.accountLabel == label })
        {
            return labeled
        }
        return matches.first
    }

    @objc dynamic func updateSearchResults(for searchController: UISearchController) {
        let text = (searchController.searchBar.text ?? "").trimmingCharacters(in: .whitespaces)
        guard text != query else { return }
        query = text
        regroup()
    }

    @objc private dynamic func regroup() {
        if !loaded {
            sections = [(.status, [.status(.loading)])]
        } else if let failure, accounts.isEmpty {
            sections = [(.status, [.status(.unavailable(ProviderLoginController.unavailableText(failure)))])]
        } else {
            let shown = query.isEmpty
                ? accounts
                : accounts.filter {
                    $0.provider.displayName.localizedStandardContains(query)
                        // an endpoint is found by the host it was signed in to as well
                        || ($0.account ?? "").localizedStandardContains(query)
                }
            let groups: [(Group, [AgentAccount])] = [
                (.signedIn, shown.filter(\.signedIn)),
                (.accounts, shown.filter { !$0.signedIn && $0.method != .apiKey }),
                (.keys, shown.filter { !$0.signedIn && $0.method == .apiKey }),
            ]
            sections = groups.filter { !$0.1.isEmpty }.map { group, items in
                (.group(group), items.map { Row.account($0, quota(for: $0)) })
            }
            if sections.isEmpty {
                sections = [(.status, [.status(.noResults)])]
            }
        }
        dataSource.update(sections)
    }

    // MARK: - Table

    private func account(at indexPath: IndexPath) -> AgentAccount? {
        guard case let .account(account, _)? = dataSource.value(at: indexPath) else { return nil }
        return account
    }

    private func statusCell(_ status: Status) -> UITableViewCell {
        switch status {
        case .loading:
            return WaitingCell().then { $0.show(String(localized: "Loading…")) }
        case let .unavailable(message):
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            var content = UIListContentConfiguration.stackedValueCell()
            content.text = String(localized: "Model Providers Unavailable")
            content.secondaryText = message
            content.secondaryTextProperties.color = .secondaryLabel

            cell.contentConfiguration = content
            cell.selectionStyle = .none
            return cell
        case .noResults:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            var content = UIListContentConfiguration.cell()
            content.text = String(localized: "No Results")
            content.textProperties.color = .secondaryLabel
            content.textProperties.alignment = .center
            cell.contentConfiguration = content
            cell.selectionStyle = .none
            return cell
        }
    }

    /// The provider's mark and name on one line; signed in, who as + quota
    /// summary under the name and a `…` menu at the end.
    private func accountCell(_ account: AgentAccount, quota: AgentQuotaSnapshot?) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content: UIListContentConfiguration
        if account.signedIn {
            content = .stackedValueCell()
            content.secondaryText = Self.signedInLine(account, quota: quota)
            content.secondaryTextProperties.color = quota?.status == .exhausted ? .systemOrange : .secondaryLabel
            content.secondaryTextProperties.numberOfLines = 2

            cell.accessoryView = menuButton(account)
            cell.selectionStyle = .default
        } else {
            content = .cell()
            cell.accessoryType = .disclosureIndicator
        }
        content.text = account.provider.displayName
        content.textProperties.numberOfLines = 1
        content.image = account.provider.icon
        content.imageProperties.maximumSize = CGSize(width: 29, height: 29)
        content.imageProperties.reservedLayoutSize = CGSize(width: 29, height: 29)
        cell.contentConfiguration = content
        return cell
    }

    /// Who is signed in, expiry if any, and concise quota summary.
    private static func signedInLine(_ account: AgentAccount, quota: AgentQuotaSnapshot?) -> String {
        let name = account.account ?? String(localized: "Signed In")
        var line = name
        if let expiresAt = account.expiresAt {
            let date = expiresAt.formatted(date: .abbreviated, time: .shortened)
            line = expiresAt < Date()
                ? String(localized: "\(name), expired \(date)")
                : String(localized: "\(name), until \(date)")
        }
        if let quota, let summary = QuotaFormatting.summaryText(for: quota), !summary.isEmpty {
            return "\(line) · \(summary)"
        }
        return line
    }

    /// `…` with no circle, its menu read each time it opens.
    private func menuButton(_ account: AgentAccount) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        button.showsMenuAsPrimaryAction = true
        button.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            completion(self?.accountActions(account) ?? [])
        }])
        button.frame = CGRect(x: 0, y: 0, width: 32, height: 44)
        button.accessibilityLabel = String(localized: "\(account.provider.displayName) Options")
        return button
    }

    private func accountActions(_ account: AgentAccount) -> [UIMenuElement] {
        [
            UIAction(
                title: String(localized: "Quota & Details"),
                image: UIImage(systemName: "chart.bar"),
            ) { [weak self] _ in
                self?.openQuotaDetail(account)
            },
            UIAction(
                title: String(localized: "Edit"),
                image: UIImage(systemName: account.isAPIKeyAccount ? "pencil" : "arrow.clockwise"),
            ) { [weak self] _ in
                self?.signIn(account)
            },
            addAccountAction(for: account.provider),
            UIAction(
                title: String(localized: "Models"),
                image: UIImage(systemName: "checklist"),
            ) { [weak self] _ in
                self?.presentPageAsFormSheet(ModelActivationController(account: account))
            },
            UIAction(
                title: String(localized: "Model Parameters"),
                image: UIImage(systemName: "slider.horizontal.3"),
            ) { [weak self] _ in
                self?.presentPageAsFormSheet(ModelParametersController(account: account))
            },
            UIMenu(options: .displayInline, children: [
                UIAction(
                    title: String(localized: "Sign Out"),
                    image: UIImage(systemName: "rectangle.portrait.and.arrow.right"),
                    attributes: .destructive,
                ) { [weak self] _ in
                    self?.confirmSignOut(account)
                },
            ]),
        ]
    }

    override func tableView(_: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        account(at: indexPath) != nil
    }

    override func tableView(
        _: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point _: CGPoint,
    ) -> UIContextMenuConfiguration? {
        guard let account = account(at: indexPath), account.signedIn else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            UIMenu(children: self?.accountActions(account) ?? [])
        })
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let account = account(at: indexPath) else { return }
        if account.signedIn {
            openQuotaDetail(account)
        } else {
            signIn(account)
        }
    }

    // MARK: - Acting

    /// A second, third … account of one provider (owner, 2026-11-28): the
    /// lowest free slot, signed in on a page of its own, so its key and its
    /// quota are that account's and never the first one's.
    private func addAccountAction(for provider: AgentProvider) -> UIKit.UIAction {
        let ids = accounts.filter { $0.provider == provider }.compactMap(\.storeID)
        let base = ids.first.map(AgentAccountID.base(of:)) ?? provider.rawValue
        let free = AgentAccountID.next(base: base, taken: Set(ids))
        // The methods are the worker's to name: the provider's unsaved row,
        // which every list carries, is what a new account is signed in with.
        let template = accounts.first { $0.provider == provider && !$0.signedIn }
            ?? accounts.first { $0.provider == provider }
        return UIKit.UIAction(
            title: String(localized: "Add Account"),
            image: UIImage(systemName: "person.badge.plus"),
            attributes: (free == nil || template == nil) ? .disabled : [],
        ) { [weak self] _ in
            guard let self, let free, let template else { return }
            signIn(AgentAccount(
                provider: provider,
                method: template.method,
                alternativeMethods: template.alternativeMethods,
                signedIn: false,
                storeID: free,
            ))
        }
    }

    private func openQuotaDetail(_ account: AgentAccount) {
        let page = ProviderQuotaDetailController(
            account: account,
            initialQuota: quota(for: account),
            onAccountsChanged: { [weak self] in self?.load() },
        )
        navigationController?.pushViewController(page, animated: true)
    }

    private func signIn(_ account: AgentAccount) {
        let page = ProviderLoginController(account: account)
        page.onFinish = { [weak self] in self?.load() }
        // a sheet of its own over Settings, kept up until it is closed: a
        // stray swipe would end a sign-in waiting on Safari
        page.isModalInPresentation = true
        presentPageAsFormSheet(page)
    }

    /// An OpenAI-compatible endpoint is named by its host: there can be
    /// several, all with the provider's one name.
    private func confirmSignOut(_ account: AgentAccount) {
        let provider = account.provider
        let name = provider.kind == .openAICompatible ? account.account ?? provider.displayName : provider.displayName
        presentConfirmation(
            title: "Sign Out of \(name)?",
            message: "Agent sessions that use it stop working until you sign in again.",
            confirmTitle: "Sign Out",
            destructive: true,
        ) { [weak self] in
            self?.signOut(provider, accountID: account.storeID)
        }
    }

    private func signOut(_ provider: AgentProvider, accountID: String?) {
        Task { [weak self] in
            do {
                try await LurosService.app.agentSignOut(provider: provider, accountID: accountID)
                EnabledModels.remove(for: provider)
                self?.load()
            } catch {
                self?.presentNotice(title: "Unable to Sign Out", message: error.readableMessage)
            }
        }
    }
}
