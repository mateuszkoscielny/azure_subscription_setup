#!/bin/bash
# In order to use the script you require files called Providers.txt and lwactivitylog.json that will be provided with the script.
# bash ./subscription_setup.sh <resource group name> <storage account name>
# Checking if CustomNodeConfigPreview feature is registered and if not register it
rg_name=$1
storageaccountname=$2
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

# Checking if storage account for subscription based logs is present if not create it
rg_check=$(az group exists --name $rg_name)
if [[ "$rg_check" == false ]]; then
    echo "Resource group for lacework log collection does not exist"
    az group create --location $location --name $rg_name
    stg_diag_check=$(az storage account check-name --name $storageaccountname --query nameAvailable)
    if [[ $stg_diag_check == false ]]; then
        echo "Storage account already exists"
    else
        echo "Storage account as it does not exist"
        az storage account create --name $storageaccountname --resource-group $rg_name --https-only true --sku Standard_LRS --kind StorageV2
    fi
else
    echo "Resource group for lacework log collection does exist"
    stg_diag_check=$(az storage account check-name --name $storageaccountname --query nameAvailable)
    if [[ "$stg_diag_check" == false ]]; then
        echo "Storage account already exists"
    else
        echo "Storage account as it does not exist"
        az storage account create --name $storageaccountname --resource-group $rg_name --https-only true --sku Standard_LRS --kind StorageV2
    fi
fi
storageAccountID=$(az storage account show --name $storageaccountname --resource-group $rg_name --query id --output tsv)
queue_check=$(az storage queue exists --name "lacework-ingestion-queue" --account-name $storageaccountname --auth-mode login --query exists --output tsv)
if [[ "$queue_check" == false ]]; then
    echo "Queue does not exist"
    az storage queue create --name lacework-ingestion-queue --account-name $storageaccountname --auth-mode login
else
    echo "Queue does exist"
fi
queueId="$storageAccountID/queueservices/default/queues/lacework-ingestion-queue"
eventgrid_check=$(az eventgrid event-subscription show --name lacework-ingestion-eventgrid --source-resource-id $storageAccountID --query provisioningState --output tsv)
if [[ "$eventgrid_check" != "Succeeded" ]]; then
    echo "Event subscription does not exist"
    az eventgrid event-subscription create --name lacework-ingestion-eventgrid --endpoint-type storagequeue --endpoint $queueId --source-resource-id $storageAccountID --subject-begins-with /blobServices/default/containers/insights-activity-logs/ --included-event-types Microsoft.Storage.BlobCreated
else
    echo "Event subscription does exist"
fi
subscriptionID=$(az account show --query id --output tsv)
# # Storage Account Contributor
RoleAssigmentSTGC=$(az role assignment list --role "Storage Account Contributor" --assignee "$SpIdLacework" --scope "/subscriptions/$subscriptionID/resourceGroups/$rg_name")
if [[ "$RoleAssigmentSTGC" = "[]" ]]; then
    echo "Role assignment is empty for role Storage Account Contributor"
    echo "Role assignment will take place for object id $SpIdLacework"
    az role assignment create --assignee-object-id $SpIdLacework --role "Storage Account Contributor" --assignee-principal-type ServicePrincipal --scope "/subscriptions/$subscriptionID/resourceGroups/$rg_name"
else
    echo "Role assignment for role Storage Account Contributor is already was done"
fi

# # EventGrid EventSubscription Reader
RoleAssigmentEvent=$(az role assignment list --role "EventGrid EventSubscription Reader" --assignee "$SpIdLacework" --scope "/subscriptions/$subscriptionID/resourceGroups/$rg_name")
if [[ "$RoleAssigmentEvent" = "[]" ]]; then
    echo "Role assignment is empty for role EventGrid EventSubscription Reader"
    echo "Role assignment will take place for object id $SpIdLacework"
    az role assignment create --assignee-object-id $SpIdLacework --role "EventGrid EventSubscription Reader" --assignee-principal-type ServicePrincipal --scope "/subscriptions/$subscriptionID/resourceGroups/$rg_name"
else
    echo "Role assignment for role EventGrid EventSubscription Reader is already was done"
fi

#Deployment of diagnostic settings for subscription
SubDeploymment=$(az deployment sub show -n "lwactivitylog" --query properties.provisioningState --output tsv)
if [[ "$SubDeploymment" != "Succeeded" ]]; then
    echo "Deployment of diagnostic setting for Azure Activity Log not present"
    echo "Starting deployment of diagnostic settings for Azure Activity Log"
    az deployment sub create --name "lwactivitylog" --location $location --template-file lwactivitylog.json --parameters "{\"settingName\":{\"value\":\"lacework-activity-logs\"},\"storageAccountID\":{\"value\":\"$storageAccountID\"}}"
else
    echo "Deployment of diagnostic setting for Azure Activity Log was already done"
fi
echo "Save this storageAccountID for the central storage solution"
echo $storageAccountID