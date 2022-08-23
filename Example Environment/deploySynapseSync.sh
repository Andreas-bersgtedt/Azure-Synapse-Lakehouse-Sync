#!/bin/bash
#
# This script is in two parts; Environment Deployment and Post-Deployment Configuration. While there appears
# to be alot going on here, it's mostly error handling for various scenarios that can arise. We're really
# just deploying the environment via Bicep, running a few queries against Synapse, and deploying a few
# Synapse pipeline and Databricks artifacts.
#
#   Part 1: Environment Deployment
#
#       This performs a Bicep template deployment if it wasn't done manually. The Bicep template creates a 
#       Databricks Workspace, Azure Data Lake Storage Gen2, and a Synapse Analytics Workspace.
#
#   Part 2: Post-Deployment Configuration
#
#       These are post-deployment configurations done at the data plan level which is beyond the scope of what  
#       Bicep is capable of managing or would normally manage. Database settings are made, sample data is copied, 
#       notebooks are copied, and pipelines are created.
#
#       These steps to make use of other dependencies such as Azure CLI, sqlcmd, and azcopy hence why it's
#       easier to execute via the Azure Cloud Shell.
#
#   This script should be executed via the Azure Cloud Shell via:
#
#       @Azure:~/Azure-Synapse-Analytics-PoC$ bash deploySynapseSync.sh
#

#
# Part 1: Synapse Environment Deployment
#

bicepDeploymentName="Azure-Databricks-Lakehouse-Synapse-Sync"
deploymentLogFile="deploySynapseSync.log"

checkBicepDeploymentState () {
    bicepDeploymentCheck=$(az deployment sub show --name $bicepDeploymentName --query properties.provisioningState --output tsv 2>&1 | sed 's/[[:space:]]*//g')
    if [ "$bicepDeploymentCheck" = "Succeeded" ]; then
        echo "Succeededs"
    elif [ "$bicepDeploymentCheck" = "Failed" ] || [ "$bicepDeploymentCheck" = "Canceled" ]; then
        echo "$(date) [ERROR] It looks like a Bicep deployment was attempted, but failed." | tee -a $deploymentLogFile
        exit 1;
    elif [[ $bicepDeploymentCheck == *"DeploymentNotFound"* ]]; then
        echo "DeploymentNotFound"
    fi
}

echo "$(date) [INFO] Starting deploySynapseSync.sh" >> $deploymentLogFile

# Make sure this configuration script hasn't been executed already
if [ -f "deploySynapse.complete" ]; then
    echo "$(date) [ERROR] It appears this configuration has already been completed." | tee -a $deploymentLogFile
    exit 1;
fi

# Try and determine if we're executing from within the Azure Cloud Shell
if [ ! "${AZUREPS_HOST_ENVIRONMENT}" = "cloud-shell/1.0" ]; then
    echo "$(date) [ERROR] It doesn't appear you are executing this from the Azure Cloud Shell. Please use the Azure Cloud Shell at https://shell.azure.com" | tee -a $deploymentLogFile
    exit 1;
fi

# Try and get a token to validate that we're logged into Azure CLI
aadToken=$(az account get-access-token --resource=https://dev.azuresynapse.net --query accessToken --output tsv 2>&1 | sed 's/[[:space:]]*//g')
if [[ $aadToken == *"ERROR"* ]]; then
    echo "$(date) [ERROR] You don't appear to be logged in to Azure CLI. Please login to the Azure CLI using 'az login'" | tee -a $deploymentLogFile
    exit 1;
fi

# Get environment details
azureSubscriptionName=$(az account show --query name --output tsv 2>&1 | sed 's/[[:space:]]*//g')
echo "$(date) [INFO] Azure Subscription: $azureSubscriptionName" >> $deploymentLogFile
azureSubscriptionID=$(az account show --query id --output tsv 2>&1 | sed 's/[[:space:]]*//g')
echo "$(date) [INFO] Azure Subscription ID: $azureSubscriptionID" >> $deploymentLogFile
azureUsername=$(az account show --query user.name --output tsv 2>&1 | sed 's/[[:space:]]*//g')
echo "$(date) [INFO] Azure AD Username: $azureUsername" >> $deploymentLogFile
azureUsernameObjectId=$(az ad user show --id $azureUsername --query id --output tsv 2>&1 | sed 's/[[:space:]]*//g')
echo "$(date) [INFO] Azure AD User Object Id: $azureUsernameObjectId" >> $deploymentLogFile

# Update a Bicep variable if they aren't configured by the user. This allows Bicep to add the user Object Id
# to the Storage Blob Data Contributor role on the Azure Data Lake Storage Gen2 account, which allows Synapse
# Serverless SQL to query files on storage.
sed -i "s/REPLACE_SYNAPSE_AZURE_AD_ADMIN_OBJECT_ID/${azureUsernameObjectId}/g" bicep/main.parameters.json 2>&1

# Check to see if the Bicep deployment was already completed manually. If not, lets do it.
if [ $(checkBicepDeploymentState) = "DeploymentNotFound" ]; then
    # Bicep deployment via Azure CLI
    echo "Deploying environment via Bicep. This will take several minutes..."
    echo "$(date) [INFO] Starting Bicep deployment" >> $deploymentLogFile
    #bicepDeploy=$(az deployment sub create --template-file Bicep/main.bicep --parameters Bicep/main.parameters.json --name $bicepDeploymentName --location eastus 2>&1 | tee -a $deploymentLogFile)

    # Make sure the Bicep deployment was successful 
    checkBicepDeploymentState
else
    echo "$(date) [INFO] It appears the Bicep deployment was done manually. Skipping..." >> $deploymentLogFile
fi

# Get the output variables from the Bicep deployment
resourceGroup=$(az deployment sub show --name ${bicepDeploymentName} --query properties.parameters.resourceGroupName.value --output tsv 2>&1 | sed 's/[[:space:]]*//g')
synapseAnalyticsWorkspaceName=$(az deployment sub show --name ${bicepDeploymentName} --query properties.outputs.synapseAnalyticsWorkspaceName.value --output tsv 2>&1 | sed 's/[[:space:]]*//g')
synapseAnalyticsSQLPoolName=$(az deployment sub show --name ${bicepDeploymentName} --query properties.outputs.synapseSQLPoolName.value --output tsv 2>&1 | sed 's/[[:space:]]*//g')
synapseAnalyticsSQLAdmin=$(az deployment sub show --name ${bicepDeploymentName} --query properties.outputs.synapseSQLAdministratorLogin.value --output tsv 2>&1 | sed 's/[[:space:]]*//g')
synapseAnalyticsSQLAdminPassword=$(az deployment sub show --name ${bicepDeploymentName} --query properties.outputs.synapseSQLAdministratorLoginPassword.value --output tsv 2>&1 | sed 's/[[:space:]]*//g')
databricksWorkspaceName=$(az deployment sub show --name ${bicepDeploymentName} --query properties.outputs.databricksWorkspaceName.value --output tsv 2>&1 | sed 's/[[:space:]]*//g')
datalakeName=$(az deployment sub show --name ${bicepDeploymentName} --query properties.outputs.datalakeName.value --output tsv 2>&1 | sed 's/[[:space:]]*//g')

# Display the environment details to the user
echo "Azure Subscription: ${azureSubscriptionName}"
echo "Azure Subscription ID: ${azureSubscriptionID}"
echo "Azure AD Username: ${azureUsername}"
echo "Resource Group: ${resourceGroup}"
echo "$(date) [INFO] Resource Group: $resourceGroup" >> $deploymentLogFile
echo "Synapse Analytics Workspace: ${synapseAnalyticsWorkspaceName}"
echo "$(date) [INFO] Synapse Analytics Workspace: $synapseAnalyticsWorkspaceName" >> $deploymentLogFile
echo "Synapse Analytics SQL Admin: ${synapseAnalyticsSQLAdmin}"
echo "$(date) [INFO] Synapse Analytics SQL Admin: $synapseAnalyticsSQLAdmin" >> $deploymentLogFile
echo "Databricks Workspace: ${databricksWorkspaceName}"
echo "$(date) [INFO] Databricks Workspace: $databricksWorkspaceName" >> $deploymentLogFile
echo "Data Lake Name: ${datalakeName}"
echo "$(date) [INFO] Data Lake Name: $datalakeName" >> $deploymentLogFile

# Enable the Synapse Dedicated SQL Result Set Cache
echo "Enabling the Synapse Dedicated SQL Result Set Caching..."
echo "$(date) [INFO] Enabling the Synapse Dedicated SQL Result Set Caching..." >> $deploymentLogFile
synapseResultSetCache=$(sqlcmd -U ${synapseAnalyticsSQLAdmin} -P ${synapseAnalyticsSQLAdminPassword} -S tcp:${synapseAnalyticsWorkspaceName}.sql.azuresynapse.net -d master -I -Q "ALTER DATABASE ${synapseAnalyticsSQLPoolName} SET RESULT_SET_CACHING ON;" 2>&1)

# Validate the Synapse Dedicated SQL Pool is running
if [[ $synapseResultSetCache == *"Cannot connect to database when it is paused"* ]]; then
    echo "$(date) [ERROR] The Synapse Dedicated SQL Pool is paused. Please resume the pool and run this script again." | tee -a $deploymentLogFile
    exit 1;
elif [[ $synapseResultSetCache == *"Login timeout expired"* ]]; then
    echo "$(date) [ERROR] Unable to connect to the Synapse Dedicated SQL Pool. The exact reason is unknown." | tee -a $deploymentLogFile
    exit 1;
fi

# Enable the Synapse Dedicated SQL Query Store
echo "Enabling the Synapse Dedicated SQL Query Store..."
echo "$(date) [INFO] Enabling the Synapse Dedicated SQL Query Store..." >> $deploymentLogFile
sqlcmd -U ${synapseAnalyticsSQLAdmin} -P ${synapseAnalyticsSQLAdminPassword} -S tcp:${synapseAnalyticsWorkspaceName}.sql.azuresynapse.net -d ${synapseAnalyticsSQLPoolName} -I -Q "ALTER DATABASE ${synapseAnalyticsSQLPoolName} SET QUERY_STORE = ON;"

# Create the Resource Class Users for the Parquet Auto Loader
echo "Creating the Synapse Dedicated SQL Resource Class Users..."
echo "$(date) [INFO] Creating the Synapse Dedicated SQL Resource Class Users..." >> $deploymentLogFile
sqlcmd -U ${synapseAnalyticsSQLAdmin} -P ${synapseAnalyticsSQLAdminPassword} -S tcp:${synapseAnalyticsWorkspaceName}.sql.azuresynapse.net -d ${synapseAnalyticsSQLPoolName} -I -i "../Azure Synapse Lakehouse Sync/Synapse Pipelines/Create_Resource_Class_Users.sql"

# Create the LS_Synapse_Managed_Identity Linked Service. This is primarily used for the Auto Loader pipeline.
echo "Creating the Synapse Workspace Linked Service..."
echo "$(date) [INFO] Creating the Synapse Workspace Linked Service..." >> $deploymentLogFile
az synapse linked-service create --only-show-errors -o none --workspace-name ${synapseAnalyticsWorkspaceName} --name LS_Synapse_Managed_Identity --file @"../Azure Synapse Lakehouse Sync/Synapse Pipelines/LS_Synapse_Managed_Identity.json"

# Create the DS_Synapse_Managed_Identity Dataset. This is primarily used for the Auto Loader pipeline.
echo "Creating the Synapse Workspace Dataset..."
echo "$(date) [INFO] Creating the Synapse Workspace Dataset..." >> $deploymentLogFile
az synapse dataset create --only-show-errors -o none --workspace-name ${synapseAnalyticsWorkspaceName} --name DS_Synapse_Managed_Identity --file @"../Azure Synapse Lakehouse Sync/Synapse Pipelines/DS_Synapse_Managed_Identity.json"

# Copy the Parquet Auto Loader Pipeline template and update the variables
cp "../Azure Synapse Lakehouse Sync/Synapse Pipelines/Parquet_Auto_Loader.json.tmpl" "../Azure Synapse Lakehouse Sync/Synapse Pipelines/Parquet_Auto_Loader.json" 2>&1
sed -i "s/REPLACE_DATALAKE_NAME/${datalakeName}/g" "../Azure Synapse Lakehouse Sync/Synapse Pipelines/Parquet_Auto_Loader.json"
sed -i "s/REPLACE_SYNAPSE_ANALYTICS_SQL_POOL_NAME/${synapseAnalyticsSQLPoolName}/g" "../Azure Synapse Lakehouse Sync/Synapse Pipelines/Parquet_Auto_Loader.json"

# Create the Parquet Auto Loader Pipeline in the Synapse Analytics Workspace
az synapse pipeline create --only-show-errors -o none --workspace-name ${synapseAnalyticsWorkspaceName} --name "Parquet Auto Loader" --file @"../Azure Synapse Lakehouse Sync/Synapse Pipelines/Parquet_Auto_Loader.json" >> $deploymentLogFile 2>&1

# Generate a SAS for the data lake so we can upload some files
tomorrowsDate=$(date --date="tomorrow" +%Y-%m-%d)
destinationStorageSAS=$(az storage container generate-sas --account-name ${datalakeName} --name data --permissions rwal --expiry ${tomorrowsDate} --only-show-errors --output tsv 2>&1 | sed 's/[[:space:]]*//g')
sampleDataStorageSAS="?sv=2021-06-08&st=2022-08-01T04%3A00%3A00Z&se=2023-08-01T04%3A00%3A00Z&sr=c&sp=rl&sig=DjC4dPo5AKYkNFplik2v6sH%2Fjhl2k1WTzna%2F1eV%2BFv0%3D"

# Copy sample data for the Parquet Auto Loader pipeline
echo "Copying the sample data..."
echo "$(date) [INFO] Copying the sample data..." >> $deploymentLogFile
az storage copy -s 'https://synapseanalyticspocdata.blob.core.windows.net/sample/AdventureWorks/'$sampleDataStorageSAS -d 'https://'$datalakeName'.blob.core.windows.net/data/Sample?'$destinationStorageSAS --recursive >> $deploymentLogFile 2>&1

echo "Deployment Complete!"
echo "$(date) [INFO] Deployment Complete" >> $deploymentLogFile
