#!/bin/sh

# Adlibre Backup - Backup Single Host

CWD="$(dirname $0)/"

# Source Config
. ${CWD}../etc/backup.conf

# Source Functions
. ${CWD}functions.sh;

HOST=$1
ANNOTATION=${2-none}
HOSTS_DIR="/${ZPOOL_NAME}/hosts/"
LOCKFILE="/var/run/$(basename $0 | sed s/\.sh//)-${HOST}.pid"
LOGFILE="${HOSTS_DIR}${HOST}/l/backup.log"

if [ ! $(whoami) = "root" ]; then
    echo "Error: Must run as root."
    exit 99
fi

if [ ! ${HOST} ]; then
    echo "Usage: backup.sh <hostname> <annotation> <expiry-in-days>."
    exit 99
fi

# Check to see if we are already running / locked, limit to one instance per host
if [ -f ${LOCKFILE} ] ; then
    logMessage 3 $LOGFILE "Error: Already running, or locked. Lockfile exists [$(ls -ld $LOCKFILE)]."
    exit 99
else
    echo $$ > ${LOCKFILE}
    # Upon exit, remove lockfile.
    trap "{ rm -f ${LOCKFILE}; }" EXIT
fi

# source host config
if [ -f  "${HOSTS_DIR}${HOST}/c/backup.conf" ]; then
    . "${HOSTS_DIR}${HOST}/c/backup.conf"
    # Check Sanity of Config (unified with global config)
    command -v $RSYNC_BIN > /dev/null || echo "rsync not found. Please specify \$RSYNC_BIN location in backup.conf."
    command -v $NSCA_BIN > /dev/null || echo "send_nsca not found. Please specify \$NSCA_BIN location in backup.conf."
else
    echo "Error: Invalid host or host config not found."
    exit 99
fi

# Options Overridable by backup.conf (or command line)
EXPIRY=$(expr ${3-$EXPIRY} \* 24 \* 60 \* 60 + `date +%s`) # Convert expiry to unix epoc

# Check to see if the host backup is disabled.
if [ "${DISABLED}" == "true" ];  then
    logMessage 1 $LOGFILE "Info: ${HOST} backup disabled by config."
    exit 0
fi

# expand excludes (with support for strings with escaped spaces)
eval "for e in $EXCLUDE $EXCLUDE_ADDITIONAL; do RSYNC_EXCLUDES=\"\$RSYNC_EXCLUDES --exclude='\${e}'\"; done"

# Do backup
(
rm -f ${LOGFILE} # delete logfile from host dir before we begin.
echo $EXPIRY > ${HOSTS_DIR}${HOST}/c/EXPIRY
echo $ANNOTATION > ${HOSTS_DIR}${HOST}/c/ANNOTATION

STARTTIME=$(date +%s)
RSYNC_CMD="${RSYNC_BIN} ${RSYNC_ARGS} ${RSYNC_ADDITIONAL_ARGS} ${RSYNC_EXCLUDES} ${SSH_USER}@${HOST}:'$BACKUP_PATHS' ${HOSTS_DIR}${HOST}/d/"
logMessage 1 $LOGFILE "Running: $RSYNC_CMD"
CMD=$(eval $RSYNC_CMD 2>&1;)
RSYNC_RETVAL=$?
STOPTIME=$(date +%s)
RUNTIME=$(expr ${STOPTIME} - ${STARTTIME})

if [ "$RSYNC_RETVAL" = "0" ] || [ "${SNAPSHOT_ON_ERROR}" == "true" ]; then

    # Create snapshot    
    if [ "$RSYNC_RETVAL" = "0" ]; then
        SNAP_NAME="${HOST}@$(date +"%F-%X-%s")"
    else
        SNAP_NAME="${HOST}@$(date +"%F-%X-%s")-partial"
    fi    
    zfs snapshot $ZPOOL_NAME/hosts/${SNAP_NAME}
    SNAPSHOT_RETVAL=$?
    
    if [ "$RSYNC_RETVAL" = "0" ] && [ "$SNAPSHOT_RETVAL" = "0" ]; then
        raiseAlert "backup ${HOST}" 0 "Backup Successful. Runtime ${RUNTIME} seconds."
        raiseAlert "${ANNOTATION}" 0 "Backup Successful. Runtime ${RUNTIME} seconds." ${HOST}
        logMessage 1 $LOGFILE "Backup Successful. Runtime ${RUNTIME} seconds."
    elif [ "$RSYNC_RETVAL" = "0" ] && [ "$SNAPSHOT_RETVAL" != "0" ]; then
        raiseAlert "backup ${HOST}" 2 "Backup succeeded, but Snapshot Failed"
        logMessage 3 $LOGFILE "Backup succeeded, but snapshot ${SNAP_NAME} Failed"
        exit 99
    elif [ "$RSYNC_RETVAL" != "0" ] && [ "$SNAPSHOT_RETVAL" = "0" ] && [ "${SNAPSHOT_ON_ERROR}" == "true" ]; then
        # Downgrade rsync failure error to nagios warning (because SNAPSHOT_ON_ERROR=true)
        raiseAlert "backup ${HOST}" 1 "Backup Failed: ${CMD}. Snapshotted anyway."
        raiseAlert "${ANNOTATION}" 1 "Backup Failed: ${CMD}. Snapshotted anyway." ${HOST}
        logMessage 3 $LOGFILE "Backup Error: ${CMD}. Rsync exited with ${RSYNC_RETVAL}. Snapshotted anyway."
        exit 99
    fi
else
    raiseAlert "backup ${HOST}" 2 "Backup Failed: ${CMD}."
    raiseAlert "${ANNOTATION}" 2 "Backup Failed: ${CMD}." ${HOST}
    logMessage 3 $LOGFILE "Backup Failed: ${CMD}. Rsync exited with ${RSYNC_RETVAL}."
    exit 99
fi

) 2>&1 1>> ${LOGFILE} | tee -a ${LOGFILE} # stderr to console, stdout&stderr to logfile

exit 0
