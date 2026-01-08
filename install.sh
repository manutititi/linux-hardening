#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# -----------------------------------------------------------------------------
# Ansible bootstrap (pip + venv) + install collections/roles from requirements.yml
#
# Good practices:
# - Uses a virtualenv (no system-wide pip installs)
# - Fails fast with clear errors
# - Works when executed from anywhere inside the repo (uses git root when possible)
# - Installs Ansible via pip (ansible or ansible-core)
# - Installs collections into a project-local collections directory
# - Installs roles from requirements.yml if present (optional)
#
# Usage:
#   ./install.sh
#
# Optional env vars:
#   ANSIBLE_VENV_DIR    (default: .venv-ansible)
#   ANSIBLE_PIP_PKG     (default: ansible)          # ansible | ansible-core
#   ANSIBLE_VERSION     (default: "")               # e.g. 10.7.0 (only if ansible)
#   ANSIBLE_CORE_VER    (default: "")               # e.g. 2.16.12 (only if ansible-core)
#   REQUIREMENTS_FILE   (default: requirements.yml)
#   COLLECTIONS_DIR     (default: ./collections)
#
# Notes:
# - On Debian/Ubuntu you must have python venv support installed:
#     sudo apt update && sudo apt install -y python3-venv
#   (or python3.10-venv for Python 3.10)
# -----------------------------------------------------------------------------

ANSIBLE_VENV_DIR="${ANSIBLE_VENV_DIR:-.venv-ansible}"
ANSIBLE_PIP_PKG="${ANSIBLE_PIP_PKG:-ansible}"      # ansible | ansible-core
ANSIBLE_VERSION="${ANSIBLE_VERSION:-}"             # only if ANSIBLE_PIP_PKG=ansible
ANSIBLE_CORE_VER="${ANSIBLE_CORE_VER:-}"           # only if ANSIBLE_PIP_PKG=ansible-core
REQUIREMENTS_FILE="${REQUIREMENTS_FILE:-requirements.yml}"
COLLECTIONS_DIR="${COLLECTIONS_DIR:-./collections}"

log() { printf '%s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; }
die() { err "$*"; exit 1; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

python_bin() {
  if have_cmd python3; then
    echo "python3"
  elif have_cmd python; then
    echo "python"
  else
    die "Python not found (python3/python). Install Python 3 first."
  fi
}

repo_root() {
  if have_cmd git && git rev-parse --show-toplevel >/dev/null 2>&1; then
    git rev-parse --show-toplevel
  else
    pwd
  fi
}

pkg_spec() {
  local pkg="$1"
  local ver="$2"
  if [[ -n "$ver" ]]; then
    echo "${pkg}==${ver}"
  else
    echo "${pkg}"
  fi
}

require_venv_support() {
  local py="$1"

  # Quick check: can we import venv?
  if ! "$py" -c 'import venv' >/dev/null 2>&1; then
    err "Python venv support is missing (module 'venv' not available)."
    err ""
    err "On Debian/Ubuntu, install it with:"
    err "  sudo apt update"
    err "  sudo apt install -y python3-venv"
    err ""
    err "If you are using Python 3.10 specifically, you may need:"
    err "  sudo apt install -y python3.10-venv"
    err ""
    die "Cannot create virtual environment."
  fi

  # Also ensure ensurepip works inside venv creation
  if ! "$py" -m venv --help >/dev/null 2>&1; then
    die "Your Python cannot run 'python -m venv'. Install venv support for your Python."
  fi
}

main() {
  local py root req_file col_dir venv_python

  py="$(python_bin)"
  root="$(repo_root)"

  cd "$root"

  req_file="$REQUIREMENTS_FILE"
  col_dir="$COLLECTIONS_DIR"

  log "[*] Repo root: $root"
  log "[*] Python: $("$py" --version 2>&1)"
  log "[*] Virtualenv dir: $ANSIBLE_VENV_DIR"

  require_venv_support "$py"

  # Create venv (fresh venv is safest if previous attempt left partial dir)
  if [[ -d "$ANSIBLE_VENV_DIR" && ! -x "$ANSIBLE_VENV_DIR/bin/python" ]]; then
    log "[*] Removing broken virtualenv: $ANSIBLE_VENV_DIR"
    rm -rf "$ANSIBLE_VENV_DIR"
  fi

  if [[ ! -d "$ANSIBLE_VENV_DIR" ]]; then
    log "[*] Creating virtualenv..."
    "$py" -m venv "$ANSIBLE_VENV_DIR"
  fi

  # shellcheck disable=SC1091
  source "$ANSIBLE_VENV_DIR/bin/activate"

  venv_python="$ANSIBLE_VENV_DIR/bin/python"
  [[ -x "$venv_python" ]] || die "Virtualenv python not found at $venv_python"

  log "[*] Upgrading pip tooling..."
  python -m pip install --upgrade pip setuptools wheel

  log "[*] Installing Ansible via pip (${ANSIBLE_PIP_PKG})..."
  case "$ANSIBLE_PIP_PKG" in
    ansible)
      python -m pip install --upgrade "$(pkg_spec ansible "$ANSIBLE_VERSION")"
      ;;
    ansible-core)
      python -m pip install --upgrade "$(pkg_spec ansible-core "$ANSIBLE_CORE_VER")"
      ;;
    *)
      die "ANSIBLE_PIP_PKG must be 'ansible' or 'ansible-core' (current: $ANSIBLE_PIP_PKG)"
      ;;
  esac

  have_cmd ansible || die "ansible not found after installation."
  have_cmd ansible-galaxy || die "ansible-galaxy not found after installation."

  log "[*] Installed Ansible:"
  ansible --version

  [[ -f "$req_file" ]] || die "Requirements file not found: $root/$req_file"

  mkdir -p "$col_dir"

  log "[*] Installing collections from '$req_file' into '$col_dir'..."
  ansible-galaxy collection install -r "$req_file" -p "$col_dir" -f

  # Optional: install roles if requirements.yml defines roles:
  log "[*] Installing roles (if defined in '$req_file') into '$col_dir/roles'..."
  mkdir -p "$col_dir/roles"
  ansible-galaxy role install -r "$req_file" -p "$col_dir/roles" -f || true

  cat <<EOF

OK.

Next steps:
  source $root/$ANSIBLE_VENV_DIR/bin/activate

Recommended ansible.cfg settings (project local):
  [defaults]
  inventory = ./inventories/lab/inventory.yml
  roles_path = ./roles
  collections_paths = ./collections:~/.ansible/collections:/usr/share/ansible/collections

Verify:
  ansible --version
  ansible-galaxy collection list | head

EOF
}

main "$@"

