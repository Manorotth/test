#!/bin/bash
###Author : Maxime Bourguignon
###Date : 18/10/2016
###Purpose : this script generate /usr/local/src/repo-snapshots/snapshot.conf 


## Manage temp file for this script 
## !!! BEWARE !!! => you need to have write permission in the current directory, you better run this script as root


## ALL THE RECQUIRED SETTINGS ARE DEFINED IN THE INCLUDE BELOW
if [[ ! -s generate_snapshotconf.settings ]];then
	echo "missing generate_snapshotconf.settings file"
else
	. generate_snapshotconf.settings
fi

###TEMP FILES
BASEDIR=/tmp
TEMP_FILE=$BASEDIR/snapshot_conf_tmpfile_sortfile
TEMP_FILE_MACHINE_TYPE=$BASEDIR/snapshot_conf_tmpfile_machinetype
FINAL_FILE=$BASEDIR/snapshot_conf_tmpfile_finalfile
> $TEMP_FILE
> $FINAL_FILE
> $TEMP_FILE_MACHINE_TYPE

##Manage the different Ubuntu release repo directory
function repo_dir_management_per_release {
local RELEASE_NAME=$1
if [ "$RELEASE_NAME" == "lucid" ]
then
        DISTRIB_DIR="old-releases.ubuntu.com"
elif [ "$RELEASE_NAME" == "oneiric" -o "$RELEASE_NAME" == "precise" -o "$RELEASE_NAME" == "trusty" -o "$RELEASE_NAME" == "xenial" ]
then
        DISTRIB_DIR="archive.ubuntu.com"
fi
}

##Creation of all repo per distrib per release per machine type and per rank
function write_repo_per_release_and_per_machine {
RANK=$1

for MACHINETYPE in ${!DISTRIB_PER_MACHINE[*]}
do
        distrib=${DISTRIB_PER_MACHINE[${MACHINETYPE}]}
        if [ "$distrib" = "ubuntu" ]
        then
		RELEASE_LIST=${UBUNTU_RELEASE_LIST[*]}
		for RELEASE in ${UBUNTU_RELEASE_LIST[*]}
		do
			repo_dir_management_per_release $RELEASE
			case $RANK in
				test)
					SNAPSHOT_DATE=$UBUNTU_DATE_TEST
				;;
				preprod)
					SNAPSHOT_DATE=$UBUNTU_DATE_PREPROD
				;;
				prod)
					SNAPSHOT_DATE=$UBUNTU_DATE_PROD
				;;
			esac
			echo "$distrib/$RELEASE/$RANK/$MACHINETYPE $SNAPSHOT_DIR/$DISTRIB_DIR/$SNAPSHOT_DATE" >> $TEMP_FILE_MACHINE_TYPE
			echo "$distrib/$RELEASE/$RANK $SNAPSHOT_DIR/$DISTRIB_DIR/$SNAPSHOT_DATE" >> $TEMP_FILE
			
		done
        elif [ "$distrib" = "debian" ]
        then
                RELEASE_LIST=${DEBIAN_RELEASE_LIST[*]}
		for RELEASE in ${DEBIAN_RELEASE_LIST[*]}
		do
			DISTRIB_DIR="ftp.fr.debian.org"
			DISTRIB_DIR_SECU="security.debian.org"
			case $RANK in
                                test)
                                        SNAPSHOT_DATE=$DEBIAN_DATE_TEST
                                ;;
                                preprod)
                                        SNAPSHOT_DATE=$DEBIAN_DATE_PREPROD
                                ;;
                                prod)
                                        SNAPSHOT_DATE=$DEBIAN_DATE_PROD
                                ;;
				*)
					echo "unexpected behaviour"
				;;
                        esac

			distrib_secu="debian-security"

			echo "$distrib_secu/$RELEASE/$RANK/$MACHINETYPE $SNAPSHOT_DIR/$DISTRIB_DIR_SECU/$SNAPSHOT_DATE" >> $TEMP_FILE_MACHINE_TYPE
			echo "$distrib/$RELEASE/$RANK/$MACHINETYPE $SNAPSHOT_DIR/$DISTRIB_DIR/$SNAPSHOT_DATE" >> $TEMP_FILE_MACHINE_TYPE
			echo "$distrib_secu/$RELEASE/$RANK $SNAPSHOT_DIR/$DISTRIB_DIR_SECU/$SNAPSHOT_DATE" >> $TEMP_FILE
			echo "$distrib/$RELEASE/$RANK $SNAPSHOT_DIR/$DISTRIB_DIR/$SNAPSHOT_DATE" >> $TEMP_FILE
		done
        else
                echo "$i machine type have an unexpected Linux distribution (should be either debian or ubuntu) : $distrib"
        fi
done
}

##Write the beginning of the snapshot.conf file
function write_beginning_snapshot.conf {
printf "# The default values can be seen in the script itself.
# These are examples on how to override the defaults.
#
# snapshot mode configuration
#
# SNAPSHOT_BASE is where the snapshots will be created. This should
# really be on the same filesystem as the repositories being snapshotted
SNAPSHOT_BASE=/var/spool/apt-mirror/snapshot
# The format for the name of the created snapshot
#SNAPSHOT_NAME=$(date +"%s")
#
# serve mode configuration
#
# all created URLs will start with URL base
# URL_BASE itself will map to the latest snapshot until FREEZE_URL_BASE is set
URL_BASE="mirror"
# the URL to browse all created snapshots
URL_SNAPSHOT="s"

# define various URLs
# The first argument is the URL and the second argument must match the path of the snapshot
# order can matter if the URLs overlap.  E.g. Apache will complain about overlapping Aliases if 2015 comes before 2015/01
# If no path matches the argument, the URL will not be created
#
# In these examples
# 2015-01-01 will map to the latest snapshot on January 1 2015
# 2015/01 will map be latest snapshot in January 2015
# 2015 will map to the latest snapshot in 2015, since it will match any date in 2015
# tip will map to the latest snapshot, since it will match any date until 2100
declare -a URLS=(
"
}


##Write the end of the snapshot.conf file
function write_end_snapshot.conf {
echo "#tip 20"
echo ")"
}


function proceed {
write_repo_per_release_and_per_machine test
write_repo_per_release_and_per_machine preprod
write_repo_per_release_and_per_machine prod
}

function apply_to_workdir {
        mv /usr/local/src/repo-snapshots/snapshot.conf /usr/local/src/repo-snapshots/snapshot.conf.backup_$(date '+%Y%m%d')
        cp $FINAL_FILE /usr/local/src/repo-snapshots/snapshot.conf
        chmod 644 /usr/local/src/repo-snapshots/snapshot.conf
        ls -ail /usr/local/src/repo-snapshots/snapshot.conf
}


function main {
write_beginning_snapshot.conf > $FINAL_FILE
proceed
cat $TEMP_FILE_MACHINE_TYPE | sort | uniq >> $FINAL_FILE
cat $TEMP_FILE >> $FINAL_FILE
write_end_snapshot.conf >> $FINAL_FILE
apply_to_workdir
cat $FINAL_FILE
}

main
