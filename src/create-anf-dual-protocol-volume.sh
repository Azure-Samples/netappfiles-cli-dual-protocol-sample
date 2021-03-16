#!/bin/bash
set -euo pipefail

# Mandatory variables for ANF resources
# Change variables according to your environment 
SUBSCRIPTION_ID="<Subscription ID>"
LOCATION="WestUS"
RESOURCEGROUP_NAME="My-rg"
VNET_NAME="testvnet"
SUBNET_NAME="testsubnet"
NETAPP_ACCOUNT_NAME="netapptestaccount"
NETAPP_POOL_NAME="netapptestpool"
NETAPP_POOL_SIZE_TIB=4
NETAPP_VOLUME_NAME="netapptestvolume"
SERVICE_LEVEL="Standard"
NETAPP_VOLUME_SIZE_GIB=100

# AD variables
DOMAIN_JOIN_USERNAME=""
DOMAIN_JOIN_PASSWORD=""
SMB_SERVER_NAME="pmcsmb"
DNS_LIST="10.0.2.4,10.0.2.5"
AD_FQDN="testdomain.local"

# Cleanup Variable
SHOULD_CLEANUP="true"

# Exit error code
ERR_ACCOUNT_NOT_FOUND=100

usage()
{
    echo "Usage:"
    echo "  $0 [OPTIONS]"
    echo "    -u <DOMAIN_JOIN_USERNAME>                [Required]: DOMAIN_JOIN_USERNAME"
    echo "    -p <DOMAIN_JOIN_PASSWORD>                [Required]: DOMAIN_JOIN_PASSWORD"
    echo
    echo "Example:"
    echo # TODO: adjust example
    echo "      $0 -u pmcadmin -p Password"
    echo
    echo
}

while getopts "u:p:" opt; do
    case ${opt} in
        u )
            DOMAIN_JOIN_USERNAME=$OPTARG
            ;;
        p )
            DOMAIN_JOIN_PASSWORD=$OPTARG
            ;;
        # Catch call, return usage and exit
        h  ) usage; exit 0;;
        \? ) echo "Unknown option: -$OPTARG" >&2; exit 1;;
        :  ) echo "Missing option argument for -$OPTARG" >&2; exit 1;;
        *  ) echo "Unimplemented option: -$OPTARG" >&2; exit 1;;
    esac
done
if [ $OPTIND -eq 1 ]; then echo; echo "No options were passed"; echo; usage; exit 1; fi
shift $((OPTIND -1))

# Utils Functions
display_bash_header()
{
    echo "-----------------------------------------------------------------------------------------------------------"
    echo "Azure NetApp Files CLI NFS Sample  - Sample Bash script that creates Azure NetApp Files Dual-Protocol protocol"
    echo "-----------------------------------------------------------------------------------------------------------"
}

display_cleanup_header()
{
    echo "----------------------------------------"
    echo "Cleaning up Azure NetApp Files Resources"
    echo "----------------------------------------"
}

display_message()
{
    time=$(date +"%T")
    message="$time : $1"
    echo $message
}

#------------------
# Create functions
#-----------------

# Create Azure NetApp Files Account
create_netapp_account()
{    
    local __resultvar=$1
    local _NEW_ACCOUNT_ID=""

    _NEW_ACCOUNT_ID=$(az netappfiles account create --resource-group $RESOURCEGROUP_NAME \
        --name $NETAPP_ACCOUNT_NAME \
        --location $LOCATION | jq -r ".id")

    az netappfiles account ad add --resource-group $RESOURCEGROUP_NAME \
        --name $NETAPP_ACCOUNT_NAME \
        --username $DOMAIN_JOIN_USERNAME \
        --password $DOMAIN_JOIN_PASSWORD \
        --smb-server-name $SMB_SERVER_NAME \
        --dns $DNS_LIST \
        --domain $AD_FQDN

    if [[ "$__resultvar" ]]; then
        eval $__resultvar="'${_NEW_ACCOUNT_ID}'"
    else
        echo "${_NEW_ACCOUNT_ID}"
    fi
}


# Create Azure NetApp Files Capacity Pool
create_netapp_pool()
{
    local __resultvar=$1
    local _NEW_POOL_ID=""

    _NEW_POOL_ID=$(az netappfiles pool create --resource-group $RESOURCEGROUP_NAME \
        --account-name $NETAPP_ACCOUNT_NAME \
        --name $NETAPP_POOL_NAME \
        --location $LOCATION \
        --size $NETAPP_POOL_SIZE_TIB \
        --service-level $SERVICE_LEVEL | jq -r ".id")

    if [[ "$__resultvar" ]]; then
        eval $__resultvar="'${_NEW_POOL_ID}'"
    else
        echo "${_NEW_POOL_ID}"
    fi
}


# Create Azure NetApp Files Volume
create_netapp_volume()
{
    local __resultvar=$1
    local _NEW_VOLUME_ID=""

    _NEW_VOLUME_ID=$(az netappfiles volume create --resource-group $RESOURCEGROUP_NAME \
        --account-name $NETAPP_ACCOUNT_NAME \
        --file-path $NETAPP_VOLUME_NAME \
        --pool-name $NETAPP_POOL_NAME \
        --name $NETAPP_VOLUME_NAME \
        --location $LOCATION \
        --service-level $SERVICE_LEVEL \
        --usage-threshold $NETAPP_VOLUME_SIZE_GIB \
        --vnet $VNET_NAME \
        --subnet $SUBNET_NAME \
        --protocol-types "CIFS" "NFSv3" \
        --security-style "ntfs" | jq -r ".id")

    if [[ "$__resultvar" ]]; then
        eval $__resultvar="'${_NEW_VOLUME_ID}'"
    else
        echo "${_NEW_VOLUME_ID}"
    fi      
}

# Return resource type from resource ID
get_resource_type()
{
    local _RESOURCE_ID=$1
    local __resultvar=$2    
    
    _RESOURCE_ID="${_RESOURCE_ID//\// }"   
    OIFS=$IFS; IFS=' '; read -ra ANF_RESOURCES_ARRAY <<< $_SPACED_RESOURCE_ID; IFS=$OIFS
    
    if [[ "$__resultvar" ]]; then
        eval $__resultvar="'${ANF_RESOURCES_ARRAY[-2]}'"
    else
        echo "${ANF_RESOURCES_ARRAY[-2]}"
    fi
}

#----------------------------
# Waiting resources functions
#----------------------------

# Wait for resources to succeed 
wait_for_resource()
{
    local _RESOURCE_ID=$1

    local _RESOURCE_TYPE="";get_resource_type $_RESOURCE_ID _RESOURCE_TYPE

    for i in {1..60}; do
        sleep 10
        if [[ "${_RESOURCE_TYPE,,}" == "netappaccounts" ]]; then
            _ACCOUNT_STATUS=$(az netappfiles account show --ids $_RESOURCE_ID | jq -r ".provisioningState")
            if [[ "${_account_status,,}" == "succeeded" ]]; then
                break
            fi        
        elif [[ "${_RESOURCE_TYPE,,}" == "capacitypools" ]]; then
            _POOL_STATUS=$(az netappfiles pool show --ids $_RESOURCE_ID | jq -r ".provisioningState")
            if [[ "${_POOL_STATUS,,}" == "succeeded" ]]; then
                break
            fi                    
        elif [[ "${_RESOURCE_TYPE,,}" == "volumes" ]]; then
            _VOLUME_STATUS=$(az netappfiles volume show --ids $_RESOURCE_ID | jq -r ".provisioningState")
            if [[ "${_VOLUME_STATUS,,}" == "succeeded" ]]; then
                break
            fi
        else
            _SNAPSHOT_STATUS=$(az netappfiles snapshot show --ids $_RESOURCE_ID | jq -r ".provisioningState")
            if [[ "${_SNAPSHOT_STATUS,,}" == "succeeded" ]]; then
                break
            fi           
        fi        
    done   
}

# Wait for resources to get fully deleted
wait_for_no_resource()
{
    local _RESOURCE_ID=$1

    local _RESOURCE_TYPE="";get_resource_type $_RESOURCE_ID _RESOURCE_TYPE
 
    for i in {1..60}; do
        sleep 10
        if [[ "${_RESOURCE_TYPE,,}" == "netappaccounts" ]]; then
            az netappfiles account show --ids $_RESOURCE_ID || break
        elif [[ "${_RESOURCE_TYPE,,}" == "capacitypools" ]]; then
            az netappfiles pool show --ids $_RESOURCE_ID || break
        elif [[ "${_RESOURCE_TYPE,,}" == "volumes" ]]; then
            az netappfiles volume show --ids $_RESOURCE_ID || break
        else
            az netappfiles snapshot show --ids $_RESOURCE_ID || break         
        fi        
    done   
}

#------------------
# Cleanup functions
#------------------

# Delete Azure NetApp Files Account
delete_netapp_account()
{
    az netappfiles account delete --resource-group $RESOURCEGROUP_NAME \
        --name $NETAPP_ACCOUNT_NAME   
}

# Delete Azure NetApp Files Capacity Pool
delete_netapp_pool()
{
    az netappfiles pool delete --resource-group $RESOURCEGROUP_NAME \
        --account-name $NETAPP_ACCOUNT_NAME \
        --name $NETAPP_POOL_NAME      
}

# Delete Azure NetApp Files Volume
delete_netapp_volume()
{
    az netappfiles volume delete --resource-group $RESOURCEGROUP_NAME \
        --account-name $NETAPP_ACCOUNT_NAME \
        --pool-name $NETAPP_POOL_NAME \
        --name $NETAPP_VOLUME_NAME  
}

# Script Start
# Display Header
display_bash_header

# Login and Authenticate to Azure
display_message "Authenticating into Azure"
az login

# Set the target subscription 
display_message "setting up the target subscription"
az account set --subscription $SUBSCRIPTION_ID

display_message "Creating Azure NetApp Files Account ..."
{    
    NEW_ACCOUNT_ID="";create_netapp_account NEW_ACCOUNT_ID
    wait_for_resource $NEW_ACCOUNT_ID
    display_message "Azure NetApp Files Account was created successfully: $NEW_ACCOUNT_ID"
} || {
    display_message "Failed to create Azure NetApp Files Account"
    exit 1
}

display_message "Creating Azure NetApp Files Pool ..."
{
    NEW_POOL_ID="";create_netapp_pool NEW_POOL_ID
    wait_for_resource $NEW_POOL_ID
    display_message "Azure NetApp Files pool was created successfully: $NEW_POOL_ID"
} || {
    display_message "Failed to create Azure NetApp Files pool"
    exit 1
}

display_message "Creating Azure NetApp Files Volume..."
{
    NEW_VOLUME_ID="";create_netapp_volume NEW_VOLUME_ID
    wait_for_resource $NEW_VOLUME_ID
    display_message "Azure NetApp Files volume was created successfully: $NEW_VOLUME_ID"
} || {
    display_message "Failed to create Azure NetApp Files volume"
    exit 1
}

# Clean up resources
if [[ "$SHOULD_CLEANUP" == true ]]; then
    # Display cleanup header
    display_cleanup_header

    # Delete Volume
    display_message "Deleting Azure NetApp Files Volume..."
    {
        delete_netapp_volume
        wait_for_no_resource $NEW_VOLUME_ID
        display_message "Azure NetApp Files volume was deleted successfully"
    } || {
        display_message "Failed to delete Azure NetApp Files volume"
        exit 1
    }

    # Delete Capacity Pool
    display_message "Deleting Azure NetApp Files Pool ..."
    {
        delete_netapp_pool
        wait_for_no_resource $NEW_POOL_ID
        display_message "Azure NetApp Files pool was deleted successfully"
    } || {
        display_message "Failed to delete Azure NetApp Files pool"
        exit 1
    }

    # Delete Account
    display_message "Deleting Azure NetApp Files Account ..."
    {
        delete_netapp_account
        display_message "Azure NetApp Files Account was deleted successfully"
    } || {
        display_message "Failed to delete Azure NetApp Files Account"
        exit 1
    }
fi