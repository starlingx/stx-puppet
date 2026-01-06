#!/bin/bash

# Grab a lock before doing anything else
LOCKFILE=/var/lock/.puppet.applyscript.lock
LOCK_FD=200
LOCK_TIMEOUT=60

eval "exec ${LOCK_FD}>$LOCKFILE"

while :; do
    flock -w $LOCK_TIMEOUT $LOCK_FD && break
    logger -t $0 "Failed to get lock for puppet applyscript after $LOCK_TIMEOUT seconds. Trying again"
    sleep 1
done

HIERADATA=$1
HOST=$2
# subfunctions is a list of subfunctions, separated by comma
SUBFUNCTIONS=$3
IFS=, read PERSONALITY SUBFUNCTION LL <<< $SUBFUNCTIONS
if [ "${SUBFUNCTION}" = "worker" ]; then
    MANIFEST="aio"
else
    PERSONALITY=${SUBFUNCTIONS}
    MANIFEST=${PERSONALITY}
fi
MANIFEST=${4:-$MANIFEST}
RUNTIMEDATA=$5


logger -t $0 "puppet-manifest-apply ${HIERADATA} ${HOST} ${SUBFUNCTIONS} ${MANIFEST} ${RUNTIMEDATA}"


PUPPET_MODULES_PATH=/usr/share/puppet/modules:/usr/share/openstack-puppet/modules
PUPPET_MANIFEST=/etc/puppet/manifests/${MANIFEST}.pp
PUPPET_TMP=/tmp/puppet
FILEBUCKET_PATH=/var/cache/puppet/clientbucket
REPORTS_PATH=/var/cache/puppet/reports

# Setup log directory and file
DATETIME=$(date -u +"%Y-%m-%d-%H-%M-%S")
LOGDIR="/var/log/puppet/${DATETIME}_${MANIFEST}"
LOGFILE=${LOGDIR}/puppet.log

mkdir -p ${LOGDIR}
chmod 700 ${LOGDIR}
rm -f /var/log/puppet/latest
ln -s ${LOGDIR} /var/log/puppet/latest

touch ${LOGFILE}
chmod 600 ${LOGFILE}


# Remove old log directories
declare -i NUM_DIRS=`ls -d1 /var/log/puppet/[0-9]* 2>/dev/null | wc -l`
declare -i MAX_DIRS=50
if [ ${NUM_DIRS} -gt ${MAX_DIRS} ]; then
    let -i RMDIRS=${NUM_DIRS}-${MAX_DIRS}
    ls -d1 /var/log/puppet/[0-9]* | head -${RMDIRS} | xargs --no-run-if-empty rm -rf
fi


# Setup staging area and hiera data configuration
# (must match hierarchy defined in hiera.yaml)
rm -rf ${PUPPET_TMP}
mkdir -p ${PUPPET_TMP}/hieradata
cp /etc/puppet/hieradata/global.yaml ${PUPPET_TMP}/hieradata/global.yaml

if [ "${MANIFEST}" = 'aio' ]; then
    cat /etc/puppet/hieradata/controller.yaml /etc/puppet/hieradata/worker.yaml > ${PUPPET_TMP}/hieradata/personality.yaml
else
    cp /etc/puppet/hieradata/${PERSONALITY}.yaml ${PUPPET_TMP}/hieradata/personality.yaml
fi

# When the worker node is first booted and goes online, sysinv-agent reports
# host CPU inventory which triggers the first runtime manifest apply that updates
# the grub. At this time, copying the host file failed due to a timing issue that
# has not yet been fully understood. Subsequent retries worked.
#
# When back to back runtime manifests (e.g. as on https modify certificate
# install) are issued, copying of the hieradata file may fail.  Suspect this is due
# to potential update of hieradata on the controller while the file is being
# copied. Check rsync status and retry if needed.

declare -i MAX_RETRIES=3

HIERA_HOST=()
if [ "${MANIFEST}" == 'ansible_bootstrap' ]; then
    HIERA_SYS=("${HIERADATA}/secure_static.yaml"  "${HIERADATA}/static.yaml")
elif [ "${MANIFEST}" == 'restore' ]; then
    HIERA_SYS=("${HIERADATA}/secure_static.yaml" "${HIERADATA}/static.yaml" "${HIERADATA}/system.yaml" "${HIERADATA}/secure_system.yaml")
elif [ "${MANIFEST}" == 'upgrade' ]; then
    HIERA_SYS=("${HIERADATA}/secure_static.yaml"  "${HIERADATA}/static.yaml" "${HIERADATA}/system.yaml")
else
    HIERA_SYS=("${HIERADATA}/secure_static.yaml" "${HIERADATA}/static.yaml" "${HIERADATA}/system.yaml" "${HIERADATA}/secure_system.yaml")
    HIERA_HOST=("${HIERADATA}/${HOST}.yaml")
fi

if [ -n "${RUNTIMEDATA}" ]; then
    HIERA_RUNTIME=("${RUNTIMEDATA}")
else
    HIERA_RUNTIME=()
fi

DELAY_SECS=15
for (( iter=1; iter<=$MAX_RETRIES; iter++ )); do
    if [ ${#HIERA_HOST[@]} -ne 0 ]; then
        rsync -c "${HIERA_HOST[@]}" ${PUPPET_TMP}/hieradata/host.yaml
        if [ $? -eq 0 ]; then
            HIERA_HOST=()
        fi
    fi

    rsync -c "${HIERA_SYS[@]}" ${PUPPET_TMP}/hieradata
    if [ $? -eq 0 ]; then
        HIERA_SYS=()
    fi

    if [ ${#HIERA_RUNTIME[@]} -ne 0 ]; then
        rsync -c "${HIERA_RUNTIME[@]}" ${PUPPET_TMP}/hieradata/runtime.yaml
        if [ $? -eq 0 ]; then
            HIERA_RUNTIME=()
        fi
    fi

    if [ ${#HIERA_HOST[@]} -eq 0 ] && [ ${#HIERA_SYS[@]} -eq 0 ]  && [ ${#HIERA_SYS[@]} -eq 0 ]; then
        break
    fi

    logger -t $0 "Failed to copy ${HIERA_HOST[*]}:${HIERA_SYS[*]}:${HIERA_FILES_RUNTIME[*]} iteration: ${iter}."
    if [ ${iter} -eq ${MAX_RETRIES} ]; then
        echo "[FAILED]"
        echo "Exiting, failed to rsync hieradata"
        logger -t $0 "Exiting, failed to rsync hieradata"
        exit 1
    else
        logger -t $0 "Failed to rsync hieradata iteration: ${iter}. Retry in ${DELAY_SECS} seconds"
        sleep ${DELAY_SECS}
    fi
done


# Exit function to save logs from initial apply
# SC2329 is a false positive here because 'finish' is invoked via 'trap'.
# shellcheck disable=SC2329
function finish {
    local SAVEDLOGS=/var/log/puppet/first_apply.tgz
    if [ ! -f ${SAVEDLOGS} ]; then
        # Save the logs
        tar czf ${SAVEDLOGS} ${LOGDIR} 2>/dev/null
        chmod 600 ${SAVEDLOGS}
    fi

    # To avoid the ever growing contents of filebucket which may trigger inode
    # issues, clean up its contents after every apply.
    if [ -d ${FILEBUCKET_PATH} ]; then
        rm -fr ${FILEBUCKET_PATH}/*
    fi

    if [ -d ${REPORTS_PATH} ]; then
        rm -fr ${REPORTS_PATH}/*
    fi
}
trap finish EXIT


# Set Keystone endpoint type to internal to prevent SSL cert failures during config
export OS_ENDPOINT_TYPE=internalURL
export CINDER_ENDPOINT_TYPE=internalURL
# Suppress stdlib deprecation warnings until all puppet modules can be updated
export STDLIB_LOG_DEPRECATIONS=false

mask_passwd() {
    sed -i -r 's/(bootstrap-password) (\"[^\"]*\"|'\''[^'"'"']*'"'"'|[^ ]*)/\1 xxxxxx/g;
            s/(set_keystone_user_option\.sh admin) (\"[^\"]*\"|'\''[^'"'"']*'"'"'|[^ ]*)/\1 xxxxxx/g' \
            ${LOGFILE}
}

echo "Applying puppet ${MANIFEST} manifest..."

# puppet wants to write to current directory. Need to move current directory to a writable place.
# it is not possible to fail cd command, but tox doesn't like it without an exit.
cd $PUPPET_TMP || exit
flock /var/run/puppet.lock \
    puppet apply --trace --modulepath ${PUPPET_MODULES_PATH} ${PUPPET_MANIFEST} \
        < /dev/null 2>&1 | awk ' { system("date -u +%FT%T.%3N | tr \"\n\" \" \""); print $0; fflush(); } ' > ${LOGFILE}

rc=$?
mask_passwd

if [ ${rc} -ne 0 ]; then
    echo "[FAILED]"
    echo "See ${LOGFILE} for details"
    exit 1
else
    #Directly patched for: sed -i 's@Warning|@MMAAAAAAAAAASKED|@g' /usr/local/bin/puppet-manifest-apply.sh
    #TODO: Revert patch when all puppet warnings are resolved on Debian
    grep -qE '^(.......)?MMAAAAAAAAAASKED|^....-..-..T..:..:..([.]...)?(.......)?.MMAAAAAAAAAASKED|^(.......)?Error|^....-..-..T..:..:..([.]...)?(.......)?.Error' ${LOGFILE}
    if [ $? -eq 0 ]; then
        echo "[WARNING]"
        echo "Warnings found. See ${LOGFILE} for details"
        exit 1
    fi
    echo "[DONE]"
fi

exit 0
