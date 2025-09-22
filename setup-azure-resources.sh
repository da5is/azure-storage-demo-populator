#!/bin/bash

# Azure Storage Demo Populator - Resource Setup Script
# This script creates a resource group, storage accounts, and assigns managed identity permissions

set -e  # Exit on any error

# Default configuration variables
DEFAULT_RESOURCE_GROUP="rg-storage-demo"
DEFAULT_LOCATION="eastus2"
DEFAULT_ACCOUNT_COUNT=2

# Parse command line arguments
RESOURCE_GROUP="$DEFAULT_RESOURCE_GROUP"
LOCATION="$DEFAULT_LOCATION"
ACCOUNT_COUNT="$DEFAULT_ACCOUNT_COUNT"

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo "Options:"
    echo "  -c, --count NUMBER     Number of storage accounts to create (default: $DEFAULT_ACCOUNT_COUNT)"
    echo "  -r, --region REGION    Azure region for resources (default: $DEFAULT_LOCATION)"
    echo "  -g, --group NAME       Resource group name (default: $DEFAULT_RESOURCE_GROUP)"
    echo "  -h, --help             Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 -c 3 -r westus2"
    echo "  $0 --count 5 --region eastus"
    echo "  $0 --help"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--count)
            ACCOUNT_COUNT="$2"
            if ! [[ "$ACCOUNT_COUNT" =~ ^[1-9][0-9]*$ ]]; then
                echo "Error: Account count must be a positive integer"
                exit 1
            fi
            shift 2
            ;;
        -r|--region)
            LOCATION="$2"
            if [[ -z "$LOCATION" ]]; then
                echo "Error: Region cannot be empty"
                exit 1
            fi
            shift 2
            ;;
        -g|--group)
            RESOURCE_GROUP="$2"
            if [[ -z "$RESOURCE_GROUP" ]]; then
                echo "Error: Resource group name cannot be empty"
                exit 1
            fi
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Error: Unknown option $1"
            usage
            ;;
    esac
done

# Generate storage account names
STORAGE_ACCOUNTS=()
TIMESTAMP=$(date +%s | tail -c 6)
for ((i=1; i<=ACCOUNT_COUNT; i++)); do
    STORAGE_ACCOUNTS+=("storagedemoacct${i}${TIMESTAMP}")
done

SUBSCRIPTION_ID=$(az account show --query id -o tsv)

echo "=========================================="
echo "Azure Storage Demo Populator Setup Script"
echo "=========================================="
echo "Resource Group: $RESOURCE_GROUP"
echo "Location: $LOCATION"
echo "Number of Storage Accounts: $ACCOUNT_COUNT"
for ((i=0; i<${#STORAGE_ACCOUNTS[@]}; i++)); do
    echo "Storage Account $((i+1)): ${STORAGE_ACCOUNTS[i]}"
done
echo "Subscription: $SUBSCRIPTION_ID"
echo "=========================================="

# Step 1: Check if Resource Group exists and get its location or create it
echo "Step 1: Checking resource group '$RESOURCE_GROUP'..."
EXISTING_LOCATION=$(az group show --name "$RESOURCE_GROUP" --query location -o tsv 2>/dev/null || echo "")
USER_SPECIFIED_LOCATION="$([[ "$LOCATION" != "$DEFAULT_LOCATION" ]] && echo "true" || echo "false")"

if [ ! -z "$EXISTING_LOCATION" ]; then
    echo "✓ Resource group '$RESOURCE_GROUP' already exists in location '$EXISTING_LOCATION'"
    if [ "$EXISTING_LOCATION" != "$LOCATION" ]; then
        if [ "$USER_SPECIFIED_LOCATION" = "true" ]; then
            echo "  WARNING: Resource group exists in '$EXISTING_LOCATION' but you specified '$LOCATION'"
            echo "  Resources will be created in the specified location '$LOCATION' (not the existing RG location)"
        else
            echo "  Using existing location '$EXISTING_LOCATION' instead of default '$LOCATION'"
            LOCATION="$EXISTING_LOCATION"
        fi
    fi
else
    echo "  Creating resource group '$RESOURCE_GROUP' in '$LOCATION'..."
    az group create \
        --name "$RESOURCE_GROUP" \
        --location "$LOCATION"
    echo "✓ Resource group created successfully"
fi

# Step 2: Create Storage Accounts
for ((i=0; i<${#STORAGE_ACCOUNTS[@]}; i++)); do
    ACCOUNT_NAME="${STORAGE_ACCOUNTS[i]}"
    STEP_NUM=$((i+2))
    echo ""
    echo "Step $STEP_NUM: Creating storage account '$ACCOUNT_NAME'..."
    az storage account create \
        --name "$ACCOUNT_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --location "$LOCATION" \
        --sku "Standard_LRS" \
        --kind "StorageV2" \
        --access-tier "Hot" \
        --allow-blob-public-access false \
        --min-tls-version "TLS1_2"
    echo "✓ Storage account $((i+1)) created successfully"
done

# Step 3: Get the current VM's managed identity principal ID
NEXT_STEP=$((${#STORAGE_ACCOUNTS[@]} + 2))
echo ""
echo "Step $NEXT_STEP: Getting current VM's managed identity..."

# Function to decode JWT payload and extract OID
decode_jwt_oid() {
    local token="$1"
    # Split JWT token and get payload (second part)
    local payload=$(echo "$token" | cut -d'.' -f2)
    
    # Add padding for base64 decoding if needed
    local padding=$((4 - ${#payload} % 4))
    if [ $padding -lt 4 ]; then
        payload="${payload}$(printf '=%.0s' $(seq 1 $padding))"
    fi
    
    # Decode base64 and extract oid using python
    echo "$payload" | python3 -c "
import base64
import json
import sys
try:
    data = base64.b64decode(sys.stdin.read().strip())
    payload = json.loads(data.decode('utf-8'))
    print(payload.get('oid', ''))
except:
    pass
"
}

# Try multiple methods to get the managed identity principal ID
PRINCIPAL_ID=""

# Method 1: Try using Azure CLI to get current identity
if command -v az >/dev/null 2>&1; then
    echo "  Trying Azure CLI method..."
    PRINCIPAL_ID=$(az account show --query user.name -o tsv 2>/dev/null | grep -E '^[0-9a-f-]{36}$' || echo "")
fi

# Method 2: Try using managed identity metadata endpoint
if [ -z "$PRINCIPAL_ID" ]; then
    echo "  Trying managed identity metadata endpoint..."
    ACCESS_TOKEN=$(curl -s --connect-timeout 5 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fmanagement.azure.com%2F' -H Metadata:true 2>/dev/null | jq -r '.access_token // empty' 2>/dev/null)
    if [ ! -z "$ACCESS_TOKEN" ] && [ "$ACCESS_TOKEN" != "null" ]; then
        PRINCIPAL_ID=$(decode_jwt_oid "$ACCESS_TOKEN")
    fi
fi

# Method 3: Try using Azure Instance Metadata Service for VM identity
if [ -z "$PRINCIPAL_ID" ]; then
    echo "  Trying Azure Instance Metadata Service..."
    VM_IDENTITY=$(curl -s --connect-timeout 5 'http://169.254.169.254/metadata/identity/info?api-version=2021-02-01' -H Metadata:true 2>/dev/null)
    if [ ! -z "$VM_IDENTITY" ]; then
        PRINCIPAL_ID=$(echo "$VM_IDENTITY" | jq -r '.principalId // empty' 2>/dev/null)
    fi
fi

if [ -z "$PRINCIPAL_ID" ]; then
    echo "⚠️  Could not automatically detect managed identity principal ID."
    echo "This could be due to:"
    echo "  - Running outside of an Azure VM with managed identity enabled"
    echo "  - Missing required tools (jq, python3, curl)"
    echo "  - Network connectivity issues"
    echo ""
    echo "Manual permission assignment required (see end of script output)."
else
    echo "✓ Managed identity principal ID: $PRINCIPAL_ID"
fi

# Function to assign role with retry logic
assign_role_with_retry() {
    local assignee="$1"
    local role="$2"
    local scope="$3"
    local max_attempts=3
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        echo "    Attempt $attempt/$max_attempts: Assigning $role..."
        
        if az role assignment create \
            --assignee "$assignee" \
            --role "$role" \
            --scope "$scope" \
            --output none 2>/dev/null; then
            echo "    ✓ Successfully assigned $role"
            return 0
        else
            # Check if assignment already exists
            if az role assignment list \
                --assignee "$assignee" \
                --role "$role" \
                --scope "$scope" \
                --query "[0].principalId" \
                --output tsv 2>/dev/null | grep -q "$assignee"; then
                echo "    ✓ Role $role already assigned"
                return 0
            fi
            
            if [ $attempt -eq $max_attempts ]; then
                echo "    ❌ Failed to assign $role after $max_attempts attempts"
                return 1
            else
                echo "    ⚠️  Failed to assign $role, retrying in 5 seconds..."
                sleep 5
            fi
        fi
        attempt=$((attempt + 1))
    done
}

# Initialize failure counters
FAILED_ASSIGNMENTS=()
TOTAL_FAILED=0

# Step 5+: Assign required permissions to all storage accounts
if [ ! -z "$PRINCIPAL_ID" ]; then
    ROLES=("Storage Blob Data Contributor" "Storage Queue Data Contributor" "Storage Table Data Contributor" "Storage File Data SMB Share Contributor")
    
    for ((i=0; i<${#STORAGE_ACCOUNTS[@]}; i++)); do
        ACCOUNT_NAME="${STORAGE_ACCOUNTS[i]}"
        PERM_STEP=$((${#STORAGE_ACCOUNTS[@]} + 3 + i))
        FAILED_ASSIGNMENTS[i]=0
        
        echo ""
        echo "Step $PERM_STEP: Assigning permissions to storage account '$ACCOUNT_NAME'..."
        
        STORAGE_SCOPE="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Storage/storageAccounts/$ACCOUNT_NAME"
        
        for role in "${ROLES[@]}"; do
            if ! assign_role_with_retry "$PRINCIPAL_ID" "$role" "$STORAGE_SCOPE"; then
                FAILED_ASSIGNMENTS[i]=$((${FAILED_ASSIGNMENTS[i]} + 1))
            fi
        done
        
        if [ ${FAILED_ASSIGNMENTS[i]} -eq 0 ]; then
            echo "✓ All permissions assigned to storage account '$ACCOUNT_NAME'"
        else
            echo "⚠️  ${FAILED_ASSIGNMENTS[i]} permission assignments failed for storage account '$ACCOUNT_NAME'"
        fi
        
        TOTAL_FAILED=$((TOTAL_FAILED + ${FAILED_ASSIGNMENTS[i]}))
    done
    
    # Check overall status
    if [ $TOTAL_FAILED -gt 0 ]; then
        echo ""
        echo "⚠️  $TOTAL_FAILED role assignments failed. You may need to assign them manually."
    fi
fi

# Step 7: Update the application configuration
CONFIG_STEP=$((${#STORAGE_ACCOUNTS[@]} + 4))
echo ""
echo "Step $CONFIG_STEP: Updating config.json with new storage account names..."

# Generate JSON for storage accounts
STORAGE_ACCOUNTS_JSON=""
for ((i=0; i<${#STORAGE_ACCOUNTS[@]}; i++)); do
    if [ $i -gt 0 ]; then
        STORAGE_ACCOUNTS_JSON="$STORAGE_ACCOUNTS_JSON,"
    fi
    STORAGE_ACCOUNTS_JSON="$STORAGE_ACCOUNTS_JSON
    {
      \"name\": \"${STORAGE_ACCOUNTS[i]}\",
      \"connectionString\": null
    }"
done

cat > config.json << EOF
{
  "authMode": "ManagedIdentity",
  "storageAccounts": [$STORAGE_ACCOUNTS_JSON
  ]
}
EOF
echo "✓ Configuration file updated"

echo ""
echo "=========================================="
echo "Setup Complete!"
echo "=========================================="
echo "Resource Group: $RESOURCE_GROUP"
for ((i=0; i<${#STORAGE_ACCOUNTS[@]}; i++)); do
    echo "Storage Account $((i+1)): ${STORAGE_ACCOUNTS[i]}"
done
echo ""
echo "The config.json file has been updated with the new storage account names."
echo "You can now run the application with: dotnet run"
echo ""
if [ -z "$PRINCIPAL_ID" ] || [ $TOTAL_FAILED -gt 0 ]; then
    echo "⚠️  IMPORTANT: Managed identity permissions require manual assignment."
    echo ""
    if [ -z "$PRINCIPAL_ID" ]; then
        echo "Could not automatically detect managed identity principal ID."
        echo "To assign permissions manually:"
        echo ""
        echo "1. Get your managed identity principal ID:"
        echo "   az ad sp list --display-name \"\$(hostname)\" --query '[0].id' -o tsv"
        echo "   # OR check in Azure portal: VM -> Identity -> Object (principal) ID"
        echo ""
        echo "2. Assign roles using Azure CLI:"
        echo "   PRINCIPAL_ID=<your-principal-id>"
        for ((i=0; i<${#STORAGE_ACCOUNTS[@]}; i++)); do
            echo "   # For storage account $((i+1)) (${STORAGE_ACCOUNTS[i]}):"
            echo "   az role assignment create --assignee \"\$PRINCIPAL_ID\" --role \"Storage Blob Data Contributor\" --scope \"/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Storage/storageAccounts/${STORAGE_ACCOUNTS[i]}\""
            echo "   az role assignment create --assignee \"\$PRINCIPAL_ID\" --role \"Storage Queue Data Contributor\" --scope \"/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Storage/storageAccounts/${STORAGE_ACCOUNTS[i]}\""
            echo "   az role assignment create --assignee \"\$PRINCIPAL_ID\" --role \"Storage Table Data Contributor\" --scope \"/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Storage/storageAccounts/${STORAGE_ACCOUNTS[i]}\""
            echo "   az role assignment create --assignee \"\$PRINCIPAL_ID\" --role \"Storage File Data SMB Share Contributor\" --scope \"/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Storage/storageAccounts/${STORAGE_ACCOUNTS[i]}\""
            if [ $i -lt $((${#STORAGE_ACCOUNTS[@]} - 1)) ]; then
                echo ""
            fi
        done
    else
        echo "Some role assignments failed. You can retry with:"
        echo ""
        echo "PRINCIPAL_ID=\"$PRINCIPAL_ID\""
        for role in "Storage Blob Data Contributor" "Storage Queue Data Contributor" "Storage Table Data Contributor" "Storage File Data SMB Share Contributor"; do
            for ((i=0; i<${#STORAGE_ACCOUNTS[@]}; i++)); do
                echo "az role assignment create --assignee \"\$PRINCIPAL_ID\" --role \"$role\" --scope \"/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Storage/storageAccounts/${STORAGE_ACCOUNTS[i]}\""
            done
        done
    fi
    echo ""
    echo "3. Alternatively, assign roles via Azure Portal:"
    echo "   Storage Account -> Access Control (IAM) -> Add role assignment"
    echo ""
fi
echo "=========================================="