#!/bin/bash
set -e
# ==============================================================================
# CONFIGURATION
# ==============================================================================
NODE_COUNT=3
VM_CPU=2
VM_MEM="2GiB"
LXD_CHANNEL="5.21/stable"
PASSPHRASE="mon-secret-tres-sur-123"

HOST_STORAGE_POOL="disks"
DISK_REMOTE_SIZE="5GiB"

OVN_IPV4_GW="10.0.10.1/24"
OVN_IPV4_RANGE="10.0.10.100-10.0.10.254"
OVN_IPV6_GW="fd42:6a3c:bac1:a22e::1/64"
OVN_DNS_IPV4="10.0.10.1"
OVN_DNS_IPV6="fd42:6a3c:bac1:a22e::1"
# ==============================================================================
# 1. PRÉPARATION HÔTE & VMS
# ==============================================================================
echo "--- 1. Préparation de l'hôte ---"
# sudo modprobe kvm_amd 2> /dev/null || sudo modprobe kvm_intel 2> /dev/null
# sudo snap refresh lxd --channel=$LXD_CHANNEL 2> /dev/null || sudo snap install lxd --channel=$LXD_CHANNEL
# lxd init --auto
# lxc network set lxdbr0 ipv4.address 10.1.123.1/24
# lxc network set lxdbr0 ipv6.address fd42:1:1234:1234::1/64
# lxc network set lxdbr0 ipv6.dhcp.stateful true
# sudo systemctl restart snap.lxd.daemon

lxc storage create $HOST_STORAGE_POOL zfs size=50GiB || true
lxc network create microbr0 ipv4.address=$OVN_IPV4_GW ipv6.address=$OVN_IPV6_GW || true
lxc network set microbr0 ipv4.firewall false  # CORRECTIF : Désactive le pare-feu LXD sur le bridge
lxc network set microbr0 ipv6.firewall false
sudo ip link set microbr0 promisc on  

for i in $(seq 1 $NODE_COUNT); do
    NAME="micro$i"
    echo "--- Création de $NAME ---"
    lxc storage volume create $HOST_STORAGE_POOL "local$i" --type block || true
    lxc storage volume create $HOST_STORAGE_POOL "remote$i" --type block size=$DISK_REMOTE_SIZE || true

    lxc init ubuntu:24.04 "$NAME" --vm \
        --config limits.cpu=$VM_CPU \
        --config limits.memory=$VM_MEM \
        -d eth0,ipv4.address="10.1.123.$((i*10))" 
    lxc storage volume attach disks "local$i" "$NAME"
    lxc storage volume attach disks "remote$i" "$NAME"
    lxc config device add "$NAME" eth1 nic network=microbr0
    lxc config device set "$NAME" eth1 security.mac_filtering false
    lxc config device set "$NAME" eth1 security.ipv4_filtering false
    # Facultatif mais aide à la stabilité :
    lxc config set "$NAME" raw.qemu -- "-cpu host"
    lxc start "$NAME"
done

echo "Attente démarrage VMs (15s)..."
sleep 15

# ==============================================================================
# 2. CONFIGURATION INTERNE
# ==============================================================================
for i in $(seq 1 $NODE_COUNT); do
    NAME="micro$i"
    echo "--- Config interne $NAME ---"
    lxc exec "$NAME" -- apt update > /dev/null
    lxc exec "$NAME" -- apt install ethtool -y > /dev/null
    lxc exec "$NAME" -- ethtool -K enp6s0 tx off rx off 
    lxc exec "$NAME" -- bash -c "cat << EOF > /etc/netplan/99-microcloud.yaml
network:
    version: 2
    ethernets:
        enp6s0: 
            accept-ra: false
            dhcp4: false
            link-local: []
EOF"
    lxc exec "$NAME" -- chmod 0600 /etc/netplan/99-microcloud.yaml
    lxc exec "$NAME" -- netplan apply
    lxc exec "$NAME" -- snap install lxd --channel=$LXD_CHANNEL --cohort="+"
    lxc exec "$NAME" -- snap install microceph --channel=squid/stable --cohort="+"
    lxc exec "$NAME" -- snap install microovn --channel=24.03/stable --cohort="+"
    lxc exec "$NAME" -- snap install microcloud --channel=2/stable --cohort="+"
done

# ==============================================================================
# 3. INITIALISATION NON-INTERACTIVE (PRESEED)
# ==============================================================================
echo "--- 3. Génération et application du preseed MicroCloud ---"

# Création du fichier YAML sur l'hôte
cat << EOF > microcloud-preseed.yaml
initiator_address: 10.1.123.10
session_passphrase: $PASSPHRASE
systems:
- name: micro1
  address: 10.1.123.10
  ovn_uplink_interface: enp6s0
  storage:
    local: { path: /dev/sdb, wipe: true }
    ceph: [ { path: /dev/sdc, wipe: true } ]
- name: micro2
  address: 10.1.123.20
  ovn_uplink_interface: enp6s0
  storage:
    local: { path: /dev/sdb, wipe: true }
    ceph: [ { path: /dev/sdc, wipe: true } ]
- name: micro3
  address: 10.1.123.30
  ovn_uplink_interface: enp6s0
  storage:
    local: { path: /dev/sdb, wipe: true }
    ceph: [ { path: /dev/sdc, wipe: true } ]
ceph:
  cephfs: true
ovn:
  ipv4_gateway: $OVN_IPV4_GW
  ipv4_range: $OVN_IPV4_RANGE
  ipv6_gateway: $OVN_IPV6_GW
  dns_servers: $OVN_DNS_IPV4,$OVN_DNS_IPV6
EOF

# Injection et exécution du preseed sur chaque nœud
for i in $(seq 1 $NODE_COUNT); do
    NAME="micro$i"
    echo "Application du preseed sur $NAME..."
    lxc file push microcloud-preseed.yaml "$NAME/root/preseed.yaml"
    lxc exec "$NAME" -- bash -c "cat /root/preseed.yaml | microcloud preseed" &
done

wait

echo "Finis"