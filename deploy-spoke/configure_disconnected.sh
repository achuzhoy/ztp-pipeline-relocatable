#!/usr/bin/env bash

set -o errexit
set -o pipefail
set -o nounset
set -m

function extract_kubeconfig() {
    ## Put Hub Kubeconfig in a safe place
    echo ">>>> Extracting all Kubeconfig from Hub cluster"
    if [[ ! -f "${OUTPUTDIR}/kubeconfig-hub" ]]; then
        cp ${KUBECONFIG_HUB} "${OUTPUTDIR}/kubeconfig-hub"
    fi

    ## Extract the Spoke kubeconfig and put it on the shared folder
    export SPOKE_KUBECONFIG="${OUTPUTDIR}/kubeconfig-${1}"
    echo "Exporting SPOKE_KUBECONFIG: ${SPOKE_KUBECONFIG}"
    oc --kubeconfig=${KUBECONFIG_HUB} get secret -n $spoke $spoke-admin-kubeconfig -o jsonpath='{.data.kubeconfig}' | base64 -d >${SPOKE_KUBECONFIG}
}

function icsp_mutate() {
    echo ">>>> Mutating Registry for: ${spoke}"
    MAP=${1}
    DST_REG=${2}
    SPOKE=${3}
    HUB_REG_ROUTE="$(oc --kubeconfig=${KUBECONFIG_HUB} get route -n ${REGISTRY} ${REGISTRY} -o jsonpath={'.status.ingress[0].host'})"
    export SPOKE_MAPPING_FILE="${MAP%%.*}-${spoke}.txt"
    sed "s/${HUB_REG_ROUTE}/${DST_REG}/g" ${MAP} | tee "${MAP%%.*}-${spoke}.txt"
}

function generate_mapping() {
    echo ">>>> Loading Common file"
    source ${WORKDIR}/${DEPLOY_REGISTRY_DIR}/common.sh ${MODE}
    echo ">>>> Creating OLM Manifests"
    echo "DEBUG: GODEBUG=x509ignoreCN=0 oc --kubeconfig=${TARGET_KUBECONFIG} adm catalog mirror ${OLM_DESTINATION_INDEX} ${DESTINATION_REGISTRY}/${OLM_DESTINATION_REGISTRY_IMAGE_NS} --registry-config=${PULL_SECRET} --manifests-only --to-manifests=${OUTPUTDIR}/olm-manifests"
    GODEBUG=x509ignoreCN=0 oc --kubeconfig=${TARGET_KUBECONFIG} adm catalog mirror ${OLM_DESTINATION_INDEX} ${DESTINATION_REGISTRY}/${OLM_DESTINATION_REGISTRY_IMAGE_NS} --registry-config=${PULL_SECRET} --manifests-only --to-manifests=${OUTPUTDIR}/olm-manifests
    echo ">>>> Copying mapping file to ${OUTPUTDIR}/mapping.txt"
    unalias cp || echo "Unaliased cp: Done!"
    cp -f ${OUTPUTDIR}/olm-manifests/mapping.txt ${OUTPUTDIR}/mapping.txt
}

function recover_mapping() {
    MAP_FILENAME='mapping.txt'
    echo ">>>> Finding Map file for OLM Sync"
    if [[ ! -f "${OUTPUTDIR}/${MAP_FILENAME}" ]]; then
        echo ">>>> No mapping file found for OLM Sync"
        MAP="${OUTPUTDIR}/${MAP_FILENAME}"
        find ${OUTPUTDIR} -name "${MAP_FILENAME}*" -exec cp {} ${MAP} \;
        if [[ ! -f ${MAP} ]]; then
            generate_mapping
        fi
    fi
}

function gen_header() {
    cat <<EOF >${ICSP_OUTFILE}
---
apiVersion: operator.openshift.io/v1alpha1
kind: ImageContentSourcePolicy
metadata:
  labels:
    operators.openshift.org/catalog: "true"
  name: kubeframe-${cluster}
spec:
  repositoryDigestMirrors:
EOF
}

function add_icsp_entry() {
    ## Add entry for every image on the packageManifests
    SRC_IMG=${1}
    DST_IMG=${2}

    cat <<EOF >>${ICSP_OUTFILE}
  - mirrors:
    - ${DST_IMG}
    source: ${SRC_IMG}
EOF

}

function icsp_maker() {
    # This function generated the ICSP for the current spoke
    if [[ $# -lt 3 ]]; then
        echo "Usage :"
        echo "  icsp_maker (MAPPING FILE) (ICSP DESTINATION FILE) hub|<spoke>"
        exit 1
    fi

    export MAP_FILE=${1}
    export ICSP_OUTFILE=${2}
    export cluster=${3}

    gen_header ${ICSP_OUTFILE} ${cluster}

    while read entry; do
        RAW_SRC=${entry%%=*}
        RAW_DST=${entry##*=}
        SRC_IMG="${RAW_SRC%%@*}"
        DST_IMG="${RAW_DST%%:*}"
        add_icsp_entry ${SRC_IMG} ${DST_IMG}
    done <${MAP_FILE}
}

function wait_for_mcp_ready() {
    # This function waits for the MCP to be ready
    # It will wait for the MCP to be ready for the given number of seconds
    # If the MCP is not ready after the given number of seconds, it will exit with an error
    if [[ $# -lt 3 ]]; then
        echo "Usage :"
        echo "wait_for_mcp_ready (kubeconfig) (spoke) (TIMEOUT)"
        exit 1
    fi

    export KUBECONF=${1}
    export SPOKE=${2}
    export TIMEOUT=${3}

    echo ">>>> Waiting for ${SPOKE} to be ready"
    for i in $(seq 1 ${TIMEOUT}); do
        echo ">>>> Showing nodes in Spoke"
        oc --kubeconfig=${KUBECONF} get nodes
        if [[ $(oc --kubeconfig=${KUBECONF} get mcp master -o jsonpath={'.status.readyMachineCount'}) -eq 3 ]]; then
            echo ">>>> MCP ${SPOKE} is ready"
            return 0
        fi
        sleep 10
        echo ">>>>"
    done

    echo ">>>> MCP ${SPOKE} is not ready after ${TIMEOUT} seconds"
    exit 1
}

# variables
# #########
# Load common vars
source ${WORKDIR}/shared-utils/common.sh
export MAP_FILENAME='mapping.txt'

MODE=${1}

if [[ ${MODE} == 'hub' ]]; then
    # Validation
    if [[ $# -lt 1 ]]; then
        echo "Usage :"
        echo "  $0 hub|spoke (STAGE (mandatory on spoke MODE))"
        exit 1
    fi

    echo ">>>> Creating ICSP for: Hub"
    TARGET_KUBECONFIG=${KUBECONFIG_HUB}
    recover_mapping
    icsp_maker ${OUTPUTDIR}/${MAP_FILENAME} ${OUTPUTDIR}/icsp-hub.yaml 'hub'
    oc --kubeconfig=${TARGET_KUBECONFIG} patch OperatorHub cluster --type json -p '[{"op": "add", "path": "/spec/disableAllDefaultSources", "value": true}]'
    oc --kubeconfig=${TARGET_KUBECONFIG} apply -f ${OUTPUTDIR}/catalogsource-hub.yaml
    oc --kubeconfig=${TARGET_KUBECONFIG} apply -f ${OUTPUTDIR}/icsp-hub.yaml

elif [[ ${MODE} == 'spoke' ]]; then
    # Validation
    if [[ $# -lt 2 ]]; then
        echo "Usage :"
        echo "  $0 hub|spoke (STAGE (mandatory on spoke MODE))"
        exit 1
    fi

    # STAGE is the value to reflect which step are you in
    #    if you didn't synced from Hub to Spoke you need to put 'pre'
    #    if you already synced from Hub to Spoke you need to put 'post'
    STAGE=${2}

    if [[ -z ${ALLSPOKES} ]]; then
        ALLSPOKES=$(yq e '(.spokes[] | keys)[]' ${SPOKES_FILE})
    fi

    for spoke in ${ALLSPOKES}; do
        # Get Spoke Kubeconfig
        if [[ ! -f "${OUTPUTDIR}/kubeconfig-${spoke}" ]]; then
            extract_kubeconfig ${spoke}
        else
            export SPOKE_KUBECONFIG="${OUTPUTDIR}/kubeconfig-${spoke}"
        fi

        TARGET_KUBECONFIG=${SPOKE_KUBECONFIG}
        recover_mapping
        # Logic
        # WC == 2 == SKIP / WC == 1 == Create ICSP
        RCICSP=$(oc --kubeconfig=${TARGET_KUBECONFIG} get ImageContentSourcePolicy kubeframe-${spoke} | wc -l || true)
        if [[ ${STAGE} == 'pre' ]]; then
            if [[ ${RCICSP} -eq 2 ]]; then
                echo "Skipping ICSP creation as it already exists"
            else
                # Spoke Sync from the Hub cluster as a Source
                echo ">>>> Deploying ICSP for: ${spoke} using the Hub as a source"
                oc --kubeconfig=${TARGET_KUBECONFIG} patch OperatorHub cluster --type json -p '[{"op": "add", "path": "/spec/disableAllDefaultSources", "value": true}]'
                oc --kubeconfig=${TARGET_KUBECONFIG} apply -f ${OUTPUTDIR}/catalogsource-hub.yaml
                oc --kubeconfig=${TARGET_KUBECONFIG} apply -f ${OUTPUTDIR}/icsp-hub.yaml
            fi
        elif [[ ${STAGE} == 'post' ]]; then
            if [[ ${RCICSP} -eq 2 ]]; then
                echo ">>>> Waiting for old stuff deletion..."
            else
                echo ">>>> Creating ICSP for: ${spoke}"
                # Use the Spoke's registry as a source
                source ${WORKDIR}/${DEPLOY_REGISTRY_DIR}/common.sh ${MODE}
                icsp_mutate ${OUTPUTDIR}/${MAP_FILENAME} ${DESTINATION_REGISTRY} ${spoke}
                icsp_maker ${SPOKE_MAPPING_FILE} ${OUTPUTDIR}/icsp-${spoke}.yaml ${spoke}

                # Clean Old stuff
                oc --kubeconfig=${TARGET_KUBECONFIG} delete -f ${OUTPUTDIR}/catalogsource-hub.yaml || echo "CatalogSoruce already deleted!"
                oc --kubeconfig=${TARGET_KUBECONFIG} delete -f ${OUTPUTDIR}/icsp-hub.yaml || echo "ICSP already deleted!"

                echo ">>>> Waiting for old stuff deletion..."
                sleep 20

                # Deploy New ICSP + CS
                oc --kubeconfig=${TARGET_KUBECONFIG} apply -f ${OUTPUTDIR}/catalogsource-${spoke}.yaml
                oc --kubeconfig=${TARGET_KUBECONFIG} apply -f ${OUTPUTDIR}/icsp-${spoke}.yaml

                wait_for_mcp_ready ${TARGET_KUBECONFIG} ${spoke} 240
            fi
        fi
    done
fi
