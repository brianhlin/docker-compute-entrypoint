#!/bin/bash

set -x

# save old -e status
if [[ $- = *e* ]]; then
    olde=-e
else
    olde=+e
fi

source /etc/osg/image-init.d/ce-common-startup

[[ ${HOSTED_CE_CONTINUE_ON_ERROR:=false} == 'true' ]] || set -e

BOSCO_KEY=/etc/osg/bosco.key
# Optional SSH certificate
BOSCO_CERT=${BOSCO_KEY}-cert.pub
ENDPOINT_CONFIG=/etc/endpoints.ini
KNOWN_HOSTS=/etc/osg/ssh_known_hosts
SKIP_WN_INSTALL=no

function errexit {
    echo "$1" >&2
    if [[ ${HOSTED_CE_CONTINUE_ON_ERROR:-false} == 'true' ]]; then
        echo "errexit at $(date +'%F %T'); sleeping for 30 minutes to let you debug." >&2
        sleep $(( 60 * 30 ))
    fi
    exit 1
}


function debug_file_contents {
    filename=$1
    echo "Contents of $filename"
    echo "===================="
    cat "$filename"
    echo "===================="
}

function fetch_remote_os_info {
    ruser=$1
    rhost=$2
    ssh -q "$ruser@$rhost" "cat /etc/os-release"
}

# Allow the condor user to run the WN client updater as the local users
function setup_sudo_users {
    users=$1

    CONDOR_SUDO_FILE=/etc/sudoers.d/10-condor-ssh
    # Replace spaces and newlines from sort ouput with commas
    condor_sudo_users=$(tr ' \n' ',' <<< "$users")
    # Remove trailing comma from list of sudo-users
    condor_sudo_users=${condor_sudo_users:0:-1}
    echo "condor ALL = ($condor_sudo_users) NOPASSWD: /usr/bin/update-remote-wn-client-override" \
         > $CONDOR_SUDO_FILE
    chmod 644 $CONDOR_SUDO_FILE
}

setup_user_ssh () {
  remote_user="$1"
  remote_fqdn="$2"
  remote_port="$3"
  extra_config="$4"

  echo "Setting up SSH for user ${remote_user}"
  ssh_dir=$(eval echo "~${remote_user}/.ssh")
  # setup user and SSH dir
  mkdir -p $ssh_dir
  chmod 700 $ssh_dir

  # copy Bosco key
  ssh_key=$ssh_dir/id_rsa
  cp $BOSCO_KEY $ssh_key
  chmod 600 $ssh_key
  # HACK: Symlink the Bosco key to the location expected by
  # bosco_cluster so it doesn't go and try to generate a new one
  ln -s $ssh_key $ssh_dir/bosco_key.rsa

  # copy Bosco certificate
  if [[ -f $BOSCO_CERT ]]; then
      ssh_cert=${ssh_key}-cert.pub
      cp $BOSCO_CERT $ssh_cert
      chmod 600 $ssh_cert
  fi

  # Write user/host stanza to the global SSH config
  cat <<EOF >> /etc/ssh/ssh_config
Match user "$remote_user"
  IdentityFile $ssh_key
  ${extra_config}

EOF

  chown -R "${ruser}": "$ssh_dir"

  # debugging
  ls -l "$ssh_dir"
}

# Install the WN client, CAs, and CRLs on the remote host
# Store logs in /var/log/condor-ce/ to simplify serving logs via Kubernetes
setup_endpoints_ini () {
    echo "Setting up endpoint.ini entry for ${ruser}@$remote_fqdn..."
    remote_os_major_ver=$1
    # The WN client updater uses "remote_dir" for WN client
    # configuration and remote copy. We need the absolute path
    # specifically for fetch-crl
    remote_home_dir=$(ssh -q "${ruser}@$remote_fqdn" pwd)
    # This relies on the tarball-install/23 format (instead of tarball-install/23-main)
    # on the OSG Yum repo
    osg_ver=$(rpm -q osg-release --qf "%{VERSION}")
    # HACK: OSG 23 does not support EL7, force the OSG 3.6 tarball
    # until we get guidance on EL7 support for remote sites (SOFTWARE-5880)
    if [[ $remote_os_major_ver == "7" ]]; then
        osg_ver="3.6"
    fi
    cat <<EOF >> $ENDPOINT_CONFIG
[Endpoint ${RESOURCE_NAME}-${ruser}]
local_user = ${ruser}
remote_host = $remote_fqdn
remote_user = ${ruser}
remote_dir = $remote_home_dir/bosco-osg-wn-client
upstream_url = https://repo.osg-htc.org/tarball-install/${osg_ver}/osg-wn-client-latest.el${remote_os_major_ver}.x86_64.tar.gz
EOF
}

# $REMOTE_HOST needs to be specified in the environment
remote_fqdn=${REMOTE_HOST%:*}
if [[ $REMOTE_HOST =~ :[0-9]+$ ]]; then
    remote_port=${REMOTE_HOST#*:}
else
    remote_port=22
fi

if [[ -f $KNOWN_HOSTS ]]; then
    REMOTE_HOST_KEY=$(cat $KNOWN_HOSTS)
else
    REMOTE_HOST_KEY=`ssh-keyscan -p "$remote_port" "$remote_fqdn"`
fi
[[ -n $REMOTE_HOST_KEY ]] || errexit "Failed to determine host key for $remote_fqdn:$remote_port"

# setup global known hosts
known_hosts=/etc/ssh/ssh_known_hosts
echo "$REMOTE_HOST_KEY" >> "$known_hosts"
debug_file_contents $known_hosts

# SOFTWARE-5650: the htcondor-ce-view package drops config to
# automatically enable it.  Disable it by default at runtime.
# Not all of these configs are marked as such in the RPM.
if [[ ${ENABLE_CE_VIEW:=false} != 'true' ]]; then
    rpm -ql htcondor-ce-view \
        | egrep '(/etc|/usr/share)/condor-ce/config\.d/.*\.conf$' \
        | xargs rm
fi

# Populate the bosco override dir from a Git repo
if [[ -n $BOSCO_GIT_ENDPOINT && -n $BOSCO_DIRECTORY ]]; then
    OVERRIDE_DIR=/etc/condor-ce/bosco_override
    /usr/local/bin/bosco-override-setup.sh "$BOSCO_GIT_ENDPOINT" "$BOSCO_DIRECTORY" /etc/osg/git.key
fi
unset GIT_SSH_COMMAND

users=$(get_mapped_users)
[[ -n $users ]] || errexit "Did not find any HTCondor-CE SCITOKENS user mappings"

# Setup sudoers.d file
setup_sudo_users "$users"

grep -qs '^OSG_GRID="/cvmfs/oasis.opensciencegrid.org/osg-software/osg-wn-client' \
     /var/lib/osg/osg-job-environment*.conf && SKIP_WN_INSTALL=yes

# Enable bosco_cluster debug output
bosco_cluster_opts=(-d )
# Remote site admins set up SSH key access out-of-band
bosco_cluster_opts+=(--copy-ssh-key no)

if [[ -n $OVERRIDE_DIR ]]; then
    if [[ -d $OVERRIDE_DIR ]]; then
        bosco_cluster_opts+=(-o "$OVERRIDE_DIR")
    else
        echo "WARNING: $OVERRIDE_DIR is not a directory. Skipping Bosco override."
    fi
fi

[[ $REMOTE_BOSCO_DIR ]] && bosco_cluster_opts+=(-b "$REMOTE_BOSCO_DIR") \
        || REMOTE_BOSCO_DIR=bosco

# Add the ability for admins to override the default Bosco tarball URL (SOFTWARE-4537)
[[ $BOSCO_TARBALL_URL ]] && bosco_cluster_opts+=(--url "$BOSCO_TARBALL_URL")

# Set up a control master for each rootly SSH connection
# Add a sentinel to simplify awk in ssh-to-login-node
cat <<EOF >> /etc/ssh/ssh_config

Host $remote_fqdn # remote login host
  Port $remote_port
  IdentitiesOnly yes

Match localuser root
  ControlMaster auto
  ControlPath /tmp/cm-%i-%r@%h:%p
  ControlPersist  15m

EOF

# Set up the necessary SSH config for each mapped user
for ruser in $users; do
    # Create new stanza for jump hosts
    if [[ -n $SSH_PROXY_JUMP ]]; then
        if [[ -n $SSH_PROXY_JUMP_USER ]]; then
            extra_ssh_config="Match user \"$ruser\" host \"$remote_fqdn\"
ProxyJump $SSH_PROXY_JUMP_USER@$SSH_PROXY_JUMP"
        else
            extra_ssh_config="Match user \"$ruser\" host \"$remote_fqdn\"
ProxyJump $ruser@$SSH_PROXY_JUMP"
        fi
    fi
    setup_user_ssh "$ruser" "$remote_fqdn" "$remote_port" "$extra_ssh_config"
done

###################
# REMOTE COMMANDS #
###################

test_remote_connect () {
    ssh -vvv "$1@$2" true
}

test_remote_forward_once () {
    # pick a random unprivileged port for remote side; test that a remote
    # port forward back to the local side works.  For the purpose of this
    # test, it doesn't actually matter whether sshd is running locally on
    # port 22, since we are not testing a reverse ssh connection--just the
    # port forward itself.
    local port=$(( RANDOM % 60000 + 1024 ))
    ssh -vvv "$1@$2" -o ExitOnForwardFailure=yes -R $port:localhost:22 true
}

test_remote_forward () {
    # try remote forward with a random port a few times ... we might get
    # unlucky and hit a remote port that is in use (being listened on),
    # but we'd have to be extremely unlucky for this to happen thrice
    retries=0
    until test_remote_forward_once "$1" "$2"; do
        (( ++retries < 3 )) || return 1
    done
}

# We have to pick a user for SSH, may as well be the first one
first_user=$(printf "%s\n" $users | head -n1)

test_remote_connect "$first_user" "$remote_fqdn" ||
    errexit "remote ssh connection to $remote_fqdn:$remote_port failed"

test_remote_forward "$first_user" "$remote_fqdn" ||
    errexit "remote ssh forward from $remote_fqdn failed"

remote_os_info=$(fetch_remote_os_info "$first_user" "$remote_fqdn")
remote_os_ver=$(echo "$remote_os_info" | awk -F '=' '/^VERSION_ID/ {print $2}' | tr -d '"')

# Skip WN client installation for non-RHEL-based remote clusters
[[ $remote_os_info =~ (^|$'\n')ID_LIKE=.*(rhel|centos|fedora) ]] || SKIP_WN_INSTALL=yes

# HACK: By default, Singularity containers don't specify $HOME and
# bosco_cluster needs it
[[ -n $HOME ]] || HOME=/root

for ruser in $users; do
    echo "Installing remote Bosco installation for ${ruser}@$remote_fqdn"
    [[ $SKIP_WN_INSTALL == 'no' ]] && setup_endpoints_ini "${remote_os_ver%%.*}"
    # $REMOTE_BATCH needs to be specified in the environment
    bosco_cluster "${bosco_cluster_opts[@]}" -a "${ruser}@$remote_fqdn" "$REMOTE_BATCH"

    echo "Installing environment files for $ruser@$remote_fqdn..."
    # Copy over environment files to allow for dynamic WN variables (SOFTWARE-4117)
    rsync -av /var/lib/osg/osg-*job-environment.conf \
          "${ruser}@$remote_fqdn:$REMOTE_BOSCO_DIR/glite/etc"
done

if [[ $SKIP_WN_INSTALL == 'no' ]]; then
    echo "Installing remote WN client tarballs..."
    sudo -u condor \
         update-all-remote-wn-clients-override --log-dir /var/log/condor-ce/
else
    echo "SKIP_WNCLIENT = True" > /etc/condor-ce/config.d/50-skip-wnclient-cron.conf
    echo "Skipping remote WN client tarball installation, using CVMFS..."
fi

set $olde
