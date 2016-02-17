#!/bin/bash
set -e

config_network_adapter () {
    local IFACE=$1
    local IPADDR=$2
    local NETMASK=$3
    local ZONE=$4

    cat << EOF > /etc/sysconfig/network-scripts/ifcfg-$IFACE
DEVICE="$IFACE"
NM_CONTROLLED="no"
BOOTPROTO="none"
MTU="1500"
ONBOOT="yes"
IPADDR="$IPADDR"
NETMASK="$NETMASK"
ZONE="$ZONE"
EOF
}

get_interface_ipv4 () {
    local IFACE=$1
    /usr/sbin/ip addr show $IFACE | /usr/bin/sed -n 's/^\s*inet \([0-9.]*\)\/\([0-9]*\)\s* brd \([0-9.]*\).*$/\1 \2 \3/p'
}

set_interface_static_ipv4_from_dhcp () {
    local IFACE=$1
    local ZONE=$2
    local IPADDR
    local PREFIX
    local NETMASK
    local BCAST

    read IPADDR PREFIX BCAST <<< `get_interface_ipv4 $IFACE`
    NETMASK=`/usr/bin/ipcalc -4 --netmask $IPADDR/$PREFIX | /usr/bin/sed -n  's/^\NETMASK=\(.*\).*$/\1/p'`

    config_network_adapter $SSHUSER_HOST $IFACE $IPADDR $NETMASK $ZONE
}

config_ovs_network_adapter () {
    local ADAPTER=$1

    cat << EOF > /etc/sysconfig/network-scripts/ifcfg-$ADAPTER
DEVICE="$ADAPTER"
NM_CONTROLLED="no"
BOOTPROTO="none"
MTU="1500"
ONBOOT="yes"
EOF
}

exec_with_retry () {
    local MAX_RETRIES=$1
    local INTERVAL=$2

    local COUNTER=0
    while [ $COUNTER -lt $MAX_RETRIES ]; do
        local EXIT=0
        eval '${@:3}' || EXIT=$?
        if [ $EXIT -eq 0 ]; then
            return 0
        fi
        let COUNTER=COUNTER+1

        if [ -n "$INTERVAL" ]; then
            sleep $INTERVAL
        fi
    done
    return $EXIT
}

function ovs_bridge_exists() {
    local BRIDGE_NAME=$1
    /usr/bin/ovs-vsctl show | grep "^\s*Bridge $BRIDGE_NAME\$" > /dev/null
}

function rdo_cleanup() {
    yum remove -y mariadb
    yum remove -y "*openstack*" "*nova*" "*neutron*" "*keystone*" "*glance*" "*cinder*" "*swift*" "*heat*" "*rdo-release*"

    rm -rf /etc/yum.repos.d/packstack_* /root/.my.cnf \
    /var/lib/mysql/ /var/lib/glance /var/lib/nova /etc/nova /etc/neutron /etc/swift \
    /srv/node/device*/* /var/lib/cinder/ /etc/rsync.d/frag* \
    /var/cache/swift /var/log/keystone || true

    vgremove -f cinder-volumes || true
}

function generate_ssh_key() {
    local SSH_KEY_PATH=$1
    local SSH_KEY_PATH_PUB="$SSH_KEY_PATH.pub"

    if [ ! -d ~/.ssh ]; then
        /bin/mkdir ~/.ssh
        /bin/chmod 700 ~/.ssh
    fi
    if [ -f "$SSH_KEY_PATH" ]; then
        /bin/rm -f $SSH_KEY_PATH
    fi
    if [ -f "$SSH_KEY_PATH_PUB" ]; then
        /bin/rm -f $SSH_KEY_PATH_PUB
    fi
    /bin/ssh-keygen -t rsa -b 2048 -N '' -C "packstack" -f $SSH_KEY_PATH
    /bin/cat $SSH_KEY_PATH_PUB >> ~/.ssh/authorized_keys
}

function fix_cinder_chap_length() {
    local CINDER_VERSION=`/usr/bin/python -c "from cinder import version; \
        print version.version_info.version"`
    if [ "$CINDER_VERSION" == "2014.2" ]; then
        local VOLUME_UTILS_PATH=`/usr/bin/python -c "import os; \
            from cinder.volume import utils; \
            print os.path.splitext(utils.__file__)[0] + '.py'"`
        /usr/bin/sed -i "s/generate_password(length=20/generate_password(length=16/g" \
            $VOLUME_UTILS_PATH
        /bin/systemctl restart openstack-cinder-volume.service
    fi
}

function fix_cinder_keystone_authtoken() {
    local CINDER_KS_PASSWD=`openstack-config --get packstack-answers.txt general CONFIG_CINDER_KS_PW`
    openstack-config --set /etc/cinder/cinder.conf keystone_authtoken auth_uri http://$HOST_IP:5000
    openstack-config --set /etc/cinder/cinder.conf keystone_authtoken auth_url http://$HOST_IP:35357
    openstack-config --set /etc/cinder/cinder.conf keystone_authtoken username cinder
    openstack-config --set /etc/cinder/cinder.conf keystone_authtoken password $CINDER_KS_PASSWD
    openstack-config --set /etc/cinder/cinder.conf keystone_authtoken identity_uri http://localhost:35357/
    /bin/systemctl restart openstack-cinder-api.service
}

function configure_private_subnet() {
    # PackStack does not handle the private subnet DNS
    local PRIVATE_SUBNET=private_subnet

    if [ "${FIP_RANGE_NAME_SERVERS[@]}" ]; then
        exec_with_retry 5 0 /usr/bin/neutron subnet-update $PRIVATE_SUBNET \
        --dns_nameservers list=true ${FIP_RANGE_NAME_SERVERS[@]}
    fi
}

function configure_public_subnet() {
    # PackStack does not handle the subnet allocation pool range and gateway
    local PUBLIC_SUBNET=public_subnet

    exec_with_retry 5 0 /usr/bin/neutron subnet-update $PUBLIC_SUBNET \
    --allocation-pool start=$FIP_RANGE_START,end=$FIP_RANGE_END

    exec_with_retry 5 0 /usr/bin/neutron subnet-update $PUBLIC_SUBNET \
        --no-gateway

    if [ $FIP_RANGE_GATEWAY ]; then
        exec_with_retry 5 0 /usr/bin/neutron subnet-update $PUBLIC_SUBNET \
        --gateway $FIP_RANGE_GATEWAY
    fi
}

function disable_nova_compute() {
    # Disable nova-compute on this host
    exec_with_retry 5 0 /usr/bin/nova service-disable $(hostname) nova-compute
    /bin/systemctl disable openstack-nova-compute.service
}

function disable_network_manager() {
    /bin/systemctl stop NetworkManager.service
    /bin/systemctl disable NetworkManager.service
    /sbin/service network start
    /sbin/chkconfig network on
}

function enable_horizon_password_retrieve() {
    local LOCAL_SETTINGS_PATH="/usr/share/openstack-dashboard/openstack_dashboard/local/local_settings.py"
    echo "OPENSTACK_ENABLE_PASSWORD_RETRIEVE = True" >> $LOCAL_SETTINGS_PATH
    /bin/systemctl restart httpd.service
}

function remove_httpd_default_site() {
    local HTTPD_DEFAULT_SITE_CONF="/etc/httpd/conf.d/15-default.conf"
    if [ -f $HTTPD_DEFAULT_SITE_CONF ]
    then
        /usr/bin/rm $HTTPD_DEFAULT_SITE_CONF
        /usr/sbin/service httpd restart
    fi
}

rdo_cleanup

if ! /usr/bin/rpm -q epel-release > /dev/null
then
    # TODO the release link version is not reliable and will return a 404 as soon as it gets updated to 7-6
    exec_with_retry 5 0 /usr/bin/rpm -Uvh http://download.fedoraproject.org/pub/epel/7/x86_64/e/epel-release-7-5.noarch.rpm
fi

#disable_network_manager

RDO_RELEASE_RPM_URL=$1
ADMIN_PASSWORD=$2
FIP_RANGE=$3
FIP_RANGE_START=$4
FIP_RANGE_END=$5
FIP_RANGE_GATEWAY=$6
FIP_RANGE_NAME_SERVERS=${@:7}

ANSWER_FILE=packstack-answers.txt
MGMT_IFACE=mgmt-int
DATA_IFACE=data
EXT_IFACE=ext
OVS_DATA_BRIDGE=br-data
OVS_EXT_BRIDGE=br-ex
NTP_HOSTS=0.pool.ntp.org,1.pool.ntp.org,2.pool.ntp.org,3.pool.ntp.org
# NOTE: use the default key path as otherwise packstack asks for the user's
# password when ssh-ing into the localhost
# TODO: check if we can use ssh-add
SSH_KEY_PATH=~/.ssh/id_rsa
MGMT_ZONE=management

set_interface_static_ipv4_from_dhcp $MGMT_IFACE $MGMT_ZONE
/usr/sbin/ifup $MGMT_IFACE
config_ovs_network_adapter $DATA_IFACE
/usr/sbin/ifup $DATA_IFACE
config_ovs_network_adapter $EXT_IFACE
/usr/sbin/ifup $EXT_IFACE

read HOST_IP NETMASK_BITS BCAST  <<< `get_interface_ipv4 $MGMT_IFACE`

exec_with_retry 5 0 /usr/bin/yum update -y

if ! /usr/bin/rpm -q rdo-release > /dev/null
then
    exec_with_retry 5 0 /usr/bin/yum install -y $RDO_RELEASE_RPM_URL
fi

exec_with_retry 5 0 /usr/bin/yum install -y openstack-packstack
exec_with_retry 5 0 /usr/bin/yum install openstack-utils -y

generate_ssh_key $SSH_KEY_PATH

/usr/bin/packstack --gen-answer-file=$ANSWER_FILE

openstack-config --set $ANSWER_FILE general CONFIG_CONTROLLER_HOST $HOST_IP
openstack-config --set $ANSWER_FILE general CONFIG_COMPUTE_HOSTS $HOST_IP
openstack-config --set $ANSWER_FILE general CONFIG_NETWORK_HOSTS $HOST_IP
openstack-config --set $ANSWER_FILE general CONFIG_STORAGE_HOST $HOST_IP
openstack-config --set $ANSWER_FILE general CONFIG_AMQP_HOST $HOST_IP
openstack-config --set $ANSWER_FILE general CONFIG_MARIADB_HOST $HOST_IP
openstack-config --set $ANSWER_FILE general CONFIG_MONGODB_HOST $HOST_IP

openstack-config --set $ANSWER_FILE general CONFIG_USE_EPEL y
openstack-config --set $ANSWER_FILE general CONFIG_HEAT_INSTALL y
#openstack-config --set $ANSWER_FILE general CONFIG_HEAT_CFN_INSTALL y
#openstack-config --set $ANSWER_FILE general CONFIG_HEAT_CLOUDWATCH_INSTALL y

openstack-config --set $ANSWER_FILE general CONFIG_PROVISION_TEMPEST n

openstack-config --set $ANSWER_FILE general CONFIG_CEILOMETER_INSTALL n

openstack-config --set $ANSWER_FILE general CONFIG_NOVA_NETWORK_PUBIF $EXT_IFACE
openstack-config --set $ANSWER_FILE general CONFIG_NEUTRON_ML2_TYPE_DRIVERS vlan
openstack-config --set $ANSWER_FILE general CONFIG_NEUTRON_ML2_TENANT_NETWORK_TYPES vlan
openstack-config --set $ANSWER_FILE general CONFIG_NEUTRON_ML2_MECHANISM_DRIVERS openvswitch,hyperv
openstack-config --set $ANSWER_FILE general CONFIG_NEUTRON_ML2_VLAN_RANGES physnet1:500:2000
openstack-config --set $ANSWER_FILE general CONFIG_NEUTRON_OVS_BRIDGE_MAPPINGS physnet1:$OVS_DATA_BRIDGE
#openstack-config --set $ANSWER_FILE general CONFIG_NEUTRON_OVS_BRIDGE_IFACES $OVS_DATA_BRIDGE:$DATA_IFACE
openstack-config --set $ANSWER_FILE general CONFIG_NTP_SERVERS $NTP_HOSTS

openstack-config --set $ANSWER_FILE general CONFIG_SSH_KEY "$SSH_KEY_PATH.pub"

openstack-config --set $ANSWER_FILE general CONFIG_KEYSTONE_ADMIN_PW "$ADMIN_PASSWORD"
openstack-config --set $ANSWER_FILE general CONFIG_KEYSTONE_DEMO_PW "$ADMIN_PASSWORD"

openstack-config --set $ANSWER_FILE general CONFIG_PROVISION_DEMO_FLOATRANGE $FIP_RANGE

openstack-config --set $ANSWER_FILE general CONFIG_NAGIOS_INSTALL n

exec_with_retry 5 0 /usr/bin/yum install -y openvswitch
/bin/systemctl start openvswitch.service

if ovs_bridge_exists $OVS_DATA_BRIDGE
then
    /usr/bin/ovs-vsctl del-br $OVS_DATA_BRIDGE
fi

/usr/bin/ovs-vsctl add-br $OVS_DATA_BRIDGE
/usr/bin/ovs-vsctl add-port $OVS_DATA_BRIDGE $DATA_IFACE

if ovs_bridge_exists $OVS_EXT_BRIDGE
then
    /usr/bin/ovs-vsctl del-br $OVS_EXT_BRIDGE
fi

/usr/bin/ovs-vsctl add-br $OVS_EXT_BRIDGE
/usr/bin/ovs-vsctl add-port $OVS_EXT_BRIDGE $EXT_IFACE

exec_with_retry 5 0 /usr/bin/yum install -y python-pip
exec_with_retry 5 0 /usr/bin/yum install -y python-netifaces
# TODO: check OpenStack version
exec_with_retry 5 0 /usr/bin/python -m pip install "networking-hyperv>=1.0.0,<2.0.0"

exec_with_retry 10 0 /usr/bin/packstack --answer-file=$ANSWER_FILE

remove_httpd_default_site

source /root/keystonerc_admin

disable_nova_compute
fix_cinder_chap_length
fix_cinder_keystone_authtoken
configure_public_subnet
configure_private_subnet
enable_horizon_password_retrieve

#rpm -Uvh --nodeps https://github.com/cloudbase/horizon-cloudbase/releases/download/v1.0/horizon-cloudbase-theme-2015.1.0-0.noarch.rpm

# TODO: limit access to: -i $MGMT_IFACE
/usr/sbin/iptables -I INPUT -p tcp --dport 3260 -j ACCEPT
/usr/sbin/iptables -I INPUT -p tcp --dport 5672 -j ACCEPT
/usr/sbin/iptables -I INPUT -p tcp --dport 9696 -j ACCEPT
/usr/sbin/iptables -I INPUT -p tcp --dport 9292 -j ACCEPT
/usr/sbin/iptables -I INPUT -p tcp --dport 8776 -j ACCEPT
/usr/sbin/service iptables save

echo "Done!"
