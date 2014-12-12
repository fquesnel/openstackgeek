#!/bin/bash

server_nic=eth0
server_ip=$(ip addr | grep "$server_nic$" | \
    grep -woE "([0-9]{1,3}.){3}[0-9]{1,3}" | head -n 1)
mysql_password=$(cat /dev/urandom | head -c2048 | md5sum | cut -d' ' -f1)
email=default@email.com
default_region=PA
cinder_space_GB=5
swift_space_GB=5

# Make sure only root can run our script
if [ "$(id -u)" != "0" ]; then
   echo "You need to be 'root' dude." 1>&2
   exit 1
fi

./openstack_disable_tracking.sh

./openstack_networking.sh

./openstack_server_test.sh

./openstack_system_update.sh

./openstack_setup.sh <<EOF
$server_ip
y
$mysql_password
$email
$default_region
n
EOF

apt-get install debconf-utils
export DEBIAN_FRONTEND=noninteractive
debconf-set-selections <<< "mysql-server mysql-server/root_password password $mysql_password"
debconf-set-selections <<< "mysql-server mysql-server/root_password_again password $mysql_password"
sed -i "s/MY_SQL_PASSWORD/$mysql_password/" openstack_all_in_one_helper.sh
sed -i 's/mysql_secure_installation/. openstack_all_in_one_helper.sh; mysql_secure_installation_helper/' \
    openstack_mysql.sh
sed -i "s/mysql -u root -p <<EOF/mysql -u root --password=$mysql_password <<EOF/" \
    openstack_mysql.sh
./openstack_mysql.sh

./openstack_keystone.sh

./openstack_glance.sh

./openstack_cinder.sh

./openstack_loop.sh <<EOF
$cinder_space_GB
EOF

./openstack_nova.sh

./openstack_swift_loop.sh <<EOF
$swift_space_GB
EOF

./openstack_horizon.sh

if ! /usr/sbin/kvm-ok &> /dev/null
then
    sed -i 's/^libvirt_type=kvm/libvirt_type=qemu/' /etc/nova/nova.conf
    sed -i 's/^virt_type=kvm/virt_type=qemu/' /etc/nova/nova-compute.conf
fi

read -p "Press [Enter] to reboot the machine. "

reboot
