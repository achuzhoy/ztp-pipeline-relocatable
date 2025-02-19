#!/usr/bin/env bash

set -o pipefail
set -o nounset
set -m

# variables
# #########
# uncomment it, change it or get it from gh-env vars (default behaviour: get from gh-env)
# export KUBECONFIG=/root/admin.kubeconfig

# Load common vars
source ${WORKDIR}/shared-utils/common.sh
source ./common.sh hub

MODE=${1}

if [[ ${MODE} == 'hub' ]]; then
    TARGET_KUBECONFIG=${KUBECONFIG_HUB}
elif [[ ${MODE} == 'spoke' ]]; then
    TARGET_KUBECONFIG=${SPOKE_KUBECONFIG}
fi

podman login ${DESTINATION_REGISTRY} -u ${REG_US} -p ${REG_PASS} --authfile=${PULL_SECRET}                                                                                                                             # to create a merge with the registry original adding the registry auth entry
if [[ $(oc --kubeconfig=${TARGET_KUBECONFIG} adm release info "${DESTINATION_REGISTRY}"/"${OCP_DESTINATION_REGISTRY_IMAGE_NS}":"${OCP_RELEASE_FULL}"-x86_64 --registry-config="${PULL_SECRET}" | wc -l) -gt 1 ]]; then ## line 1 == error line. If found image should show more information (>1 line)
    #Everyting is ready
    exit 0
fi
#image has not been pulled and does not exist. Launching the step to create it...
exit 1
