#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# KAITO Local E2E Test Runner
#
# Uses `tilt up` to build, push, and deploy the workspace controller, then
# runs the e2e test suite against it.
#
# Usage:
#   ./run-e2e.sh                  # Full run: create cluster + deploy + test
#   ./run-e2e.sh --skip-create    # Skip cluster/ACR creation (reuse existing)
#   ./run-e2e.sh --skip-tilt      # Skip tilt (controller already running)
#   ./run-e2e.sh --cleanup        # Delete the resource group when done
#   ./run-e2e.sh --cleanup-only   # Just delete the resource group and exit
#
# Customize by editing the variables below or exporting them before running.
###############################################################################

# ---------------------------------------------------------------------------
# Configuration  (override any of these via environment before running)
# ---------------------------------------------------------------------------
USER="$(whoami)"
export AZURE_RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-${USER}rg}"
export AZURE_LOCATION="${AZURE_LOCATION:-swedencentral}"
export AZURE_CLUSTER_NAME="${AZURE_CLUSTER_NAME:-${USER}aks}"
export AZURE_SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-$(az account show --query id -o tsv)}"

# ACR name (must be alphanumeric only, no dots)
ACR_NAME="$(echo "${AZURE_CLUSTER_NAME}" | tr '[:upper:]' '[:lower:]' | tr -d '-')"
export REGISTRY="${ACR_NAME}.azurecr.io"

# Test configuration
export TEST_SUITE="${TEST_SUITE:-gpuprovisioner}"
export KAITO_NAMESPACE="${KAITO_NAMESPACE:-kaito-workspace}"
export GPU_PROVISIONER_NAMESPACE="${GPU_PROVISIONER_NAMESPACE:-gpu-provisioner}"
export GPU_PROVISIONER_NAME="${GPU_PROVISIONER_NAME:-gpu-provisioner}"
export KARPENTER_NAMESPACE="${KARPENTER_NAMESPACE:-karpenter}"

# Ginkgo settings
export GINKGO_NODES="${GINKGO_NODES:-1}"
export GINKGO_LABEL="${GINKGO_LABEL:-FastCheck}"
export GINKGO_FOCUS="${GINKGO_FOCUS:-}"
export GINKGO_SKIP="${GINKGO_SKIP:-}"
export GINKGO_TIMEOUT="${GINKGO_TIMEOUT:-120m}"

# Secret names (used by test suite to pull images inside cluster)
export AI_MODELS_REGISTRY_SECRET="${AI_MODELS_REGISTRY_SECRET:-${ACR_NAME}-models-secret}"
export E2E_ACR_REGISTRY_SECRET="${E2E_ACR_REGISTRY_SECRET:-${ACR_NAME}-acr-secret}"
export AI_MODELS_REGISTRY="${AI_MODELS_REGISTRY:-${REGISTRY}}"
export E2E_ACR_REGISTRY="${E2E_ACR_REGISTRY:-${REGISTRY}}"

export SUPPORTED_MODELS_YAML_PATH="${SUPPORTED_MODELS_YAML_PATH:-$(pwd)/presets/workspace/models/supported_models.yaml}"

# ---------------------------------------------------------------------------
# Parse flags
# ---------------------------------------------------------------------------
SKIP_CREATE=false
SKIP_TILT=false
CLEANUP=false
CLEANUP_ONLY=false
for arg in "$@"; do
  case "$arg" in
    --skip-create)  SKIP_CREATE=true ;;
    --skip-tilt)    SKIP_TILT=true ;;
    --cleanup)      CLEANUP=true ;;
    --cleanup-only) CLEANUP_ONLY=true ;;
    *)              echo "Unknown flag: $arg"; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Fast path: --cleanup-only deletes the resource group and exits immediately
# ---------------------------------------------------------------------------
if [ "$CLEANUP_ONLY" = true ]; then
  cleanup_resource_group
  log "Done!"
  exit 0
fi

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------
log()  { echo -e "\n\033[1;34m==> $*\033[0m"; }
ok()   { echo -e "\033[1;32m    OK\033[0m"; }
fail() { echo -e "\033[1;31m    FAILED: $*\033[0m"; exit 1; }

check_tool() {
  command -v "$1" &>/dev/null || fail "'$1' is required but not found in PATH"
}

cleanup_resource_group() {
  log "Cleaning up resource group '${AZURE_RESOURCE_GROUP}'"
  az group delete --name "${AZURE_RESOURCE_GROUP}" --yes --no-wait
  echo "    Deletion started (async). Resources will be removed in the background."
}

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
log "Preflight checks"
for tool in az kubectl helm podman tilt yq; do
  check_tool "$tool"
done
ok

# ---------------------------------------------------------------------------
# Step 1: Create Azure infrastructure (resource group, ACR, AKS)
# ---------------------------------------------------------------------------
if [ "$SKIP_CREATE" = false ]; then

  log "Creating resource group '${AZURE_RESOURCE_GROUP}' in '${AZURE_LOCATION}'"
  az group create --name "${AZURE_RESOURCE_GROUP}" --location "${AZURE_LOCATION}" -o none
  ok

  log "Creating ACR '${ACR_NAME}' (admin-enabled)"
  az acr create --resource-group "${AZURE_RESOURCE_GROUP}" \
    --name "${ACR_NAME}" \
    --sku Basic \
    --admin-enabled true \
    -o none 2>/dev/null || echo "    ACR already exists, continuing..."
  ok

  log "Creating AKS cluster '${AZURE_CLUSTER_NAME}'"
  az aks create \
    --name "${AZURE_CLUSTER_NAME}" \
    --resource-group "${AZURE_RESOURCE_GROUP}" \
    --location "${AZURE_LOCATION}" \
    --attach-acr "${ACR_NAME}" \
    --generate-ssh-keys \
    --enable-managed-identity \
    --enable-workload-identity \
    --enable-oidc-issuer \
    --node-vm-size Standard_D4ads_v5 \
    -o none 2>/dev/null || echo "    AKS cluster already exists, continuing..."
  ok

  log "Getting AKS credentials (needed for identity + helm steps)"
  az aks get-credentials \
    --name "${AZURE_CLUSTER_NAME}" \
    --resource-group "${AZURE_RESOURCE_GROUP}" \
    --overwrite-existing
  ok

  log "Generating identities for ${TEST_SUITE}"
  make generate-identities \
    AZURE_CLUSTER_NAME="${AZURE_CLUSTER_NAME}" \
    AZURE_RESOURCE_GROUP="${AZURE_RESOURCE_GROUP}" \
    TEST_SUITE="${TEST_SUITE}" \
    AZURE_SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID}"
  ok

  log "Installing node provisioner (${TEST_SUITE})"
  if [ "${TEST_SUITE}" = "azkarpenter" ]; then
    make azure-karpenter-helm \
      AZURE_CLUSTER_NAME="${AZURE_CLUSTER_NAME}" \
      AZURE_RESOURCE_GROUP="${AZURE_RESOURCE_GROUP}" \
      KARPENTER_NAMESPACE="${KARPENTER_NAMESPACE}"
  elif [ "${TEST_SUITE}" = "gpuprovisioner" ]; then
    make gpu-provisioner-helm \
      AZURE_CLUSTER_NAME="${AZURE_CLUSTER_NAME}" \
      AZURE_RESOURCE_GROUP="${AZURE_RESOURCE_GROUP}" \
      GPU_PROVISIONER_NAMESPACE="${GPU_PROVISIONER_NAMESPACE}"
  else
    echo "    Skipping provisioner install (TEST_SUITE=${TEST_SUITE})"
  fi
  ok
fi

# ---------------------------------------------------------------------------
# Step 2: Get cluster credentials
# ---------------------------------------------------------------------------
log "Getting AKS credentials"
az aks get-credentials \
  --name "${AZURE_CLUSTER_NAME}" \
  --resource-group "${AZURE_RESOURCE_GROUP}" \
  --overwrite-existing
ok

kubectl get nodes

# ---------------------------------------------------------------------------
# Step 3: ACR login + credentials for Podman (host + machine)
# ---------------------------------------------------------------------------
log "Retrieving ACR credentials"
ACR_USERNAME="${ACR_NAME}"
ACR_PASSWORD="$(az acr credential show \
  --name "${ACR_NAME}" \
  --resource-group "${AZURE_RESOURCE_GROUP}" \
  --query "passwords[0].value" -o tsv)"
export ACR_USERNAME ACR_PASSWORD

log "Logging in to ACR on Podman host"
podman login "${REGISTRY}" \
  -u "${ACR_USERNAME}" \
  -p "${ACR_PASSWORD}"
ok

log "Logging in to ACR inside Podman machine"
podman machine ssh podman-machine-default \
  "podman login ${REGISTRY} -u '${ACR_USERNAME}' -p '${ACR_PASSWORD}'" 2>/dev/null \
  || echo "    Podman machine login skipped (no machine or already logged in)"
ok

# ---------------------------------------------------------------------------
# Step 4: Build and push e2e test fixture images
# ---------------------------------------------------------------------------
log "Building and pushing e2e adapter images"

# e2e-adapter
podman build --platform linux/amd64 \
  --build-arg ADAPTER_PATH=docker/adapters/adapter1 \
  -f docker/adapters/Dockerfile \
  -t "${REGISTRY}/e2e-adapter:0.0.1" .
podman push "${REGISTRY}/e2e-adapter:0.0.1"

# e2e-adapter2
podman build --platform linux/amd64 \
  --build-arg ADAPTER_PATH=docker/adapters/adapter2 \
  -f docker/adapters/Dockerfile \
  -t "${REGISTRY}/e2e-adapter2:0.0.1" .
podman push "${REGISTRY}/e2e-adapter2:0.0.1"

# adapter-phi-3-mini-pycoder
podman build --platform linux/amd64 \
  --build-arg ADAPTER_PATH=docker/adapters/adapter-phi-3-mini-pycoder \
  -f docker/adapters/Dockerfile \
  -t "${REGISTRY}/adapter-phi-3-mini-pycoder:0.0.1" .
podman push "${REGISTRY}/adapter-phi-3-mini-pycoder:0.0.1"
ok

log "Building and pushing e2e dataset images"

# e2e-dataset
podman build --platform linux/amd64 \
  --build-arg DATASET_PATH=docker/datasets/dataset1 \
  -f docker/datasets/Dockerfile \
  -t "${REGISTRY}/e2e-dataset:0.0.1" .
podman push "${REGISTRY}/e2e-dataset:0.0.1"

# e2e-dataset2
podman build --platform linux/amd64 \
  --build-arg DATASET_PATH=docker/datasets/dataset2 \
  -f docker/datasets/Dockerfile \
  -t "${REGISTRY}/e2e-dataset2:0.0.1" .
podman push "${REGISTRY}/e2e-dataset2:0.0.1"
ok

# ---------------------------------------------------------------------------
# Step 5: Create image pull secrets in the 'default' namespace
#         (BeforeSuite copies these into the test namespace automatically)
# ---------------------------------------------------------------------------
log "Creating image pull secrets in 'default' namespace"

kubectl delete secret "${AI_MODELS_REGISTRY_SECRET}" --namespace default --ignore-not-found
kubectl create secret docker-registry "${AI_MODELS_REGISTRY_SECRET}" \
  --namespace default \
  --docker-server="${REGISTRY}" \
  --docker-username="${ACR_USERNAME}" \
  --docker-password="${ACR_PASSWORD}"

kubectl delete secret "${E2E_ACR_REGISTRY_SECRET}" --namespace default --ignore-not-found
kubectl create secret docker-registry "${E2E_ACR_REGISTRY_SECRET}" \
  --namespace default \
  --docker-server="${REGISTRY}" \
  --docker-username="${ACR_USERNAME}" \
  --docker-password="${ACR_PASSWORD}"
ok

# ---------------------------------------------------------------------------
# Step 6: Deploy KAITO workspace controller via Tilt
#         Tilt handles: CRD generation, image build+push, Helm deploy, live-reload
# ---------------------------------------------------------------------------
if [ "$SKIP_TILT" = false ]; then

  # Ensure tilt-settings.yaml is configured for this cluster/registry
  log "Writing tilt-settings.yaml"
  cat > tilt-settings.yaml <<EOF
default_registry: ${REGISTRY}
allowed_contexts:
  - ${AZURE_CLUSTER_NAME}
cluster_name: ${AZURE_CLUSTER_NAME}
build_engine: podman
EOF
  cat tilt-settings.yaml
  ok

  log "Starting Tilt (building, pushing, and deploying controller)"
  log "Tilt will run in CI mode — it exits once all resources are ready"
  tilt ci 2>&1 | tee /tmp/tilt-e2e.log || {
    echo ""
    log "Tilt failed — check /tmp/tilt-e2e.log for details"
    fail "tilt ci exited with an error"
  }
  ok

  log "Waiting for kaito-workspace deployment to be ready"
  kubectl wait --for=condition=available deploy "kaito-workspace" \
    -n "${KAITO_NAMESPACE}" --timeout=300s
  ok
fi

# ---------------------------------------------------------------------------
# Step 7: Run e2e tests
# ---------------------------------------------------------------------------
log "Running e2e tests (GINKGO_LABEL=${GINKGO_LABEL}, GINKGO_NODES=${GINKGO_NODES})"
echo "  TEST_SUITE=${TEST_SUITE}"
echo "  AI_MODELS_REGISTRY=${AI_MODELS_REGISTRY}"
echo "  E2E_ACR_REGISTRY=${E2E_ACR_REGISTRY}"
echo "  KAITO_NAMESPACE=${KAITO_NAMESPACE}"
echo "  AZURE_CLUSTER_NAME=${AZURE_CLUSTER_NAME}"

make kaito-workspace-e2e-test \
  TEST_SUITE="${TEST_SUITE}" \
  KAITO_NAMESPACE="${KAITO_NAMESPACE}" \
  GPU_PROVISIONER_NAMESPACE="${GPU_PROVISIONER_NAMESPACE}" \
  GPU_PROVISIONER_NAME="${GPU_PROVISIONER_NAME}" \
  KARPENTER_NAMESPACE="${KARPENTER_NAMESPACE}" \
  AI_MODELS_REGISTRY="${AI_MODELS_REGISTRY}" \
  AI_MODELS_REGISTRY_SECRET="${AI_MODELS_REGISTRY_SECRET}" \
  E2E_ACR_REGISTRY="${E2E_ACR_REGISTRY}" \
  E2E_ACR_REGISTRY_SECRET="${E2E_ACR_REGISTRY_SECRET}" \
  SUPPORTED_MODELS_YAML_PATH="${SUPPORTED_MODELS_YAML_PATH}" \
  AZURE_CLUSTER_NAME="${AZURE_CLUSTER_NAME}" \
  GINKGO_NODES="${GINKGO_NODES}" \
  GINKGO_LABEL="${GINKGO_LABEL}" \
  GINKGO_FOCUS="${GINKGO_FOCUS}" \
  GINKGO_SKIP="${GINKGO_SKIP}" \
  GINKGO_TIMEOUT="${GINKGO_TIMEOUT}"

# ---------------------------------------------------------------------------
# Step 8: Optional cleanup
# ---------------------------------------------------------------------------
if [ "$CLEANUP" = true ]; then
  cleanup_resource_group
fi

log "Done!"
