#!/usr/bin/env bash

set -euo pipefail

# Check if the DEBUG env var is set to true
if [ "${DEBUG:-false}" = "true" ]; then
    set -x
fi

NETWORK_OPERATOR_NS="network-operator"

function wait_until_mofed_is_ready() {
    mofed_label="nvidia.com/ofed-driver"

    # Wait until the number of nodes with label 'network.nvidia.com/operator.mofed.wait: "false"' is equal to the number of mofed pods.
    while true; do
        # Get the mofed pod count
        mofed_pods_count="$(kubectl get pods \
            -n ${NETWORK_OPERATOR_NS} \
            -l ${mofed_label} \
            --no-headers | wc -l)"

        # Get the number of nodes with label 'network.nvidia.com/operator.mofed.wait: "false"'
        nodes_with_mofed_wait_false="$(kubectl get nodes \
            -l "network.nvidia.com/operator.mofed.wait=false" \
            --no-headers | wc -l)"

        if [[ "${mofed_pods_count}" -gt 0 && "${mofed_pods_count}" -eq "${nodes_with_mofed_wait_false}" ]]; then
            echo "✅ MOFED driver is successfully installed on all nodes."
            break
        fi

        [[ "${mofed_pods_count}" -eq 0 ]] && echo "⏳ Waiting for mofed pods to show up..."
        echo "⏳ Waiting for all nodes to be labeled 'network.nvidia.com/operator.mofed.wait=false' ..."
        sleep 2
    done
}

function wait_until_sriov_is_ready() {
    sriov_label="app=sriovdp"

    echo "⏳ Waiting for all sriov pods in namespace ${NETWORK_OPERATOR_NS} to be in 'Running' phase..."

    while true; do
        pods_json=$(kubectl get pods -n "${NETWORK_OPERATOR_NS}" -l "$sriov_label" -o json)

        total=$(echo "${pods_json}" | jq '.items | length')
        running=$(echo "${pods_json}" | jq '[.items[] | select(.status.phase == "Running")] | length')

        if [ "${total}" -eq "${running}" ] && [ "${total}" -ne 0 ]; then
            echo "✅ All ${total} pods are in 'Running' state."
            break
        else
            echo "⏳ Waiting, ${running}/${total} pods running..."
            sleep 5
        fi
    done

    echo -e '\nRDMA IB devices on nodes:\n'
    rdma_ib_on_nodes_cmd="kubectl get nodes -o json | jq -r '.items[] | {name: .metadata.name, \"rdma/ib\": .status.allocatable[\"rdma/ib\"]}'"
    echo "$ ${rdma_ib_on_nodes_cmd}"
    eval "${rdma_ib_on_nodes_cmd}"
}

function wait_until_rdma_is_ready() {
    rdma_label="app=rdma-shared-dp"

    echo "⏳ Waiting for all rdma-shared-dp pods in namespace ${NETWORK_OPERATOR_NS} to be in 'Running' phase..."

    while true; do
        pods_json=$(kubectl get pods -n "${NETWORK_OPERATOR_NS}" -l "${rdma_label}" -o json)

        total=$(echo "${pods_json}" | jq '.items | length')
        running=$(echo "${pods_json}" | jq '[.items[] | select(.status.phase == "Running")] | length')

        if [ "${total}" -eq "${running}" ] && [ "${total}" -ne 0 ]; then
            echo "✅ All rdma-shared-dp ${total} pods are in 'Running' state."
            break
        else
            echo "⏳ Waiting for rdma-shared-dp, ${running}/${total} pods running..."
            sleep 5
        fi
    done

    echo -e '\nRDMA Shared IB devices on nodes:\n'
    rdma_ib_on_nodes_cmd="kubectl get nodes -o json | jq -r '.items[] | {name: .metadata.name, \"rdma/shared_ib\": .status.allocatable[\"rdma/shared_ib\"]}'"
    echo "$ ${rdma_ib_on_nodes_cmd}"
    eval "${rdma_ib_on_nodes_cmd}"
}

function _check_if_all_pods_in_ds_are_ready() {
    namespace="${1}"
    ds_name="${2}"

    ready=$(kubectl get daemonset "$ds_name" -n "$namespace" -o jsonpath='{.status.numberReady}')
    desired=$(kubectl get daemonset "$ds_name" -n "$namespace" -o jsonpath='{.status.desiredNumberScheduled}')

    [[ "$ready" -eq "$desired" ]] && return 0

    return 1
}

function wait_until_ipoib_is_ready() {
    ds_list=(
        cni-plugins-ds
        kube-ipoib-cni-ds
        kube-multus-ds
        whereabouts
    )

    while true; do
        all_ready=true
        for ds in "${ds_list[@]}"; do
            if ! _check_if_all_pods_in_ds_are_ready "${NETWORK_OPERATOR_NS}" "${ds}"; then
                all_ready=false
                echo "⏳ Waiting for DaemonSet '$ds' in namespace '${NETWORK_OPERATOR_NS}' to be ready..."
            else
                echo "✅ DaemonSet '$ds' in namespace '${NETWORK_OPERATOR_NS}' is ready."
            fi
        done

        if [[ "$all_ready" == true ]]; then
            echo "✅ All DaemonSets are ready!"
            break
        else
            echo "⏳ Waiting for all DaemonSets to be ready..."
            sleep 5
        fi
    done
}

function ipoib_add_ep_ip() {
    while true; do
        ep_ip=$(kubectl get pods -l role=leader -o json | jq -r '
        .items[]
            | select(.metadata.annotations["k8s.v1.cni.cncf.io/network-status"] != null)
            | .metadata.annotations["k8s.v1.cni.cncf.io/network-status"]
            | fromjson
            | map(select(.name == "default/aks-infiniband"))[0]
            | if . == null then
                error("Network name is not default/aks-infiniband")
              else
                .ips[0]
              end')

        # Break only if ep_ip is not empty
        if [[ -n "${ep_ip}" ]]; then
            echo "✅ Found leader pod Infiniband IP: ${ep_ip}".
            break
        fi
        echo "⏳ Waiting for leader pod to be ready..."
        sleep 5
    done

    kubectl apply -f - <<EOF
apiVersion: v1
kind: Endpoints
metadata:
  name: leader-ib
subsets:
  - addresses:
      - ip: ${ep_ip}
EOF
}

function find_gpu_per_node() {
    case "${NODE_POOL_VM_SIZE}" in
    "Standard_ND96asr_v4" | "Standard_ND96amsr_A100_v4")
        GPU_PER_NODE=eight
        ;;
    *)
        echo "❌ Unknown VM size: $NODE_POOL_VM_SIZE"
        exit 1
        ;;
    esac
}

function fail_on_job_failure() {
    # As soon as the job fails, print the logs and exit with an error.
    while true; do
        JOB_STATUS="$(kubectl get job -l "${1}" -n "${2}" -o jsonpath='{.items[*].status.conditions[?(@.type=="Failed")].status}')"
        if [[ "${JOB_STATUS}" == "True" ]]; then
            echo
            echo "❌ Job '${1}' in namespace '${2}' failed. Printing logs..."
            echo
            kubectl logs -n "$2" "$(kubectl get pods -n "$2" -l "${1}" -o jsonpath='{.items[0].metadata.name}')" --all-containers
            exit 1
        fi

        JOB_STATUS="$(kubectl get job -l "${1}" -n "${2}" -o jsonpath='{.items[*].status.conditions[?(@.type=="Complete")].status}')"
        if [[ "${JOB_STATUS}" == "True" ]]; then
            echo
            echo "✅ Job '${1}' in namespace '${2}' succeeded. Printing logs..."
            echo
            kubectl logs -n "$2" "$(kubectl get pods -n "$2" -l "${1}" -o jsonpath='{.items[0].metadata.name}')" --all-containers
            break
        fi

        echo "⏳ Waiting for job with label '${1}' in namespace '${2}' to complete..."
        sleep 5
    done
}
