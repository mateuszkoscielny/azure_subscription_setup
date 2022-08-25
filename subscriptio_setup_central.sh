#!/bin/bash
# In order to use the script you require files called Providers.txt and lwactivitylog.json that will be provided with the script.
# bash ./subscription_setup.sh <storage account ID for central log>
# Checking if CustomNodeConfigPreview feature is registered and if not register it
location="centralus"
echo "Checking if CustomNodeConfigPreview feature is registerd?"
CustomNodeConfigPreview=$(az feature show --namespace microsoft.ContainerService --name CustomNodeConfigPreview --query properties.state --output tsv)
NotRegistered="NotRegistered"
if [[ "$CustomNodeConfigPreview" = "$NotRegistered" ]]; then
    echo "CustomNodeConfigPreview is NotRegistered"
    az feature register --namespace microsoft.ContainerService --name CustomNodeConfigPreview
else
    echo "CustomNodeConfigPreview is Registered"
fi
# Checking if AKS-NATGatewayPreview feature is registered and if not register it
echo "Checking if AKS-NATGatewayPreview feature is registerd?"
NATGatewayPreview=$(az feature show --namespace microsoft.ContainerService --name AKS-NATGatewayPreview --query properties.state --output tsv)
if [[ "$NATGatewayPreview" = "$NotRegistered" ]]; then
    echo "AKS-NATGatewayPreview is NotRegistered"
    az feature register --namespace microsoft.ContainerService --name AKS-NATGatewayPreview
else
    echo "AKS-NATGatewayPreview is Registered"
fi
#Add Reader role for Lacework log reader for the subscription
echo "Getting AppId for Lacework log reader"
AppIdLacework=$(az ad app list --display-name 'Lacework log app' --query "[].appId" --output tsv)
SpIdLacework=$(az ad sp show --id "$AppIdLacework" --query id --output tsv)
RoleAssigmentReader=$(az role assignment list --role "Reader" --assignee "$SpIdLacework")
if [[ "$RoleAssigmentReader" = "[]" ]]; then
    echo "Role assignment is empty"
    echo "Role assignment will take place for object id $SpIdLacework"
    az role assignment create --role "Reader" --assignee-object-id "$SpIdLacework" --assignee-principal-type ServicePrincipal
else
    echo "Role assignment for role Reader is already was done"
fi
# Check if Provider form file is registered and if not registering it
while IFS= read -r provider; do
    printf 'Checking provider %s\n' "$provider"
    providerstatus=$(az provider show --namespace $provider --query registrationState --output tsv)
    if [[ "$providerstatus" = "NotRegistered" ]]; then
        printf 'Provider %s is not registered\n' "$provider"
        printf 'Provider %s us currently registered\n' "$provider"
        az provider register --namespace "$provider"
    else
        printf 'Provisioner %s is registered\n' "$provider"
    fi
done <./Providers.txt

# Get storage account ID from the central storage account that is in a separate subscription.
storageAccountID=$1
subscriptionID=$(az account show --query id --output tsv)

#Deployment of diagnostic settings for subscription
SubDeploymment=$(az deployment sub show -n "lwactivitylog" --query properties.provisioningState --output tsv)
if [[ "$SubDeploymment" != "Succeeded" ]]; then
    echo "Deployment of diagnostic setting for Azure Activity Log not present"
    echo "Starting deployment of diagnostic settings for Azure Activity Log"
    az deployment sub create --name "lwactivitylog" --location $location --template-file lwactivitylog.json --parameters "{\"settingName\":{\"value\":\"lacework-activity-logs\"},\"storageAccountID\":{\"value\":\"$storageAccountID\"}}"
else
    echo "Deployment of diagnostic setting for Azure Activity Log was already done"
fi
