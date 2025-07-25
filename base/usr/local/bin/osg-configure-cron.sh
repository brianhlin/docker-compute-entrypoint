#!/bin/bash

# Run osg-configure if we detect config changes

echoerr() { printf "%s\n" "$*" >&2; }

if [[ $(ps -eo cmd | grep 'osg-configure -c' | grep -qv grep)  ]]; then
    echoerr "ERROR: osg-configure already running, exiting."
    exit 1
fi

config_dir=/etc/osg/config.d/
configmap_config_dir="/tmp/$config_dir"

# There may be other files dropped into the target dir so we set up a
# temporary staging dir with the combined contents of the target +
# updates from the ConfigMap
staging_config_dir=$(mktemp -d)
rsync -a "$config_dir/" "$staging_config_dir"
rsync -a "$configmap_config_dir/" "$staging_config_dir"

config_checksum=$(sha256sum $config_dir/* | cut -d ' ' -f1 | sha256sum)
staging_config_checksum=$(sha256sum $staging_config_dir/* | cut -d ' ' -f1 | sha256sum)

if [[ $staging_config_checksum == "$config_checksum" ]]; then
    echoerr "No changes detected in $configmap_config_dir, exiting."
    [[ -d "$staging_config_dir" ]] && rm -rf "$staging_config_dir"
    exit 0
fi

# Perform an in-place replacement of the target dir
rsync -a --delete "$staging_config_dir/" "$config_dir/"
osg-configure -c
condor_ce_reconfig
rm -rf "$staging_config_dir"
