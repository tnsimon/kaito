#!/usr/bin/env bash
set -euo pipefail

# This script interrogates the AKS cluster and Azure resources to generate
# the required identities and role assignment for either gpu-provisioner or karpenter.
# The script takes three arguments: the name of the AKS cluster, the resource group where the AKS cluster is deployed,
# and the name of the component for which the identities and role assignments are being created.
# # Path: hack/deploy/deploy.sh

if [ "$#" -ne 4 ]; then
    echo "Usage: $0 <cluster-name> <resource-group> <component-name> <subscription-id>"
    exit 1
fi

echo "Generating Identities for cluster $1 in resource group $2 to run $3 ..."

AZURE_CLUSTER_NAME=$1
AZURE_RESOURCE_GROUP=$2
COMPONENT_NAME=$3

AZURE_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
AKS_JSON=$(az aks show --name "${AZURE_CLUSTER_NAME}" --resource-group "${AZURE_RESOURCE_GROUP}")
IDENTITY_NAME=${COMPONENT_NAME}Identity
FED_NAME=${COMPONENT_NAME}-fed

if [[ "${COMPONENT_NAME}" == "azkarpenter" ]]; then
  NAMESPACE="karpenter"
  SA_NAME="karpenter-sa"
else
  NAMESPACE="gpu-provisioner"
  SA_NAME="gpu-provisioner"
fi

echo "Creating the workload MSI for $COMPONENT_NAME ..."
IDENTITY_JSON=$(az identity create --name "${IDENTITY_NAME}" --resource-group "${AZURE_RESOURCE_GROUP}")
echo "IDENTITY_JSON: $IDENTITY_JSON"

IDENTITY_PRINCIPAL_ID=$(jq -r '.principalId' <<< "$IDENTITY_JSON")

AZURE_RESOURCE_GROUP_RESOURCE_ID=$(az group show --name "${AZURE_RESOURCE_GROUP}" --query "id" -otsv)

AZURE_RESOURCE_GROUP_MC=$(jq -r ".nodeResourceGroup" <<< "$AKS_JSON")
AZURE_RESOURCE_GROUP_MC_RESOURCE_ID=$(az group show --name "${AZURE_RESOURCE_GROUP_MC}" --query "id" -otsv)

sleep 40 ## wait for the identity credential to be created

echo "Creating federated credential linked to the $COMPONENT_NAME service account ..."
AKS_OIDC_ISSUER=$(jq -r ".oidcIssuerProfile.issuerUrl" <<< "$AKS_JSON")
az identity federated-credential create --name "${FED_NAME}" \
--identity-name "${IDENTITY_NAME}" --resource-group "${AZURE_RESOURCE_GROUP}" \
--issuer "${AKS_OIDC_ISSUER}" --audience api://AzureADTokenExchange \
--subject system:serviceaccount:"${NAMESPACE}:${SA_NAME}"

if [[ "${COMPONENT_NAME}" == "azkarpenter" ]]; then
  echo "Creating role assignments for $COMPONENT_NAME ..."
  # Well-known role definition IDs
  ROLE_IDS=("9980e02c-c2be-4d73-94e8-173b1dc7cf3c" "4d97b98b-1d4f-4787-a291-c67834d212e7" "f1a07417-d97a-45cb-824c-7a7467783830")
  ROLE_NAMES=("Virtual Machine Contributor" "Network Contributor" "Managed Identity Operator")
  SCOPE="$AZURE_RESOURCE_GROUP_MC_RESOURCE_ID"
  for i in "${!ROLE_IDS[@]}"; do
    echo "  Assigning ${ROLE_NAMES[$i]} ..."
    ASSIGNMENT_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')
    az rest --method PUT \
      --url "https://management.azure.com${SCOPE}/providers/Microsoft.Authorization/roleAssignments/${ASSIGNMENT_ID}?api-version=2022-04-01" \
      --body "{\"properties\":{\"roleDefinitionId\":\"/subscriptions/${AZURE_SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/${ROLE_IDS[$i]}\",\"principalId\":\"${IDENTITY_PRINCIPAL_ID}\",\"principalType\":\"ServicePrincipal\"}}" \
      -o none 2>&1 || echo "    (may already exist, continuing)"
  done
else
  echo "Creating role assignments for $COMPONENT_NAME ..."
  # Contributor role definition ID
  ASSIGNMENT_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')
  az rest --method PUT \
    --url "https://management.azure.com${AZURE_RESOURCE_GROUP_RESOURCE_ID}/providers/Microsoft.Authorization/roleAssignments/${ASSIGNMENT_ID}?api-version=2022-04-01" \
    --body "{\"properties\":{\"roleDefinitionId\":\"/subscriptions/${AZURE_SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/b24988ac-6180-42a0-ab88-20f7382dd24c\",\"principalId\":\"${IDENTITY_PRINCIPAL_ID}\",\"principalType\":\"ServicePrincipal\"}}" \
    -o none 2>&1 || echo "    (may already exist, continuing)"
fi

echo "Identities and role assignments for $COMPONENT_NAME have been created successfully."
