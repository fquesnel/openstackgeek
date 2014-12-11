#!/bin/bash

swift_file="/home/swift.img"
swift_dev="/dev/loop4"
swift_part="sdb1"
swift_mountpoint="/srv/node/$swift_part"

# Make sure only root can run our script
if [ "$(id -u)" != "0" ]; then
   echo "You need to be 'root' dude." 1>&2
   exit 1
fi

clear

# source the setup file
. ./setuprc

apt-get install -y swift swift-account swift-container swift-object xfsprogs

cat > /etc/swift/swift.conf <<EOF
[swift-hash] # random unique string that can never change (DO NOT LOSE)
swift_hash_path_suffix = MyDogHasFleas
EOF

# ask how big and create loopback file
read -p "Enter the integer amount in gigabytes (min 1G) to use as a loopback file for Swift: " gigabytes
echo;
echo "Creating loopback file of size $gigabytes GB at $swift_file"
gigabytesly=$gigabytes"G"
dd if=/dev/zero of=$swift_file bs=1 count=0 seek=$gigabytesly
echo;

# loop the file up
losetup $swift_dev $swift_file

# format the pseudo device and create mount point
mkfs.xfs $swift_dev
mkdir -p $swift_mountpoint
chown -R swift:swift $swift_mountpoint

# create a rebootable remount of the file
cat > /etc/init.d/swift-setup-backing-file <<EOF
losetup $swift_dev $swift_file
mount $swift_dev $swift_mountpoint
chown -R swift:swift $swift_mountpoint
exit 0
EOF

chmod 755 /etc/init.d/swift-setup-backing-file
ln -s /etc/init.d/swift-setup-backing-file \
    /etc/rc2.d/S10swift-setup-backing-file

# create directories used by Swift
mkdir -p /var/swift/recon
chown -R swift:swift /var/swift/recon
mkdir /home/swift
chown -R swift:swift /home/swift

# install and configure proxy
apt-get install -y swift-proxy memcached python-keystoneclient \
    python-swiftclient python-webob

cat > /etc/swift/proxy-server.conf <<EOF
[DEFAULT]
bind_port = 8080
user = swift

[pipeline:main]
pipeline = healthcheck authtoken keystoneauth proxy-server

[app:proxy-server]
use = egg:swift#proxy
allow_account_management = true
account_autocreate = true

[filter:keystoneauth]
use = egg:swift#keystoneauth
operator_roles = _member_,admin,swiftoperator

[filter:authtoken]
paste.filter_factory = keystoneclient.middleware.auth_token:filter_factory

# Delaying the auth decision is required to support token-less
# usage for anonymous referrers ('.r:*').
delay_auth_decision = true

# cache directory for signing certificate
signing_dir = /home/swift/keystone-signing

# auth_* settings refer to the Keystone server
auth_protocol = http
auth_host = $SG_SERVICE_CONTROLLER_IP
auth_port = 35357

# the service tenant and swift username and password created in Keystone
admin_tenant_name = service
admin_user = swift
admin_password = $SG_SERVICE_PASSWORD

[filter:catch_errors]
use = egg:swift#catch_errors

[filter:healthcheck]
use = egg:swift#healthcheck
EOF

# create rings
pwd_bak=$PWD
cd /etc/swift
swift-ring-builder account.builder create 18 3 1
swift-ring-builder container.builder create 18 3 1
swift-ring-builder object.builder create 18 3 1

swift-ring-builder account.builder add r1z1-127.0.0.1:6002/$swift_part 100
swift-ring-builder container.builder add r1z1-127.0.0.1:6001/$swift_part 100
swift-ring-builder object.builder add r1z1-127.0.0.1:6000/$swift_part 100

swift-ring-builder account.builder rebalance
swift-ring-builder container.builder rebalance
swift-ring-builder object.builder rebalance

chown -R swift:swift /etc/swift
swift-init restart all
cd $pwd_bak

# link Swift with Keystone
. ./stackrc
keystone user-create --name swift --pass $SG_SERVICE_PASSWORD
keystone user-role-add --user swift --tenant service --role admin
keystone service-create --name swift --type object-store \
    --description "OpenStack Object Storage"
keystone endpoint-create \
    --service-id $(keystone service-list | awk '/ object-store / {print $2}') \
    --publicurl "http://$SG_SERVICE_CONTROLLER_IP:8080/v1/AUTH_%(tenant_id)s" \
    --internalurl "http://$SG_SERVICE_CONTROLLER_IP:8080/v1/AUTH_%(tenant_id)s" \
    --adminurl http://$SG_SERVICE_CONTROLLER_IP:8080 --region $KEYSTONE_REGION
