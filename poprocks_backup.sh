#!/bin/bash

# Poprocks Backup v. 0.1.3
# 
#
# Released under the terms of the GNU General Public License
#     http://www.gnu.org/licenses/gpl.txt
#
# Usage: /path/to/backup_script

# Exit Status Codes:
#	0: Exit without error
#	1: Exit with folder / file archive creation error.
#	2: Exit with MySQL dump error.
#	3: Exit with FTP upload error (due to folder size limitation).
#	4: Exit with FTP upload error (unrelated to folder size limitation).
#	5: Exit with output folder creation error.


### VARIABLE DECLARATIONS ###

# Script logging definitions
MAIL_ENABLED=0
MAIL_ADDRESSES="" # separate multiple email addresses with a space
LOG_DIR="/var/log/backup"

# Script output definitions
BACKUPDIR="/var/backups" # point this to the desired local backup location, such as a second block device
BACKUP_PREFIX="backup" # backup prefix

# Folder archive definitions
FOLDERS_ENABLED=1
FILESPERBACKUP=2 # creates separate tarballs for files and dbs
DAYSTOKEEP=7
BACKUP="/home" # recursive file system path to archive. separate multiple directories with a space
EXCLUDE="*.tar.gz" # separate tar --exclude directives, written as a full path or with a wildcard, separated with a space (i.e., "/home/foo/bar *.tar.gz")

# MySQL archive definitions
MYSQL_ENABLED=0
MYSQL_HOST="" # typically 'localhost'
MYSQL_USERNAME="" # typically 'root'
MYSQL_PASSWORD=""

# Remote FTP site definitions
FTP_ENABLED=0
FTP_HOST=""
FTP_USERNAME=""
FTP_PASSWORD=""
FTP_REMOTE_DIR="."
FTP_SPACE="1048576"  # adjust this for VPS or dedicated server - 1GB or 2GB - in KB. 2 GB = 2097152

# Script-specific definitions, typically you don't need to alter these
GENERIC_MYSQLDUMP_ARGS="-h $MYSQL_HOST -u $MYSQL_USERNAME --password=$MYSQL_PASSWORD -f --opt"
MYSQL_DATABASES=`mysql -h $MYSQL_HOST -u $MYSQL_USERNAME -p$MYSQL_PASSWORD -e 'show databases' | grep -Ev "(Database|*_schema)"`
FILESTOKEEP=$(($FILESPERBACKUP * $DAYSTOKEEP))
EXIT_STATUS=0
TIMESTAMP="$(date +%Y)$(date +%m)$(date +%d)"
TMP_LOG="/var/log/backup.log"


### FUNCTIONS ###

# Add timestamps to log call for logging
function log() {
    echo $(date +%D) $(date +%T): $* >> $TMP_LOG
}


### BEGIN SHELL SCRIPT ###

log "Starting backup script..."

if [ ! -d $BACKUPDIR ] ; then
	mkdir $BACKUPDIR
	if [ ! -d $BACKUPDIR ] ; then
		log "Could not create directory $BACKUPDIR, please do it manually!"
		EXIT_STATUS=5
		exit $EXIT_STATUS
	fi
fi

if [ $FOLDERS_ENABLED -eq 1 ] ; then
	log "Beginning folder archive operation..."
	if [ -z $BACKUP ] ; then
		log "Folder backup was enabled but no folders were selected."
	else
		OUT=$BACKUPDIR/$BACKUP_PREFIX-folders-$TIMESTAMP.tar.gz
		log "Compressing folders..."
		tar -X <(echo -e ${EXCLUDE// /\\n}) --ignore-failed-read -hzcf $OUT $BACKUP
		if [ $? -eq 0 ]; then
			log "Compression of archive completed without error."
		else
			log "Compression of archive failed with exit code: $?."
			EXIT_STATUS=1
		fi
	fi
	
	log "Folder archive creation operation completed!"
fi

if [ $MYSQL_ENABLED -eq 1 ] ; then
	log "Beginning MySQL archive operation..."
	for DATABASE in $MYSQL_DATABASES; do
		log "Starting to backup database $DATABASE"
		mysqldump $GENERIC_MYSQLDUMP_ARGS --databases $DATABASE > $BACKUPDIR/$DATABASE.sql
		if [ $? -eq 0 ]; then
			log "Dump of database $DATABASE completed without error."
        else
			log "Dump of database $DATABASE failed with exit code: $?."
			EXIT_STATUS=2
        fi
	done

	log "Creating single MySQL database archive..."
	CURRENT_DIR=`pwd`
	cd $BACKUPDIR
	OUT=$BACKUP_PREFIX-mysql-$TIMESTAMP.tar.gz
	tar -zcf $OUT ./*.sql
	rm -f ./*.sql
	cd $CURRENT_DIR
	log "MySQL archive creation operation complete!"
fi

if [ $EXIT_STATUS -eq 0 ] ; then
	log "Removing outdated archives..."
	# Retention. Delete the oldest files, determined by sorting via mtime attribute displayed as unix epoch timestamp.
	if [ $(ls -1 $BACKUPDIR | wc -l) -gt $FILESTOKEEP ] ; then
		for i in `find $BACKUPDIR -exec stat --format '%Y:%n' {} \; | sort -n | cut -d: -f 2 | head -$(($(ls -1 $BACKUPDIR | wc -l) - $FILESTOKEEP))`; do 
			log "Removing archive $i..."; 
			rm -f $i; 
		done
	fi
	log "Removal of outdated archives complete!"
else
	log "Previous error detected, not removing old archives. Please analyze logs to avoid disk bloat."
fi

if [ $FTP_ENABLED -eq 1 ] ; then
	log "Beginning FTP upload operation..."
	BACKUP_SIZE=`du $BACKUPDIR -s | cut -f1`
	if [ $BACKUP_SIZE -gt $FTP_SPACE ] ; then
		log "Unfortunately, the size of your backups is greater than $FTP_SPACE. FTP upload has been cancelled."
		EXIT_STATUS=3
	else    
		log "Backing up FTP Site...";
		lftp -u $FTP_USERNAME,$FTP_PASSWORD $FTP_HOST/$FTP_REMOTE_DIR -e "mirror -R -e --verbose=3 --parallel=4 --use-cache $BACKUPDIR $FTP_REMOTE_DIR;quit"
		if [ $? -eq 0 ] ; then
			log "FTP upload operation completed without error."
		else
			log "FTP upload operation completed with exit code: $?."
			EXIT_STATUS=4
		fi
	fi

	log "FTP upload operation complete!"
fi

log "Current disk space:"
echo "`df -h`"
log "Contents of backup directory:"
echo "`ls -lh $BACKUPDIR`"

log "Backup script has completed with exit code: $EXIT_STATUS!"

if [ $MAIL_ENABLED -eq 1 ] ; then
	mail -s "`hostname` Backup Status: $EXIT_STATUS" $MAIL_ADDRESSES < $TMP_LOG
fi

if [ ! -d $LOG_DIR ] ; then
	mkdir $LOG_DIR
	if [ ! -d $LOG_DIR ] ; then
		exit
	fi
fi

if [ -d $LOG_DIR ] ; then
	cp $TMP_LOG $LOG_DIR/$TIMESTAMP.log
	cat /dev/null > $TMP_LOG
fi

exit $EXIT_STATUS
