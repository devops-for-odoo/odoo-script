#!/bin/bash
echo "Enter username(firstname.lastname):"
read username

sleep 2


# Function to automatically format or validate the Odoo version
auto_format_version() {
    version=$1
    # Check if the version is already in the correct format (e.g., 17.0, 18.0)
    if [[ "$version" =~ ^[1-9][0-9]*\.[0-9]+$ ]]; then
        echo "Valid Odoo version: $version"
    # If the version doesn't have a decimal, add ".0"
    elif [[ "$version" =~ ^[1-9][0-9]*$ ]]; then
        formatted_version="${version}.0"
        echo "Auto-formatted Odoo version: $formatted_version"
    else
        echo "Invalid input. Please enter a valid Odoo version (e.g., 17.0 or 18.0)."
    fi
}

# Prompt the user to enter the Odoo version
echo "Enter odoo_version (eg: 17.0 or 18.0):"
read odoo_version

# Call the function to format or validate the entered version
auto_format_version "$odoo_version"
sleep 2


echo "Enter Folder Name:"
read folder_name

sleep 3


while true; do
#read -p "Enter the Ubuntu version:" un
echo "Enter the Ubuntu version (eg:20.04 OR 22.04):"
read un

sleep 2

cd /home/$username/ 



case $un in '20.04'|'20' ) echo ok, Installing packages for ubuntu '20.04'......;
sleep 3
sudo wget https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6-1/wkhtmltox_0.12.6-1.focal_amd64.deb
sudo dpkg -i wkhtmltox_0.12.6-1.focal_amd64.deb
sudo apt --fix-broken install -y
sudo dpkg -i wkhtmltox_0.12.6-1.focal_amd64.deb
                break;;
        '22'|'22.04' ) echo Ok, Installing packages for ubuntu '22.04'...;
sudo wget https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-2/wkhtmltox_0.12.6.1-2.jammy_amd64.deb
sudo dpkg -i wkhtmltox_0.12.6.1-2.jammy_amd64.deb
sudo apt --fix-broken install -y
sudo dpkg -i wkhtmltox_0.12.6.1-2.jammy_amd64.deb
                break;;
        * ) echo "Unsupported Ubuntu version. Please enter a supported version."
esac

done


sudo add-apt-repository ppa:deadsnakes/ppa -y
sudo apt-get install python3.10  -y
python3.10 --version

sudo apt-get install -y openssh-server fail2ban

sudo apt-get install -y python3.10-dev  python3.10-venv git

sudo apt-get install -y python-dev python3-dev python3.10-dev python3-venv python3.10-venv libxml2-dev libxslt1-dev zlib1g-dev libsasl2-dev libldap2-dev build-essential libssl-dev libffi-dev libmysqlclient-dev libjpeg-dev libpq-dev libjpeg8-dev liblcms2-dev libblas-dev libatlas-base-dev

sudo apt-get install -y npm
sudo ln -s /usr/bin/nodejs /usr/bin/node
sudo npm install -g less         less-plugin-clean-css
sudo apt-get install -y node-less
sudo npm install -g rtlcss

sudo wget https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6-1/wkhtmltox_0.12.6-1.focal_amd64.deb
sudo dpkg -i wkhtmltox_0.12.6-1.focal_amd64.deb

sudo apt --fix-broken install -y

sudo apt-get install curl ca-certificates gnupg
curl https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo apt-key add -
sudo sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
sudo apt-get update
sudo apt-get install -y postgresql-16 
sudo su - postgres -c "createuser -eld  $username" 2> /dev/null || true
sudo -u postgres psql -c "ALTER USER postgres PASSWORD 'postgres';"


#createuser --createdb --username postgres --no-createrole --no-superuser --pwprompt $username
sleep 2 
cd /etc/postgresql/15/main/;
sudo sed -i 's/peer/trust/g' pg_hb.conf ;
sleep 2
sudo systemctl restart postgresql.service ;

#sudo su - postgres "psql -c 'CREATE ROLE "$username" WITH LOGIN'";;
#sudo su - postgres "psql -c 'ALTER USER "$username" WITH SUPERUSER CREATEDB'";;

sleep 2
cd /home/$username/
sudo mkdir /home/$username/$folder_name
sudo chown -R $username: /home/$username/
cd $folder_name

#clone odoo reosetory from git
sudo git clone https://www.github.com/odoo/odoo --depth 1 --branch $odoo_version --single-branch



##### For enterprise Version Uncomment the below line ####

sudo git clone  https://bista.devops:glpat-C5dyWKdv49RtXEgVxrdR@git.bistasolutions.com/bistasolutions/odoo_enterprise.git --depth 1 --branch $odoo_version --single-branch

 
sleep 3

sudo chown -R $username: /home/$username/
sleep 2

cd /home/$username/$folder_name/odoo/
sleep 2
sudo apt insatll -y python3.10-venv 

cd /home/$username/$folder_name/
sudo python3.10 -m venv 18.0-venv
sudo chown -R $username: /home/$username/
cd odoo
/home/$username/$folder_name/18.0-venv/bin/python3 -m pip install wheel
/home/$username/$folder_name/18.0-venv/bin/python3 -m pip install -r requirements.txt


sleep 3

#configuring odoo.conf file
sudo touch /home/$username/$folder_name/odoo/odoo.conf
sleep 3
sudo chown -R $username: /home/$username/
sleep 3
sudo cat <<EOT > /home/$username/$folder_name/odoo/odoo.conf
[options]
addons_path = /home/$username/$folder_name/odoo_enterprise,/home/$username/$folder_name/odoo/addons,/home/$username/$folder_name/odoo/odoo/addons
#addons_path = /home/$username/$folder_name/odoo/addons,/home/$username/$folder_name/odoo/odoo/addons
admin_passwd = admin@123
data_dir = /home/$username/.local/share/Odoo
db_host = False
db_name = False
db_password = False
db_port = False
db_user = False
dbfilter =
http_enable = True
http_interface =
http_port = 8069
EOT
sleep 3

sudo chown $username: /home/$username/$folder_name/odoo/odoo.conf
sudo chmod 640 /home/$username/$folder_name/odoo/odoo.conf

cd /home/$username/$folder_name/odoo/

############
#start the odoo server

sleep 3


print  "/home/$username/$folder_name/18.0-venv/bin/python3 /home/$username/$folder_name/odoo/odoo-bin -c /home/$username/$folder_name/odoo/odoo.conf"

/home/$username/$folder_name/$folder_name/18.0-venv/bin/python3 /home/$username/$folder_name/odoo/odoo-bin -c /home/$username/$folder_name/odoo/odoo.conf
