#!/bin/bash

# ==============================================================================
# CONFIGURATION
# ==============================================================================
VM_LIST=(
# nom_machine| nb_CPU | taille RAM | user | mdp | disque supplémentaire (0 = non)
    "machine |   1    |    1GiB    | admin | admin | 0"
)

STORAGE_POOL="remote"
NETWORK="default" 
DISK_ROOT="10GiB"
IMAGE=ubuntu:24.04

# Augmenter la patience du cluster
lxc config set cluster.offline_threshold 60

echo "--- Préparation globale ---"
# 1. On télécharge l'image VM UNE SEULE FOIS avant la boucle
if ! lxc image alias list | grep -q "image-ready"; then
    echo "Récupération de l'image VM Ubuntu 24.04 (Opération lourde)..."
    lxc image copy $IMAGE local: --alias image-ready --vm --quiet || { echo "Erreur critique : échec du téléchargement de l'image"; exit 1; }
fi

create_vm() {
    local NAME=$(echo $1 | cut -d'|' -f1 | xargs)
    local CPU=$(echo $1 | cut -d'|' -f2 | xargs)
    local MEM=$(echo $1 | cut -d'|' -f3 | xargs)
    local USER=$(echo $1 | cut -d'|' -f4 | xargs)
    local PASS=$(echo $1 | cut -d'|' -f5 | xargs)
    local EXTRA_DISK=$(echo $1 | cut -d'|' -f6 | xargs)

    echo "--------------------------------------------------------"
    echo "Déploiement de : $NAME"
    echo "--------------------------------------------------------"

    # 2. INITIALISATION
    if ! lxc init image-ready "$NAME" --vm --storage "$STORAGE_POOL" --device root,size="$DISK_ROOT"; then
        echo "ERREUR : Impossible d'initialiser $NAME."
        return
    fi

    # 3. CONFIGURATION DES RESSOURCES
    lxc config set "$NAME" limits.cpu "$CPU"
    lxc config set "$NAME" limits.memory "$MEM"

    # 4. CONFIGURATION CLOUD-INIT
    cat << EOF > cloud-config.yaml
#cloud-config
users:
  - name: $USER
    groups: sudo
    shell: /bin/bash
    sudo: ['ALL=(ALL) NOPASSWD:ALL']
    lock_passwd: false
    passwd: $(openssl passwd -6 "$PASS")
ssh_pwauth: true
EOF
    lxc config set "$NAME" user.user-data - < cloud-config.yaml
    rm cloud-config.yaml

    # 5. ATTACHEMENT RÉSEAU
    lxc network attach "$NETWORK" "$NAME" eth0

    # 6. DISQUE SUPPLÉMENTAIRE
    if [ "$EXTRA_DISK" != "0" ]; then
        echo "Création du disque additionnel de $EXTRA_DISK..."
        lxc storage volume create "$STORAGE_POOL" "vol-$NAME" --type=block size="$EXTRA_DISK"
        lxc config device add "$NAME" extra-disk disk pool="$STORAGE_POOL" source="vol-$NAME"
    fi

    # 7. DÉMARRAGE
    echo "Démarrage de la VM..."
    lxc start "$NAME"
    echo "Attente de stabilisation (10s)..."
    sleep 10
}

for vm_data in "${VM_LIST[@]}"; do
    create_vm "$vm_data"
done

lxc list