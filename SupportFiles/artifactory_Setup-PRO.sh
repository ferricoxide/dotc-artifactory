#!/bin/bash
# shellcheck disable=SC1091,SC2034,SC2015,SC2046,SC2155
# set +x
#
# Script to install and configure the Artifactory software
#
#################################################################
PROGNAME=$(basename "${0}")
while read -r AFENV
do
   # shellcheck disable=SC2163
   export "${AFENV}"
done < /etc/cfn/AF.envs
AFRPM="${ARTIFACTORY_RPM:-UNDEF}"
ARTIFACTORY_ETC="${ARTIFACTORY_HOME}/etc"
ARTIFACTORY_LOGS="${ARTIFACTORY_HOME}/logs"
ARTIFACTORY_TOMCAT_HOME="${ARTIFACTORY_HOME}/tomcat"
ARTIFACTORY_VARS="${ARTIFACTORY_HOME}/etc/default"
S3BKUPDEST="${ARTIFACTORY_S3_BACKUPS:-UNDEF}"
AFHOMEDIR="${ARTIFACTORY_HOME:-UNDEF}"
AFETCDIR="${ARTIFACTORY_ETC:-UNDEF}"
AFLICENSE="${ARTIFACTORY_LICENSE:-UNDEF}"
AFLOGDIR="${ARTIFACTORY_LOGS:-UNDEF}"
AFVARDIR="${ARTIFACTORY_VARS:-UNDEF}"
AFTOMCATDIR="${ARTIFACTORY_TOMCAT_HOME:-UNDEF}"
AFPROXFQDN="${ARTIFACTORY_PROXY_HOST}"
AFPROXTMPLT="${ARTIFACTORY_PROXY_TEMPLATE}"
BINSTORXML="${ARTIFACTORY_HOME}/etc/binarystore.xml"
CFNENDPOINT="${ARTIFACTORY_CFN_ENDPOINT:-UNDEF}"
DBPROPERTIES="${AFETCDIR}/db.properties"
FSBACKUPDIR="${ARTIFACTORY_BACKUPDIR:-UNDEF}"
FSDATADIR="${ARTIFACTORY_DATADIR:-UNDEF}"
NGINXRPM="nginx"
PGSQLJDBC=postgresql-jdbc
PGSQLHOST="${ARTIFACTORY_DBHOST:-UNDEF}"
PGSQLPORT="${ARTIFACTORY_DBPORT:-UNDEF}"
PGSQLINST="${ARTIFACTORY_DBINST:-UNDEF}"
PGSQLUSER="${ARTIFACTORY_DBUSER:-UNDEF}"
PGSQLPASS="${ARTIFACTORY_DBPASS:-UNDEF}"
SELSRC=${ARTIFACTORY_ETC}/mimetypes.xml
STACKNAME="${ARTIFACTORY_CFN_STACKNAME:-UNDEF}"
SVCALIASES=(${ARTIFACTORY_PROXY_AKAS//,/ })
BKUPCRON="/usr/local/sbin/bkup2s3.sh"

##
## Set up an error logging and exit-state
function err_exit {
   local ERRSTR="${1}"
   local SCRIPTEXIT=${2:-1}

   # Our output channels
   echo "${ERRSTR}" > /dev/stderr
   logger -t "${PROGNAME}" -p kern.crit "${ERRSTR}"

   # Need our exit to be an integer
   if [[ ${SCRIPTEXIT} =~ ^[0-9]+$ ]]
   then
      exit "${SCRIPTEXIT}"
   else
      exit 1
   fi
}

##
## Tweak SEL as necessary
function SelMods {
   printf "Ensure httpd processes can use network... "
   setsebool -P httpd_can_network_connect 1 && echo "Success" || \
     err_exit "Failed setting httpd network boolean"

   if [ ! "${1}" = "" ]
   then
      printf "Allow processes running httpd context to use NFS... "
      setsebool -P httpd_use_nfs 1 && echo "Success" || \
        err_exit "Failed setting httpd/NFS SEL-boolean"

      printf "Alow httpd rw access to %s... " "${1}"
      semanage fcontext -a -t "httpd_sys_rw_content_t" "${1}(/.*)?" && \
        echo "Success" || err_exit "Unable to give httpd rw access to ${1}"
   fi
}

##
## Install and configure Nginx-based reverse-proxy
function ReverseProxy {
   # Install Nginx
   printf "Install Nginx service... "
   yum --enablerepo="*epel" install -y "${NGINXRPM}" && \
     echo "Success." || \
     err_exit 'Nginx installation failed'
   local NGINXDIR=$(
         dirname $(rpm -ql "${NGINXRPM}" | grep -E 'nginx.conf$')
      )

   local PROXCONF="${NGINXDIR}/conf.d/AFproxy.conf"

   # Create the proxy config in the Nginx config-dir
   if [[ -d ${NGINXDIR}/conf.d ]]
   then
      printf "Grabbing reverse-proxy template-source... "
      install -b -m 000600 /dev/null "${PROXCONF}"
      curl -skL "${AFPROXTMPLT}" -o "${PROXCONF}" && \
         echo "Success" || \
         err_exit 'Failed to create reverse-proxy config'

      if [[ $(getenforce) != Disabled ]]
      then
         chcon --reference="${NGINXDIR}"/nginx.conf "${PROXCONF}"
      fi

      printf "Localizing proxy-config... "
      for ALIAS in "${SVCALIASES[@]}"
      do
         SVCALIASES+=('~(?<repo>.+)\.'${ALIAS})
      done

      sed -i '{
         s/__AF-FQDN__/'"${AFPROXFQDN}"'/g
         /^[ 	]*server_name/s/;$/ '"${SVCALIASES[*]}"';/
      }' "${PROXCONF}" && \
         echo "Success" || \
         err_exit 'Failed to localize reverse-proxy config'
   fi

   CURBUCKTHASH=$(nginx -T 2>&1 | grep 'server_names_hash_bucket_size' | \
                  sed 's/^.*: //')

   # Adjust 
   if [[ -z ${CURBUCKTHASH+xxx} ]] || [ "${CURBUCKTHASH}" = "" ]
   then
      printf "No 'server_names_hash_bucket_size' error detected:\n"
      printf "\tserver config should be ok as is.\n"
   else
      echo "Doubling currently-defined 'server_names_hash_bucket_size' size."
      NEWHASH=$((CURBUCKTHASH * 2))
      sed -i '/^http /a server_names_hash_bucket_size '"${NEWHASH}"';' \
        "${NGINXDIR}"/nginx.conf
   fi

   # Lasso SELinux as necessary
   if [[ $(getenforce) = Disabled ]]
   then
      "SELinux not enabled: no need to tweak"
   else
      # Check for proxy-temp dirs to except
      if [[ $(grep -q proxy_temp_path "${PROXCONF}" )$? -eq 0 ]]
      then
         local PROXTMPDIR=$(
             awk '/proxy_temp_path/{ print $2 }' "${PROXCONF}" | \
               sed -e 's/;$//' -e 's/\/$//'
            )
      fi

      # Call routine to tweak SEL config
      SelMods "${PROXTMPDIR}"
   fi

   # Enable and start Nginx
   systemctl enable nginx
   systemctl start nginx
}

##
## Prep for rebuild or setup rejoin as appropriate
function RebuildStuff {
   # This is a rebuild
   if [[ $(aws s3 ls s3://"${S3BKUPDEST}"/rebuild > /dev/null)$? -eq 0 ]]
   then
      echo "Found rebuild-file in s3://${S3BKUPDEST}/"

      if [[ ! -d "${AFHOMEDIR}"/access/etc/keys/ ]]
      then
         echo "Creating missing key-directories"
         install -d -m 0700 -o artifactory -g artifactory \
            "${AFHOMEDIR}"/access/{,etc/{,keys}}
      fi

      # Pulling key-files
      for KEY in root.crt private.key
      do
         printf "Attempting to pull down %s... " "${KEY}"
         aws s3 cp s3://"${S3BKUPDEST}"/creds/"${KEY}" \
            "${AFHOMEDIR}"/access/etc/keys/"${KEY}" && echo "Success!" || \
              err_exit "Failed to pull down ${KEY}"
         chown artifactory:artifactory "${AFHOMEDIR}"/access/etc/keys/"${KEY}"
      done

      # Syncing-down artifact-data from S3
      printf "Fetching available Artifactory user data... "
      aws s3 sync s3://"${S3BKUPDEST}"/data/ "${FSDATADIR}" 
      chown -R artifactory:artifactory "${FSDATADIR}"
      echo
   # This is a new build
   else
      touch /tmp/rebuild
      aws s3 cp /tmp/rebuild s3://"${S3BKUPDEST}"/ || \
        err_exit 'Failed to set rebuild flag. Reinstantiations of EC2 will not happen without intervention.'
      export NEWBUILD="true"
   fi
}


#######################
## Main Program Logic  
#######################

# Install the Artifactory RPM
echo "Attempt to install Artifactory RPM..."
yum install -y "${AFRPM}" && echo "Success!" || \
  err_exit 'Artifactory RPM install failed'

# Install the License file
printf 'Fetching license key... '
curl -o /tmp/artifactory.lic -skL "${AFLICENSE}" && echo "Success!" || \
  err_exit 'Failed fetching license key'
printf "Attempting to install the Artifactory license key... "
install -b -m 0640 -o artifactory -g artifactory /tmp/artifactory.lic \
  "${ARTIFACTORY_ETC}"/artifactory.lic && echo "Success!" || \
  err_exit 'License file installation failed.'

# Ensure that Artifactory's "extra" filesystems are properly-owned
for FIXPERM in  "${FSBACKUPDIR}" "${FSDATADIR}"
do
   printf "Setting ownership on %s..." "${FIXPERM}"
   chown artifactory:artifactory "${FIXPERM}" && echo "Success!" || \
     err_exit "Failed to set ownership on ${FIXPERM}"
done

##
## Ensure PGSQL JAR file installed and linked
if [[ $(rpm -q --quiet ${PGSQLJDBC})$? -eq 0 ]]
then
   echo "PostGreSQL JDBC installed"
else
   echo "Attempting to install PostGreSQL JDBC..."
   yum install -y ${PGSQLJDBC} || \
      err_exit "Failed to install ${PGSQLJDBC}"
fi

if [[ -f ${AFTOMCATDIR}/lib/postgresql-jdbc.jar ]]
then
   echo "Found a PGSQL JDBC JAR in ${AFTOMCATDIR}/lib"
else
   echo "Linking PostGreSQL JDBC into Artifactory..."
   ln -s "$(rpm -ql ${PGSQLJDBC} | grep jdbc.jar)" \
      "${AFTOMCATDIR}/lib/" || \
         err_exit "Failed to link PostGreSQL JDBC into Artifactory."
fi

##
## DB-setup for non-clustered nodes
if [[ -f ${DBPROPERTIES} ]]
then
   mv "${DBPROPERTIES}" "${DBPROPERTIES}.BAK-${DATE}" || \
     err_exit "Failed to preserve existing '${DBPROPERTIES}' file"
fi

# Locate example contents
# shellcheck disable=SC2086
SRCPGSQLCONF=$(rpm -ql ${ARTIFACTORY_RPM} | grep postgresql.properties)

# Grab header-content from RPM's example file
grep ^# "${SRCPGSQLCONF}" > "${DBPROPERTIES}" || \
   err_exit "Failed to create stub '${DBPROPERTIES}' content"

##
## Append db-connection info to db.properties file
printf "Crerating new '%s' file... " "${DBPROPERTIES}"
cat << EOF >> "${DBPROPERTIES}"

type=postgresql
driver=org.postgresql.Driver
url=jdbc:postgresql://${PGSQLHOST}:${PGSQLPORT}/${PGSQLINST}
username=${PGSQLUSER}
password=${PGSQLPASS}
EOF

# Make sure the properites file actually got created/updated
# shellcheck disable=SC2181
if [[ $? -eq 0 ]]
then
   echo "Success!"
   chown artifactory:artifactory "${DBPROPERTIES}" || \
      err_exit "Failed to set ownership on ${DBPROPERTIES}"
else
   err_exit "Error creating new '${DBPROPERTIES}' file. Aborting."
fi

##
## Make Artifactory use extra storage
if [ ! "${FSDATADIR}" = "" ]
then
   ##
   ## Preserve any existing binarystore.xml file
   if [[ -f ${BINSTORXML} ]]
   then
     mv "${BINSTORXML}" "${BINSTORXML}.BAK-${DATE}" || \
       err_exit "Unable to backup the \"${BINSTORXML}\" file! Aborting..."
     SELSRC="${BINSTORXML}.BAK-${DATE}"
   fi

   ##
   ## Bail if the offered binarystore.xml directory doesn't exist
   # shellcheck disable=SC2086
   if [[ ! -d $(dirname "${BINSTORXML}") ]]
   then
      err_exit "Aborting: no such directory '$(dirname ${BINSTORXML})'."
   fi

   ##
   ## Create an S3-enabled binarystore.xml file with customized contents
   cat << EOF > "${BINSTORXML}"
<config version="1">
    <chain template="file-system"/>
    <provider id="file-system" type="file-system">
        <baseDataDir>${FSDATADIR}</baseDataDir>
    </provider>
</config>
EOF

fi

# Clean up /etc/rc.d/rc.local
chmod a-x /etc/rc.d/rc.local || err_exit 'Failed to deactivate rc.local'
sed -i '/Artifactory config-tasks/,$d' "$(readlink -f /etc/rc.d/rc.local)"

# Pull down key-files if we're rebuilding
RebuildStuff

# Add a reverse-proxy
ReverseProxy

# Check a new-build flag 
if [[ ! -z ${NEWBUILD+xxx} ]]
then
   printf 'Temp-starting Artifactory to create credentials... '
   systemctl start artifactory && echo "Success" || \
     err_exit 'Failed to start Artifactory'
   echo "New install: push creds to S3 to support future rebuilds"
   aws s3 sync "${AFHOMEDIR}"/access/etc/keys/ s3://"${S3BKUPDEST}"/creds/
   printf 'Ending Artifactory temp-start... '
   systemctl stop artifactory && echo "Success" || \
     err_exit 'Failed to stop Artifactory'
fi

##########################
## Create Backup Script ##
echo "Creating sync-to-s3 backup script..."

printf "Setting base permissions/ownerships... "
install -b -m 000700 -o root -g root /dev/null "${BKUPCRON}" && \
  echo "Success." || err_exit "Failed setting base permissions/ownerships"

printf "Injecting script contents... "
cat << EOF >> "${BKUPCRON}"
#!/bin/bash
# shellcheck disable=SC1091,SC2034,SC2015,SC2046,SC2155
# set +x
#
# Script to move Artifactory-generated backups from the backups
# filesystem-target to S3
#
#################################################################
PROGNAME=\$(basename "\${0}")
while read -r AFENV
do
   # shellcheck disable=SC2163
   export "\${AFENV}"
done < /etc/cfn/AF.envs
BKUPDIR="\${ARTIFACTORY_BACKUPDIR}"
BKUPBKT="\${ARTIFACTORY_S3_BACKUPS}"
BKUPDST="\${BKUPBKT}/Backups"

##
## Set up an error logging and exit-state
function err_exit {
   local ERRSTR="\${1}"
   local SCRIPTEXIT=\${2:-1}

   # Our output channels
   echo "\${ERRSTR}" > /dev/stderr
   logger -t "\${PROGNAME}" -p kern.crit "\${ERRSTR}"

   # Need our exit to be an integer
   if [[ \${SCRIPTEXIT} =~ ^[0-9]+\$ ]]
   then
      exit "\${SCRIPTEXIT}"
   else
      exit 1
   fi
}

# Reroot to avoid creating some of the weird S3 pathing
printf "Re-rooting to \${BKUPDIR}... "
cd "\${BKUPDIR}" && echo "Success" || err_exit "Failed to cd to \${BKUPDIR}"

for BKUPSRC in [0-9]*.[0-9]*
do
   printf "Syncing %s to %s... " "\${BKUPSRC}" "\${BKUPDST}"
   aws s3 sync --quiet "\${BKUPSRC}" "s3://\${BKUPDST}/\${BKUPSRC}"/ && \\
     echo "Success." || err_exit "Failed syncing \${BKUPSRC} to \${BKUPDST}"

   printf "Cleanup: removing %s... " "\${BKUPSRC}"
   rm -rf "\${BKUPSRC}" && echo "Success." || \\
     err_exit "Failed to remove \${BKUPSRC}"
done
EOF

# shellcheck disable=SC2181
if [[ $? -eq 0 ]]
then
   echo "Success."
else
   err_exit "Injecting script contents... "
fi

##   End backup Script  ##
##########################

# Put the backup script in cron
# Add backupscript to crontab
printf "Creating cron entry for backup job..."
(crontab -l 2>/dev/null; echo "0 23 * * * ${BKUPCRON}") | crontab - && \
  echo "Success" || err_exit "Failed creating backup cron-job"
