#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# -----------------------------------------------------------------------------
# Ansible bootstrap (pip + venv) + install collections/roles from requirements.yml
#
# - Creates a local virtualenv (no system-wide pip installs)
# - Auto-installs python venv support on Debian/Ubuntu if missing
# - Repairs/removes broken virtualenvs automatically
# - Works when executed from anywhere inside the repo
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

run_root() {
  # Run a command as root (directly if already root, else via sudo if available)
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    "$@"
  else
    have_cmd sudo || die "Necesitas privilegios de root y no existe 'sudo'. Ejecuta como root o instala sudo."
    sudo "$@"
  fi
}

python_bin() {
  if have_cmd python3; then
    echo "python3"
  elif have_cmd python; then
    echo "python"
  else
    die "Python no encontrado (python3/python). Instala Python 3."
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

is_debian_like() {
  [[ -r /etc/os-release ]] || return 1
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == "debian" || "${ID:-}" == "ubuntu" || "${ID_LIKE:-}" == *"debian"* ]]
}

python_major_minor() {
  local py="$1"
  "$py" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")'
}

install_venv_support_debian() {
  local py="$1"
  local mm pkg

  mm="$(python_major_minor "$py")"

  # Prefer versioned venv package if it exists; fallback to python3-venv.
  # On Ubuntu 22.04 + Python 3.10: python3.10-venv
  pkg="python${mm}-venv"

  log "[*] Instalando soporte venv para Python ${mm} (Debian/Ubuntu)..."
  run_root apt-get update -y

  if run_root apt-get install -y "$pkg"; then
    return 0
  fi

  log "[*] No se pudo instalar '$pkg'. Probando con 'python3-venv'..."
  run_root apt-get install -y python3-venv
}

ensure_venv_support() {
  local py="$1"

  # Check if venv module exists
  if "$py" -c 'import venv' >/dev/null 2>&1; then
    return 0
  fi

  err "Falta soporte de venv (modulo 'venv' no disponible)."

  if is_debian_like && have_cmd apt-get; then
    install_venv_support_debian "$py"
  else
    err "No puedo auto-instalar dependencias en este sistema."
    err "Instala el soporte de venv para tu Python y reintenta."
    die "No se puede crear el virtualenv."
  fi

  # Re-check after install
  if ! "$py" -c 'import venv' >/dev/null 2>&1; then
    die "He intentado instalar venv pero sigue sin estar disponible. Revisa paquetes de Python/venv."
  fi
}

venv_is_valid() {
  local vdir="$1"
  [[ -x "$vdir/bin/python" ]] && [[ -f "$vdir/bin/activate" ]] && [[ -x "$vdir/bin/pip" ]]
}

recreate_venv_if_needed() {
  local py="$1"
  local vdir="$2"

  if [[ -d "$vdir" ]] && ! venv_is_valid "$vdir"; then
    log "[*] Detectado virtualenv roto/incompleto: $vdir"
    log "[*] Eliminando y recreando..."
    rm -rf "$vdir"
  fi

  if [[ ! -d "$vdir" ]]; then
    log "[*] Creando virtualenv en $vdir..."
    "$py" -m venv "$vdir"
  fi

  # Validate again
  venv_is_valid "$vdir" || die "Virtualenv no válido tras crearlo: $vdir"
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

  ensure_venv_support "$py"
  recreate_venv_if_needed "$py" "$ANSIBLE_VENV_DIR"

  # shellcheck disable=SC1091
  source "$ANSIBLE_VENV_DIR/bin/activate"

  venv_python="$ANSIBLE_VENV_DIR/bin/python"
  [[ -x "$venv_python" ]] || die "Python del venv no encontrado: $venv_python"

  log "[*] Upgrading pip tooling..."
  "$venv_python" -m pip install --upgrade pip setuptools wheel

  log "[*] Installing Ansible via pip (${ANSIBLE_PIP_PKG})..."
  case "$ANSIBLE_PIP_PKG" in
    ansible)
      "$venv_python" -m pip install --upgrade "$(pkg_spec ansible "$ANSIBLE_VERSION")"
      ;;
    ansible-core)
      "$venv_python" -m pip install --upgrade "$(pkg_spec ansible-core "$ANSIBLE_CORE_VER")"
      ;;
    *)
      die "ANSIBLE_PIP_PKG debe ser 'ansible' o 'ansible-core' (actual: $ANSIBLE_PIP_PKG)"
      ;;
  esac

  have_cmd ansible || die "ansible no está en PATH tras la instalación (¿venv activado?)."
  have_cmd ansible-galaxy || die "ansible-galaxy no está en PATH tras la instalación (¿venv activado?)."

  log "[*] Installed Ansible:"
  "$ANSIBLE_VENV_DIR/bin/ansible" --version

  [[ -f "$req_file" ]] || die "Requirements file no encontrado: $root/$req_file"

  mkdir -p "$col_dir"

  log "[*] Installing collections from '$req_file' into '$col_dir'..."
  "$ANSIBLE_VENV_DIR/bin/ansible-galaxy" collection install -r "$req_file" -p "$col_dir" -f

  log "[*] Installing roles (if defined in '$req_file') into '$col_dir/roles'..."
  mkdir -p "$col_dir/roles"
  "$ANSIBLE_VENV_DIR/bin/ansible-galaxy" role install -r "$req_file" -p "$col_dir/roles" -f || true

  log "[*] Installing Reporting dependencies (pandas, fpdf2)..."
  "$venv_python" -m pip install --upgrade pandas fpdf2

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
