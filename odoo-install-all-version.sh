sudo cat odoo-script/odoo-install-all-version.sh 
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

# Prompt for Enterprise
echo "Do you want to install the Odoo Enterprise source code? (y/n):"
read install_enterprise
if [[ "$install_enterprise" =~ ^[Yy]$ ]]; then
    echo "Enter Git Username for Enterprise Repo (e.g., bista.devops):"
    read git_user
    echo "Enter Git Token for Enterprise Repo (input will be hidden):"
    read -s git_token
fi

# Ubuntu version
ubuntu_version=$(lsb_release -rs)

# Clean, fix packages
sudo apt-get clean
sudo apt-get update -y
sudo apt-get --fix-broken install -y

# Install required compilers and headers
sudo apt-get install -y build-essential gcc g++ make python3-dev libffi-dev libssl-dev libjpeg-dev libpq-dev libxml2-dev libxslt1-dev zlib1g-dev libsasl2-dev libldap2-dev > /dev/null

# Install Node.js 18
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash - > /dev/null
sudo apt-get install -y nodejs

# Additional dependencies
sudo apt-get install -y libjpeg8-dev liblcms2-dev libblas-dev libatlas-base-dev npm curl gnupg ca-certificates xfonts-75dpi > /dev/null
sudo ln -s /usr/bin/nodejs /usr/bin/node 2>/dev/null
sudo npm install -g less less-plugin-clean-css rtlcss > /dev/null
sudo apt-get install -y node-less openssh-server fail2ban > /dev/null

# wkhtmltopdf
cd /home/$username
if [[ "$ubuntu_version" == "22.04" ]]; then
  sudo wget -q https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-2/wkhtmltox_0.12.6.1-2.jammy_amd64.deb
  sudo dpkg -i wkhtmltox_0.12.6.1-2.jammy_amd64.deb > /dev/null
  sudo apt-get --fix-broken install -y > /dev/null
fi

# PostgreSQL GPG key fix for Ubuntu 22.04
if [[ "$ubuntu_version" == "22.04" ]]; then
  sudo mkdir -p /etc/apt/keyrings
  curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | \
    gpg --dearmor | sudo tee /etc/apt/keyrings/postgresql.gpg > /dev/null
  echo "deb [signed-by=/etc/apt/keyrings/postgresql.gpg] http://apt.postgresql.org/pub/repos/apt jammy-pgdg main" | \
    sudo tee /etc/apt/sources.list.d/pgdg.list > /dev/null
  sudo apt-get update -qq
fi

# Declare versions to install
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

# Add deadsnakes PPA if needed
sudo add-apt-repository -y ppa:deadsnakes/ppa > /dev/null
sudo apt-get update -qq > /dev/null

# Determine PostgreSQL versions to install
for version in "${!odoo_map[@]}"; do
  pgver=$(echo ${odoo_map[$version]} | cut -d ':' -f3)
  [[ $pgver == "15" ]] && install_pg15=true
  [[ $pgver == "17" ]] && install_pg17=true
done

# Install PostgreSQL versions
$install_pg15 && sudo apt-get install -y postgresql-15 > /dev/null
$install_pg17 && sudo apt-get install -y postgresql-17 > /dev/null

# Configure PostgreSQL roles and trust
declare -A pg_ports
for pgver in 15 17; do
  if [[ -d "/etc/postgresql/$pgver" ]]; then
    echo "postgres:postgres" | sudo chpasswd
    sudo su - postgres -c "createuser -s $username" 2>/dev/null || true
    sudo sed -i 's/peer/trust/g' /etc/postgresql/$pgver/main/pg_hba.conf
    sudo systemctl restart postgresql@$pgver-main
    conf_file="/etc/postgresql/$pgver/main/postgresql.conf"
    if [[ -f "$conf_file" ]]; then
      pg_ports[$pgver]=$(awk -F= '/^port/ {gsub(/ /, "", $2); print $2}' "$conf_file")
    else
      pg_ports[$pgver]="5432"
    fi
  fi
done

# Prepare summary file
summary_file="/tmp/odoo-summary.sh"
echo "echo -e \"\n===== Odoo Installation Summary =====\"" > "$summary_file"

# Loop through Odoo versions
for version in "${!odoo_map[@]}"; do
  IFS=":" read python_ver odoo_port pg_version <<< "${odoo_map[$version]}"
  folder_suffix="${version/.0/}"
  folder_name="odoo$folder_suffix"

  echo "Setting up Odoo $version (Python $python_ver, Port $odoo_port, PostgreSQL $pg_version)..."

  sudo apt-get install -y $python_ver $python_ver-venv $python_ver-dev > /dev/null || true
  mkdir -p /home/$username/$folder_name
  chown -R $username: /home/$username/$folder_name
  cd /home/$username/$folder_name

  sudo -u $username git clone https://github.com/odoo/odoo --depth 1 --branch $version --single-branch || continue
  if [[ "$install_enterprise" =~ ^[Yy]$ ]]; then
    sudo -u $username git clone https://$git_user:$git_token@git.bistasolutions.com/bistasolutions/odoo_enterprise.git --depth 1 --branch $version --single-branch || true
  fi

  venv_path="/home/$username/$folder_name/${version}-venv"
  sudo -u $username $python_ver -m venv "$venv_path"
  "$venv_path/bin/python3" -m ensurepip --upgrade
  "$venv_path/bin/python3" -m pip install wheel > /dev/null || continue

  cd odoo || continue

  # Workaround gevent build issue
  cp requirements.txt requirements.txt.bak
  sed -i '/gevent/d' requirements.txt
  "$venv_path/bin/python3" -m pip install -r requirements.txt --prefer-binary > /dev/null || true
  "$venv_path/bin/python3" -m pip install gevent==22.10.2 psycopg2-binary > /dev/null || true

  db_port=${pg_ports[$pg_version]:-5432}

  cat <<EOT > /home/$username/$folder_name/odoo/odoo.conf
[options]
addons_path = /home/$username/$folder_name/odoo/addons,/home/$username/$folder_name/odoo/odoo/addons
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

  chown $username: /home/$username/$folder_name/odoo/odoo.conf
  chmod 640 /home/$username/$folder_name/odoo/odoo.conf

  echo "echo \"Odoo $version installed at /home/$username/$folder_name.\"" >> "$summary_file"
  echo "echo \"Start it with: $venv_path/bin/python3 /home/$username/$folder_name/odoo/odoo-bin -c /home/$username/$folder_name/odoo/odoo.conf\"" >> "$summary_file"
  echo "echo" >> "$summary_file"
done

chmod +x "$summary_file"
"$summary_file"
rm "$summary_file"