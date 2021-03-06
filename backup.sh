#!/bin/sh
# Version: 20 februari 2013
# exit codes are taken from /usr/include/sysexits.h
export DISPLAY=:0

script=$(/bin/readlink -f "${0}")
script_dir=$(/usr/bin/dirname "${script}")

# include settings
. "${script_dir}/settings.inc"
logfile="${script_dir}/backup.log"

# function display a message if -v is given as argument
handle_message()
{
  message=`date '+%Y/%m/%d %H:%M:%S '`
  message="${message} [${$}] ${1}"
  echo ${message} >> "${logfile}"

  if [ ${verbose} = 1 ]
  then
    echo ${message}
  fi

  if [ ! -z "${2}" ]
  then
    handle_notification "${2}" "${message}"
  fi
}

# add [ERR] to the first parameter and pass it on to handle_message
handle_error()
{
  handle_message "[ERR] ${1}" 'Backup error'
}

handle_notification()
{
executable='/usr/bin/notify-send'
  if [ -f ${executable} ]
  then
    ${executable} -i "${script_dir}/backup-ambiance_44x44.png" "${1}" "${2}"
  fi
}

# Make sure the system wide version of each executable used.
ssh_executable='/usr/bin/ssh'
rsync_executable='/usr/bin/rsync'

verbose=0 # verbose defaults to 0
usage="Usage: `/usr/bin/basename $0` [-v]"

# Parse command line options.
while getopts hvo: OPT; do
  case "$OPT" in
    h)
      echo ${usage}
      exit 0; # successful termination
      ;;
    v)
      verbose=1
      ;;
  esac
done

if [ ${verbose} = 0 ]
then
  exec 2>>"${logfile}" # Append all errors to the log, this also prevents output during cron run.
fi

handle_message '-- Backup script started' 'Backup script started'
handle_message "Command line: ${0} ${*}"

# Date for this backup.
date=`date '+%Y-%m-%d_%Hh%Mm%Ss'`

# backups are placed in a subfolder name $identifier, the identifier is also used as a lockfile
identifier=`/bin/hostname`

# Check and create lockfile, the identifier is used as a name for the lockfile
lockfile="${script_dir}/${identifier}.lck"

if [ -f "${lockfile}" ]
then
  # Lockfile already exists, check if it belongs to a running process
  read -r lockpid < "${lockfile}" #Read the first line which contains a PID
  if [ -z "`ps -p ${lockpid} | grep ${lockpid}`" ]
  then
    # The process doesn't exist anymore. Should there be an incomple folder, it will be removed at the end of the script.
    handle_message "Lockfile for ghost process (PID: ${lockpid}) found, continuing backup."
  else
    handle_message "-- Lockfile '${lockfile}' for running process (PID: ${lockpid}) found, backup script stopped."  'Backup script stopped'
    exit 73 # can't create (user) output file
  fi
fi

# The lockfile doesn't exist or belongs to a ghost process, make or update it containing the current PID.
echo ${$} > "${lockfile}"

handle_message "Lockfile '${lockfile}' created or updated with PID ${$}."

# Create the connection string.
ssh_connect="${ssh_user}@${ssh_server}"

handle_message "Testing SSH connection to '${ssh_connect}'."

# Check if the ${ssh_executable} connection can be made, a ${ssh_executable} keypair without keyphrase must exist.
${ssh_executable} -q -o 'BatchMode=yes' -o 'ConnectTimeout 10' -p ${ssh_port} ${ssh_connect} exit > /dev/null

if [ $? != 0 ]
then
  handle_error "SSH connection to '${ssh_connect}' failed."
  exit 69 # service unavailable
fi

handle_message "SSH connection is ok, checking if target '${target}' exists."

# check if target exists
if ${ssh_executable} -p ${ssh_port} ${ssh_connect} "[ ! -d '${target}' ]"
then
  handle_error "Target '${target}' does not exist, backup stopped."
  exit 66 # cannot open input
fi

# Get the identifier and append it to target, create a folder for the identifier if it doesn't exist.
target="${target}${identifier}/"

handle_message "Target exists, checking if target '${target}' exists."

if ${ssh_executable} -p ${ssh_port} ${ssh_connect} "[ ! -d '${target}' ]"
then
  ${ssh_executable} -p ${ssh_port} ${ssh_connect} "mkdir '${target}'"
  if [ $? = 0 ]
  then
    handle_message "Created target '${target}'."
  else
    handle_error "Couldn't create target '${target}'."
    exit 73 # can't create (user) output file
  fi
fi

handle_message 'Target exists, checking if rotation folders exists.'

# Note: this is not a real array since bin/bash can't be used.
folders0='hourly'
folders1='daily'
folders2='weekly'
folders3='monthly'
folders4='yearly'

index=0
max_index=5

while [ ${index} -lt ${max_index} ]
do
  eval folder="\${target}\${folders${index}}"

  if ${ssh_executable} -p ${ssh_port} ${ssh_connect} "[ ! -d '${folder}' ]"
  then
    ${ssh_executable} -p ${ssh_port} ${ssh_connect} "mkdir '${folder}'"
    if [ $? = 0 ]
    then
      handle_message "Created rotation folder '${folder}'."
    else
      handle_error "Couldn't create rotation folder '${folder}'."
      exit 73 # can't create (user) output file
    fi
  fi

  index=`expr ${index} + 1`
done

handle_message "Rotation folders exists, starting backup to '${target}${date}-incomplete'."

# -- make backup
# Make the actual backup, note: the first time this is run, the latest folder
# can't be found. rsync will display this but will proceed.
verbosity='quiet'
if [ ${verbose} = 1 ]
then
  verbosity='verbose'
fi

# Option --xattrs temporarily removed, Synology Diskstation does not support it.
command="${rsync_executable} \
--${verbosity} \
--progress \
--rsh='${ssh_executable} -p ${ssh_port}' \
--archive \
--compress \
--human-readable \
--delete \
--link-dest='${target}latest' \
--exclude-from='${script_dir}/exclude-list.txt' \
${backup} \
'${ssh_connect}:${target}${date}-incomplete'"

eval ${command}

if [ $? = 0 ]
then
  handle_message "Backup complete, moving to hourly rotation folder as '${target}hourly/${date}'."
else
  handle_error 'Error while running the backup.'
  exit 70 # internal software error
fi

# Backup complete, it will be moved to the hourly folder.
${ssh_executable} -p ${ssh_port} ${ssh_connect} "mv '${target}${date}-incomplete' '${target}hourly/${date}'"
if [ $? = 0 ]
then
  handle_message "Moved backup, updating 'latest' symlink."
else
  handle_error "Error while moving the backup."
  exit 74 # input/output error
fi

# Create a symlink to new backup .
${ssh_executable} -p ${ssh_port} ${ssh_connect} "rm -f '${target}latest' && ln -s '${target}hourly/${date}' '${target}latest'"
if [ $? = 0 ]
then
  handle_message 'Symlink updated, setting modification moment for backup to now.'
else
  handle_error "Error while updating the symlink."
  exit 74 # input/output error
fi

# Set the modification moment to now for the new backup, this way, when rotating,
# the time when a backup was finished is used.
${ssh_executable} -p ${ssh_port} ${ssh_connect} "touch '${target}hourly/${date}'"
if [ $? = 0 ]
then
  handle_message 'Modification moment set, rotating backups.'
else
  handle_error "Error while setting modifitcation moment."
  exit 74 # input/output error
fi

# -- rotate backups
# To determine when to rotate a backup from ie hourly to daily, the latter must
# be checked to see if there is a backup present up until the amount of days
# ago. If there isn't, and the former folder has more then 1 backup, the oldest
# is moved to the latter folder.
rotate1='2' # Rotate the oldest hourly if there is no daily in the last 2 days
rotate2='14' # Rotate the oldest daily if there is no weekly in the last 14 days
rotate3='60' # Rotate the oldest weekly if there is no monthly in the last 60 days (approx. 2 months)
rotate4='730' # Rotate the oldest monthly if there is no yearly in the last 730 days (approx. 2 years)

index=0 # Start with 0, this ways the first from folder can be determined.
max_index=4

while [ ${index} -lt ${max_index} ]
do
  eval from="\${target}\${folders${index}}"

  # Increase index now so the amount of days and the to folder can be determined.
  index=`expr ${index} + 1`

  eval days="\${rotate${index}}"
  eval to="\${target}\${folders${index}}"

  # The -name '20*' is there to limit the files which can be found to everything
  # starting with 20*. This means the script only works for the years 2000-2099 but
  # this should be enough :).
  if [ `${ssh_executable} -p ${ssh_port} ${ssh_connect} "find '${from}' -maxdepth 1 -name '20*' | wc -l"` -gt 1 ] && [ `${ssh_executable} -p ${ssh_port} ${ssh_connect} "find '${to}' -maxdepth 1 -type d -mtime -${days} -name '20*' | wc -l"` -eq 0 ]
  then
    oldest=`${ssh_executable} -p ${ssh_port} ${ssh_connect} "ls -1 -tr '${from}' | head -1"`
    ${ssh_executable} -p ${ssh_port} ${ssh_connect} "mv '${from}/$oldest' '${to}'"
  fi

  if [ $? != 0 ]
  then
    handle_error "Error while rotating backups."
    exit 74 # input/output error
  fi

done

handle_message 'Backups rotated, deleting old backups.'

# -- delete old backups
# To determine when to delete a backup from ie hourly it must be older then
# the given amount of days. Note, because of this deletion, the rotation is
# done before it.
delete0='0' # Hourly backups older then 1 day are removed.
delete1='7' # Daily backups older then 7 days are removed.
delete2='30' # Weekly backups older then 30 days (approx. 1 month) are removed.
delete3='365' # Monthly backups older then 365 days (approx. 1 year) are removed.
delete4='1095' # Yearly backups older then 1095 days (approx. 3 years) are removed.

index=0
max_index=5

while [ ${index} -lt ${max_index} ]
do
  eval from="\${target}\${folders${index}}"
  eval days="\${delete${index}}"

  ${ssh_executable} -p ${ssh_port} ${ssh_connect} "find '${from}' -maxdepth 1 -type d -mtime +${days} | xargs rm -rf"

  if [ $? != 0 ]
  then
    handle_error "Error while deleting old backups."
    exit 74 # input/output error
  fi

  index=`expr ${index} + 1`
done

handle_message 'Old backups deleted, deleting any remaining incomplete folders.'

# Remove any remaining incomplete folders at target, those belong to ghost processes.
${ssh_executable} -p ${ssh_port} ${ssh_connect} "find '${target}' -type d -maxdepth 1 -name '*incomplete' -exec rm -rf {} \;"

if [ $? = 0 ]
then
  handle_message "Finished deleting any remaining incomplete folders, deleting lockfile '${lockfile}'."
else
  handle_error "Error while deleting any remaining incomplete folders."
  exit 74 # input/output error
fi

# Remove lockfile
rm -f "${lockfile}"

if [ $? = 0 ]
then
  handle_message 'Lockfile is deleted.'
else
  handle_error "Error while deleting the lockfile."
  exit 74 # input/output error
fi

handle_message "-- Backup to '${target}hourly/${date}' finished" 'Backup script finished'

exit 0; # successful termination

