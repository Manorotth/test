#!/usr/bin/env bash

# this is a simple wrapper so we can
# run apt-mirror as apt-mirror
# run the serve script as root
#
# unfortunately, the serve script needs root access to configure and restart apache

SCRIPT_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )

# set global vars
SYSLOG_TAG=""
LOG_FILE=""
LOCK_FILE=""
RUN_AS="root"

# config file for variables
[[ -z "${CONF}" ]] && CONF="${SCRIPT_DIR}/apt-mirror-helper.conf"
if [[ -n "$CONF" && -f "$CONF" && -r "$CONF" ]]; then
    . $CONF
fi

# command line options
verbose=0
quiet=0
dryrun=0

function main() {
    args $@
    user_check $@
    lock_check
    setup_output

    trap 'cleanup; exit 1' SIGHUP SIGINT SIGTERM

    # real code starts here
    # run apt-mirror
    sudo -u apt-mirror apt-mirror
    # we could run $SCRIPT_DIR/snapshot.sh -m snapshot
    # but we assume apt-mirror's postmirror script does that


    #Create the snapshot		
    $SCRIPT_DIR/snapshot.sh -m snapshot	
    # update apache
    $SCRIPT_DIR/snapshot.sh -v -m serve

    cleanup
    exit 0
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
    -v  verbose
EOF
    exit 1
}

function args() {
    # getopts requires bash
    while getopts "v" opt
    do
        case "${opt}" in
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
