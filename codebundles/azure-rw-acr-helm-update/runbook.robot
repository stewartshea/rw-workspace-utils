*** Settings ***
Documentation       Checks (or applies) RunWhen image updates with Helm CLI if any updated images exist in the upstream ACR registry. 
Metadata            Author    stewartshea
Metadata            Display Name    RunWhen Local Helm Update (ACR)
Metadata            Supports    Azure    ACR    Update    RunWhen    Helm

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem


Suite Setup         Suite Initialization
*** Tasks ***
Apply Available RunWhen Helm Images in ACR Registry`${REGISTRY_NAME}`
    [Documentation]    Count the number of running RunWhen images that have updates available in ACR (via Helm CLI). 
    [Tags]    acr    update    codecollection    utility    helm    runwhen
    ${rwl_image_updates}=    RW.CLI.Run Bash File
    ...    bash_file=helm_update.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=300
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=false
    RW.Core.Add Pre To Report    ${rwl_image_updates.stdout}
    ${update_command}=    RW.CLI.Run Cli
    ...    cmd=[ -f "$WORKDIR/helm_update_required" ] && cat "$WORKDIR/helm_update_required" | grep true | awk -F ":" '{print $2}' | tr -d '\n'
    ...    env=${env}
    ...    include_in_history=false 
    IF    "${update_command.stdout}" != "" and "${HELM_APPLY_UPGRADE}" == "false"
        RW.Core.Add Issue    title=OpenTelemetry Collector Has Error Logs
        ...    severity=3
        ...    next_steps=Manually update RunWhen helm release with the following command. 
        ...    actual=RunWhen Local helm release is not up to date. 
        ...    expected=RunWhen Local helm releases should be up to date. 
        ...    title=RunWhen Local image updates are available for namespace ${NAMESPACE} in cluster ${CONTEXT}
        ...    reproduce_hint=${rwl_image_updates.cmd}
        ...    details=Run the following command:\n ${update_command.stdout}
    END

*** Keywords ***
Suite Initialization

    ${REGISTRY_NAME}=    RW.Core.Import User Variable    REGISTRY_NAME
    ...    type=string
    ...    description=The name of the Azure Container Registry to import images into. 
    ...    pattern=\w*
    ...    example=myacr.azurecr.io
    ...    default=myacr.azurecr.io
    ${kubeconfig}=    RW.Core.Import Secret
    ...    kubeconfig
    ...    type=string
    ...    description=The kubeconfig used to fetch the Helm release details
    ...    pattern=\w*
    ${azure_credentials}=    RW.Core.Import Secret
    ...    azure_credentials
    ...    type=string
    ...    description=The secret containing AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_CLIENT_SECRET, AZURE_SUBSCRIPTION_ID
    ...    pattern=\w*
    ${REGISTRY_REPOSITORY_PATH}=    RW.Core.Import User Variable    REGISTRY_REPOSITORY_PATH
    ...    type=string
    ...    description=The name root path of the repository for image storage.   
    ...    pattern=\w*
    ...    example=runwhen
    ...    default=runwhen
    ${HELM_APPLY_UPGRADE}=    RW.Core.Import User Variable    HELM_APPLY_UPGRADE
    ...    type=string
    ...    description=Set to true in order to automatically apply the suggested Helm upgrade   
    ...    pattern=\w*
    ...    example=false
    ...    default=false
    ${NAMESPACE}=    RW.Core.Import User Variable    NAMESPACE
    ...    type=string
    ...    description=Which Namespace to evaluate for RunWhen Helm Updates  
    ...    pattern=\w*
    ...    example=runwhen-local
    ...    default=runwhen-local
    ${CONTEXT}=    RW.Core.Import User Variable    CONTEXT
    ...    type=string
    ...    description=The Kubernetes Context to use  
    ...    pattern=\w*
    ...    example=default
    ...    default=default
    ${HELM_RELEASE}=    RW.Core.Import User Variable    HELM_RELEASE
    ...    type=string
    ...    description=The Helm release name to update  
    ...    pattern=\w*
    ...    example=runwhen-local
    ...    default=runwhen-local
    ${AZURE_RESOURCE_SUBSCRIPTION_ID}=    RW.Core.Import User Variable    AZURE_RESOURCE_SUBSCRIPTION_ID
    ...    type=string
    ...    description=The Azure Subscription ID for the resource.  
    ...    pattern=\w*
    Set Suite Variable    ${AZURE_RESOURCE_SUBSCRIPTION_ID}    ${AZURE_RESOURCE_SUBSCRIPTION_ID}

    Set Suite Variable
    ...    ${env}
    ...    {"CURDIR":"${CURDIR}","KUBECONFIG":"./${kubeconfig.key}", "HELM_RELEASE":"${HELM_RELEASE}","REGISTRY_NAME":"${REGISTRY_NAME}", "WORKDIR":"${OUTPUT DIR}/azure-rw-acr-helm-update", "NAMESPACE":"${NAMESPACE}","CONTEXT":"${CONTEXT}", "HELM_APPLY_UPGRADE":"${HELM_APPLY_UPGRADE}", "REGISTRY_REPOSITORY_PATH":"${REGISTRY_REPOSITORY_PATH}", "AZURE_RESOURCE_SUBSCRIPTION_ID":"${AZURE_RESOURCE_SUBSCRIPTION_ID}"}
