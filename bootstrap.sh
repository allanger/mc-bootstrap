#!/usr/bin/env bash


echo "Oi! We're gonna bootstrap a new cluster now"
cat << EOF 
It's gonna run kubectl apply and stuff
Make sure you're not connected to real clusters
Currently it's $(kubectl config current-context)

EOF
while true; do
    read -p "Are you sure you want to continue? " yn
    case $yn in
         yes) break;;
        * ) echo "Please answer yes or no." and exit 1;;
    esac
done

# ---------------------------------------------------------------------
# Well, let's start with namespaces
# We'll create them and then later we gonna pass it over to flux
# I'm using helm to manage namespaces, but kustomize is also possible
# Helm release will be installed to the default namespace
# ---------------------------------------------------------------------
# Prepare the environment
rm -rf k8s-config
git clone git@github.com:allanger/k8s-config.git
source .env

helmfile -l name=namespaces apply
kubectl get namespaces

# ---------------------------------------------------------------------
# Then we'll have to prepare the system stuff, like CNI and CoreDNS.
# I guess it also will make sense to manage it with flux later, but I'm not sure
# But I'll have to skip it for now, because I need to understand it a bit better first
# 
# ---------------------------------------------------------------------

helmfile apply -l name=flux-giantswarm -e aws
helmfile sync -l name=root
