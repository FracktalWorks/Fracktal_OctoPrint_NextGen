#!/usr/bin/env bash
# Install / upgrade / roll back the Fracktal Works OctoPrint fork (1.11.x line) on a printer.
#
#   bash install-octoprint.sh                       # DRY RUN: detect + print the plan, change nothing
#   bash install-octoprint.sh --yes                 # install latest release (replaces an old OctoPrint)
#   bash install-octoprint.sh --yes --version 1.11.8.post1
#   bash install-octoprint.sh --yes --source ./dist/OctoPrint-1.11.8.post1-py3-none-any.whl
#   bash install-octoprint.sh --rollback --yes      # put the previous venv + config back
#
# Run as the printer user (normally `pi`), NOT as root; it uses sudo for systemd only.
# Idempotent. Never overwrites an existing ~/.octoprint/config.yaml. The previous venv is
# kept as <venv>.old-<timestamp> until you pass --purge-old.
#
# Works on the read-only-root base image (it flips `fw-rw on` for the /etc change and
# reverts), and on older Debian 10-12 printers.
set -euo pipefail

OP_REPO="FracktalWorks/Fracktal_OctoPrint_NextGen"
CC_REPO="FracktalWorks/ControlCenter"
USER_NAME="$(id -un)"
HOME_DIR="$HOME"
VENV="${HOME_DIR}/OctoPrint/venv"
BASEDIR="${HOME_DIR}/.octoprint"
VERSION=""          # empty = latest GitHub release of $OP_REPO
SOURCE=""           # URL / wheel / sdist / source dir; overrides --version
CC_SOURCE=""        # empty = latest release of $CC_REPO; "skip" = do not install ControlCenter
EXTRA_PLUGINS=""    # space separated pip specs
SYSTEM_SITE=1       # ControlCenter needs apt's PyQt5 / opencv, so share system packages
DO=0; ROLLBACK=0; PURGE=0; NO_START=0
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TS="$(date +%Y%m%d-%H%M%S)"

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --yes) DO=1 ;;
    --version) VERSION="$2"; shift ;;
    --source) SOURCE="$2"; shift ;;
    --cc-source) CC_SOURCE="$2"; shift ;;
    --plugins) EXTRA_PLUGINS="$2"; shift ;;
    --venv) VENV="$2"; shift ;;
    --basedir) BASEDIR="$2"; shift ;;
    --no-system-site-packages) SYSTEM_SITE=0 ;;
    --no-start) NO_START=1 ;;
    --rollback) ROLLBACK=1 ;;
    --purge-old) PURGE=1 ;;
    -h|--help) usage 0 ;;
    *) echo "unknown option: $1" >&2; usage 2 ;;
  esac; shift
done

log()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
run()  { if [ "$DO" = 1 ]; then "$@"; else printf '   [dry-run] %s\n' "$*"; fi; }

[ "$(id -u)" -ne 0 ] || die "run as the printer user (e.g. pi), not root"
command -v python3 >/dev/null || die "python3 not found"

# ---- read-only root support (base image): remount rw for /etc changes ----------------
RW_FLIPPED=0
rw_on()  { if command -v fw-rw >/dev/null 2>&1 && ! touch /etc/.fw-rwtest 2>/dev/null; then sudo fw-rw on >/dev/null && RW_FLIPPED=1; else sudo rm -f /etc/.fw-rwtest 2>/dev/null || true; fi; }
rw_off() { [ "$RW_FLIPPED" = 1 ] && sudo fw-rw off >/dev/null || true; }
trap rw_off EXIT

github_latest() {  # $1 = owner/repo -> prints tag name of the latest published release
  curl -fsSL "https://api.github.com/repos/$1/releases/latest" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])'
}
api_key() {  # read api.key from the config with the venv's own YAML library
  "$VENV/bin/python" - "$BASEDIR/config.yaml" <<'PY' 2>/dev/null || true
import sys
from ruamel.yaml import YAML
print((YAML().load(open(sys.argv[1])) or {}).get("api", {}).get("key", ""))
PY
}
wait_api() {  # $1 = key; wait up to 90 s for /api/version
  local i out
  for i in $(seq 1 45); do
    out="$(curl -fsS -m 3 -H "X-Api-Key: $1" http://127.0.0.1:5000/api/version 2>/dev/null)" && { echo "$out"; return 0; }
    sleep 2
  done; return 1
}
venv_octoprint_version() { [ -x "$1/bin/python" ] && "$1/bin/python" -c 'import octoprint;print(octoprint.__version__)' 2>/dev/null || true; }

# ---- rollback --------------------------------------------------------------------------
if [ "$ROLLBACK" = 1 ]; then
  OLD="$(ls -d "${VENV}".old-* 2>/dev/null | sort | tail -1 || true)"
  BK="$(ls -t "${HOME_DIR}"/octoprint-backup-*.tar.gz 2>/dev/null | head -1 || true)"
  [ -n "$OLD" ] || die "no ${VENV}.old-* to roll back to"
  log "Rollback: venv ${OLD} -> ${VENV}; config backup: ${BK:-none}"
  run sudo systemctl stop octoprint
  run mv "$VENV" "${VENV}.failed-${TS}"
  run mv "$OLD" "$VENV"
  [ -z "$BK" ] || run tar -C "$HOME_DIR" -xzf "$BK"
  run sudo systemctl start octoprint
  [ "$DO" = 1 ] || log "Dry run only. Re-run with --yes."
  exit 0
fi

# ---- 1. detect ---------------------------------------------------------------------------
PYV="$(python3 -c 'import sys;print("%d.%d"%sys.version_info[:2])')"
python3 -c 'import sys; sys.exit(0 if (3,9)<=sys.version_info[:2]<(3,14) else 1)' \
  || die "system Python is $PYV; OctoPrint 1.11.x needs 3.9-3.13 (Debian 13 ships 3.13)"
python3 -c 'import venv, ensurepip' 2>/dev/null || die "python3-venv missing:  sudo apt install python3-venv python3-dev"
CUR="$(venv_octoprint_version "$VENV")"
UNIT_EXEC="$(systemctl cat octoprint 2>/dev/null | sed -n 's/^ExecStart=//p' | head -1 || true)"
log "Host:        $(. /etc/os-release; echo "$PRETTY_NAME") / python $PYV / user $USER_NAME"
log "Venv:        $VENV   (installed OctoPrint: ${CUR:-none})"
log "Unit starts: ${UNIT_EXEC:-<no octoprint.service>}"
case "$CUR" in 1.7.*) log "Detected the OLD OctoPrint 1.7.x fork: it will be replaced (old venv kept for rollback)";; esac
if [ -n "$UNIT_EXEC" ] && ! printf '%s' "$UNIT_EXEC" | grep -q "^${VENV}/bin/octoprint"; then
  warn "octoprint.service runs ${UNIT_EXEC%% *}, not ${VENV}/bin/octoprint; it will be rewritten to use ${VENV}"
fi
df -Pm "$HOME_DIR" | awk 'NR==2{ if ($4<800) {print "WARN: only " $4 " MB free in home (need ~800)"} }' >&2

# ---- 2. resolve what to install ---------------------------------------------------------
if [ -z "$SOURCE" ]; then
  if [ -z "$VERSION" ]; then VERSION="$(github_latest "$OP_REPO")" || die "cannot query latest release of $OP_REPO (no internet? pass --source/--version)"; fi
  SOURCE="https://github.com/${OP_REPO}/archive/refs/tags/${VERSION}.zip"
fi
if [ "$CC_SOURCE" = "" ]; then
  CCV="$(github_latest "$CC_REPO" 2>/dev/null || true)"
  CC_SOURCE="${CCV:+https://github.com/${CC_REPO}/archive/refs/tags/${CCV}.zip}"
  [ -n "$CC_SOURCE" ] || warn "no published ControlCenter release found; pass --cc-source <url|path> or 'skip'"
fi
log "OctoPrint:   $SOURCE"
log "ControlCenter: ${CC_SOURCE:-<none>}"
OLD_PLUGINS=""
if [ -x "$VENV/bin/pip" ]; then
  OLD_PLUGINS="$("$VENV/bin/pip" freeze 2>/dev/null | grep -i '^octoprint[-_]' | grep -vi '^octoprint==' || true)"
  [ -z "$OLD_PLUGINS" ] || { log "Plugins in the OLD venv (NOT migrated automatically):"; printf '   %s\n' $OLD_PLUGINS; }
fi

if [ "$DO" != 1 ]; then
  log "Dry run: steps that would run: backup ${BASEDIR} -> ~/octoprint-backup-${TS}.tar.gz; move ${VENV} -> ${VENV}.old-${TS};"
  log "         create venv (system-site-packages=${SYSTEM_SITE}); pip install OctoPrint + ControlCenter${EXTRA_PLUGINS:+ + $EXTRA_PLUGINS};"
  log "         seed config.yaml if absent (unique api key + secretKey); install octoprint.service; start; verify /api/version."
  log "Re-run with --yes to apply."; exit 0
fi

# ---- 3. back up, swap venv ----------------------------------------------------------------
if [ -d "$BASEDIR" ]; then
  log "Backing up $BASEDIR (without uploads/timelapse/logs)"
  tar -C "$(dirname "$BASEDIR")" --exclude="$(basename "$BASEDIR")/uploads" --exclude="$(basename "$BASEDIR")/timelapse" \
      --exclude="$(basename "$BASEDIR")/logs" --exclude="$(basename "$BASEDIR")/generated" \
      -czf "${HOME_DIR}/octoprint-backup-${TS}.tar.gz" "$(basename "$BASEDIR")"
fi
sudo systemctl stop octoprint 2>/dev/null || true
if [ -d "$VENV" ]; then mv "$VENV" "${VENV}.old-${TS}"; fi
mkdir -p "$(dirname "$VENV")"
log "Creating venv (system-site-packages=${SYSTEM_SITE})"
if [ "$SYSTEM_SITE" = 1 ]; then python3 -m venv --system-site-packages "$VENV"; else python3 -m venv "$VENV"; fi
"$VENV/bin/pip" install -q --upgrade pip wheel

# ---- 4. install ----------------------------------------------------------------------------
log "Installing OctoPrint"
"$VENV/bin/pip" install -q "$SOURCE" || { warn "install failed; restoring previous venv"; rm -rf "$VENV"; [ -d "${VENV}.old-${TS}" ] && mv "${VENV}.old-${TS}" "$VENV"; sudo systemctl start octoprint || true; die "OctoPrint install failed"; }
NEW="$(venv_octoprint_version "$VENV")"; log "Installed OctoPrint ${NEW}"
if [ "$CC_SOURCE" != "skip" ] && [ -n "$CC_SOURCE" ]; then
  log "Installing ControlCenter plugin"; "$VENV/bin/pip" install -q "$CC_SOURCE"
fi
# shellcheck disable=SC2086
[ -z "$EXTRA_PLUGINS" ] || "$VENV/bin/pip" install -q $EXTRA_PLUGINS

# ---- 5. config: seed only if absent -----------------------------------------------------------
mkdir -p "$BASEDIR"
TEMPLATE="$HERE/config/config.yaml"
if [ ! -f "$BASEDIR/config.yaml" ]; then
  [ -f "$TEMPLATE" ] || die "no config template at $TEMPLATE (run this script from the release checkout/zip)"
  log "Seeding $BASEDIR/config.yaml with a unique API key and secretKey"
  "$VENV/bin/python" - "$TEMPLATE" "$BASEDIR/config.yaml" <<'PY'
import secrets, sys
from ruamel.yaml import YAML
y = YAML(); y.preserve_quotes = True
d = y.load(open(sys.argv[1]))
d.setdefault("api", {})["key"] = secrets.token_hex(16).upper()
d.setdefault("server", {})["secretKey"] = secrets.token_urlsafe(24)
y.dump(d, open(sys.argv[2], "w"))
PY
  chmod 600 "$BASEDIR/config.yaml"
else
  log "Keeping existing $BASEDIR/config.yaml (api key and settings unchanged)"
fi
if [ ! -f "$BASEDIR/users.yaml" ]; then
  log "No users.yaml: creating the 'admin' user (random password, auto-login covers the UI)"
  "$VENV/bin/octoprint" --basedir "$BASEDIR" user add admin --password "$(python3 -c 'import secrets;print(secrets.token_urlsafe(12))')" --admin >/dev/null 2>&1 || warn "could not create admin user"
fi

# ---- 6. service ---------------------------------------------------------------------------------
rw_on
sed -e "s#^User=.*#User=${USER_NAME}#" -e "s#^ExecStart=.*#ExecStart=${VENV}/bin/octoprint serve --basedir ${BASEDIR}#" \
    "$HERE/systemd/octoprint.service" | sudo tee /etc/systemd/system/octoprint.service >/dev/null
sudo systemctl daemon-reload
sudo systemctl enable octoprint >/dev/null 2>&1
rw_off; RW_FLIPPED=0

# ---- 7. start + verify --------------------------------------------------------------------------
if [ "$NO_START" = 1 ]; then log "Not starting (--no-start)."; exit 0; fi
sudo systemctl restart octoprint
KEY="$(api_key)"
if [ -z "$KEY" ]; then warn "could not read the API key from config.yaml; skipping API check"; exit 0; fi
if OUT="$(wait_api "$KEY")"; then
  log "OctoPrint is up: $OUT"
else
  warn "OctoPrint did not answer on :5000 within 90 s -> journalctl -u octoprint -n 50; rollback: bash $0 --rollback --yes"
  exit 1
fi
[ "$PURGE" = 0 ] || { log "Purging old venvs"; rm -rf "${VENV}".old-*; }
log "Done. Previous venv kept at ${VENV}.old-${TS}. Roll back with: bash $0 --rollback --yes"
