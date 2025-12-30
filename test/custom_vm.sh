#!/bin/bash

# ==============================================================================
# CONFIGURATION DES MACHINES À CRÉER
# FORMAT: "NOM | CPU | MEM | USER | PASSWORD | EXTRA_DISK_SIZE"
# ==============================================================================
VM_LIST=(
    "web-server   | 2 | 2GiB | adminweb | P@ssword123 | 2GiB"
    "db-server    | 4 | 4GiB | dbauser  | SQLMaster!  | 5GiB"
    "test-machine | 1 | 1GiB | tester   | testpass    | 0"
)

STORAGE_POOL="remote"
NETWORK="default" 
DISK_ROOT="5GiB" # Taille par défaut du disque système

create_vm() {
    # Nettoyage des espaces
    local NAME=$(echo $1 | cut -d'|' -f1 | xargs)
    local CPU=$(echo $1 | cut -d'|' -f2 | xargs)
    local MEM=$(echo $1 | cut -d'|' -f3 | xargs)
    local USER=$(echo $1 | cut -d'|' -f4 | xargs)
    local PASS=$(echo $1 | cut -d'|' -f5 | xargs)
    local EXTRA_DISK=$(echo $1 | cut -d'|' -f6 | xargs)

    echo "--------------------------------------------------------"
    echo "Déploiement de la VM : $NAME"
    echo "--------------------------------------------------------"

    # 1. Génération du Cloud-init
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

    # 2. Création et configuration (On utilise launch directement pour simplifier)
    lxc launch ubuntu:24.04 "$NAME" --vm \
        --network "$NETWORK" \
        --storage "$STORAGE_POOL" \
        --config limits.cpu="$CPU" \
        --config limits.memory="$MEM" \
        --config user.user-data="$(cat cloud-config.yaml)" \
        --device root,size="$DISK_ROOT"

    # 3. Ajout d'un disque supplémentaire si demandé
    if [ "$EXTRA_DISK" != "0" ]; then
        echo "Ajout d'un disque supplémentaire de $EXTRA_DISK..."
        lxc storage volume create "$STORAGE_POOL" "vol-$NAME" --type=block size="$EXTRA_DISK"
        # Correction ici : on utilise 'device add' pour une VM
        lxc config device add "$NAME" extra-disk disk pool="$STORAGE_POOL" source="vol-$NAME"
    fi

    rm cloud-config.yaml
    echo "VM $NAME lancée avec succès."
}

for vm_data in "${VM_LIST[@]}"; do
    create_vm "$vm_data"
done