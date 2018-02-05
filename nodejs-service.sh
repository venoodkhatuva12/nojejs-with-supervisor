#!/bin/bash
#Distro : Linux -Centos, Rhel, and any fedora
#Check whether root user is running the script
if [ "$(id -u)" != "0" ]; then
   echo "This script must be run as root" 1>&2
   exit 1
fi

# Update yum repos.and install development tools
echo "Starting installation of Portal..."
sudo yum update -y
sudo yum groupinstall "Development Tools" -y

# Installing needed dependencies and setting ulimit
echo "updating ulimit to max for all user"
sudo yum install  gcc openssl openssl-devel pcre-devel git unzip wget -y
sudo sed -i '61 i *     soft    nofile  99999' /etc/security/limits.conf
sudo sed -i '62 i *     hard    nofile  99999' /etc/security/limits.conf
sudo sed -i '63 i *     soft    noproc  20000' /etc/security/limits.conf
sudo sed -i '64 i *     hard    noproc  20000' /etc/security/limits.conf
echo "fs.file-max=6816768" >> /etc/sysctl.conf
sudo sysctl -w fs.file-max=6816768
sudo sysctl -p
sudo yum install -y epel-release wget vim nodejs
sudo yum clean all

user_present="`cat /etc/passwd | grep nodeservice | grep -v grep | wc -l`"
  if [ "$user_present" == "1" ]; then
        echo -e "\nUser $user already present No need to create .. "
  else
        adduser nodeservice && sudo sed -i "95 i nodeservice   ALL=(ALL)       ALL" /etc/sudoers
  fi

cd /home/nodeservice
git clone  https://git.com/scm/nodejs-service.git
chown -R nodeservice:nodeservice /home/nodeservice
sudo mkdir /var/log/nodeservice

echo "Installing Supervisord service"
sudo yum install -y supervisor
mv /etc/supervisord.conf /etc/supervisord_conf_old

read -p "what stage you need to use staging or production? " stage
read -p "what region you need to use va or ca ? " region

ipaddr=$(hostname -I)

echo "[unix_http_server]
file=/var/run/supervisor/supervisor.sock   ; (the path to the socket file)

[inet_http_server]         ; inet (TCP) server disabled by default
#port=9001        ; (ip_address:port specifier, *:port for all iface)
#username=root              ; (default is no username (open server))
#password=123456               ; (default is no password (open server))

[supervisord]
logfile = /var/log/supervisor/supervisord.log  ; (main log file;default $CWD/supervisord.log)
loglevel = debug
pidfile = /var/run/supervisord.pid ; (supervisord pidfile;default supervisord.pid)

[rpcinterface:supervisor]
supervisor.rpcinterface_factory = supervisor.rpcinterface:make_main_rpcinterface

[supervisorctl]
serverurl = http://127.0.0.1:9001 ; use an http:// url to specify an inet socket

[include]
files = /etc/supervisor/conf.d/*.conf

[program:atlas-vpn-service]
process_name = $ipaddr
directory = /home/nodeservice/nodejs-service
command = node /home/nodeservice/nodejs-servicee/application.js
autostart = true
autorestart = true
environment=NODE_ENV=<$stage>,NODE_REGION=<$region>
stderr_logfile = /var/log/nodeservice/nodejs-service.err.log
stdout_logfile = /var/log/nodeservice/nodejs-servicee.out.log
user = nodeservice" >> /etc/supervisord.d/nodejs-service.conf

sudo systemctl enable supervisord && sudo systemctl start supervisord


#Syslog-ng nodejs supervisor installtaion starts from here
echo "installing syslog-ng"
sudo yum install syslog-ng syslog-ng-libdbi -y

if [ "$region" =="va" ]
then
    net=10.1.1.10
elif [ "region" = "ca" ]
then
    net=10.1.2.10
else
    read -p "Please enter ip for syslog collector ? :" net
fi

echo '@version: 3.5
source atlas_vpn_service {
    file("/var/log/nodeservice/nodejs-service.err.log" follow-freq(1)); };
destination atlas_err { network("$net" transport("tcp") port(5048)); };
filter f_atlas { level(debug,info,notice,warn) and
                        not facility(auth,authpriv); };
log { source(atlas_vpn_service); filter(f_atlas); destination(atlas_err); };' >> /etc/syslog-ng/conf.d/nodejs-service.conf

echo "Installing nginx with selfsigned certificate"
sudo yum install nginx -y

echo "Generating an SSL private key to sign your certificate..."
openssl genrsa -des3 -out myssl.key 1024

echo "Generating a Certificate Signing Request..."
openssl req -new -key myssl.key -out myssl.csr

echo "Removing passphrase from key (for nginx)..."
cp myssl.key myssl.key.org
openssl rsa -in myssl.key.org -out myssl.key
rm myssl.key.org

echo "Generating certificate..."
openssl x509 -req -days 365 -in myssl.csr -signkey myssl.key -out myssl.crt

echo "Copying certificate (myssl.crt) to /etc/ssl/certs/"
mkdir -p  /etc/ssl/certs
cp myssl.crt /etc/ssl/certs/

echo "Copying key (myssl.key) to /etc/ssl/private/"
mkdir -p  /etc/ssl/private
cp myssl.key /etc/ssl/private/

read -p "whats the domain name ? :" srv_name

echo 'server {
 listen 443 ssl;
 server_name $srv_name;
 ssl_certificate /etc/ssl/certs/ssl.crt;
 ssl_certificate_key /etc/ssl/private/myssl.key;
 location / {
 proxy_read_timeout 120;
 proxy_pass http://127.0.0.1:9001;
 proxy_set_header X-Real-IP $remote_addr;
 proxy_set_header X-Forwarded-Proto https;
 proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
 proxy_set_header Host $http_host;
 proxy_set_header Host $host;
 }
 }' >> /etc/nginx/conf.d/supervisor.conf
 
 sudo systemctl start nginx.service && sudo systemctl enable nginx.service

#Setting up filewall rules
echo "Iptables Update"
sudo firewall-cmd --zone=public --add-port=1812/udp --permanent
echo "Radius 1812 UDP Firewall Rule Added"
sudo firewall-cmd --zone=public --add-port=9001/tcp --permanent
echo "Supervisor 9001 TCP Firewall Rule Added"
sudo firewall-cmd --zone=public --add-port=22/tcp --permanent
