#!/bin/bash
##Maxime Bourguignon 20-10-2016
##This script generate an apache site conf that match vhost aliases with snapshot repo
##The main input is the snapshot .conf file 
##The differents steps (see also main):
# 1/ create a test conf
# 2/ validate it
# 3/ backup prod conf 
# 4/ apply to prod




SCRIPT_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )

# config file for variables
[[ -z "${CONF}" ]] && CONF="${SCRIPT_DIR}/snapshot.conf"
if [[ -n "${CONF}" && -f "${CONF}" && -r "${CONF}" ]]; then
    . ${CONF}
fi


URL_BASE="mirror"

APT_MIRROR_HOME="$( getent passwd "apt-mirror" | cut -d: -f6 )"
[[ -z "${REPO_BASE}" ]] && REPO_BASE="${APT_MIRROR_HOME}/mirror"

[[ -z "${LOGS_BASE}" ]] && LOGS_BASE="${APT_MIRROR_HOME}/logs"

[[ -z "${SNAPSHOT_BASE}" ]] && SNAPSHOT_BASE=$(readlink -f $REPO_BASE/../snapshot)
# slashes will be directories
[[ -z "${SNAPSHOT_NAME}" ]] && SNAPSHOT_NAME="$(date +"%Y/%m/%d_%H%M")"



function configure_apache() {
    local sites_base="/etc/apache2/sites-available"
    local sites1=$1

	> ${sites_base}/${sites1}.conf	

    cat >>${sites_base}/${sites1}.conf << EOF
	<VirtualHost *:8008>
    	ServerAdmin webmaster@ymagis.net
    	ServerName debian.ymagis.net
    	DocumentRoot ${REPO_BASE}

EOF

    while [[ ${#URLS[@]} -gt 1 ]]; do
        local url_part="${URLS[0]}"
        local path_match="${URLS[1]}"

	#echo "Generating  : Alias /${url_part} ${path_match}"
        URLS=("${URLS[@]:2}")

        local path_full=$(find "${SNAPSHOT_BASE}" -maxdepth 5 -type d -name dists -print | sort -n | grep "${path_match}" | tail -n 1)
        if [[ -n "${path_full}" ]]; then
            path_full=$(dirname ${path_full})
            # generate the specified URL locations configuration
                cat >>${sites_base}/${sites1}.conf << EOF
    			Alias /${url_part} ${path_full}
EOF
	echo "generated  : Alias /${url_part} ${path_full}"
        fi
    done

    
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
      
        
}

function validate_apache {
local site=$1
a2ensite $site.conf
service apache2 reload
for i in $(cat /etc/apache2/sites-enabled/$site.conf | grep Alias | awk '{print $2}')
do
	if wget -q --spider http://debian.ymagis.net:8008$i; then
		checkurl=0
		echo "http://debian.ymagis.net:8008$i => OK"
	else
		checkurl=1
		echo "==========="
		echo "ERROR |  http://debian.ymagis.net:8008$i"
		echo "==========="
		return $checkurl
		exit
	fi
done
return $checkurl 
} 

function backup_prod {
local site=$1
BACKUP_DIR=$SCRIPT_DIR/backup
if [[ ! -d $BACKUP_DIR ]]; then
	mkdir $BACKUP_DIR
	chmod 644 $BACKUP_DIR
fi
cp -a /etc/apache2/sites-available/$site.conf $BACKUP_DIR/$site.conf_$(date '+%Y%m%d_%H%M%S')	
cp -a /usr/local/src/repo-snapshots/snapshot.conf $BACKUP_DIR/snapshot.conf_$(date '+%Y%m%d_%H%M%S')
}


function main {
##1st : create a test conf and validate it
##2nd : if test is validated push to prod
#1/
testing_value="repo-snapshots-test-for-validation"
push2prod_value="repo-snapshots"	
 #1/
configure_apache $testing_value
if validate_apache $testing_value; then
#2
	echo "======================"
	echo TEST VALIDATED
	echo "======================"
	backup_prod $push2prod_value
	#configure_apache $push2prod_value
	#validate_apache $push2prod_value
fi
}

main

