import AlertController
import LurosProtocol
import UIKit

/// Saves one provider's enabled models only when the user confirms.
final class ModelActivationController: TableController, UISearchResultsUpdating {
    private let account: AgentAccount
    @objc private dynamic var selected: Set<String>
    @objc private dynamic var shown: [String]
    @objc private dynamic var models: [String]
    @objc private dynamic var custom: Set<String>
    @objc private dynamic var hidden: Set<String>
    private var loader: Task<Void, Never>?
    @objc private dynamic var saving = false
    /// Shown where the fetch button was while the provider is being asked
    /// (owner, 2026-11-28): a page that looks frozen reads as broken.
    private let fetchSpinner = UIActivityIndicatorView(style: .medium)
    private var fetchItem: UIBarButtonItem?
    private var verification: TaskHandle?
    private let search = UISearchController(searchResultsController: nil)

    init(account: AgentAccount) {
        self.account = account
        let available = account.models ?? []
        let enabled = EnabledModels.ids(for: account.provider)
        custom = Set(EnabledModels.customIDs(for: account.provider))
        hidden = account.isAPIKeyAccount ? EnabledModels.hiddenIDs(for: account.provider) : []
        selected = account.isAPIKeyAccount ? enabled.subtracting(hidden) : enabled.intersection(available)
        models = account.isAPIKeyAccount
            ? Array(Set(available).union(custom).union(selected).subtracting(hidden)).sorted()
            : available
        shown = models
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(account:)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Enable Models")
        navigationItem.largeTitleDisplayMode = .never
        let save = UIBarButtonItem(
            title: String(localized: "Save"),
            primaryAction: UIAction { [weak self] _ in self?.save() },
        )
        // The provider's own list, asked for on arrival and again from here
        // (owner, 2026-11-28): what the account already knows is drawn until
        // the provider answers, and stays when it cannot.
        let fetch = UIBarButtonItem(
            image: UIImage(systemName: "arrow.clockwise"),
            primaryAction: UIAction { [weak self] _ in self?.fetchModels() },
        )
        fetch.accessibilityLabel = String(localized: "Refresh Models")
        fetchItem = fetch
        if usesAPIKey {
            let add = UIBarButtonItem(
                image: UIImage(systemName: "plus"),
                primaryAction: UIAction { [weak self] _ in self?.addCustomModel() },
            )
            add.accessibilityLabel = String(localized: "Add Custom Model")
            navigationItem.rightBarButtonItems = [save, add, fetch]
        } else {
            navigationItem.rightBarButtonItems = [save, fetch]
        }
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = String(localized: "Search Models")
        search.searchBar.autocapitalizationType = .none
        navigationItem.searchController = search
        definesPresentationContext = true
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "model")
        updateRows()
    }

    private struct ModelRow: Equatable {
        let id: String
        let selected: Bool
    }

    private lazy var dataSource = TableDataSource<Int, String, ModelRow>(
        tableView: tableView,
        identifier: { $0.id },
    ) { [weak self] table, indexPath, row in
        self?.cell(in: table, at: indexPath, row: row)
    }

    @objc private dynamic func updateRows() {
        dataSource.headerTitle = { [weak self] _ in self.map { $0.account.account ?? $0.account.provider.displayName } }
        dataSource.footerTitle = { _ in String(localized: "Choose the models to show in the chat model picker. You can change this later in Model Providers.") }
        dataSource.allowsEditing = usesAPIKey
        dataSource.update([(0, shown.map { ModelRow(id: $0, selected: selected.contains($0)) })], reconfigure: true)
    }

    @objc private dynamic var usesAPIKey: Bool {
        account.isAPIKeyAccount
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard loader == nil else { return }
        fetchModels()
    }

    /// The provider's model list for this account, merged with the models the
    /// reader added and the ones already enabled: a provider that cannot
    /// answer leaves the list as it was, which is where the defaults show.
    @objc private dynamic func fetchModels() {
        loader?.cancel()
        dataSource.beginLoad()
        navigationItem.prompt = nil
        showFetching(true)
        loader = Task { [weak self] in
            guard let self else { return }
            defer { showFetching(false) }
            do {
                let fetched = try await LurosService.app.agentModelList(
                    provider: account.provider,
                    accountID: account.storeID,
                ).models
                guard !Task.isCancelled else { return }
                guard !fetched.isEmpty else {
                    navigationItem.prompt = String(localized: "Unable to Fetch Models")
                    updateSearchResults(for: search)
                    return
                }
                models = Array(Set(fetched).union(custom).union(selected).subtracting(hidden)).sorted()
                updateSearchResults(for: search)
            } catch {
                guard !Task.isCancelled else { return }
                navigationItem.prompt = String(localized: "Unable to Fetch Models")
                updateSearchResults(for: search)
            }
        }
    }

    deinit { loader?.cancel() }

    /// The spinner stands where the fetch button was, in the same place in
    /// the bar, so the page says it is working and nothing else moves.
    private func showFetching(_ fetching: Bool) {
        guard let fetchItem, var items = navigationItem.rightBarButtonItems else { return }
        if fetching {
            fetchSpinner.startAnimating()
            let spinning = UIBarButtonItem(customView: fetchSpinner)
            items = items.map { item -> UIBarButtonItem in
                item === fetchItem ? spinning : item
            }
        } else {
            fetchSpinner.stopAnimating()
            items = items.map { item -> UIBarButtonItem in
                item.customView === fetchSpinner ? fetchItem : item
            }
        }
        navigationItem.rightBarButtonItems = items
    }

    @objc dynamic func updateSearchResults(for searchController: UISearchController) {
        let query = (searchController.searchBar.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        shown = models.filter { query.isEmpty || $0.localizedStandardContains(query) }
        updateRows()
    }

    private func cell(in tableView: UITableView, at indexPath: IndexPath, row: ModelRow) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "model", for: indexPath)
        let model = row.id
        var content = cell.defaultContentConfiguration()
        // The catalog's name over the provider's id: the id is what the
        // conversation sends, and it stays readable under the name.
        content.text = account.displayName(for: model)
        content.textProperties.numberOfLines = 0
        if account.catalogTitle(for: model) != nil {
            content.secondaryText = model
            content.secondaryTextProperties.color = .secondaryLabel
        }
        cell.contentConfiguration = content
        cell.accessoryType = row.selected ? .checkmark : .none
        cell.accessibilityTraits = row.selected ? [.button, .selected] : [.button]
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !saving, let model = dataSource.itemIdentifier(for: indexPath) else { return }
        if !selected.insert(model).inserted {
            selected.remove(model)
        }
        updateRows()
    }

    override func tableView(
        _: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath,
    ) -> UISwipeActionsConfiguration? {
        guard usesAPIKey, !saving, let model = dataSource.itemIdentifier(for: indexPath) else { return nil }
        let delete = UIContextualAction(
            style: .destructive,
            title: String(localized: "Delete"),
        ) { [weak self] _, _, completion in
            guard let self, !saving, let row = shown.firstIndex(of: model) else { completion(false); return }
            selected.remove(model)
            custom.remove(model)
            hidden.insert(model)
            models.removeAll { $0 == model }
            shown.remove(at: row)
            completion(true)
            updateRows()
        }
        delete.image = UIImage(systemName: "trash")
        return UISwipeActionsConfiguration(actions: [delete])
    }

    @objc private dynamic func addCustomModel() {
        let alert = AlertInputViewController(
            title: "Add Custom Model",
            message: "Enter the model ID accepted by this provider.",
            placeholder: "Model ID",
            text: "",
            doneButtonText: "Add",
        ) { [weak self] value in
            guard let self else { return }
            let id = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, id.count <= 256, !id.contains(where: \.isWhitespace) else {
                presentNotice(
                    title: "Invalid Model ID",
                    message: String(localized: "Enter a model ID without spaces or line breaks."),
                )
                return
            }
            custom.insert(id)
            hidden.remove(id)
            models = Array(Set(models + [id])).sorted()
            selected.insert(id)
            updateSearchResults(for: search)
        }
        present(alert, animated: true)
    }

    @objc private dynamic func save() {
        guard !saving else { return }
        // Only Copilot OAuth needs a provider-side policy opt-in. An API key's
        // model selection is local, even if its catalog is currently offline.
        guard !usesAPIKey, account.provider == .githubCopilot, !selected.isEmpty
        else { finishSaving(); return }
        saving = true
        navigationController?.isModalInPresentation = true
        navigationItem.leftBarButtonItem?.isEnabled = false
        navigationItem.rightBarButtonItems?.forEach { $0.isEnabled = false }
        Task { [weak self] in
            guard let self else { return }
            defer {
                saving = false
                verification = nil
                navigationController?.isModalInPresentation = false
                navigationItem.leftBarButtonItem?.isEnabled = true
                navigationItem.rightBarButtonItems?.forEach { $0.isEnabled = true }
            }
            do {
                try await ProviderProgress.run(
                    title: "Enabling Models",
                    from: self,
                    cancel: { [weak self] in
                        if let handle = self?.verification {
                            try? await LurosService.app.agentSignInCancel(taskID: handle.taskID)
                        }
                    },
                ) {
                    let handle = try await LurosService.app.agentModelActivate(
                        provider: self.account.provider,
                        models: self.selected.sorted(),
                    )
                    self.verification = handle
                    if Task.isCancelled {
                        try? await LurosService.app.agentSignInCancel(taskID: handle.taskID)
                        throw CancellationError()
                    }
                    for try await event in LurosService.app.events(of: handle) {
                        guard event.kind == TaskEvent.stateKind,
                              let state = event.payload?["state"]?.stringValue.flatMap(TaskState.init(rawValue:)),
                              state.isTerminal
                        else { continue }
                        if state == .cancelled {
                            throw CancellationError()
                        }
                        guard state == .succeeded else {
                            throw LurosError(
                                .unavailable,
                                event.payload?["message"]?.stringValue
                                    ?? String(localized: "Model verification failed."),
                            )
                        }
                        return
                    }
                    throw LurosError(.unavailable, String(localized: "Model verification did not finish."))
                }
                finishSaving()
            } catch {
                if !(error is CancellationError) {
                    presentNotice(title: "Unable to Save", message: error.readableMessage)
                }
            }
        }
    }

    @objc private dynamic func finishSaving() {
        EnabledModels.save(selected, custom: custom, hidden: hidden, for: account.provider)
        dismiss(animated: true)
    }
}
