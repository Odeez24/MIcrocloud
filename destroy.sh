#!/bin/bash

# 1. Suppression des conteneurs
CONTAINERS=("node1" "node2" "node3")
for CONTAINER in "${CONTAINERS[@]}"; do
    if lxc info "$CONTAINER" >/dev/null 2>&1; then
        lxc delete --force "$CONTAINER"
        echo "Conteneur $CONTAINER supprimé"
    fi
done

# 2. Suppression du réseau
if lxc network show microbr0 >/dev/null 2>&1; then
    lxc network delete microbr0
    echo "Réseau microbr0 supprimé"
fi

# 3. Suppression des volumes (On combine local et remote)
# Correction de la syntaxe pour la liste des volumes
VOLUMES=$(echo local{1..4} remote{1..3})

for VOL in $VOLUMES; do
    # On vérifie si le volume existe avant de tenter de le supprimer
    if lxc storage volume show disks "custom/$VOL" >/dev/null 2>&1; then
        lxc storage volume delete disks "custom/$VOL"
        echo "Volume $VOL supprimé"
    fi
done

# 4. Suppression du pool de stockage
if lxc storage show disks >/dev/null 2>&1; then
    lxc storage delete disks
    echo "Pool de stockage 'disks' supprimé"
fi

echo "Nettoyage terminé."