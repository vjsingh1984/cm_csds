#!/bin/bash
##
# Licensed to Cloudera, Inc. under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  Cloudera, Inc. licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
##

add_to_kms_site() {
  FILE=`find $CONF_DIR -name kms-site.xml`
  CONF_END="</configuration>"
  NEW_PROPERTY="<property><name>$1</name><value>$2</value></property>"
  TMP_FILE=$CONF_DIR/tmp-kms-site
  cat $FILE | sed "s#$CONF_END#$NEW_PROPERTY#g" > $TMP_FILE
  cp $TMP_FILE $FILE
  rm -f $TMP_FILE
  echo $CONF_END >> $FILE
}

set -x

# Time marker for both stderr and stdout
date; date 1>&2

CMD=$1
shift

DEFAULT_KMS_HOME=/usr/lib/hadoop-kms

# Use CDH_KMS_HOME if available
export KMS_HOME=${KMS_HOME:-$CDH_KMS_HOME}
# If KMS_HOME is still not set, use the default value
export KMS_HOME=${KMS_HOME:-$DEFAULT_KMS_HOME}

# Set KMS config dir to conf dir
export KMS_CONFIG=${CONF_DIR}

# We want verbose startup logs
export KMS_SILENT=false

KMS_RUN=$CONF_DIR/run/
export KMS_TEMP=$KMS_RUN

# Need to set the libexec dir to find kms-config.sh
export HADOOP_HOME=${CDH_HADOOP_HOME}
export HADOOP_LIBEXEC_DIR=${HADOOP_HOME}/libexec

# Needed to find catalina.sh
export KMS_CATALINA_HOME=$TOMCAT_HOME

export CATALINA_TMPDIR=$PWD/temp
# Create temp directory for Catalina
mkdir -p $CATALINA_TMPDIR

# Choose between the non-SSL and SSL tomcat configs
TOMCAT_CONFIG_FOLDER=tomcat-conf.http
if [ "x$SSL_ENABLED"  == "xtrue" ]; then
    TOMCAT_CONFIG_FOLDER=tomcat-conf.https
else
    SSL_ENABLED=false
fi

# Package settings for tomcat deployment
DEPLOY_SCRIPT_BASE=/usr/lib/hadoop-kms/
TOMCAT_CONF_BASE=/etc/hadoop-kms/

# Rejigger the above if we're using parcels
if [ "$CDH_KMS_HOME" != "$DEFAULT_KMS_HOME" ]; then
    TOMCAT_CONF_BASE=$CDH_KMS_HOME/../../etc/hadoop-kms/
    DEPLOY_SCRIPT_BASE=$CDH_KMS_HOME
fi

# Construct the actual TOMCAT_CONF from the base and folder
TOMCAT_CONF=$TOMCAT_CONF_BASE/$TOMCAT_CONFIG_FOLDER

export CATALINA_BASE="$KMS_STAGING_DIR/tomcat-deployment"

# Set up the number of threads and heap size
export KMS_MAX_THREADS
export KMS_PROTOCOL
export KMS_ACCEPT_COUNT
export KMS_ACCEPTOR_THREAD_COUNT
export CATALINA_OPTS="-Xmx${KMS_HEAP_SIZE} ${CSD_JAVA_OPTS} ${KMS_JAVA_OPTS}"

# do some ssl password stuff in private
set +x

# Make sure settings are coherent
if [ "$SSL_ENABLED" = "true" -a \( -z "$KMS_SSL_KEYSTORE_FILE" -o -z "$KMS_SSL_KEYSTORE_PASS" \) ]; then
    echo "When SSL is enabled, the keystore location and password must be configured."
    exit 1
fi

#turn back on the logging
set -x

# Get Parcel Root to fix Key Trustee configuration directory location
PARCEL_ROOT=${KEYTRUSTEE_KP_HOME%%KEYTRUSTEE*}
echo "PARCEL_ROOT is ${PARCEL_ROOT}"

MIN_CDH_MAJOR_VERSION_WITH_BLANK_TRUSTSTORE_PWD=5
MIN_CDH_MINOR_VERSION_WITH_BLANK_TRUSTSTORE_PWD=10
UNKNOWN_VERSION="unknown version"

if [[ ! -f $KMS_HOME/cloudera/cdh_version.properties ]]; then
  CDH_VERSION=$UNKNOWN_VERSION
  CDH_MAJOR_VERSION=5
  CDH_MINOR_VERSION=4
  echo "$KMS_HOME/cloudera/cdh_version.properties not found. Assuming older version of CDH is being used."
else
  # example first line of version file: version=2.6.0-cdh5.9.3
  CDH_VERSION=$(grep "^version=" $KMS_HOME/cloudera/cdh_version.properties | cut -d '=' -f 2)
  CDH_MAJOR_VERSION=$(echo $CDH_VERSION | cut -d '-' -f 2 | sed 's/cdh//g' | cut -d '.' -f 1)
  CDH_MINOR_VERSION=$(echo $CDH_VERSION | cut -d '-' -f 2 | sed 's/cdh//g' | cut -d '.' -f 2)
  echo "CDH version found: ${CDH_VERSION}"
fi

# Setup Tomcat Truststore options
if [[ ${CDH_VERSION} == ${UNKNOWN_VERSION} || \
      ${CDH_MAJOR_VERSION} -lt ${MIN_CDH_MAJOR_VERSION_WITH_BLANK_TRUSTSTORE_PWD} || \
      ${CDH_MAJOR_VERSION} -eq ${MIN_CDH_MAJOR_VERSION_WITH_BLANK_TRUSTSTORE_PWD} && \
         ${CDH_MINOR_VERSION} -lt ${MIN_CDH_MINOR_VERSION_WITH_BLANK_TRUSTSTORE_PWD} ]]; then
  set +x
  export CATALINA_OPTS="$CATALINA_OPTS -Djavax.net.ssl.trustStore=${KMS_SSL_TRUSTSTORE_FILE} -Djavax.net.ssl.trustStorePassword=${KMS_SSL_TRUSTSTORE_PASS} -Dcdh.parcel.root=${PARCEL_ROOT}"
  CATALINA_OPTS_DISP=`echo ${CATALINA_OPTS} | sed -e 's/trustStorePassword=[^ ]*/trustStorePassword=***/'`
  #turn back on the logging
  set -x
  print "Using   CATALINA_OPTS:       ${CATALINA_OPTS_DISP}"
else
  export CATALINA_OPTS="$CATALINA_OPTS -Djavax.net.ssl.trustStore=${KMS_SSL_TRUSTSTORE_FILE} -Dcdh.parcel.root=${PARCEL_ROOT}"
  print "Using   CATALINA_OPTS:       ${CATALINA_OPTS}"
fi

KMS_PLUGIN_DIR=${KEYTRUSTEE_KP_HOME:-/usr/share/keytrustee-keyprovider}/lib

# Deploy KMS tomcat app.
env TOMCAT_CONF=${TOMCAT_CONF} TOMCAT_DEPLOYMENT=${CATALINA_BASE} KMS_HOME=${KMS_HOME} \
    KMS_PLUGIN_DIR=${KMS_PLUGIN_DIR} \
    bash ${DEPLOY_SCRIPT_BASE}/tomcat-deployment.sh

# Print out all the env vars we've set
echo "KMS_HOME is ${KMS_HOME}"
echo "KMS_LOG is ${KMS_LOG}"
echo "KMS_CONFIG is ${KMS_CONFIG}"
echo "KMS_MAX_THREADS is ${KMS_MAX_THREADS}"
echo "KMS_PROTOCOL is ${KMS_PROTOCOL}"
echo "KMS_ACCEPT_COUNT is ${KMS_ACCEPT_COUNT}"
echo "KMS_ACCEPTOR_THREAD_COUNT is ${KMS_ACCEPTOR_THREAD_COUNT}"
echo "KMS_HEAP_SIZE is ${KMS_HEAP_SIZE}"
echo "TOMCAT_CONF is ${TOMCAT_CONF}"
echo "CATALINA_BASE is ${CATALINA_BASE}"
echo "SSL_ENABLED is ${SSL_ENABLED}"
echo "KMS_SSL_KEYSTORE_FILE is ${KMS_SSL_KEYSTORE_FILE}"

echo "KMS_PLUGIN_DIR is ${KMS_PLUGIN_DIR}"
echo "KMS_SSL_TRUSTSTORE_FILE is ${KMS_SSL_TRUSTSTORE_FILE}"
echo "CSD_JAVA_OPTS is ${CSD_JAVA_OPTS}"
echo "KMS_JAVA_OPTS is ${KMS_JAVA_OPTS}"

# Add zk quorum to kms-site.xml
add_to_kms_site hadoop.kms.authentication.signer.secret.provider.zookeeper.connection.string $ZK_QUORUM

# replace {{CONF_DIR}} template in kms-site.xml
perl -pi -e "s#{{CONF_DIR}}#${CONF_DIR}#" ${CONF_DIR}/kms-site.xml

# replace {{TKP_INSECURE}} template in kts-site.xml
# "insecure" needs to be set to the opposite of "secure", aka SSL
TKP_INSECURE="false"
if [ "$SSL_ENABLED" = "false" ]; then
    TKP_INSECURE="true"
    unset KMS_SSL_KEYSTORE_PASS
    unset KMS_SSL_TRUSTSTORE_PASS
fi
if [ -n "$ZK_QUORUM" ]; then
    add_to_kms_site hadoop.kms.authentication.signer.secret.provider zookeeper
    add_to_kms_site hadoop.kms.authentication.zk-dt-secret-manager.enable true
fi
perl -pi -e "s#{{TKP_INSECURE}}#${TKP_INSECURE}#" ${CONF_DIR}/kts-site.xml

case $CMD in
    (start)
        cmd="${KMS_HOME}/sbin/kms.sh run"
        exec ${cmd}
        ;;
    (backup)
        if [ -f $KMS_PLUGIN_DIR/../../bin/ktbackup.sh ]; then
            cmd="${KMS_PLUGIN_DIR}/../../bin/ktbackup.sh  --cleartext --confdir=${KMS_CONFDIR}/.keytrustee --output=${KMS_CONFDIR}/.."
            exec ${cmd}
        else
            echo " The backup script does not exist. Will not be taking the backup."
        fi
        ;;
    (*)
        echo "Unknown command ${CMD}"
        exit 1
        ;;
esac
