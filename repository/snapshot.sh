#!/usr/bin/env bash

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


# poor man's enum
snapshot_mode=0
serve_mode=1
apache22_mode=0
apache24_mode=1

# command line options
verbose=0
quiet=0
dryrun=0
mode=$snapshot_mode

function main() {
    args $@
    user_check $@
    lock_check
    setup_output

    trap 'cleanup; exit 1' SIGHUP SIGINT SIGTERM

    # real code starts here
    if [[ $mode -eq $snapshot_mode ]]; then
        snapshot
    elif [[ $mode -eq $serve_mode ]]; then
        serve
    fi

    cleanup
    exit 0
}

function snapshot() {
    snapshot_apt
}

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
    local snapshot_dir=$(echo $repo_path | sed -e "s#${REPO_BASE}/##" -e "s#/#_#g")
    # create snapshot_path
    local snapshot_repo_base="${SNAPSHOT_BASE}/${snapshot_dir}"
    local snapshot_path=${snapshot_repo_base}/${SNAPSHOT_NAME}
    vecho "Repo base         : $REPO_BASE"
    vecho "Repo name         : $repo_path"
    vecho "Snapshot base     : $SNAPSHOT_BASE"
    vecho "Snapshot dir      : $snapshot_repo_base"
    vecho "Snapshot to create: $snapshot_path"
    vvecho "depth: $DEPTH"


    # take the snapshot
    if [[ -e "${snapshot_path}" ]]; then
        :
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
            vecho "first snapshot"
            make_apt_snapshot $src $dst
        else
            # find the last snapshot
            local last_snapshot=$(find "${snapshot_repo_base}" -mindepth $DEPTH -maxdepth $DEPTH -print | sort -n | tail -n 1)
            if [[ -z "${last_snapshot}" ]]; then
                vecho "last snapshot not found"
                make_apt_snapshot $src $dst
            else
                # see if the repo is different than last snapshot
                vecho "compare ${src} to ${last_snapshot}"
                # Phased upgrades are triggering snapshots every time.  Only snapshot if the packages actually change
                local diff_changes=$(diff -qr "${src}" "${last_snapshot}")
                local diff_changes_count=$(echo "${diff_changes}" | grep -c "/pool")
                if [[ $diff_changes_count -gt 0 ]]; then
                    vecho "change"
                    make_apt_snapshot $src $dst "${diff_changes}"
                else
                    vecho "no change - snapshot will NOT be created"
                fi
            fi
        fi
    fi
}

function make_apt_snapshot() {
    local src=$1
    local dst=$2

    vecho "snapshot ${src} as ${dst}"
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

function serve() {
    vvecho "serve mode"

    if ! [[ -r ${SNAPSHOT_BASE} ]]; then
        echo "unable to read snapshot base: ${SNAPSHOT_BASE}"
        exit 1
    fi
    configure_web_server
}

function configure_web_server() {
    local apache_sites_base="/etc/apache2/sites-available"
    local apache24_sites_base="/etc/apache2/sites-available"

    if [[ -d "${apache_sites_base}" ]]; then
        # older packages of apache
        # TODO support.  Needs different Allow/Deny config
        configure_apache24 "${apache_sites_base}" $apache22_mode
    elif [[ -d "${apache24_sites_base}" ]]; then
        # newer packages of apache
        configure_apache24 "${apache24_sites_base}" $apache24_mode
    fi
}

function configure_apache24() {
    local sites_base=$1
    local apache_mode=$2

    # apache2 package needed
    if ! [[ -w ${sites_base} ]]; then
        vecho "Apache not installed, not configuring"
        return
    fi

    local sites1=10-repo-snapshots

    if [[ $dryrun -eq 0 ]]; then
        # empty the config
        >${sites_base}/${sites1}.conf
    fi

    cat >>${sites_base}/${sites1}.conf << EOF
<VirtualHost *:80>
    ServerAdmin webmaster@ymagis.net
    ServerName debian.ymagis.net
    DocumentRoot ${REPO_BASE}

EOF

    # map the configured URLs to matching paths
    vvecho ${URLS[@]}
    vvecho ${#URLS[@]}
    # parameters come as a pair of array values
    while [[ ${#URLS[@]} -gt 1 ]]; do
        local url_part="${URLS[0]}"
        local path_match="${URLS[1]}"

        URLS=("${URLS[@]:2}")

        # TODO since we use depth, could we just find all directories?
        # we know each snapshot will have a dists directory
        # add two to depth for the snapshot_dir and dists dir
        local path_full=$(find "${SNAPSHOT_BASE}" -maxdepth $(( $DEPTH + 2 )) -type d -name dists -print | sort -n | grep "${path_match}" | tail -n 1)
        if [[ -n "${path_full}" ]]; then
            path_full=$(dirname ${path_full})
            # generate the specified URL locations configuration
            vecho "URL map /${url_part} to ${path_full}"
            if [[ $dryrun -eq 0 ]]; then
                cat >>${sites_base}/${sites1}.conf << EOF
    Alias /${url_part} ${path_full}
EOF
            fi
        fi
    done

    # order matters to avoid overlapping Alias problem
    # map a URL for all snapshots
    vecho "URL map /${URL_BASE}/${URL_SNAPSHOT} to ${SNAPSHOT_BASE}"
    # map the URL_BASE to the latest SNAPSHOT
    vecho "URL map /${URL_BASE} to ${REPO_BASE}"
    if [[ $dryrun -eq 0 ]]; then
        cat >>${sites_base}/${sites1}.conf << EOF
    # browse all snapshots
    Alias /${URL_BASE}/${URL_SNAPSHOT} ${SNAPSHOT_BASE}
    # browse all repos
    Alias /${URL_BASE} ${REPO_BASE}

    # access
    <Directory ${SNAPSHOT_BASE}>
        Options +Indexes +MultiViews
        Require all granted
    </Directory>
    <Directory ${REPO_BASE}>
        Options +Indexes +MultiViews
        Require all granted
    </Directory>

    ErrorLog ${LOGS_BASE}/repository_error.log
    CustomLog ${LOGS_BASE}/repository_access.log combined
    LogLevel warn
    ServerSignature Off
</VirtualHost>
EOF
        a2ensite $sites1
        service apache2 reload
    fi
}

########### standard functions below ###########

function vecho() {
    [[ ${verbose} -ge 1 ]] && echo "$@"
}

function vvecho() {
    [[ ${verbose} -ge 2 ]] && echo "$@"
}

function vvvecho() {
    [[ ${verbose} -ge 3 ]] && echo "$@"
}

function usage() {
    cat >&2 << EOF
usage: $0
    -m  [snapshot|serve] script mode.  Defaults to snapshot
    -d  dryrun
    -v  verbose
EOF
    exit 1
}

function args() {
    # getopts requires bash
    while getopts "vdm:" opt
    do
        case "${opt}" in
        m)
            vvecho "set mode to: ${OPTARG}"
            if [[ "${OPTARG}" == "serve" ]]; then
               mode=$serve_mode
               RUN_AS="root"
               # a2ensite may not be on default path
               PATH="${PATH}:/usr/sbin"
            elif [[ "${OPTARG}" == "snapshot" ]]; then
               mode=$snapshot_mode
               RUN_AS=""
            else
                usage
            fi 
            ;;
        d)
            dryrun=$((dryrun + 1))
            ;;
        v)
            verbose=$((verbose + 1))
            if [[ $verbose -ge 4 ]]; then
                set -x
            fi
            ;;
        \?) # unknown flag
            usage 
            ;;
        esac
    done
}

function user_check() {
    if [[ -z "${RUN_AS}" ]]; then
        return 0
    fi

    # ignore on dryrun
    if [[ $dryrun -gt 0 ]]; then
        return 0
    fi

    RUN_AS_UID=$(/usr/bin/id -u ${RUN_AS})
    if [[ -z "$RUN_AS_UID" ]]; then
        local msg="Failing.  Can't run as ${RUN_AS}"
        echo >&2 ${msg}
        cleanup
        exit 1
    fi
    if [[ ${EUID} -eq 0 && ${RUN_AS_UID} -ne 0 ]]; then
        echo >&2 "relaunching as ${RUN_AS}"
        /usr/bin/sudo -E -u ${RUN_AS} $0 $@
        cleanup
        exit $?
    elif [[ ${EUID} -ne ${RUN_AS_UID} ]]; then
        local msg="Run script as ${RUN_AS}"
        echo >&2 ${msg}
        cleanup
        exit 1
    fi
}

function setup_output() {
    # we can send stdout and stderr to a logfile
    if [[ -n "${LOG_FILE}" ]]; then
        mkdir -p $(dirname ${LOG_FILE})
        exec 1> >(tee -a ${LOG_FILE})
        exec 2>&1
    fi

    # we can send stdout and stderr to syslog
    if [[ -n "${SYSLOG_TAG}" ]]; then
        exec 1> >(tee >(logger -t ${SYSLOG_TAG}))
        exec 2>&1
    fi

    # Apache logs
    mkdir -p ${LOGS_BASE}
}

function lock_check() {
    # flock or lockfile-progs should be used for critical scenarios
    if [[ -z "${LOCK_FILE}" ]]; then
        return 0
    fi

    if ( set -o noclobber; echo "$$" > "${LOCK_FILE}") 2> /dev/null; then
        # critical-section BK: (the protected bit)
        return 0
    else
        echo >&2 "lockfile exists: ${LOCK_FILE}"
        exit 1
    fi
}

function cleanup() {
    if [[ -n "${LOCK_FILE}" ]]; then
        rm -f ${LOCK_FILE}
    fi
}

main $@
