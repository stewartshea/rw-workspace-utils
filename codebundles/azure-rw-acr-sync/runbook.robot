*** Settings ***
Metadata          Author    stewartshea
Documentation     This CodeBundle will sync all of the images needed to operate RunWhen (Local + Runner components), to Azure ACR using the az cli. 
Metadata          Supports     Azure,ACR
Metadata          Display Name     Azure RunWhen ACR Image Sync
Suite Setup       Suite Initialization
Library           BuiltIn
Library           RW.Core
Library           RW.platform
Library           OperatingSystem
Library           RW.CLI


*** Keywords ***
Suite Initialization
    ${ACR_REGISTRY}=    RW.Core.Import User Variable    ACR_REGISTRY
    ...    type=string
    ...    description=The name of the Azure Container Registry to import images into. 
    ...    pattern=\w*
    ...    example=myacr.azurecr.io
    ...    default=myacr.azurecr.io
    ${IMAGE_ARCHITECTURE}=    RW.Core.Import User Variable    IMAGE_ARCHITECTURE
    ...    type=string
    ...    description=The image architecutre to sync (amd64 or arm64) 
    ...    pattern=\w*
    ...    example=amd64
    ...    default=amd64
    ${DOCKER_USERNAME}=    RW.Core.Import Secret
    ...    DOCKER_USERNAME
    ...    type=string
    ...    description=Docker username to use if rate limited by Docker. 
    ...    pattern=\w*
    ${DOCKER_TOKEN}=    RW.Core.Import Secret
    ...    DOCKER_TOKEN
    ...    type=string
    ...    description=Docker token to use if rate limited by Docker.
    ...    pattern=\w*
    ${azure_credentials}=    RW.Core.Import Secret
    ...    azure_credentials
    ...    type=string
    ...    description=The secret containing AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_CLIENT_SECRET, AZURE_SUBSCRIPTION_ID
    ...    pattern=\w*

    Set Suite Variable
    ...    ${env}
    ...    {"ACR_REGISTRY":"${ACR_REGISTRY}", "IMAGE_ARCHITECTURE": "${IMAGE_ARCHITECTURE}"}
*** Tasks ***
Sync RunWhen Local Images into Azure Container Registry `${ACR_REGISTRY}`
    [Documentation]    Sync latest images for RunWhen into ACR
    [Tags]    azure    acr    registry    runwhen
    ${az_rw_acr_image_sync}=    RW.CLI.Run Bash File
    ...    bash_file=sync_with_az_import.sh
    ...    env=${env}
    ...    include_in_history=False
    ...    secret__DOCKER_USERNAME=${DOCKER_USERNAME}
    ...    secret__DOCKER_TOKEN=${DOCKER_TOKEN}
    ...    timeout_seconds=1200
    ${helm_output}=    RW.CLI.Run CLI
    ...    cmd= cat ../updated_values.yaml
    RW.Core.Add Pre To Report    Updated Helm Values for RunWhen Local:\n${helm_output.stdout}
