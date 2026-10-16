#!/bin/bash

# ---------------------------------------------------------------------------
# Universal multi-version Odoo installer
#   Ubuntu : 20.04 / 22.04 / 24.04 and newer
#   Odoo   : 13.0 - 20.0 (side by side, one folder / venv / port per version)
# Run with:  sudo bash odoo-install-all-version.sh   (or as a sudo-capable user)
# ---------------------------------------------------------------------------

# ----- helpers --------------------------------------------------------------
as_root() {
  if [[ $EUID -eq 0 ]]; then "$@"; else sudo "$@"; fi
}

apt_install() {
  as_root env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y -qq "$@"
}

apt_update() {
  as_root env DEBIAN_FRONTEND=noninteractive apt-get update -qq
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

pkg_available() {   # true if apt has an installable candidate for the package
  local candidate
  candidate=$(apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ {print $2}')
  [[ -n "$candidate" && "$candidate" != "(none)" ]]
}

install_available() {   # install the packages that exist on this Ubuntu, skip the rest
  local pkg list=() skipped=()
  for pkg in "$@"; do
    if pkg_available "$pkg"; then list+=("$pkg"); else skipped+=("$pkg"); fi
  done
  if [[ ${#list[@]} -gt 0 ]] && ! apt_install "${list[@]}" > /dev/null 2>&1; then
    for pkg in "${list[@]}"; do
      apt_install "$pkg" > /dev/null 2>&1 || skipped+=("$pkg")
    done
  fi
  if [[ ${#skipped[@]} -gt 0 ]]; then
    echo "Note: skipped (not available on Ubuntu $ubuntu_version): ${skipped[*]}"
  fi
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

# Odoo version -> Python candidates (first installable wins) : Odoo port : PostgreSQL version
declare -A odoo_map=(
  ["13.0"]="3.7,3.8:8013:15"
  ["14.0"]="3.7,3.8:8014:15"
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
    echo "Enter Git Token for Enterprise Repo (input will be hidden):"
    read -s git_token
fi

# ----- base system ----------------------------------------------------------
# Clean, fix packages
as_root apt-get clean
apt_update
as_root env DEBIAN_FRONTEND=noninteractive apt-get --fix-broken install -y -qq > /dev/null 2>&1

# Bootstrap tools needed by the rest of the script
apt_install software-properties-common curl gnupg ca-certificates wget lsb-release git > /dev/null 2>&1

# Ubuntu version
ubuntu_version=$(lsb_release -rs 2>/dev/null)
ubuntu_codename=$(lsb_release -cs 2>/dev/null)
echo "Detected Ubuntu $ubuntu_version ($ubuntu_codename)"

# ----- Node.js 18 (remove conflicting distro node packages first) -----------
current_node_major=0
if command -v node &>/dev/null; then
  current_node_major=$(node -v 2>/dev/null | sed 's/^v\([0-9]*\).*/\1/')
  [[ "$current_node_major" =~ ^[0-9]+$ ]] || current_node_major=0
fi

if [[ "$current_node_major" -lt 18 ]]; then
  old_node_pkgs=$(dpkg-query -W -f='${Package} ${Status}\n' 2>/dev/null | \
    awk '$4=="installed" && ($1 ~ /^libnode/ || $1=="nodejs-doc" || $1=="nodejs" || $1=="npm") {print $1}')
  if [[ -n "$old_node_pkgs" ]]; then
    as_root env DEBIAN_FRONTEND=noninteractive apt-get remove -y -qq --purge $old_node_pkgs > /dev/null 2>&1 || true
  fi
  curl -fsSL https://deb.nodesource.com/setup_18.x | as_root bash - > /dev/null 2>&1
  apt_install nodejs > /dev/null 2>&1
fi

# ----- extra apt repositories (PostgreSQL + deadsnakes) ---------------------
as_root mkdir -p /etc/apt/keyrings
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor | as_root tee /etc/apt/keyrings/postgresql.gpg > /dev/null
echo "deb [signed-by=/etc/apt/keyrings/postgresql.gpg] http://apt.postgresql.org/pub/repos/apt ${ubuntu_codename}-pgdg main" | \
  as_root tee /etc/apt/sources.list.d/pgdg.list > /dev/null

# Add deadsnakes PPA (extra Python versions)
as_root add-apt-repository -y ppa:deadsnakes/ppa > /dev/null 2>&1 || true

if ! apt_update; then
  echo "Repository update failed. Retrying without the PostgreSQL repo..."
  as_root rm -f /etc/apt/sources.list.d/pgdg.list
  apt_update
fi

# ----- build tools & libraries ----------------------------------------------
install_available build-essential gcc g++ make python3-dev python3-pip libffi-dev libssl-dev \
  libjpeg-dev libpq-dev libxml2-dev libxslt1-dev zlib1g-dev libsasl2-dev libldap2-dev \
  libjpeg8-dev liblcms2-dev libblas-dev libatlas-base-dev xfonts-75dpi xfonts-base

as_root ln -s /usr/bin/nodejs /usr/bin/node 2>/dev/null
as_root npm install -g less less-plugin-clean-css rtlcss > /dev/null 2>&1
apt_install node-less openssh-server fail2ban > /dev/null 2>&1 || apt_install openssh-server fail2ban > /dev/null 2>&1

# ----- wkhtmltopdf ----------------------------------------------------------
cd /home/$username
if ! command -v wkhtmltopdf &>/dev/null; then
  if [[ "$ubuntu_version" == "20.04" ]]; then
    as_root wget -q https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6-1/wkhtmltox_0.12.6-1.focal_amd64.deb
    as_root dpkg -i wkhtmltox_0.12.6-1.focal_amd64.deb > /dev/null 2>&1
  elif [[ "$ubuntu_version" == "22.04" || "$ubuntu_version" == "24.04" ]]; then
    as_root wget -q https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-2/wkhtmltox_0.12.6.1-2.jammy_amd64.deb
    as_root dpkg -i wkhtmltox_0.12.6.1-2.jammy_amd64.deb > /dev/null 2>&1
  fi
  as_root env DEBIAN_FRONTEND=noninteractive apt-get --fix-broken install -y -qq > /dev/null 2>&1
  # Fallback to the distro package if the downloaded one is unusable
  if ! wkhtmltopdf --version &>/dev/null; then
    apt_install wkhtmltopdf > /dev/null 2>&1 || true
  fi
  as_root rm -f /home/$username/wkhtmltox_*.deb
fi

# ----- PostgreSQL (only the versions needed by the selected Odoo versions) --
declare -A pg_needed
for version in "${selected_versions[@]}"; do
  pg_needed[$(echo "${odoo_map[$version]}" | cut -d ':' -f3)]=1
done

declare -A pg_ports

setup_postgres() {
  local pgver=$1 cluster port i

  if ! dpkg -s "postgresql-$pgver" &>/dev/null; then
    if ! apt_install "postgresql-$pgver" > /dev/null 2>&1; then
      echo "Warning: could not install PostgreSQL $pgver."
      pg_ports[$pgver]="5432"
      return 1
    fi
  fi

  # Make sure a cluster exists for this version
  cluster=$(as_root pg_lsclusters -h 2>/dev/null | awk -v v="$pgver" '$1==v {print $2; exit}')
  if [[ -z "$cluster" ]]; then
    echo "No PostgreSQL $pgver cluster found. Creating 'main' cluster..."
    as_root pg_createcluster "$pgver" main > /dev/null 2>&1
    cluster="main"
  fi
  as_root pg_ctlcluster "$pgver" "$cluster" start > /dev/null 2>&1 || true

  port=$(as_root pg_lsclusters -h 2>/dev/null | awk -v v="$pgver" -v c="$cluster" '$1==v && $2==c {print $3; exit}')
  [[ -n "$port" ]] || port="5432"

  # Wait (max 20s) until the cluster accepts connections
  if command -v pg_isready &>/dev/null; then
    for i in $(seq 1 20); do
      pg_isready -q -p "$port" && break
      sleep 1
    done
  else
    sleep 3
  fi

  echo "postgres:postgres" | as_root chpasswd > /dev/null 2>&1 || true
  as_root runuser -u postgres -- createuser -s -p "$port" "$username" > /dev/null 2>&1 || true

  if [[ -f "/etc/postgresql/$pgver/$cluster/pg_hba.conf" ]]; then
    as_root sed -i 's/peer/trust/g' "/etc/postgresql/$pgver/$cluster/pg_hba.conf"
  fi
  as_root pg_ctlcluster "$pgver" "$cluster" restart > /dev/null 2>&1 || as_root systemctl restart postgresql

  pg_ports[$pgver]="$port"
  return 0
}

cd /tmp
for pgver in "${!pg_needed[@]}"; do
  setup_postgres "$pgver"
done

# ----- Python helper --------------------------------------------------------
setup_python() {   # $1 = comma separated minor versions, prints the python binary name
  local m pkg
  for m in ${1//,/ }; do
    pkg="python$m"
    if ! command -v "$pkg" &>/dev/null; then
      pkg_available "$pkg" || continue
      apt_install "$pkg" > /dev/null 2>&1 || continue
    fi
    apt_install "$pkg-venv" "$pkg-dev" > /dev/null 2>&1 || {
      apt_install "$pkg-venv" > /dev/null 2>&1
      apt_install "$pkg-dev" > /dev/null 2>&1
    }
    if command -v "$pkg" &>/dev/null; then
      echo "$pkg"
      return 0
    fi
  done
  return 1
}

# ----- Loop through the selected Odoo versions ------------------------------
summary_lines=()

for version in "${selected_versions[@]}"; do
  IFS=":" read python_candidates odoo_port pg_version <<< "${odoo_map[$version]}"
  folder_suffix="${version/.0/}"
  folder_name="odoo$folder_suffix"
  base_dir="/home/$username/$folder_name"
  venv_path="$base_dir/${version}-venv"
  venv_python="$venv_path/bin/python3"

  echo "Setting up Odoo $version (Python ${python_candidates//,/ or }, Port $odoo_port, PostgreSQL $pg_version)..."

  # Python
  python_ver=$(setup_python "$python_candidates")
  if [[ -z "$python_ver" ]]; then
    echo "  FAILED: no suitable Python ($python_candidates) could be installed on Ubuntu $ubuntu_version."
    summary_lines+=("Odoo $version : FAILED - Python ${python_candidates//,/ or } not available on Ubuntu $ubuntu_version")
    continue
  fi
  echo "  Using $python_ver"

  # Folder + source
  as_root mkdir -p "$base_dir"
  as_root chown -R "$username": "$base_dir"
  cd "$base_dir"

  if [[ ! -d "$base_dir/odoo/.git" ]]; then
    if ! run_as git clone -q https://github.com/odoo/odoo --depth 1 --branch "$version" --single-branch; then
      echo "  FAILED: could not clone Odoo $version."
      summary_lines+=("Odoo $version : FAILED - could not clone the Odoo source")
      continue
    fi
  else
    echo "  Odoo source already present, skipping clone."
  fi

  enterprise_ok=false
  if [[ "$install_enterprise" =~ ^[Yy]$ ]]; then
    if [[ ! -d "$base_dir/odoo_enterprise/.git" ]]; then
      if run_as git clone -q "https://$git_user:$git_token@git.bistasolutions.com/bistasolutions/odoo_enterprise.git" \
           --depth 1 --branch "$version" --single-branch; then
        # do not keep the token stored in the repo config
        run_as git -C "$base_dir/odoo_enterprise" remote set-url origin \
          "https://git.bistasolutions.com/bistasolutions/odoo_enterprise.git" 2>/dev/null || true
        enterprise_ok=true
      else
        echo "  Warning: could not clone the Enterprise repo for $version (continuing without it)."
      fi
    else
      enterprise_ok=true
    fi
  fi

  # Virtual environment
  if [[ ! -x "$venv_python" ]]; then
    run_as "$python_ver" -m venv "$venv_path" || {
      echo "  FAILED: could not create the virtual environment."
      summary_lines+=("Odoo $version : FAILED - could not create virtualenv with $python_ver")
      continue
    }
  fi
  run_as "$venv_python" -m ensurepip --upgrade > /dev/null 2>&1
  run_as "$venv_python" -m pip install -q --upgrade pip wheel > /dev/null || {
    echo "  FAILED: pip is not working in the virtual environment."
    summary_lines+=("Odoo $version : FAILED - pip not working in the virtualenv")
    continue
  }

  # gevent / greenlet: install compatible builds first, then install the
  # remaining requirements without Odoo's gevent/greenlet pins (they have no
  # wheels for newer Python and conflict with newer gevent).
  py_minor=$(run_as "$venv_python" -c 'import sys; print(sys.version_info.minor)')
  if [[ "$py_minor" -ge 12 ]]; then
    run_as "$venv_python" -m pip install -q --prefer-binary "gevent==24.10.3" "greenlet>=3.1.1" > /dev/null 2>&1 || \
    run_as "$venv_python" -m pip install -q --prefer-binary gevent > /dev/null 2>&1 || true
  else
    run_as "$venv_python" -m pip install -q --prefer-binary gevent==22.10.2 > /dev/null 2>&1 || \
    run_as "$venv_python" -m pip install -q --prefer-binary gevent==21.12.0 > /dev/null 2>&1 || \
    run_as "$venv_python" -m pip install -q --prefer-binary gevent > /dev/null 2>&1 || true
  fi

  req_tmp=$(mktemp)
  grep -v -i -E 'gevent|greenlet' "$base_dir/odoo/requirements.txt" > "$req_tmp"
  chmod 644 "$req_tmp"

  warn=""
  if ! run_as "$venv_python" -m pip install -q -r "$req_tmp" --prefer-binary > /dev/null; then
    warn=" (some Python packages failed to install - see messages above)"
    echo "  Warning: some Python requirements failed to install."
  fi
  rm -f "$req_tmp"

  # psycopg2-binary only if the pinned psycopg2 did not build
  if ! run_as "$venv_python" -c 'import psycopg2' > /dev/null 2>&1; then
    run_as "$venv_python" -m pip install -q psycopg2-binary > /dev/null 2>&1 || true
  fi

  # odoo.conf
  db_port=${pg_ports[$pg_version]:-5432}
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

  summary_lines+=("Odoo $version : installed at $base_dir (Python $python_ver, port $odoo_port, PostgreSQL $pg_version/port $db_port)$warn")
  summary_lines+=("   Start it with: $venv_python $base_dir/odoo/odoo-bin -c $base_dir/odoo/odoo.conf")
done

# ----- Summary --------------------------------------------------------------
echo ""
echo "===== Odoo Installation Summary ====="
for line in "${summary_lines[@]}"; do
  echo "$line"
done
echo ""
