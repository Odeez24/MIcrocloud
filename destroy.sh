#!/bin/bash

CONTAINERS=$(echo node{1..3})

for CONTAINER in $CONTAINERS; do
	lxc delete --force $CONTAINER
	echo "Container $CONTAINER deleted"
done

lxc network delete microbr0