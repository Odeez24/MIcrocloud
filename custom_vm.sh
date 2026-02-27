#!/bin/bash

# ==============================================================================
# CONFIGURATION
# ==============================================================================
CONFIG_FILE="/root/vms.yaml"
STORAGE_POOL="remote"
NETWORK="default" 
DISK_ROOT="10GiB"

# Vérifier si yq est installé, sinon l'installer (via snap)
if ! command -v yq &> /dev/null; then
    echo "Installation de yq..."
    apt install yq -y
fi

# Augmenter la patience du cluster
lxc config set cluster.offline_threshold 60

create_vm() {
    local NAME=$1
    local IMAGE=$2
    local CPU=$3
    local MEM=$4
    local USER=$5
    local PASS=$6
    local EXTRA_DISK=$7

    # Création d'un nom d'alias local propre (ex: img-ubuntu-24.04)
    local ALIAS="img-$(echo $IMAGE | tr ':/' '-')"

    echo "--------------------------------------------------------"
    echo "Instance : $NAME | Image : $IMAGE"
    echo "--------------------------------------------------------"

    # 1. GESTION DE L'IMAGE
    # On vérifie si on a déjà une version locale de cette image pour gagner du temps
    if ! lxc image alias list | grep -q "$ALIAS"; then
        echo "Téléchargement de l'image $IMAGE (ceci peut prendre du temps)..."
        if ! lxc image copy "$IMAGE" local: --alias "$ALIAS" --vm --quiet; then
            echo "ERREUR : Impossible de récupérer l'image $IMAGE"
            return
        fi
    fi

    # 2. INITIALISATION
    if ! lxc init "$ALIAS" "$NAME" --vm --storage "$STORAGE_POOL" --device root,size="$DISK_ROOT"; then
        echo "ERREUR : Impossible d'initialiser $NAME."
        return
    fi

    lxc config set "$NAME" limits.cpu "$CPU"
    lxc config set "$NAME" limits.memory "$MEM"

    # CLOUD-INIT
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
network:
  version: 2
  ethernets:
    enp5s0:
      dhcp4: true
EOF
    lxc config set "$NAME" user.user-data - < cloud-config.yaml
    rm cloud-config.yaml

    lxc network attach "$NETWORK" "$NAME" eth0

    if [ "$EXTRA_DISK" != "0" ]; then
        echo "Création du disque additionnel de $EXTRA_DISK..."
        lxc storage volume create "$STORAGE_POOL" "vol-$NAME" --type=block size="$EXTRA_DISK"
        lxc config device add "$NAME" extra-disk disk pool="$STORAGE_POOL" source="vol-$NAME"
    fi

    lxc start "$NAME"
    echo "Démarrage de $NAME lancé."
}

# ==============================================================================
# LECTURE DU FICHIER YAML ET BOUCLE DE CRÉATION
# ==============================================================================
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Erreur : Fichier $CONFIG_FILE introuvable."
    exit 1
fi

yq -r '.vms[] | [.name, .image, .cpu, .memory, .user, .password, .extra_disk] | @tsv' "$CONFIG_FILE" | while IFS=$'\t' read -r name image cpu mem user pass disk; do
    [ -z "$name" ] && continue
    create_vm "$name" "$image" "$cpu" "$mem" "$user" "$pass" "$disk"
done

lxc list