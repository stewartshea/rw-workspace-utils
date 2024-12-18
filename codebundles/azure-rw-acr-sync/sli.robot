*** Settings ***
Documentation       Determines if any RunWhen CodeCollection or private runner components require image updates. 
Metadata            Author    stewartshea
Metadata            Display Name    RunWhen Platform Azure ACR Image Sync
Metadata            Supports    Azure    ACR    Update    RunWhen    CodeCollection

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem


Suite Setup         Suite Initialization
*** Tasks ***
Check for CodeCollection Updates against ACR Registry`${REGISTRY_NAME}`
    [Documentation]    Count the number of CodeCollection image upates that need to be synced internally to the private registry. 
    [Tags]    acr    update    codecollection    utility
    ${codecollection_images}=    RW.CLI.Run Bash File
    ...    bash_file=rwl_codecollection_updates.sh
    ...    env=${env}
    ...    secret__DOCKER_USERNAME=${DOCKER_USERNAME}
    ...    secret__DOCKER_TOKEN=${DOCKER_TOKEN}
    ...    timeout_seconds=300
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=false

    ${image_update_count}=    RW.CLI.Run Cli
    ...    cmd=[ -f "${OUTPUT_DIR}/azure-rw-acr-sync/cc_images_to_update.json" ] && cat "${OUTPUT_DIR}/azure-rw-acr-sync/cc_images_to_update.json" | jq 'if . == null or . == [] then 0 else length end' | tr -d '\n' || echo -n 0
    ...    env=${env}
    ...    include_in_history=false

    Set Global Variable    ${outdated_codecollection_images}    ${image_update_count.stdout}

Check for RunWhen Local Image Updates against ACR Registry`${REGISTRY_NAME}`
    [Documentation]    Count the number of RunWhen Local image upates that need to be synced internally to the private registry. 
    [Tags]    acr    update    codecollection    utility
    ${runwhen_local_images}=    RW.CLI.Run Bash File
    ...    bash_file=rwl_helm_image_updates.sh
    ...    cmd_override=./rwl_helm_image_updates.sh https://runwhen-contrib.github.io/helm-charts runwhen-contrib runwhen-local 
    ...    env=${env}
    ...    secret__DOCKER_USERNAME=${DOCKER_USERNAME}
    ...    secret__DOCKER_TOKEN=${DOCKER_TOKEN}
    ...    timeout_seconds=300
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=false

    ${image_update_count}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT DIR}/azure-rw-acr-sync/images_to_update.json | jq 'to_entries | map(select(.value.update_required == true)) | from_entries | length '| tr -d '\n'
    ...    env=${env}
    ...    include_in_history=false

    Set Global Variable    ${outdated_runwhen_local_images}    ${image_update_count.stdout}


Count Images Needing Update and Push Metric
    ${total_images}=      Evaluate  (${outdated_codecollection_images}+${outdated_runwhen_local_images})
    RW.Core.Push Metric    ${total_images}

*** Keywords ***
Suite Initialization
    ${USE_DATE_TAG}=    RW.Core.Import User Variable    USE_DATE_TAG
    ...    type=string
    ...    description=Set to true in order to generate a unique date base tag. Useful if it is not possible to overwrite the latest tag.  
    ...    pattern=\w*
    ...    example=true
    ...    default=false
    ${SYNC_IMAGES}=    RW.Core.Import User Variable   SYNC_IMAGES
    ...    type=string
    ...    description=Set to true in order to update the images in the private registry.   
    ...    pattern=\w*
    ...    example=true
    ...    default=false
    Set Suite Variable     ${SYNC_IMAGES}    ${SYNC_IMAGES}

    ${REGISTRY_NAME}=    RW.Core.Import User Variable    REGISTRY_NAME
    ...    type=string
    ...    description=The name of the Azure Container Registry to import images into. 
    ...    pattern=\w*
    ...    example=myacr.azurecr.io
    ...    default=myacr.azurecr.io
    ${REGISTRY_REPOSITORY_PATH}=    RW.Core.Import User Variable    REGISTRY_REPOSITORY_PATH
    ...    type=string
    ...    description=The path of the repository for image storage.   
    ...    pattern=\w*
    ...    example=runwhen
    ...    default=runwhen
    ${AZURE_RESOURCE_SUBSCRIPTION_ID}=    RW.Core.Import User Variable    AZURE_RESOURCE_SUBSCRIPTION_ID
    ...    type=string
    ...    description=The Azure Subscription ID for the resource.  
    ...    pattern=\w*
    Set Suite Variable    ${AZURE_RESOURCE_SUBSCRIPTION_ID}    ${AZURE_RESOURCE_SUBSCRIPTION_ID}

    Set Suite Variable    ${DOCKER_USERNAME}    ""
    Set Suite Variable    ${DOCKER_TOKEN}    ""
    ${USE_DOCKER_AUTH}=    RW.Core.Import User Variable
    ...    USE_DOCKER_AUTH
    ...    type=string
    ...    enum=[true,false]
    ...    description=Import the docker secret for authentication. Useful in bypassing rate limits. 
    ...    pattern=\w*
    ...    default=false
    Set Suite Variable    ${USE_DOCKER_AUTH}    ${USE_DOCKER_AUTH}
    Run Keyword If    "${USE_DOCKER_AUTH}" == "true"    Import Docker Secrets

    ${azure_credentials}=    RW.Core.Import Secret
    ...    azure_credentials
    ...    type=string
    ...    description=The secret containing AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_CLIENT_SECRET, AZURE_SUBSCRIPTION_ID
    ...    pattern=\w*
    Set Suite Variable     ${REGISTRY_REPOSITORY_PATH}    ${REGISTRY_REPOSITORY_PATH}
    Set Suite Variable     ${REGISTRY_NAME}    ${REGISTRY_NAME}
    Set Suite Variable     ${USE_DATE_TAG}    ${USE_DATE_TAG}

    Set Suite Variable
    ...    ${env}
    ...    {"REGISTRY_NAME":"${REGISTRY_NAME}", "WORKDIR":"${OUTPUT DIR}/azure-rw-acr-sync", "TMPDIR":"/var/tmp/runwhen", "SYNC_IMAGES":"${SYNC_IMAGES}", "USE_DATE_TAG":"${USE_DATE_TAG}", "REGISTRY_REPOSITORY_PATH":"${REGISTRY_REPOSITORY_PATH}", "AZURE_RESOURCE_SUBSCRIPTION_ID":"${AZURE_RESOURCE_SUBSCRIPTION_ID}"}

Import Docker Secrets
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
