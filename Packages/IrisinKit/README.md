# IrisinKit (vendored)

Irisin's installer, taken from [`Lakr233/Irisin`](https://github.com/Lakr233/Irisin)
at tag `v5.1.8` (`39242846e35fb60740a6fb3a3940dd24bb9769c3`, the head of
`main-4.0` when this copy was made), MIT, © OwnGoal Studio — `LICENSE` beside
this file is Irisin's own and travels with every copy.

Luros used to ship Irisin's prebuilt `irisind` and `irisin-install` and talk to
the first over `wiki.qaq.irisin.service`. Two launchd jobs cannot own one Mach
service name: a device that also had another program's irisind job made Luros's
never start, and a request sent to the name waited forever. Luros now compiles
the installer from source into `lurosd` and spawns itself in installer mode, so
no daemon, no service name and no shipped binary of Irisin's remain.

## Taken

| Path | What it is |
|---|---|
| `Sources/IrisinProtocol` | `InstallerJob`, `InstallerEvent`, the install root and bootstrap layout, versions and relations, the spawn wrappers |
| `Sources/IrisinPreparation` | a `.deb` into the prepared tree (`ArchiveKit`, the same libarchive `LurosKit` links) |
| `Sources/IrisinInstaller` | the root transaction: dpkg's database and payload, maintainer scripts, triggers, application registration, respring |
| `Sources/CIrisinSpawn` | `posix_spawn` declared without the SDK's availability attributes |
| `Sources/CIrisinDB` | `db(3)`, which the Darwin module leaves out |
| `Tests/IrisinProtocolTests`, `Tests/IrisinInstallerTests` | Irisin's own tests for the two |

## Left behind

- `IrisinDaemon` — the Mach service, its peer authentication and the helper
  launch. Luros's session host is the only caller now, and it is already root.
- `IrisinProtocol/Wire/{IrisinXPC,XPCCoding,ExecutableAdmission}.swift` and
  `Sources/CIrisinXPC` — the daemon's side of the wire. Nothing in this copy
  imports XPC; `ExecutableAdmissionTests` went with it.
- `IrisinClient`, `IrisinVendor`, the app, the CLI, the Launchpad, the WebUI
  and `Packages/{AptRepository,IrisinWeb,MarkdownView,PackageDepiction,Runestone}`.
- The `IcliKit` dependency (icli's library). Its two uses are replaced:
  Luros supplies the application registrar (uicache, the same tool
  `ApplicationInstall` runs) and a respring of its own, and it never sends
  Irisin's own launchd maintenance jobs.

## Patches against upstream

Re-apply these when updating; each is small and says why.

1. `Sources/IrisinInstaller/ApplicationRegistrar.swift` — the IcliKit import,
   the `IcliError` branch and the IcliKit `live` implementation are removed.
   Without an injected `perform`, `live` refuses; `lurosd` always injects its
   own.
2. `Sources/IrisinInstaller/LaunchDaemon.swift` — likewise. Luros never sends
   `.bootstrapIrisinDaemon`/`.bootoutIrisinDaemon`, so the fallback refuses.
3. `Sources/IrisinProtocol/Wire/IrisinWire.swift` — `transactionsPath` is
   `/var/lib/luros/install-transactions` and `installerLogPath` is
   `/var/log/luros-install.log`: these records are Luros's alone. The wire
   members kept beside them (`serviceName`, the operation list, the reply
   codes) are quiet in this copy and are kept for provenance.

`#if targetEnvironment(simulator)` blocks stay as upstream wrote them: they are
Irisin's Mac-test hooks, not a build variant of the installer, and the tests
below need them.

## Invariants

- No `import IcliKit`, no XPC, no UIKit in this package.
- The installer runs as root and only from `lurosd`'s hand-built job: it is
  spawned with an empty environment, the job on standard input, the package on
  descriptor 3 and its transcript on standard output, in a session of its own.
- `IrisinWire.transactionsPath` and `installerLogPath` are Luros's; Irisin's
  own paths are never read or written.
- libarchive is pinned to `1.0.0`, the revision `Licenses/review.json`
  records. Raising it changes the binary artifact, and `collect-licenses`
  refuses a pin nobody reviewed: update that review, and the rows in
  `Licenses/Compatibility.md`, in the same change.
- A Swift 6 compiler is needed: `IrisinProtocol/Process/ProcessSpawn.swift`
  uses typed throws (`throws(Failure)`). Every other file here parses with
  Swift 5.10, which is what an on-device check can reach.

## Updating

    git archive --format=tar v<new> | tar -x -C /tmp/irisin
    # copy Sources/{IrisinProtocol,IrisinPreparation,IrisinInstaller,CIrisinSpawn,CIrisinDB}
    # and Tests/{IrisinProtocolTests,IrisinInstallerTests}, then re-apply the
    # patches above, delete ExecutableAdmission's test, and run:
    swift test

The suite is Irisin's own and passes on a Mac without a device.
