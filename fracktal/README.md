# Fracktal OctoPrint NextGen (1.11.x)

OctoPrint 1.11.8 plus the changes Fracktal Works printers need. This is the OctoPrint for **new-generation printers**
(Debian 13, Python 3.13). Printers on the old OctoPrint 1.7.x keep using
[`Fracktal_OctoPrint`](https://github.com/FracktalWorks/Fracktal_OctoPrint) and are not touched by this repo.

| | Old printers | New printers (this repo) |
|---|---|---|
| OctoPrint | 1.7.x, Python 3.7 | 1.11.x, Python 3.9-3.13 |
| Updates come from | `FracktalWorks/Fracktal_OctoPrint` releases | `FracktalWorks/Fracktal_OctoPrint_NextGen` releases, branch `production` |

**Never publish a release of this fork in `Fracktal_OctoPrint`**, and never point an old printer here: Python 3.7 cannot run 1.11.

## What differs from upstream OctoPrint

Everything is in git history on branch `production` (`git log 1.11.8..production`). Summary:

- **Heated filament** (`F:` in temperature reports, `M142`/`M192`): printer-profile flag `heatedFilament`, API `GET/POST /api/printer/filament`,
  shown to clients as temperature sensor `filament`. Commands are dropped with a warning if the profile has no heated filament.
- **Secondary heaters** (`H0..Hn`, one per extruder): profile flag `hasSecondaryHeaters`, API `GET/POST /api/printer/heater/<n>`,
  `M104 H<n> S<t>` targets the heater and never a tool. Shown as sensors `H0`, `H1`, ... in the UI graph.
- **Temperature profiles** carry optional `chamber` and `filament` targets.
- **Deleting a `.gcode` also deletes its sibling `.png`** thumbnail (ControlCenter uploads one with each file).
- STL slicer mapping also accepts `png`; Fracktal branding (logo, first-run text, timelapse watermark).
- **Software update** points at this repository (see below).
- Not carried over from 1.7.x: the change that disabled the first-run access check. It was a security downgrade; instead
  `fracktal/config/config.yaml` ships with `firstRun: false`.

Tests: `tests/util/test_comm_fracktal.py` (run with the rest: `pytest tests`).

## Install / upgrade / roll back on a printer

```sh
bash fracktal/install-octoprint.sh                  # dry run: shows what it found and what it would do
bash fracktal/install-octoprint.sh --yes            # install latest release; replaces an old OctoPrint
bash fracktal/install-octoprint.sh --rollback --yes # restore previous venv + config
```

It detects the existing install (including 1.7.x), backs up `~/.octoprint`, keeps the old venv as `OctoPrint/venv.old-<time>`,
installs OctoPrint and ControlCenter into `~/OctoPrint/venv`, seeds `config.yaml` **only if absent** with a unique API key and
`secretKey` per printer, installs `octoprint.service`, and checks `/api/version`. Plugins installed in the old venv are listed but
not migrated; reinstall them with `--plugins "pkg1 pkg2"`.

## Automatic updates for printers on this fork

Printers check GitHub releases of **this repository** (`github_release`, built into the fork's `softwareupdate` defaults).

- **Stable channel** offers releases created from branch `production`.
- **Beta channel** (test printers) also offers releases created from `beta`.
- To publish an update: merge into `production`, tag with a PEP 440 version above the last (`1.11.8.post1`, `1.11.8.post2`,
  `1.11.9.post1`, ...), then **create a GitHub Release from that tag** (a tag alone is not enough).
  Check on a printer in the *Beta* channel first.
- ControlCenter updates the same way from `FracktalWorks/ControlCenter` releases.

## Configuration defaults

`fracktal/config/config.yaml` is the template: serial port `/tmp/printer` (Klipper pty), no checksums, autoconnect, tracking and
error reporting off, wizard skipped, listen on all interfaces. Access is deliberately relaxed: clients on private networks are
auto-logged-in as `admin` and cross-origin API calls are allowed, so ControlCenter and tools connect without a login.
The base-image firewall restricts printers to the LAN; do not expose one to the internet.

## Rebasing on upstream OctoPrint

`git fetch upstream --tags && git rebase <new upstream tag>` on `production`. Conflicts are most likely in `util/comm.py`
and `printer/standard.py`. Moving to OctoPrint 2.0 later: the patches are ~600 lines, port them the same way.
