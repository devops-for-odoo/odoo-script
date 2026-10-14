#!/bin/bash

# ---------------------------------------------------------------------------
# Universal Odoo installer (Ubuntu 20.04 / 22.04 / 24.04+ , Odoo 13.0 - 20.0)
# ---------------------------------------------------------------------------

# Non-interactive apt helper (no prompts, no "apt CLI" warnings)
apt_install() {
  sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y -qq "$@"
}
apt_update() {
  sudo env DEBIAN_FRONTEND=noninteractive apt-get update -qq
}

# Prompt for user info
echo "Enter username (firstname.lastname):"
read username

# Validate username and home directory
if ! id -u "$username" &>/dev/null; then
  echo "User '$username' does not exist. Exiting."
  exit 1
fi

if [[ ! -d "/home/$username" ]]; then
  echo "Home directory /home/$username does not exist. Exiting."
  exit 1
fi

echo "Enter Odoo version (13.0, 14.0, 15.0, 16.0, 17.0, 18.0, 19.0, 20.0):"
read odoo_version

echo "Enter Folder Name:"
read folder_name

# Detect Ubuntu version
ubuntu_version=$(lsb_release -rs)

# PostgreSQL configuration (always version 17)
pg_version="17"
if dpkg -s "postgresql-$pg_version" &>/dev/null; then
    echo "PostgreSQL $pg_version already installed. Skipping installation."
    install_pgsql_flag=false
else
    echo "PostgreSQL $pg_version not detected. Will install."
    install_pgsql_flag=true
fi

# Odoo Enterprise option
echo "Do you want to install the Odoo Enterprise source code? (y/n):"
read install_enterprise
if [[ "$install_enterprise" =~ ^[Yy]$ ]]; then
    echo "Enter Git Username for Enterprise Repo (e.g., bista.devops):"
    read git_user
    echo "Enter Git Token for Enterprise Repo (input will be hidden):"
    read -s git_token
fi

# Determine Python package (system default)
case "$ubuntu_version" in
  20.04) python_package="python3.8" ;;
  22.04) python_package="python3.10" ;;
  24.04) python_package="python3.12" ;;
  *) python_package="python3" ;;
esac

# Odoo 19 / 20 require Python 3.12 -> override the system default
if [[ "$odoo_version" == 19* || "$odoo_version" == 20* ]]; then
  python_package="python3.12"
  echo "Odoo $odoo_version requires Python 3.12. Setting up python3.12..."

  if ! command -v python3.12 &>/dev/null; then
    # Ubuntu 24.04 ships python3.12 natively; older/other releases need deadsnakes PPA
    if [[ "$ubuntu_version" != "24.04" ]]; then
      apt_update > /dev/null
      apt_install software-properties-common > /dev/null
      sudo add-apt-repository ppa:deadsnakes/ppa -y > /dev/null 2>&1
      apt_update > /dev/null
    fi
    apt_install python3.12 python3.12-venv python3.12-dev > /dev/null
  else
    # Make sure venv/dev packages exist even if python3.12 is already present
    apt_install python3.12-venv python3.12-dev > /dev/null 2>&1 || true
  fi

  python3.12 --version || {
    echo "Failed to install Python 3.12 on Ubuntu $ubuntu_version. Exiting."
    exit 1
  }
fi

echo "Using $python_package for Odoo $odoo_version on Ubuntu $ubuntu_version"

# ---------------------------------------------------------------------------
# Node.js 18 (remove conflicting distro node packages first, e.g. libnode-dev)
# ---------------------------------------------------------------------------
current_node_major=0
if command -v node &>/dev/null; then
  current_node_major=$(node -v 2>/dev/null | sed 's/^v\([0-9]*\).*/\1/')
  [[ "$current_node_major" =~ ^[0-9]+$ ]] || current_node_major=0
fi

if [[ "$current_node_major" -lt 18 ]]; then
  old_node_pkgs=$(dpkg-query -W -f='${Package} ${Status}\n' 2>/dev/null | \
    awk '$4=="installed" && ($1 ~ /^libnode/ || $1=="nodejs-doc" || $1=="nodejs" || $1=="npm") {print $1}')
  if [[ -n "$old_node_pkgs" ]]; then
    sudo env DEBIAN_FRONTEND=noninteractive apt-get remove -y -qq --purge $old_node_pkgs > /dev/null 2>&1 || true
  fi
  apt_update > /dev/null
  apt_install curl ca-certificates gnupg > /dev/null
  curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash - > /dev/null 2>&1
  apt_install nodejs > /dev/null
fi

# ---------------------------------------------------------------------------
# Install dependencies (packages not available on this Ubuntu are skipped)
# ---------------------------------------------------------------------------
apt_update > /dev/null

base_pkgs=(
  "$python_package" "$python_package-venv" "$python_package-dev" python3-pip
  git build-essential
  libxml2-dev libxslt1-dev zlib1g-dev libsasl2-dev libldap2-dev libssl-dev libffi-dev libjpeg-dev
  libpq-dev libmysqlclient-dev libjpeg8-dev liblcms2-dev libblas-dev libatlas-base-dev
  curl gnupg ca-certificates
)

install_list=()
skipped_list=()
for pkg in "${base_pkgs[@]}"; do
  candidate=$(apt-cache policy "$pkg" 2>/dev/null | awk '/Candidate:/ {print $2}')
  if [[ -n "$candidate" && "$candidate" != "(none)" ]]; then
    install_list+=("$pkg")
  else
    skipped_list+=("$pkg")
  fi
done

if ! apt_install "${install_list[@]}" > /dev/null 2>&1; then
  # Fallback: install one by one so a single bad package cannot block the rest
  for pkg in "${install_list[@]}"; do
    apt_install "$pkg" > /dev/null 2>&1 || skipped_list+=("$pkg")
  done
fi

if [[ ${#skipped_list[@]} -gt 0 ]]; then
  echo "Note: skipped (not available on Ubuntu $ubuntu_version): ${skipped_list[*]}"
fi

sudo ln -s /usr/bin/nodejs /usr/bin/node 2>/dev/null
sudo npm install -g less less-plugin-clean-css rtlcss > /dev/null 2>&1
apt_install node-less openssh-server fail2ban > /dev/null 2>&1 || apt_install openssh-server fail2ban > /dev/null 2>&1

# ---------------------------------------------------------------------------
# wkhtmltopdf
# ---------------------------------------------------------------------------
cd /home/$username
if ! command -v wkhtmltopdf &>/dev/null; then
  if [[ "$ubuntu_version" == "20.04" ]]; then
    sudo wget -q https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6-1/wkhtmltox_0.12.6-1.focal_amd64.deb
    sudo dpkg -i wkhtmltox_0.12.6-1.focal_amd64.deb > /dev/null 2>&1
  elif [[ "$ubuntu_version" == "22.04" || "$ubuntu_version" == "24.04" ]]; then
    sudo wget -q https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-2/wkhtmltox_0.12.6.1-2.jammy_amd64.deb
    sudo dpkg -i wkhtmltox_0.12.6.1-2.jammy_amd64.deb > /dev/null 2>&1
  else
    apt_install wkhtmltopdf > /dev/null 2>&1 || true
  fi
  sudo env DEBIAN_FRONTEND=noninteractive apt-get --fix-broken install -y -qq > /dev/null 2>&1
  sudo rm -f /home/$username/wkhtmltox_*.deb
fi

# ---------------------------------------------------------------------------
# Install PostgreSQL 17
# ---------------------------------------------------------------------------
if [[ "$install_pgsql_flag" == true ]]; then
  sudo mkdir -p /etc/apt/keyrings
  curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor | sudo tee /etc/apt/keyrings/postgresql.gpg >/dev/null
  echo "deb [signed-by=/etc/apt/keyrings/postgresql.gpg] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" | sudo tee /etc/apt/sources.list.d/pgdg.list >/dev/null

  if ! apt_update; then
      echo "Failed to update PostgreSQL repo. Retrying with fallback..."
      sudo rm -f /etc/apt/sources.list.d/pgdg.list
      apt_update
  fi

  apt_install postgresql-$pg_version > /dev/null
fi

# ---------------------------------------------------------------------------
# Configure PostgreSQL (make sure a PG17 cluster exists, is running, get its port)
# ---------------------------------------------------------------------------
pg_cluster=$(pg_lsclusters -h 2>/dev/null | awk -v v="$pg_version" '$1==v {print $2; exit}')
if [[ -z "$pg_cluster" ]]; then
  echo "No PostgreSQL $pg_version cluster found. Creating 'main' cluster..."
  sudo pg_createcluster "$pg_version" main > /dev/null 2>&1
  pg_cluster="main"
fi

sudo pg_ctlcluster "$pg_version" "$pg_cluster" start > /dev/null 2>&1 || true

pg_port=$(pg_lsclusters -h 2>/dev/null | awk -v v="$pg_version" -v c="$pg_cluster" '$1==v && $2==c {print $3; exit}')
[[ -n "$pg_port" ]] || pg_port=5432

# Wait (max 20s) until PostgreSQL accepts connections
for _ in $(seq 1 20); do
  pg_isready -q -p "$pg_port" && break
  sleep 1
done

pg_hba="/etc/postgresql/$pg_version/$pg_cluster/pg_hba.conf"

echo "postgres:postgres" | sudo chpasswd > /dev/null 2>&1 || true
sudo -u postgres createuser -ld -p "$pg_port" "$username" > /dev/null 2>&1 || true
if [[ -f "$pg_hba" ]]; then
  sudo sed -i 's/peer/trust/g' "$pg_hba"
fi
sudo pg_ctlcluster "$pg_version" "$pg_cluster" restart > /dev/null 2>&1 || sudo systemctl restart postgresql

# ---------------------------------------------------------------------------
# Setup Odoo source
# ---------------------------------------------------------------------------
sudo mkdir -p /home/$username/$folder_name
sudo chown -R $username: /home/$username/$folder_name
cd /home/$username/$folder_name
sudo git clone -q https://www.github.com/odoo/odoo --depth 1 --branch $odoo_version --single-branch

if [[ "$install_enterprise" =~ ^[Yy]$ ]]; then
  sudo git clone -q https://$git_user:$git_token@git.bistasolutions.com/bistasolutions/odoo_enterprise.git --depth 1 --branch $odoo_version --single-branch
fi

cd odoo
venv_path="/home/$username/$folder_name/${odoo_version}-venv"

# Create virtual environment
sudo -u $username $python_package -m venv "$venv_path"

# Ensure pip inside venv
"$venv_path/bin/python3" -m ensurepip --upgrade > /dev/null 2>&1
"$venv_path/bin/python3" -m pip install -q --upgrade pip wheel setuptools

sudo chown -R $username: "/home/$username/$folder_name"

# ---------------------------------------------------------------------------
# gevent / greenlet handling
# (Odoo's pinned versions have no wheels for newer Python and gevent 24.x needs
#  greenlet >= 3.1.1, so we install compatible ones first and drop the pins)
# ---------------------------------------------------------------------------
py_minor=$("$venv_path/bin/python3" -c 'import sys; print(sys.version_info.minor)')

if [[ "$py_minor" -ge 10 ]]; then
  if [[ "$py_minor" -ge 12 || "$odoo_version" == 18* || "$odoo_version" == 19* || "$odoo_version" == 20* ]]; then
    "$venv_path/bin/pip" install -q "gevent==24.10.3" "greenlet>=3.1.1" --only-binary=:all:
    sed -i '/gevent/d;/greenlet/d' requirements.txt
  else
    if ! "$venv_path/bin/pip" install -q gevent==21.12.0 --only-binary=:all: 2>/dev/null; then
      "$venv_path/bin/pip" install -q "gevent==24.10.3" "greenlet>=3.1.1" --only-binary=:all:
    fi
    sed -i '/gevent/d;/greenlet/d' requirements.txt
  fi
fi

# Install Python requirements
if ! "$venv_path/bin/python3" -m pip install -q -r requirements.txt > /dev/null; then
  echo "Failed to install Python requirements. Please check the errors above."
  exit 1
fi

# Build addons_path (enterprise path is added only if Enterprise was selected)
addons_path="/home/$username/$folder_name/odoo/addons,/home/$username/$folder_name/odoo/odoo/addons"
if [[ "$install_enterprise" =~ ^[Yy]$ ]]; then
  addons_path="/home/$username/$folder_name/odoo_enterprise,$addons_path"
fi

# Create odoo.conf
cat <<EOT | sudo tee /home/$username/$folder_name/odoo/odoo.conf > /dev/null
[options]
addons_path = $addons_path
admin_passwd = admin@123
data_dir = /home/$username/.local/share/Odoo
db_host = False
db_name = False
db_password = False
db_port = $pg_port
db_user = False
dbfilter =
http_enable = True
http_interface =
http_port = 8069
EOT

sudo chown $username: /home/$username/$folder_name/odoo/odoo.conf
sudo chmod 640 /home/$username/$folder_name/odoo/odoo.conf

# Final message
echo ""
echo "✅ Odoo $odoo_version installation completed successfully."
echo "To start the server, run:"
echo "$venv_path/bin/python3 /home/$username/$folder_name/odoo/odoo-bin -c /home/$username/$folder_name/odoo/odoo.conf"
