#!/bin/bash

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

echo "Enter Odoo version (13.0, 14.0, 15.0, 16.0, 17.0, 18.0, 19.0):"
read odoo_version

echo "Enter Folder Name:"
read folder_name

# Detect Ubuntu version
ubuntu_version=$(lsb_release -rs)

# PostgreSQL configuration (always version 17)
pg_version="17"
if [[ -d /etc/postgresql/17 ]]; then
    echo "PostgreSQL 17 already installed. Skipping installation."
    install_pgsql_flag=false
else
    echo "PostgreSQL 17 not detected. Will install."
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

echo "Using $python_package for Odoo $odoo_version on Ubuntu $ubuntu_version"

# Install Node.js 18
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash - > /dev/null
sudo apt install -y nodejs

# Install dependencies
sudo apt update -qq > /dev/null
sudo apt install -y $python_package $python_package-venv python3-pip git build-essential \
    libxml2-dev libxslt1-dev zlib1g-dev libsasl2-dev libldap2-dev libssl-dev libffi-dev libjpeg-dev \
    libpq-dev libmysqlclient-dev libjpeg8-dev liblcms2-dev libblas-dev libatlas-base-dev npm curl gnupg ca-certificates > /dev/null

sudo ln -s /usr/bin/nodejs /usr/bin/node 2>/dev/null
sudo npm install -g less less-plugin-clean-css rtlcss > /dev/null
sudo apt install -y node-less openssh-server fail2ban > /dev/null

# wkhtmltopdf
cd /home/$username
if [[ "$ubuntu_version" == "20.04" ]]; then
  sudo wget -q https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6-1/wkhtmltox_0.12.6-1.focal_amd64.deb
  sudo dpkg -i wkhtmltox_0.12.6-1.focal_amd64.deb > /dev/null
elif [[ "$ubuntu_version" == "22.04" || "$ubuntu_version" == "24.04" ]]; then
  sudo wget -q https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-2/wkhtmltox_0.12.6.1-2.jammy_amd64.deb
  sudo dpkg -i wkhtmltox_0.12.6.1-2.jammy_amd64.deb > /dev/null
fi
sudo apt --fix-broken install -y > /dev/null

# Install PostgreSQL 17
if [[ "$install_pgsql_flag" == true ]]; then
  sudo mkdir -p /etc/apt/keyrings
  curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor | sudo tee /etc/apt/keyrings/postgresql.gpg >/dev/null
  echo "deb [signed-by=/etc/apt/keyrings/postgresql.gpg] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" | sudo tee /etc/apt/sources.list.d/pgdg.list >/dev/null

  if ! sudo apt-get update -qq; then
      echo "Failed to update PostgreSQL repo. Retrying with fallback..."
      sudo rm /etc/apt/sources.list.d/pgdg.list
      sudo apt-get update -qq
  fi

  sudo apt-get install -y postgresql-$pg_version
fi

# Configure PostgreSQL
echo "postgres:postgres" | sudo chpasswd
sudo su - postgres -c "createuser -eld $username" 2>/dev/null || true
sudo sed -i 's/peer/trust/g' /etc/postgresql/$pg_version/main/pg_hba.conf
sudo systemctl restart postgresql

# Setup Odoo source
sudo mkdir -p /home/$username/$folder_name
sudo chown -R $username: /home/$username/$folder_name
cd /home/$username/$folder_name
sudo git clone -q https://www.github.com/odoo/odoo --depth 1 --branch $odoo_version --single-branch

if [[ "$install_enterprise" =~ ^[Yy]$ ]]; then
  sudo git clone https://$git_user:$git_token@git.bistasolutions.com/bistasolutions/odoo_enterprise.git --depth 1 --branch $odoo_version --single-branch
fi

cd odoo
venv_path="/home/$username/$folder_name/${odoo_version}-venv"

# Ensure python-venv & pip are installed
sudo apt-get install -y $python_package-venv python3-pip > /dev/null

# Create virtual environment
sudo -u $username $python_package -m venv "$venv_path"

# Ensure pip inside venv
"$venv_path/bin/python3" -m ensurepip --upgrade
"$venv_path/bin/python3" -m pip install --upgrade pip wheel setuptools > /dev/null

sudo chown -R $username: "/home/$username/$folder_name"

# Patch gevent handling (updated for Odoo 19)
if [[ "$ubuntu_version" == "22.04" || "$ubuntu_version" == "24.04" ]]; then
  echo "# gevent==1.5.0 ; sys_platform != 'win32' and python_version == '3.7'" >> requirements.txt
  echo "# gevent==20.9.0 ; sys_platform != 'win32' and python_version > '3.7' and python_version <= '3.9'" >> requirements.txt
  echo "# gevent==21.8.0 ; sys_platform != 'win32' and python_version > '3.9' and python_version < '3.12'" >> requirements.txt

  # Newer Odoo (18+), Python 3.12 → use latest gevent
  if [[ "$odoo_version" == 18* || "$odoo_version" == 19* ]]; then
    "$venv_path/bin/pip" install gevent==24.10.3 --only-binary=:all: > /dev/null
  else
    "$venv_path/bin/pip" install gevent==21.12.0 --only-binary=:all: > /dev/null 2>/dev/null || \
    "$venv_path/bin/pip" install gevent==24.10.3 --only-binary=:all: > /dev/null
  fi

  sed -i '/gevent/d' requirements.txt
fi

# Install Python requirements
"$venv_path/bin/python3" -m pip install -r requirements.txt > /dev/null

# Create odoo.conf
cat <<EOT | sudo tee /home/$username/$folder_name/odoo/odoo.conf > /dev/null
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
