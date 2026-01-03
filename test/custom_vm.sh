#!/bin/bash

# ==============================================================================
# CONFIGURATION
# ==============================================================================
VM_LIST=(
    "web-server   | 1 | 1GiB | adminweb | Password123 | 1GiB"
    "db-server    | 1 | 1GiB | dbauser  | SQLMaster!  | 2GiB"
    "test-machine | 1 | 512MiB | tester   | testpass    | 0"
)

STORAGE_POOL="remote"
NETWORK="default" 
DISK_ROOT="4GiB" # On reste à 4Go car vos disques physiques font 5Go

# Augmenter la patience du cluster
lxc config set cluster.offline_threshold 60

create_vm() {
    local NAME=$(echo $1 | cut -d'|' -f1 | xargs)
    local CPU=$(echo $1 | cut -d'|' -f2 | xargs)
    local MEM=$(echo $1 | cut -d'|' -f3 | xargs)
    local USER=$(echo $1 | cut -d'|' -f4 | xargs)
    local PASS=$(echo $1 | cut -d'|' -f5 | xargs)
    local EXTRA_DISK=$(echo $1 | cut -d'|' -f6 | xargs)

    echo "--------------------------------------------------------"
    echo "Déploiement pas-à-pas de : $NAME"
    echo "--------------------------------------------------------"

    # 1. PRÉPARATION DE L'IMAGE (CORRECTION ICI)
    # On supprime l'éventuelle image "conteneur" qui pollue l'alias
    lxc image delete ubuntu-ready 2>/dev/null || true
    
    echo "  Récupération de l'image VM Ubuntu 24.04 (veuillez patienter)..."
    # Le flag --vm ici est CRUCIAL
    lxc image copy ubuntu:24.04 local: --alias ubuntu-ready --vm --quiet

    # 2. INITIALISATION VIDE
    echo "  Initialisation de la structure VM..."
    if ! lxc init ubuntu-ready "$NAME" --vm --storage "$STORAGE_POOL"; then
        echo "ERREUR : Impossible d'initialiser $NAME."
        return
    fi

    # 3. CONFIGURATION DES RESSOURCES
    echo "  Configuration des ressources de la VM ..."
    lxc config set "$NAME" limits.cpu "$CPU"
    lxc config set "$NAME" limits.memory "$MEM"
    lxc config device override "$NAME" root size="$DISK_ROOT"

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
    echo "  Configuration des information utilisateur de la VM ..."
    lxc config set "$NAME" user.user-data - < cloud-config.yaml
    rm cloud-config.yaml

    echo "  Connexion de l'interface réseau de la VM ..."
    # 5. ATTACHEMENT RÉSEAU
    lxc network attach "$NETWORK" "$NAME" eth0

    # 6. DISQUE SUPPLÉMENTAIRE
    if [ "$EXTRA_DISK" != "0" ]; then
        echo "  Création du disque additionnel de $EXTRA_DISK..."
        lxc storage volume create "$STORAGE_POOL" "vol-$NAME" --type=block size="$EXTRA_DISK"
        lxc config device add "$NAME" extra-disk disk pool="$STORAGE_POOL" source="vol-$NAME"
    fi

    # 7. DÉMARRAGE
    echo "  Démarrage de la VM..."
    lxc start "$NAME"
    echo "  VM $NAME lancée avec succès."
}

for vm_data in "${VM_LIST[@]}"; do
    create_vm "$vm_data"
done

lxc list