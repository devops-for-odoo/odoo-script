#!/bin/bash

# Prompt for username
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

# Ubuntu version
ubuntu_version=$(lsb_release -rs)

# Install Node.js 18
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash - > /dev/null
sudo apt install -y nodejs

# Base dependencies
sudo apt update -qq > /dev/null
sudo apt install -y python3-pip git build-essential \
  libxml2-dev libxslt1-dev zlib1g-dev libsasl2-dev libldap2-dev \
  libssl-dev libffi-dev libjpeg-dev libpq-dev libmysqlclient-dev \
  libjpeg8-dev liblcms2-dev libblas-dev libatlas-base-dev npm curl gnupg ca-certificates > /dev/null

sudo ln -s /usr/bin/nodejs /usr/bin/node 2>/dev/null
sudo npm install -g less less-plugin-clean-css rtlcss > /dev/null
sudo apt install -y node-less openssh-server fail2ban > /dev/null

# wkhtmltopdf
cd /home/$username
if [[ "$ubuntu_version" == "20.04" ]]; then
  sudo wget -q https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6-1/wkhtmltox_0.12.6-1.focal_amd64.deb
  sudo dpkg -i wkhtmltox_0.12.6-1.focal_amd64.deb > /dev/null
elif [[ "$ubuntu_version" == "22.04" ]]; then
  sudo wget -q https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-2/wkhtmltox_0.12.6.1-2.jammy_amd64.deb
  sudo dpkg -i wkhtmltox_0.12.6.1-2.jammy_amd64.deb > /dev/null
fi
sudo apt --fix-broken install -y > /dev/null

# Declare PostgreSQL version flags
install_pg15=false
install_pg17=false

# Odoo version -> Python -> Port -> PG map
declare -A odoo_map=(
  ["14.0"]="python3.7:8014:15"
  ["15.0"]="python3.8:8015:15"
  ["16.0"]="python3.10:8016:17"
  ["17.0"]="python3.10:8017:17"
  ["18.0"]="python3.11:8018:17"
)

# Add deadsnakes PPA
sudo add-apt-repository ppa:deadsnakes/ppa -y > /dev/null
sudo apt-get update -qq > /dev/null

# Determine which PostgreSQL versions are needed
for version in "${!odoo_map[@]}"; do
  pgver=$(echo ${odoo_map[$version]} | cut -d ':' -f3)
  [[ $pgver == "15" ]] && install_pg15=true
  [[ $pgver == "17" ]] && install_pg17=true
done

# Install PostgreSQL keys
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo tee /etc/apt/keyrings/postgresql.gpg > /dev/null
echo "deb [signed-by=/etc/apt/keyrings/postgresql.gpg] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" | sudo tee /etc/apt/sources.list.d/pgdg.list > /dev/null
sudo apt update -qq > /dev/null

# Install PostgreSQL versions as needed
if $install_pg15; then
  sudo apt install -y postgresql-15 > /dev/null
fi
if $install_pg17; then
  sudo apt install -y postgresql-17 > /dev/null
fi

# Configure PostgreSQL 15 and/or 17
for pgver in 15 17; do
  if [[ -d "/etc/postgresql/$pgver" ]]; then
    echo "postgres:postgres" | sudo chpasswd
    sudo su - postgres -c "createuser -s $username" 2>/dev/null || true
    sudo sed -i 's/peer/trust/g' /etc/postgresql/$pgver/main/pg_hba.conf
    sudo systemctl restart postgresql@$pgver-main
  fi
done

# Loop through Odoo versions
for version in "${!odoo_map[@]}"; do
  IFS=":" read python_ver odoo_port pg_version <<< "${odoo_map[$version]}"
  folder_name="odoo-${version}"

  echo "Setting up Odoo $version (Python $python_ver, Port $odoo_port, PostgreSQL $pg_version)..."

  sudo apt-get install -y $python_ver $python_ver-venv $python_ver-dev > /dev/null
  mkdir -p /home/$username/$folder_name
  chown -R $username: /home/$username/$folder_name
  cd /home/$username/$folder_name

  sudo -u $username git clone https://github.com/odoo/odoo --depth 1 --branch $version --single-branch
  venv_path="/home/$username/$folder_name/${version}-venv"
  sudo -u $username $python_ver -m venv "$venv_path"
  "$venv_path/bin/python3" -m pip install wheel > /dev/null

  cd odoo

  if [[ "$version" == "14.0" && "$ubuntu_version" == "22.04" ]]; then
    "$venv_path/bin/pip" install gevent==1.5.0 --only-binary=:all: > /dev/null
  elif [[ "$ubuntu_version" == "22.04" ]]; then
    "$venv_path/bin/pip" install gevent==21.12.0 --only-binary=:all: > /dev/null
  fi

  "$venv_path/bin/python3" -m pip install -r requirements.txt > /dev/null

  cat <<EOT > /home/$username/$folder_name/odoo/odoo.conf
[options]
addons_path = /home/$username/$folder_name/odoo/addons,/home/$username/$folder_name/odoo/odoo/addons
admin_passwd = admin@123
data_dir = /home/$username/.local/share/Odoo
db_host = False
db_name = False
db_password = False
db_port = 5432
db_user = False
dbfilter =
http_enable = True
http_port = $odoo_port
EOT

  chown $username: /home/$username/$folder_name/odoo/odoo.conf
  chmod 640 /home/$username/$folder_name/odoo/odoo.conf

  echo "Odoo $version installed at /home/$username/$folder_name."
  echo "Start it with: $venv_path/bin/python3 /home/$username/$folder_name/odoo/odoo-bin -c /home/$username/$folder_name/odoo/odoo.conf"
  echo

done

echo "All requested Odoo versions have been installed."
