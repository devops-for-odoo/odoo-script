#!/bin/bash

echo "Enter username (firstname.lastname):"
read username

sleep 2

# Function to automatically format or validate the Odoo version
auto_format_version() {
    version=$1
    if [[ "$version" =~ ^[1-9][0-9]*\.[0-9]+$ ]]; then
        echo "Valid Odoo version: $version"
        odoo_version="$version"
    elif [[ "$version" =~ ^[1-9][0-9]*$ ]]; then
        formatted_version="${version}.0"
        echo "Auto-formatted Odoo version: $formatted_version"
        odoo_version="$formatted_version"
    else
        echo "Invalid input. Please enter a valid Odoo version (e.g., 17.0 or 18.0)."
        exit 1
    fi
}

echo "Enter Odoo version (e.g., 17.0 or 18.0):"
read input_version
auto_format_version "$input_version"

sleep 2

echo "Enter folder name:"
read folder_name

sleep 3

while true; do
    echo "Enter the Ubuntu version (e.g., 20.04 or 22.04):"
    read un
    sleep 2
    cd /home/"$username"/ || exit 1

    case $un in
        '20.04'|'20')
            echo "Installing packages for Ubuntu 20.04..."
            sleep 2
            sudo wget https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6-1/wkhtmltox_0.12.6-1.focal_amd64.deb
            sudo dpkg -i wkhtmltox_0.12.6-1.focal_amd64.deb
            sudo apt --fix-broken install -y
            sudo dpkg -i wkhtmltox_0.12.6-1.focal_amd64.deb
            break;;
        '22.04'|'22')
            echo "Installing packages for Ubuntu 22.04..."
            sleep 2
            sudo wget https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-2/wkhtmltox_0.12.6.1-2.jammy_amd64.deb
            sudo dpkg -i wkhtmltox_0.12.6.1-2.jammy_amd64.deb
            sudo apt --fix-broken install -y
            sudo dpkg -i wkhtmltox_0.12.6.1-2.jammy_amd64.deb
            break;;
        *)
            echo "Unsupported Ubuntu version. Please enter 20.04 or 22.04."
    esac
done

sudo add-apt-repository ppa:deadsnakes/ppa -y
sudo apt update
sudo apt-get install -y python3.10 python3.10-dev python3.10-venv
python3.10 --version

sudo apt-get install -y openssh-server fail2ban git
sudo apt-get install -y libxml2-dev libxslt1-dev zlib1g-dev libsasl2-dev libldap2-dev \
build-essential libssl-dev libffi-dev libmysqlclient-dev libjpeg-dev libpq-dev \
libjpeg8-dev liblcms2-dev libblas-dev libatlas-base-dev

sudo apt-get install -y npm
sudo ln -s /usr/bin/nodejs /usr/bin/node || true
sudo npm install -g less less-plugin-clean-css rtlcss
sudo apt-get install -y node-less

sudo apt-get install -y curl ca-certificates gnupg
curl https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo apt-key add -
sudo sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
sudo apt update
sudo apt-get install -y postgresql-16 

sudo su - postgres -c "createuser -eld $username" 2>/dev/null || true
sudo -u postgres psql -c "ALTER USER postgres PASSWORD 'postgres';"

sleep 2
sudo sed -i 's/peer/trust/g' /etc/postgresql/16/main/pg_hba.conf
sudo systemctl restart postgresql.service

mkdir -p /home/"$username"/"$folder_name"
sudo chown -R "$username": /home/"$username"/

cd /home/"$username"/"$folder_name"

# Clone Odoo repositories
sudo git clone https://github.com/odoo/odoo --depth 1 --branch "$odoo_version" --single-branch

# Uncomment if using enterprise
sudo git clone https://bista.devops:glpat-C5dyWKdv49RtXEgVxrdR@git.bistasolutions.com/bistasolutions/odoo_enterprise.git --depth 1 --branch "$odoo_version" --single-branch

sudo chown -R "$username": /home/"$username"/

# Set up virtual environment
cd /home/"$username"/"$folder_name"/
sudo python3.10 -m venv "$odoo_version-venv"
sudo chown -R "$username": /home/"$username"/

cd odoo
/home/"$username"/"$folder_name"/"$odoo_version-venv"/bin/python3 -m pip install wheel
/home/"$username"/"$folder_name"/"$odoo_version-venv"/bin/python3 -m pip install -r requirements.txt

# Create odoo.conf
sudo tee /home/"$username"/"$folder_name"/odoo/odoo.conf > /dev/null <<EOT
[options]
addons_path = /home/$username/$folder_name/odoo_enterprise,/home/$username/$folder_name/odoo/addons,/home/$username/$folder_name/odoo/odoo/addons
admin_passwd = admin@123
data_dir = /home/$username/.local/share/Odoo
db_host = False
db_name = False
db_password = False
db_port = False
db_user = False
dbfilter =
http_enable = True
http_port = 8069
EOT

sudo chmod 640 /home/"$username"/"$folder_name"/odoo/odoo.conf
sudo chown "$username": /home/"$username"/"$folder_name"/odoo/odoo.conf

# Print final command to run Odoo
echo "To start Odoo run:"
echo "/home/$username/$folder_name/$odoo_version-venv/bin/python3 /home/$username/$folder_name/odoo/odoo-bin -c /home/$username/$folder_name/odoo/odoo.conf"
