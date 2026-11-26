import LurosProtocol
import UIKit

/// The approval mode, and below it the screen switches: Ask Before Using the
/// Screen, which holds in every mode, and — shown while that one is off —
/// Let the Agent Unlock the Device, which needs this device's passcode saved and
/// tested first (owner, 2026-11-27; the Device Passcode page it pushes was
/// its own row before).
final class PermissionModeController: TableController {
    private let modes: [ApprovalMode] = [.confirm, .relaxed, .full]

    private enum Section: Hashable {
        case modes
        case screen
        case unlock
    }

    private enum RowID: Hashable {
        case mode(ApprovalMode)
        case asksBeforeScreen
        case allowsUnlock
        case passcode
    }

    private struct Row: Equatable {
        let id: RowID
        var selected = false
        var enabled = true
    }

    private lazy var dataSource = TableDataSource<Section, RowID, Row>(
        tableView: tableView,
        identifier: { $0.id },
    ) { [weak self] table, _, row in
        self?.cell(in: table, row: row)
    }

    /// What luros-diagnostics last answered about the device's passcode; nil
    /// until it has. Read when the page appears, and before the unlock switch
    /// is turned on for the first time.
    private var passcodeState: DevicePasscodeState?
    /// Asking luros-diagnostics whether a passcode is saved, so the switch
    /// stays where the reader left it until the answer is in.
    private var isResolvingUnlock = false

    @objc private dynamic func updateRows() {
        let screenFooter = self.screenFooter
        let unlockFooter = self.unlockFooter
        dataSource.footerTitle = { section in
            switch section {
            case .modes: AgentPermissions.explanation
            case .screen: screenFooter
            case .unlock: unlockFooter
            }
        }
        // Ask Before Using the Screen is a group of its own, and the unlock
        // switch another, so each reads with its own explanation under it
        // rather than two paragraphs crowding one group.
        var sections: [(Section, [Row])] = [
            (.modes, modes.map { Row(id: .mode($0), selected: $0 == AgentPermissions.mode) }),
            (.screen, [Row(id: .asksBeforeScreen, selected: AgentPermissions.asksBeforeScreen)]),
        ]
        if !AgentPermissions.asksBeforeScreen {
            sections.append((.unlock, unlockRows()))
        }
        dataSource.update(sections, reconfigure: true)
    }

    /// The unlock group: the switch, and the page that holds the passcode
    /// once one is saved and tested.
    private func unlockRows() -> [Row] {
        var rows = [Row(id: .allowsUnlock, selected: AgentPermissions.allowsUnlock, enabled: !isResolvingUnlock)]
        if AgentPermissions.allowsUnlock, passcodeState?.saved == true {
            rows.append(Row(id: .passcode))
        }
        return rows
    }

    private var screenFooter: String {
        String(localized: "While this is on, the agent asks you before it opens an app or a link, reads what is on the screen or acts on it, through Luros’s screen tools or icli, in every permission mode. Before a screenshot it always asks in the conversation. Each chat follows a change when you send its next message.")
    }

    private var unlockFooter: String {
        String(localized: "While this is on, the agent can press unlock on the Lock Screen by itself, using the passcode you save and test here, so work that needs the screen can carry on while the device is locked. A device with no passcode needs none, and the passcode stays in this device’s keychain: the agent never sees it. Each chat follows a change when you send its next message.")
    }

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init()")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Permission Mode")
        updateRows()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadPasscodeState()
    }

    // MARK: - The passcode the unlock switch needs

    /// Whether a passcode is saved, so the unlock switch knows what turning it
    /// on costs: no passcode on this device, one already tested, or one to
    /// save. Read when the page appears and again after the page that saves
    /// one comes back.
    private func reloadPasscodeState() {
        Task { [weak self] in
            let answer = try? await LurosService.app.devicePasscodeState()
            guard let self else { return }
            passcodeState = answer
            updateRows()
        }
    }

    /// Turns the switch on when the device needs no passcode or one is
    /// already saved and tested; otherwise sends the reader to the page that
    /// tests one, which turns it on when that passed.
    private func usePasscode(_ state: DevicePasscodeState) {
        if state.saved || state.device == .noPasscode {
            AgentPermissions.allowsUnlock = true
            updateRows()
        } else {
            presentPasscodePage()
        }
    }

    private func resolvePasscode() {
        isResolvingUnlock = true
        updateRows()
        Task { [weak self] in
            let answer = try? await LurosService.app.devicePasscodeState()
            guard let self else { return }
            isResolvingUnlock = false
            passcodeState = answer
            if let answer {
                usePasscode(answer)
            } else {
                updateRows()
            }
        }
    }

    /// Settings ▸ Permission Mode ▸ Device Passcode: the passcode itself,
    /// tested and saved before the unlock switch may rest on it, and removed
    /// from the same page.
    private func presentPasscodePage() {
        let page = DevicePasscodeController()
        page.onSaved = { [weak self] in
            AgentPermissions.allowsUnlock = true
            self?.reloadPasscodeState()
        }
        navigationController?.pushViewController(page, animated: true)
    }

    // MARK: - Table

    private func cell(in tableView: UITableView, row: Row) -> UITableViewCell {
        switch row.id {
        case let .mode(mode):
            let cell = tableView.dequeueReusableCell(withIdentifier: "mode")
                ?? UITableViewCell(style: .default, reuseIdentifier: "mode")
            var content = cell.defaultContentConfiguration()
            content.text = AgentPermissions.title(for: mode)
            cell.contentConfiguration = content
            let selected = row.selected
            cell.accessoryType = selected ? .checkmark : .none
            cell.accessibilityTraits = selected ? [.button, .selected] : [.button]
            return cell
        case .asksBeforeScreen, .allowsUnlock:
            // The switch says on or off itself; the row's text names it.
            let identifier = row.id == .asksBeforeScreen ? "screen" : "unlock"
            let cell = tableView.dequeueReusableCell(withIdentifier: identifier)
                ?? UITableViewCell(style: .default, reuseIdentifier: identifier)
            var content = cell.defaultContentConfiguration()
            content.text = row.id == .asksBeforeScreen
                ? String(localized: "Ask Before Using the Screen")
                : String(localized: "Let the Agent Unlock the Device")
            cell.contentConfiguration = content
            cell.selectionStyle = .none
            let toggle = (cell.accessoryView as? UISwitch) ?? UISwitch()
            toggle.isOn = row.selected
            toggle.isEnabled = row.enabled
            toggle.removeTarget(nil, action: nil, for: .valueChanged)
            toggle.addTarget(
                self,
                action: row.id == .asksBeforeScreen
                    ? #selector(asksBeforeScreenChanged(_:))
                    : #selector(allowsUnlockChanged(_:)),
                for: .valueChanged,
            )
            cell.accessoryView = toggle
            return cell
        case .passcode:
            let cell = tableView.dequeueReusableCell(withIdentifier: "passcode")
                ?? UITableViewCell(style: .value1, reuseIdentifier: "passcode")
            var content = UIListContentConfiguration.valueCell()
            content.text = String(localized: "Device Passcode")
            content.secondaryText = String(localized: "Saved")
            cell.contentConfiguration = content
            cell.accessoryType = .disclosureIndicator
            return cell
        }
    }

    override func tableView(_: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        switch dataSource.value(at: indexPath)?.id {
        case .mode, .passcode: return true
        default: return false
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch dataSource.value(at: indexPath)?.id {
        case .passcode:
            presentPasscodePage()
        case let .mode(mode):
            select(mode)
        default:
            break
        }
    }

    // MARK: - Changes

    @objc private dynamic func asksBeforeScreenChanged(_ toggle: UISwitch) {
        AgentPermissions.asksBeforeScreen = toggle.isOn
        updateRows()
    }

    @objc private dynamic func allowsUnlockChanged(_ toggle: UISwitch) {
        guard toggle.isOn else {
            AgentPermissions.allowsUnlock = false
            updateRows()
            return
        }
        if let passcodeState {
            usePasscode(passcodeState)
        } else {
            // Nothing is on until the passcode question is settled: the switch
            // goes back, and the page that tests one turns it on when it can.
            toggle.isOn = false
            resolvePasscode()
        }
    }

    private func select(_ mode: ApprovalMode) {
        let current = AgentPermissions.mode
        guard mode != current else { return }
        switch mode {
        // Root without asking: confirmed in words, then by the device owner.
        // Leaving Full never asks.
        case .full:
            presentConfirmation(
                title: "Enable Full Mode?",
                message: "The agent can run commands as root without asking, with full control of this device. Each chat switches when you send its next message.",
                confirmTitle: "Enable Full Mode",
                destructive: true,
            ) { [weak self] in
                Task { @MainActor in
                    guard await DeviceOwnerCheck.confirm(
                        reason: String(localized: "Let the agent run commands as root without asking."),
                    ) else { return }
                    self?.save(mode)
                }
            }
        case .relaxed where current == .confirm:
            presentConfirmation(
                title: "Enable Relaxed Mode?",
                message: "The agent can run commands and make changes without asking, within the app’s permissions. Each chat switches when you send its next message.",
                confirmTitle: "Enable Relaxed Mode",
            ) { [weak self] in self?.save(mode) }
        default:
            save(mode)
        }
    }

    private func save(_ mode: ApprovalMode) {
        AgentPermissions.mode = mode
        updateRows()
    }
}
