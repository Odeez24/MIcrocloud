#!/bin/bash
# Supprime toute l'infrastructure créée par le script de déploiement

NODE_COUNT=3
HOST_STORAGE_POOL="disks"

echo "--- Suppression des instances ---"
for i in $(seq 1 $NODE_COUNT); do
    lxc delete -f "micro$i" || true
done

echo "--- Suppression des volumes de stockage ---"
for i in $(seq 1 $NODE_COUNT); do
    lxc storage volume delete $HOST_STORAGE_POOL "local$i" || true
    lxc storage volume delete $HOST_STORAGE_POOL "remote$i" || true
done

echo "--- Suppression du pool et du réseau ---"
lxc storage delete $HOST_STORAGE_POOL || true
lxc network delete microbr0 || true

# sudo snap remove lxd --purge

echo "Nettoyage terminé."