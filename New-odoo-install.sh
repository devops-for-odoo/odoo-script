#!/bin/bash

# Prompt for user info
echo "Enter username (firstname.lastname):"
read username

# Validate username and home directory
if ! id -u "$username" &>/dev/null; then
  echo "❌ User '$username' does not exist. Exiting."
  exit 1
fi

if [[ ! -d "/home/$username" ]]; then
  echo "❌ Home directory /home/$username does not exist. Exiting."
  exit 1
fi

echo "Enter Odoo version (e.g., 15.0, 16.0, 17.0, or 18.0):"
read odoo_version

echo "Enter Folder Name:"
read folder_name

# Detect existing PostgreSQL installation
if [[ -d /etc/postgresql ]]; then
    pg_detected_version=$(ls /etc/postgresql | sort -nr | head -n1)
    echo "Detected existing PostgreSQL installation in /etc/postgresql (version $pg_detected_version)."
    echo -n "Do you want to continue and (re)install PostgreSQL version $pg_detected_version? (y/n): "
    read continue_pg
    if [[ "$continue_pg" =~ ^[Nn]$ ]]; then
        install_pgsql_flag=false
        pg_version="$pg_detected_version"
    else
        install_pgsql_flag=true
        pg_version="$pg_detected_version"
    fi
else
    echo "No existing PostgreSQL installation detected."
    pg_version="17"
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

# Detect Ubuntu version
ubuntu_version=$(lsb_release -rs)

# Determine Python version
case "$odoo_version" in
  15*) python_package="python3.8" ;;
  16*|17*) python_package="python3.10" ;;
  18*)
    echo "Odoo 18 detected. Installing Python 3.11."
    sudo add-apt-repository ppa:deadsnakes/ppa -y > /dev/null
    sudo apt-get update -qq > /dev/null
    sudo apt-get install -y python3.11 python3.11-venv python3.11-dev > /dev/null
    python_package="python3.11"
    ;;
  *) echo "Unsupported Odoo version: $odoo_version"; exit 1 ;;
esac

# Install dependencies
sudo apt update -qq > /dev/null
sudo apt install -y $python_package $python_package-venv $python_package-dev python3-pip git build-essential \
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
elif [[ "$ubuntu_version" == "22.04" ]]; then
  sudo wget -q https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-2/wkhtmltox_0.12.6.1-2.jammy_amd64.deb
  sudo dpkg -i wkhtmltox_0.12.6.1-2.jammy_amd64.deb > /dev/null
fi
sudo apt --fix-broken install -y > /dev/null

# Install PostgreSQL
if [[ "$install_pgsql_flag" == true ]]; then
  curl -s https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo apt-key add - > /dev/null
  echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" | sudo tee /etc/apt/sources.list.d/pgdg.list > /dev/null
  sudo apt update -qq > /dev/null
  sudo apt install -y postgresql-$pg_version > /dev/null
fi

# Configure PostgreSQL

# Set system password for 'postgres' Linux user
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
sudo -u $username $python_package -m venv "$venv_path"
sudo chown -R $username: "/home/$username/$folder_name"

"$venv_path/bin/python3" -m pip install wheel > /dev/null

# Patch gevent
if [[ "$ubuntu_version" == "22.04" ]]; then
  echo "# gevent==1.5.0 ; sys_platform != 'win32' and python_version == '3.7'" >> requirements.txt
  echo "# gevent==20.9.0 ; sys_platform != 'win32' and python_version > '3.7' and python_version <= '3.9'" >> requirements.txt
  echo "# gevent==21.8.0 ; sys_platform != 'win32' and python_version > '3.9' and python_version < '3.12' # (Jammy)" >> requirements.txt
  "$venv_path/bin/pip" install gevent==21.12.0 --only-binary=:all: > /dev/null
  sed -i '/gevent/d' requirements.txt
fi

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
echo -e "\n✅ Odoo $odoo_version installation completed."
echo "👉 To start the server, run:"
echo "$venv_path/bin/python3 /home/$username/$folder_name/odoo/odoo-bin -c /home/$username/$folder_name/odoo/odoo.conf"
