#!/bin/bash

# ---------------------------------------------------------------------------
# Universal multi-version Odoo installer
#   OS     : Ubuntu / Debian family (any release with apt)
#   Odoo   : 13.0 - 20.0 (side by side, one folder / venv / port per version)
# Run as root, or as a sudo-capable user.
#
# Built to survive messy machines:
#   - waits for other apt/dpkg processes (automatic updates) instead of failing
#   - repairs a half-configured dpkg before starting and after any failure
#   - success is verified from dpkg / the real interpreter, not from exit codes
#   - every command's output goes to a log file; real errors are shown to you
#   - falls back to another PostgreSQL / Python source when the first one fails
# ---------------------------------------------------------------------------

export DEBIAN_FRONTEND=noninteractive
LOG_FILE="/tmp/odoo-install-$(date +%Y%m%d-%H%M%S).log"
: > "$LOG_FILE" 2>/dev/null && chmod 600 "$LOG_FILE" 2>/dev/null

APT_OPTS=(-y
  -o Dpkg::Options::=--force-confdef
  -o Dpkg::Options::=--force-confold
  -o DPkg::Lock::Timeout=300
  -o Acquire::Retries=3)

NODE_MAJOR=18
UV_PYTHON_DIR=/opt/uv-python
DEADSNAKES_TRIED=false
PYTHON_BIN=""
PG_PORT=""

# ----- basic helpers --------------------------------------------------------
as_root() {
  if [[ $EUID -eq 0 ]]; then "$@"; else sudo "$@"; fi
}

run_as() {   # run a command as the target Odoo user
  if [[ "$(id -un)" == "$username" ]]; then
    "$@"
  elif [[ $EUID -eq 0 ]]; then
    runuser -u "$username" -- "$@"
  else
    sudo -u "$username" "$@"
  fi
}

die() {
  echo "" >&2
  echo "ERROR: $*" >&2
  echo "Full log: $LOG_FILE" >&2
  echo "Last log lines:" >&2
  tail -n 15 "$LOG_FILE" 2>/dev/null | sed 's/^/    /' >&2
  exit 1
}

urlencode() {
  python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1" 2>/dev/null || printf '%s' "$1"
}

if [[ $EUID -ne 0 ]] && ! command -v sudo &>/dev/null; then
  echo "Please run this script as root, or install sudo."
  exit 1
fi
if ! command -v apt-get &>/dev/null; then
  echo "This installer supports Ubuntu / Debian (apt) systems only."
  exit 1
fi

# ----- OS detection (no dependency on lsb_release) --------------------------
distro_id=""; ubuntu_version=""; ubuntu_codename=""
if [[ -r /etc/os-release ]]; then
  distro_id=$(. /etc/os-release; echo "${ID:-}")
  ubuntu_version=$(. /etc/os-release; echo "${VERSION_ID:-}")
  ubuntu_codename=$(. /etc/os-release; echo "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}")
fi
[[ -n "$ubuntu_version" ]]  || ubuntu_version=$(lsb_release -rs 2>/dev/null)
[[ -n "$ubuntu_codename" ]] || ubuntu_codename=$(lsb_release -cs 2>/dev/null)

# ----- apt helpers ----------------------------------------------------------
wait_for_apt_lock() {
  command -v fuser &>/dev/null || return 0
  local waited=0
  local locks="/var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock"
  while as_root fuser $locks >/dev/null 2>&1; do
    [[ $waited -eq 0 ]] && echo "  Waiting for another package process (automatic updates?) to finish..."
    sleep 5
    waited=$((waited + 5))
    [[ $waited -ge 600 ]] && break
  done
}

repair_apt() {   # fix an interrupted dpkg / broken dependencies
  as_root env DEBIAN_FRONTEND=noninteractive dpkg --configure -a --force-confdef --force-confold >>"$LOG_FILE" 2>&1
  as_root env DEBIAN_FRONTEND=noninteractive apt-get "${APT_OPTS[@]}" -f install >>"$LOG_FILE" 2>&1
  sleep 2
}

apt_run() {   # apt-get with lock wait, logging and up to 3 attempts (repairing between attempts)
  local attempt rc=1
  for attempt in 1 2 3; do
    wait_for_apt_lock
    as_root env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get "${APT_OPTS[@]}" "$@" >>"$LOG_FILE" 2>&1
    rc=$?
    [[ $rc -eq 0 ]] && return 0
    [[ $attempt -lt 3 ]] && repair_apt
  done
  return $rc
}

pkg_installed() {   # true only if dpkg says "install ok installed"
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

pkg_available() {   # true if apt has an installable candidate (locale independent)
  local c
  c=$(LC_ALL=C apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ {print $2; exit}')
  [[ -n "$c" && "$c" != "(none)" ]]
}

apt_install() {   # success = every requested package is really installed afterwards
  local p
  apt_run install "$@"
  for p in "$@"; do
    [[ "$p" == -* ]] && continue
    pkg_installed "$p" || return 1
  done
  return 0
}

drop_broken_repos() {   # remove the extra repos WE add if they cannot be used on this release
  local out=$1 f key dropped=1
  for f in /etc/apt/sources.list.d/pgdg.list /etc/apt/sources.list.d/*deadsnakes*; do
    [[ -e "$f" ]] || continue
    case "$f" in *pgdg*) key='apt.postgresql.org' ;; *) key='deadsnakes' ;; esac
    if grep -E 'Release file|404|NO_PUBKEY|not signed|Failed to fetch|Err:' "$out" | grep -q "$key"; then
      echo "  Removing repository that is not usable on this system: $f"
      as_root rm -f "$f"
      dropped=0
    fi
  done
  return $dropped
}

apt_update() {
  local out rc
  out=$(mktemp)
  wait_for_apt_lock
  as_root env DEBIAN_FRONTEND=noninteractive apt-get "${APT_OPTS[@]}" update >"$out" 2>&1
  rc=$?
  cat "$out" >>"$LOG_FILE"
  if [[ $rc -ne 0 ]]; then
    if drop_broken_repos "$out"; then
      as_root env DEBIAN_FRONTEND=noninteractive apt-get "${APT_OPTS[@]}" update >>"$LOG_FILE" 2>&1
      rc=$?
    fi
  fi
  rm -f "$out"
  if [[ $rc -ne 0 ]]; then
    echo "  Warning: 'apt-get update' reported errors (see $LOG_FILE). Continuing with the package lists available."
  fi
  return 0
}

# install_group <required|optional> item...   (an item can be "a|b" = first available alternative)
install_group() {
  local kind=$1; shift
  local item pkg chosen alts list=() unavailable=() failed=()
  for item in "$@"; do
    chosen=""
    IFS='|' read -ra alts <<< "$item"
    for pkg in "${alts[@]}"; do
      if pkg_installed "$pkg" || pkg_available "$pkg"; then chosen=$pkg; break; fi
    done
    if [[ -z "$chosen" ]]; then unavailable+=("$item"); continue; fi
    pkg_installed "$chosen" || list+=("$chosen")
  done

  if [[ ${#list[@]} -gt 0 ]] && ! apt_install "${list[@]}"; then
    for pkg in "${list[@]}"; do
      pkg_installed "$pkg" || apt_install "$pkg" || failed+=("$pkg")
    done
  fi

  if [[ ${#unavailable[@]} -gt 0 ]]; then
    echo "Note: not available on this system (skipped): ${unavailable[*]}"
  fi
  if [[ ${#failed[@]} -gt 0 ]]; then
    echo "Warning: could not install: ${failed[*]}"
  fi
  if [[ "$kind" == "required" && ( ${#unavailable[@]} -gt 0 || ${#failed[@]} -gt 0 ) ]]; then
    die "Required system packages are missing (${unavailable[*]} ${failed[*]}). Check that the Ubuntu 'main' and 'universe' repositories are enabled and that apt works ('sudo apt-get update')."
  fi
}

# ----- Python helpers -------------------------------------------------------
python_ok() {   # interpreter exists, can make venvs (ensurepip) and has headers (Python.h)
  command -v "$1" &>/dev/null || return 1
  "$1" -c 'import os, sys, sysconfig, venv, ensurepip
inc = sysconfig.get_paths()["include"]
sys.exit(0 if os.path.exists(os.path.join(inc, "Python.h")) else 1)' >/dev/null 2>&1
}

add_deadsnakes_once() {
  [[ "$DEADSNAKES_TRIED" == true ]] && return 0
  DEADSNAKES_TRIED=true
  [[ "$distro_id" == "ubuntu" ]] || return 0
  echo "  Adding the deadsnakes PPA (extra Python versions)..."
  install_group optional software-properties-common
  as_root add-apt-repository -y ppa:deadsnakes/ppa >>"$LOG_FILE" 2>&1 || return 0
  apt_update
}

python_via_uv() {   # last-resort fallback: standalone Python from uv (works on any Linux)
  local m=$1 uvbin py
  if ! command -v uv &>/dev/null && [[ ! -x /usr/local/bin/uv ]]; then
    curl -LsSf https://astral.sh/uv/install.sh | as_root env UV_UNMANAGED_INSTALL=/usr/local/bin sh >>"$LOG_FILE" 2>&1 || return 1
  fi
  uvbin=$(command -v uv 2>/dev/null || echo /usr/local/bin/uv)
  [[ -x "$uvbin" ]] || return 1
  as_root env UV_PYTHON_INSTALL_DIR="$UV_PYTHON_DIR" "$uvbin" python install "$m" >>"$LOG_FILE" 2>&1 || return 1
  py=$(as_root env UV_PYTHON_INSTALL_DIR="$UV_PYTHON_DIR" "$uvbin" python find "$m" 2>/dev/null | tail -n 1)
  [[ -n "$py" && -x "$py" ]] || return 1
  as_root chmod -R a+rX "$UV_PYTHON_DIR" 2>/dev/null
  python_ok "$py" || return 1
  PYTHON_BIN=$py
  return 0
}

setup_python() {   # $1 = comma separated X.Y candidates; sets PYTHON_BIN
  local m pkg
  PYTHON_BIN=""
  for m in ${1//,/ }; do
    pkg="python$m"
    if ! python_ok "$pkg"; then
      pkg_available "$pkg" || add_deadsnakes_once
      if pkg_available "$pkg"; then
        apt_install "$pkg" "$pkg-venv" "$pkg-dev" || {
          apt_install "$pkg"; apt_install "$pkg-venv"; apt_install "$pkg-dev"
        }
      fi
    fi
    if python_ok "$pkg"; then PYTHON_BIN=$pkg; return 0; fi
  done
  for m in ${1//,/ }; do
    echo "  System packages for Python $m not usable - trying a standalone Python (uv)..."
    python_via_uv "$m" && return 0
  done
  return 1
}

# ----- PostgreSQL helpers ---------------------------------------------------
pg_psql() {   # $1 version, $2 port, rest = psql args (run as the postgres OS user)
  local v=$1 p=$2; shift 2
  as_root runuser -u postgres -- "/usr/lib/postgresql/$v/bin/psql" -X -p "$p" -d postgres -tA "$@" 2>>"$LOG_FILE"
}

pg_prepare() {   # $1 = installed PG version: make sure a cluster exists + runs; sets PG_PORT
  local v=$1 cluster port i
  PG_PORT=""
  cluster=$(as_root pg_lsclusters -h 2>/dev/null | awk -v v="$v" '$1==v {print $2; exit}')
  if [[ -z "$cluster" ]]; then
    echo "  No PostgreSQL $v cluster found. Creating 'main' cluster..."
    as_root pg_createcluster "$v" main >>"$LOG_FILE" 2>&1
    cluster="main"
  fi
  as_root pg_ctlcluster "$v" "$cluster" start >>"$LOG_FILE" 2>&1 || true

  port=$(as_root pg_lsclusters -h 2>/dev/null | awk -v v="$v" -v c="$cluster" '$1==v && $2==c {print $3; exit}')
  [[ -n "$port" ]] || port=5432

  for i in $(seq 1 30); do
    as_root "/usr/lib/postgresql/$v/bin/pg_isready" -q -p "$port" 2>/dev/null && break
    sleep 1
  done

  echo "postgres:postgres" | as_root chpasswd >>"$LOG_FILE" 2>&1 || true
  if [[ "$(pg_psql "$v" "$port" -c "SELECT 1 FROM pg_roles WHERE rolname='$username'")" != "1" ]]; then
    pg_psql "$v" "$port" -c "CREATE ROLE \"$username\" WITH SUPERUSER LOGIN" >>"$LOG_FILE" 2>&1 || \
      echo "  Warning: could not create the PostgreSQL role '$username'."
  fi

  if [[ -f "/etc/postgresql/$v/$cluster/pg_hba.conf" ]]; then
    as_root sed -i 's/peer/trust/g' "/etc/postgresql/$v/$cluster/pg_hba.conf"
  fi
  as_root pg_ctlcluster "$v" "$cluster" restart >>"$LOG_FILE" 2>&1 || as_root systemctl restart postgresql >>"$LOG_FILE" 2>&1
  PG_PORT=$port
}

declare -A pg_needed pg_ports pg_actual

setup_postgres() {   # $1 = wanted version; falls back to another version if it cannot be installed
  local want=$1 actual=""
  if pkg_installed "postgresql-$want"; then
    actual=$want
  elif pkg_available "postgresql-$want" && apt_install "postgresql-$want"; then
    actual=$want
  else
    echo "Warning: PostgreSQL $want could not be installed - looking for an alternative..."
    actual=$(as_root pg_lsclusters -h 2>/dev/null | awk '{print $1}' | sort -n | tail -n 1)
    if [[ -z "$actual" ]] && apt_install postgresql; then
      actual=$(dpkg-query -W -f='${Package}\n' 2>/dev/null | sed -n 's/^postgresql-\([0-9][0-9]*\)$/\1/p' | sort -n | tail -n 1)
    fi
    if [[ -n "$actual" ]]; then
      echo "  Using PostgreSQL $actual instead of $want (Odoo works with it)."
    fi
  fi
  if [[ -z "$actual" ]]; then
    echo "ERROR: no PostgreSQL server could be installed (details in $LOG_FILE)."
    pg_ports[$want]=""
    return 1
  fi
  pg_prepare "$actual"
  pg_ports[$want]=$PG_PORT
  pg_actual[$want]=$actual
  return 0
}

# ----- prompts --------------------------------------------------------------
echo "Enter username (firstname.lastname):"
read username

if ! id -u "$username" &>/dev/null; then
  echo "User '$username' does not exist. Exiting."
  exit 1
fi

if [[ ! -d "/home/$username" ]]; then
  echo "Home directory /home/$username does not exist. Exiting."
  exit 1
fi

# Odoo version -> Python candidates (first usable wins) : Odoo port : PostgreSQL version
declare -A odoo_map=(
  ["13.0"]="3.8,3.7:8013:15"
  ["14.0"]="3.8,3.7,3.9:8014:15"
  ["15.0"]="3.8,3.9,3.10:8015:15"
  ["16.0"]="3.10,3.11:8016:17"
  ["17.0"]="3.10,3.11:8017:17"
  ["18.0"]="3.11,3.12,3.10:8018:17"
  ["19.0"]="3.12:8019:17"
  ["20.0"]="3.12:8020:17"
)

default_versions="14.0 15.0 16.0 17.0 18.0 19.0 20.0"
echo "Enter Odoo versions to install, separated by spaces (13.0 - 20.0),"
echo "or press Enter for all [$default_versions]:"
read selected_input
selected_input=${selected_input:-$default_versions}
[[ "$selected_input" == "all" ]] && selected_input="$default_versions"

selected_versions=()
for v in $selected_input; do
  [[ "$v" =~ ^[0-9]+$ ]] && v="$v.0"
  if [[ -n "${odoo_map[$v]}" ]]; then
    selected_versions+=("$v")
  else
    echo "Unsupported Odoo version '$v' - skipping."
  fi
done

if [[ ${#selected_versions[@]} -eq 0 ]]; then
  echo "No valid Odoo version selected. Exiting."
  exit 1
fi

# Prompt for Enterprise
echo "Do you want to install the Odoo Enterprise source code? (y/n):"
read install_enterprise
if [[ "$install_enterprise" =~ ^[Yy]$ ]]; then
    echo "Enter Git Username for Enterprise Repo (e.g., bista.devops):"
    read git_user
    if [[ "$git_user" =~ ^(glpat-|ghp_|gho_|github_pat_) ]]; then
      echo "That looks like an access TOKEN, not a username. Enter the username (e.g., bista.devops):"
      read git_user
    fi
    echo "Enter Git Token for Enterprise Repo (input will be hidden):"
    read -s git_token
    echo ""
fi

# Disk space hint (about 3 GB per version)
avail_gb=$(df -Pk /home 2>/dev/null | awk 'NR==2 {printf "%d", $4/1048576}')
need_gb=$(( ${#selected_versions[@]} * 3 ))
if [[ "$avail_gb" =~ ^[0-9]+$ && "$avail_gb" -lt "$need_gb" ]]; then
  echo "Warning: only ${avail_gb} GB free in /home, about ${need_gb} GB is recommended for ${#selected_versions[@]} version(s)."
fi

echo "Detected ${distro_id:-linux} $ubuntu_version ($ubuntu_codename) - log: $LOG_FILE"

# ----- base system ----------------------------------------------------------
echo "Preparing the package manager..."
wait_for_apt_lock
repair_apt
as_root apt-get clean >>"$LOG_FILE" 2>&1
apt_update

install_group required curl gnupg ca-certificates wget git software-properties-common lsb-release

# Make sure 'universe' is enabled on Ubuntu (several packages live there)
if [[ "$distro_id" == "ubuntu" ]]; then
  as_root add-apt-repository -y universe >>"$LOG_FILE" 2>&1 || true
  apt_update
fi

# ----- Node.js (remove conflicting distro node packages first) --------------
current_node_major=0
if command -v node &>/dev/null; then
  current_node_major=$(node -v 2>/dev/null | sed 's/^v\([0-9]*\).*/\1/')
  [[ "$current_node_major" =~ ^[0-9]+$ ]] || current_node_major=0
fi

if [[ "$current_node_major" -lt "$NODE_MAJOR" ]]; then
  echo "Installing Node.js $NODE_MAJOR..."
  old_node_pkgs=$(dpkg-query -W -f='${Package} ${Status}\n' 2>/dev/null | \
    awk '$4=="installed" && ($1 ~ /^libnode/ || $1=="nodejs-doc" || $1=="nodejs" || $1=="npm") {print $1}')
  if [[ -n "$old_node_pkgs" ]]; then
    apt_run remove --purge $old_node_pkgs || true
  fi
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | as_root bash - >>"$LOG_FILE" 2>&1 || \
    echo "Warning: could not add the NodeSource repository."
  apt_install nodejs || echo "Warning: Node.js could not be installed (less / rtlcss will be skipped)."
fi

# ----- extra apt repository: PostgreSQL (PGDG) ------------------------------
as_root mkdir -p /etc/apt/keyrings
if curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor | as_root tee /etc/apt/keyrings/postgresql.gpg > /dev/null 2>>"$LOG_FILE"; then
  echo "deb [signed-by=/etc/apt/keyrings/postgresql.gpg] http://apt.postgresql.org/pub/repos/apt ${ubuntu_codename}-pgdg main" | \
    as_root tee /etc/apt/sources.list.d/pgdg.list > /dev/null
else
  echo "Warning: could not fetch the PostgreSQL repository key - using the distribution's PostgreSQL."
fi
apt_update

# ----- build tools & libraries ----------------------------------------------
echo "Installing build tools and libraries..."
install_group required build-essential gcc g++ make python3-dev libffi-dev libssl-dev \
  "libjpeg-dev|libjpeg-turbo8-dev" libpq-dev libxml2-dev libxslt1-dev zlib1g-dev \
  libsasl2-dev "libldap-dev|libldap2-dev"
install_group optional python3-pip "libjpeg8-dev|libjpeg-turbo8-dev" liblcms2-dev \
  "libblas-dev|libopenblas-dev" "libatlas-base-dev|libopenblas-dev" xfonts-75dpi xfonts-base \
  node-less openssh-server fail2ban

if command -v npm &>/dev/null; then
  as_root npm install -g less less-plugin-clean-css rtlcss >>"$LOG_FILE" 2>&1 || \
    echo "Warning: npm packages (less, rtlcss) could not be installed."
fi
[[ -e /usr/bin/node || ! -e /usr/bin/nodejs ]] || as_root ln -s /usr/bin/nodejs /usr/bin/node 2>/dev/null

# ----- wkhtmltopdf ----------------------------------------------------------
if ! command -v wkhtmltopdf &>/dev/null; then
  echo "Installing wkhtmltopdf..."
  wk_deb=""
  if [[ "$ubuntu_version" == "20.04" ]]; then
    wk_url="https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6-1/wkhtmltox_0.12.6-1.focal_amd64.deb"
  elif [[ "$ubuntu_version" == "22.04" || "$ubuntu_version" == "24.04" ]]; then
    wk_url="https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-2/wkhtmltox_0.12.6.1-2.jammy_amd64.deb"
  else
    wk_url=""
  fi
  if [[ -n "$wk_url" ]]; then
    wk_deb="/tmp/$(basename "$wk_url")"
    if wget -q -O "$wk_deb" "$wk_url"; then
      as_root dpkg -i "$wk_deb" >>"$LOG_FILE" 2>&1 || repair_apt
    fi
    rm -f "$wk_deb"
  fi
  command -v wkhtmltopdf &>/dev/null || install_group optional wkhtmltopdf
  command -v wkhtmltopdf &>/dev/null || echo "Warning: wkhtmltopdf could not be installed (PDF reports will not work)."
fi

# ----- PostgreSQL (only the versions needed by the selected Odoo versions) --
cd /tmp
for version in "${selected_versions[@]}"; do
  pg_needed[$(echo "${odoo_map[$version]}" | cut -d ':' -f3)]=1
done
for pgver in "${!pg_needed[@]}"; do
  echo "Setting up PostgreSQL $pgver..."
  setup_postgres "$pgver"
done

# ----- Loop through the selected Odoo versions ------------------------------
summary_lines=()
failures=0

for version in "${selected_versions[@]}"; do
  IFS=":" read python_candidates odoo_port pg_version <<< "${odoo_map[$version]}"
  folder_suffix="${version/.0/}"
  folder_name="odoo$folder_suffix"
  base_dir="/home/$username/$folder_name"
  venv_path="$base_dir/${version}-venv"
  venv_python="$venv_path/bin/python3"

  echo ""
  echo "Setting up Odoo $version (Python ${python_candidates//,/ or }, Port $odoo_port, PostgreSQL $pg_version)..."

  # Python
  if ! setup_python "$python_candidates"; then
    echo "  FAILED: no usable Python (${python_candidates//,/ or }) on ${distro_id:-this system} $ubuntu_version."
    summary_lines+=("Odoo $version : FAILED - Python ${python_candidates//,/ or } could not be set up (see $LOG_FILE)")
    failures=$((failures + 1))
    continue
  fi
  python_ver=$PYTHON_BIN
  echo "  Using $python_ver ($("$python_ver" --version 2>&1))"

  # Folder + source
  as_root mkdir -p "$base_dir"
  as_root chown -R "$username": "$base_dir"
  cd "$base_dir" || { summary_lines+=("Odoo $version : FAILED - cannot enter $base_dir"); failures=$((failures + 1)); continue; }

  if [[ ! -d "$base_dir/odoo/.git" ]]; then
    if ! run_as git clone -q https://github.com/odoo/odoo --depth 1 --branch "$version" --single-branch >>"$LOG_FILE" 2>&1; then
      echo "  FAILED: could not clone Odoo $version."
      summary_lines+=("Odoo $version : FAILED - could not clone the Odoo source (see $LOG_FILE)")
      failures=$((failures + 1))
      continue
    fi
  else
    echo "  Odoo source already present, skipping clone."
  fi

  enterprise_ok=false
  if [[ "$install_enterprise" =~ ^[Yy]$ ]]; then
    if [[ ! -d "$base_dir/odoo_enterprise/.git" ]]; then
      enc_user=$(urlencode "$git_user"); enc_tok=$(urlencode "$git_token")
      clone_out=$(run_as env GIT_TERMINAL_PROMPT=0 git clone -q \
        "https://${enc_user}:${enc_tok}@git.bistasolutions.com/bistasolutions/odoo_enterprise.git" \
        --depth 1 --branch "$version" --single-branch 2>&1)
      if [[ $? -eq 0 ]]; then
        # do not keep the token stored in the repo config
        run_as git -C "$base_dir/odoo_enterprise" remote set-url origin \
          "https://git.bistasolutions.com/bistasolutions/odoo_enterprise.git" 2>/dev/null || true
        enterprise_ok=true
      else
        clone_out=${clone_out//"$git_token"/***}
        clone_out=${clone_out//"$enc_tok"/***}
        echo "  Warning: could not clone the Enterprise repo for $version (continuing without it)."
        echo "$clone_out" | tail -n 3 | sed 's/^/    /'
      fi
    else
      enterprise_ok=true
    fi
  fi

  # Virtual environment (recreate it if an old run built it with a different Python)
  want_mm=$("$python_ver" -c 'import sys; print("%d.%d" % sys.version_info[:2])')
  if [[ -x "$venv_python" ]]; then
    have_mm=$("$venv_python" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null)
    if [[ "$have_mm" != "$want_mm" ]]; then
      echo "  Existing virtualenv uses Python ${have_mm:-?}, but Odoo $version needs $want_mm - recreating it."
      as_root rm -rf "$venv_path"
    fi
  fi
  if [[ ! -x "$venv_python" ]]; then
    if ! run_as "$python_ver" -m venv "$venv_path" >>"$LOG_FILE" 2>&1; then
      echo "  FAILED: could not create the virtual environment."
      summary_lines+=("Odoo $version : FAILED - could not create virtualenv with $python_ver (see $LOG_FILE)")
      failures=$((failures + 1))
      continue
    fi
  fi
  run_as "$venv_python" -m ensurepip --upgrade >>"$LOG_FILE" 2>&1
  if ! run_as "$venv_python" -m pip install -q --upgrade pip wheel >>"$LOG_FILE" 2>&1; then
    echo "  FAILED: pip is not working in the virtual environment."
    summary_lines+=("Odoo $version : FAILED - pip not working in the virtualenv (see $LOG_FILE)")
    failures=$((failures + 1))
    continue
  fi

  # gevent / greenlet: install compatible builds first, then install the
  # remaining requirements without Odoo's gevent/greenlet pins (they have no
  # wheels for newer Python and conflict with newer gevent).
  py_minor=$(run_as "$venv_python" -c 'import sys; print(sys.version_info.minor)')
  if [[ "$py_minor" -ge 12 ]]; then
    run_as "$venv_python" -m pip install -q --prefer-binary "gevent==24.10.3" "greenlet>=3.1.1" >>"$LOG_FILE" 2>&1 || \
    run_as "$venv_python" -m pip install -q --prefer-binary gevent >>"$LOG_FILE" 2>&1 || true
  else
    run_as "$venv_python" -m pip install -q --prefer-binary gevent==22.10.2 >>"$LOG_FILE" 2>&1 || \
    run_as "$venv_python" -m pip install -q --prefer-binary gevent==21.12.0 >>"$LOG_FILE" 2>&1 || \
    run_as "$venv_python" -m pip install -q --prefer-binary gevent >>"$LOG_FILE" 2>&1 || true
  fi

  req_tmp=$(mktemp)
  grep -v -i -E 'gevent|greenlet' "$base_dir/odoo/requirements.txt" > "$req_tmp"
  chmod 644 "$req_tmp"

  warn=""
  echo "  Installing Python requirements (this takes a while)..."
  if ! run_as "$venv_python" -m pip install -q -r "$req_tmp" --prefer-binary >>"$LOG_FILE" 2>&1; then
    warn=" (some Python packages failed to install - see $LOG_FILE)"
    echo "  Warning: some Python requirements failed to install."
    grep -E 'ERROR|error:' "$LOG_FILE" | tail -n 3 | sed 's/^/    /'
  fi
  rm -f "$req_tmp"

  # psycopg2-binary only if the pinned psycopg2 did not build
  if ! run_as "$venv_python" -c 'import psycopg2' > /dev/null 2>&1; then
    run_as "$venv_python" -m pip install -q psycopg2-binary >>"$LOG_FILE" 2>&1 || true
  fi
  if ! run_as "$venv_python" -c 'import psycopg2, lxml' > /dev/null 2>&1; then
    warn="$warn (core packages psycopg2/lxml are MISSING - Odoo will not start)"
  fi

  # odoo.conf
  db_port=${pg_ports[$pg_version]}
  if [[ -z "$db_port" ]]; then
    db_port=5432
    warn="$warn (PostgreSQL $pg_version was not set up - check db_port in odoo.conf)"
  fi
  addons_path="$base_dir/odoo/addons,$base_dir/odoo/odoo/addons"
  if [[ "$enterprise_ok" == true ]]; then
    addons_path="$base_dir/odoo_enterprise,$addons_path"
  fi

  cat <<EOT | as_root tee "$base_dir/odoo/odoo.conf" > /dev/null
[options]
addons_path = $addons_path
admin_passwd = admin@123
data_dir = /home/$username/.local/share/Odoo
db_host = False
db_name = False
db_password = False
db_port = $db_port
db_user = False
dbfilter =
http_enable = True
http_port = $odoo_port
EOT

  as_root chown -R "$username": "$base_dir"
  as_root chmod 640 "$base_dir/odoo/odoo.conf"

  pg_note="PostgreSQL ${pg_actual[$pg_version]:-$pg_version}/port $db_port"
  summary_lines+=("Odoo $version : installed at $base_dir (Python $want_mm, port $odoo_port, $pg_note)$warn")
  summary_lines+=("   Start it with: $venv_python $base_dir/odoo/odoo-bin -c $base_dir/odoo/odoo.conf")
done

# ----- Summary --------------------------------------------------------------
echo ""
echo "===== Odoo Installation Summary ====="
for line in "${summary_lines[@]}"; do
  echo "$line"
done
echo ""
echo "Full log: $LOG_FILE"
echo ""
[[ $failures -eq 0 ]] || exit 1