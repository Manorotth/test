#!/usr/bin/env bash
#Author : Olivier Cloirec - 2016
#Maintainer : Maxime Bourguignon


# This script will take snapshots of repositories.  The general use case is to use 
# it in addition to a repository mirror, like apt-mirror. The easiest way to integrate 
# with apt-mirror is to use this script as apt-mirror's postmirror script.
#
# When used with apt-mirror, 
# This script will create a snapshot of the mirrored repositories if anything has changed
# since the last snapshot was created.  The snapshot uses hard links to the mirrored
# repositories, so they use minimal space.
#
# This script can also be run in "serve" mode, which will generate Apache configuration
# to map URLs to the snapshot directories.  There are default URLs created, and other
# URLs can be configured based on snapshot path.
#
#
# KNOWN LIMITATIONS
# apt-mirror must be set to use unlink with the configuration "set unlink 1"
# This script can be run by hand, but the REPO_BASE value MUST be set correctly
# Untested and unlikely to work on directories with a space in the name
# 
# TODO
# make snapshots more generic so non-apt repositories could be used
# work with paths with spaces in them

# directory of script being run
SCRIPT_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )

# set global vars
SYSLOG_TAG=""
LOG_FILE=""
LOCK_FILE=""

# config file for variables
[[ -z "${CONF}" ]] && CONF="${SCRIPT_DIR}/snapshot.conf"
if [[ -n "${CONF}" && -f "${CONF}" && -r "${CONF}" ]]; then
    . ${CONF}
fi

# variables
# postmirror script starts in the mirror directory
#[[ -z "${REPO_BASE}" ]] && REPO_BASE="${PWD}"
# use the apt-mirror HOME
APT_MIRROR_HOME="$( getent passwd "apt-mirror" | cut -d: -f6 )"
[[ -z "${REPO_BASE}" ]] && REPO_BASE="${APT_MIRROR_HOME}/mirror"
# TODO sanity check on REPO_BASE in case run manually
[[ -z "${LOGS_BASE}" ]] && LOGS_BASE="${APT_MIRROR_HOME}/logs"

[[ -z "${SNAPSHOT_BASE}" ]] && SNAPSHOT_BASE=$(readlink -f $REPO_BASE/../snapshot)
# slashes will be directories
[[ -z "${SNAPSHOT_NAME}" ]] && SNAPSHOT_NAME="$(date +"%Y/%m/%d_%H%M")"
# count depth. This helps speed up the finds alot
# strip first and last characters, in case a slash was used, which will mess up the count
SNAPSHOT_NAME_STRIPPED=${SNAPSHOT_NAME:1:-1}
SLASHES=${SNAPSHOT_NAME_STRIPPED//[^\/]}
DEPTH=$((${#SLASHES} + 1))

# serve mode variables
[[ -z "${URL_BASE}" ]] && URL_BASE="mirror"
[[ -z "${URL_SNAPSHOT}" ]] && URL_SNAPSHOT="snapshots"
# URLs are pairs of values that define the URL to serve and the local file system path to match
# If multiple file system paths match, the latest is used
# In the default configuration, tip will match the latest snapshot taken in 2000 through 2099
[[ -z "${URLS}" ]] && declare -a URLS=(tip 20)


function snapshot_apt() {
    # find all apt repositories
    local repos=($(find $REPO_BASE -type d -name dists -print))
    # sanity check
    if [[ ${#repos[@]} -lt 1 ]]; then
        echo "No repos found: ${#repos[@]}"
        exit 1
    fi

    # snapshot each mirror
    for ((i=0; i < ${#repos[@]}; i++))
    do
        # the dists directory needs to be removed from the path
        local repo=$(dirname ${repos[$i]})
        snapshot_apt_repo "${repo}"
    done
}

function snapshot_apt_repo() {
    local repo_path=$1
    # create a directory name based on just the name of the repo
    local snapshot_dir=$(echo $repo_path | sed -e "s#${REPO_BASE}/##" | awk -F'/' '{print $1}')
    # create snapshot_path
    local snapshot_repo_base="${SNAPSHOT_BASE}/${snapshot_dir}"
    local snapshot_path=${snapshot_repo_base}/${SNAPSHOT_NAME}
    echo "Repo base         : $REPO_BASE"
    echo "Repo name         : $repo_path"
    echo "Snapshot base     : $SNAPSHOT_BASE"
    echo "Snapshot dir      : $snapshot_repo_base"
    echo "Snapshot to create: $snapshot_path"
    echo "depth: $DEPTH"


    # take the snapshot
    if [[ -e "${snapshot_path}" ]]; then
        echo "${snapshot_path} already exist, no action performed"
        # TODO what should we do when the snapshot directory exists already?
    else
        # get where the repo really starts
        local src="${repo_path}"
        local dst="${snapshot_path}"

        # sanity check
        if [[ -z "${src}" ]]; then
            echo "ERROR - couldn't find the repo source."
            exit 1
        fi

        if ! [[ -e "${snapshot_repo_base}" ]]; then
            # this is the first snapshot, do it
            echo "first snapshot"
            make_apt_snapshot $src $dst
        else
            # find the last snapshot
            local last_snapshot=$(find "${snapshot_repo_base}" -mindepth $DEPTH -maxdepth $DEPTH -print | sort -n | tail -n 1)
            if [[ -z "${last_snapshot}" ]]; then
                echo "last snapshot not found"
                make_apt_snapshot $src $dst
            else
                # see if the repo is different than last snapshot
                echo "compare ${src} to ${last_snapshot}"
                # Phased upgrades are triggering snapshots every time.  Only snapshot if the packages actually change
                local diff_changes=$(diff -qr "${src}" "${last_snapshot}")
                local diff_changes_count=$(echo "${diff_changes}" | grep -c "/pool")
                if [[ $diff_changes_count -gt 0 ]]; then
                    echo "change"
                    make_apt_snapshot $src $dst "${diff_changes}"
                else
                    echo "no change - snapshot will NOT be created"
                fi
            fi
        fi
    fi
}

function make_apt_snapshot() {
    local src=$1
    local dst=$2

    echo "snapshot ${src} as ${dst}"
    if [[ $dryrun -eq 0 ]]; then
        # use the parent, so when we copy the directory it becomes named the final piece
        mkdir -p "$(dirname ${dst})"
        cp -al "${src}" "${dst}"

        # make it easier to figure out what you're browsing
        cat > ${dst}/snapshot.txt << EOF
	${dst##"${SNAPSHOT_BASE}/"}

	${@:3}
EOF
    fi
}


function main {
snapshot_apt
}

main
