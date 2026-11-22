# Bundled tools

Luros carries the one device tool it cannot work without, so its package
depends on no package for it:

| File | From | Version | SHA-256 |
|---|---|---|---|
| `bin/icli` | `com.icli.icli` | 0.11.0 | `728f350e54a0101793506e4771342dc68cde2ee5e4f6cb9579b5293d20b87cfb` |

`Scripts/package-deb.sh` copies it into `Luros.app/Vendor/`, so the installed
app finds it beside itself:

- `Luros.app/Vendor/bin` goes on the `PATH` every run gets
  (`DevelopmentEnvironment.searchPath`), behind the bootstrap's own
  directories, so an `icli` the device installed still wins.

## The installer is not here any more

Irisin's `irisind` and `irisin-install` used to be carried as binaries and
talked to over `wiki.qaq.irisin.service`. Two launchd jobs cannot own one Mach
service name, so a device that also had another program's irisind job made
Luros's never start, and a request sent to the name waited for an answer that
never came.

The installer is now source: `Packages/IrisinKit` (Irisin `v5.1.8`, MIT, pinned
in its README) is compiled into `lurosd`'s installer mode. The session host
spawns `lurosd --installer` for one job, hands it the package by descriptor
and reads its transcript; there is no daemon to register, no name to look up,
and nothing of Irisin's on disk to replace or remove.

## Updating

icli: replace the file, then update the version and digest in this table. Take
the binary from a device that has the package installed:

    cp /usr/bin/icli Vendor/bin/icli
    chmod 0755 Vendor/bin/icli
    shasum -a 256 Vendor/bin/icli

The copy is committed rather than fetched at build time because the package is
built on macOS, where the package is not installed, and a build that reached
GitHub for it would fail offline. The installer is updated in
`Packages/IrisinKit` instead, by the steps in its README.

## Licensing

`icli` is MIT, © OwnGoal Studio, and its licence ships beside it in the
package at `/usr/share/doc/icli/LICENSE`.

The installer is Irisin's, MIT, © OwnGoal Studio; its upstream `LICENSE`
ships in `Packages/IrisinKit`, and the package's `Licenses.json` lists it with
the rest.
