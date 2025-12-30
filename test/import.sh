#!/bin/bash
set -e

# ==============================================================================
# CONFIGURATION
# ==============================================================================
NODE_COUNT=3
HOST_STORAGE_POOL="disks"
DISK_REMOTE_SIZE="5GiB"  # Taille réduite pour économiser de l'espace
BACKUP_DIR="."           # Dossier contenant micro1.tar.gz, etc.

# ==============================================================================
# 1. PRÉPARATION DE L'HÔTE
# ==============================================================================
echo "--- 1. Vérification de l'hôte ---"

sudo modprobe kvm_amd 2> /dev/null || sudo modprobe kvm_intel 2> /dev/null
sudo snap refresh lxd --channel=$LXD_CHANNEL 2> /dev/null || sudo snap install lxd --channel=$LXD_CHANNEL
lxd init --auto
lxc network set lxdbr0 ipv4.address 10.1.123.1/24
lxc network set lxdbr0 ipv6.dhcp.stateful true
sudo systemctl restart snap.lxd.daemon

# Création du pool de stockage dédié (100Go pour être large)
lxc storage show $HOST_STORAGE_POOL >/dev/null 2>&1 || {
    echo "Création du pool $HOST_STORAGE_POOL..."
    lxc storage create $HOST_STORAGE_POOL zfs size=100GiB
}

# Création du réseau bridge pour les nœuds
lxc network show microbr0 >/dev/null 2>&1 || {
    echo "Création du réseau microbr0..."
    lxc network create microbr0 ipv4.address=10.0.10.1/24 ipv6.address=none
}

# ==============================================================================
# 2. IMPORTATION DES NŒUDS DU CLUSTER
# ==============================================================================
for i in $(seq 1 $NODE_COUNT); do
    NAME="micro$i"
    FILE="$BACKUP_DIR/$NAME.tar.gz"

    if [ ! -f "$FILE" ]; then
        echo "Erreur : Fichier $FILE non trouvé. Passage au suivant."
        continue
    fi

    echo "--- [ $NAME ] Préparation des volumes ---"
    # On crée les volumes de blocs AVANT l'importation pour valider la config LXD
    lxc storage volume create $HOST_STORAGE_POOL "local$i" --type block || true
    lxc storage volume create $HOST_STORAGE_POOL "remote$i" --type block size=$DISK_REMOTE_SIZE || true

    echo "--- [ $NAME ] Importation sur le pool $HOST_STORAGE_POOL ---"
    lxc delete "$NAME" --force 2>/dev/null || true
    
    # Importation forcée sur le pool 'disks' pour éviter de remplir la partition racine
    lxc import "$FILE" "$NAME" --storage "$HOST_STORAGE_POOL"

    # Ré-attachement explicite par sécurité
    lxc storage volume attach $HOST_STORAGE_POOL "local$i" "$NAME" 2>/dev/null || true
    lxc storage volume attach $HOST_STORAGE_POOL "remote$i" "$NAME" 2>/dev/null || true

    # Configuration réseau (eth1 vers microbr0)
    lxc config device add "$NAME" eth1 nic network=microbr0 2>/dev/null || true

    echo "--- [ $NAME ] Démarrage ---"
    lxc start "$NAME"
done

# ==============================================================================
# 3. ATTENTE DU CLUSTER MICROCLOUD
# ==============================================================================
echo ""
echo "--- Attente du démarrage de MicroCloud dans micro1 ---"

# Attente que la socket LXD réponde à l'intérieur de micro1
until lxc exec micro1 -- lxc info >/dev/null 2>&1; do
    echo "   > Socket LXD non prête dans micro1 (EOF)... attente 5s"
    sleep 5
done

# Attente que le cluster soit ONLINE (tous les nœuds doivent répondre)
echo "--- Vérification de l'état du cluster (Ceph/OVN) ---"
until lxc exec micro1 -- lxc cluster list | grep -q "YES"; do
    echo "   > Le cluster n'est pas encore totalement synchronisé... attente 5s"
    sleep 5
done

# Petit délai supplémentaire pour laisser OVN et Ceph se stabiliser
echo "--- Cluster prêt. Stabilisation finale (15s)... ---"
sleep 15

# ==============================================================================
# 4. DÉPLOIEMENT DES VMS DE PRODUCTION
# ==============================================================================
if [ -f "custom_vm.sh" ]; then
    echo "--- ÉTAPE 4 : Transfert et exécution de custom_vm.sh ---"
    lxc file push custom_vm.sh micro1/root/custom_vm.sh
    lxc exec micro1 -- bash /root/custom_vm.sh
else
    echo "Attention : Fichier custom_vm.sh non trouvé, déploiement ignoré."
fi

echo "=========================================================="
echo " TERMINÉ : Votre infrastructure est restaurée"
echo "=========================================================="
lxc exec micro1 -- lxc list