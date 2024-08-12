*** Settings ***
Metadata          Author    stewartshea
Documentation     This CodeBundle will inspect alertmanager webhook payload data (stored in the RunWhen Platform), parse the data for SLX hints, and add Tasks to the RunSession
Metadata          Supports     AlertManager
Suite Setup       Suite Initialization
Library           BuiltIn
Library           RW.Core
Library           RW.platform
Library           OperatingSystem
Library           RW.CLI
Library           RW.Workspace

*** Keywords ***
Suite Initialization
    ${WEBHOOK_DATA}=     RW.Workspace.Import Memo Variable    
    ...    key=webhookJson
    ${WEBHOOK_JSON}=    Evaluate    json.loads(r'''${WEBHOOK_DATA}''')    json
    Set Suite Variable    ${WEBHOOK_JSON}    ${WEBHOOK_JSON}

*** Tasks ***
Run SLX Tasks with matching AlertManager Webhook commonLabels
    [Documentation]    Parse the alertmanager webhook commonLabels and route and SLX where commonLabels match SLX tags
    [Tags]    webhook    grafana    alertmanager    alert    runwhen
    IF    $WEBHOOK_JSON["status"] == "firing"
        Log    Parsing webhook data ${WEBHOOK_JSON}
        ${common_labels_list}=    Evaluate    [{'name': k, 'value': v} for k, v in ${WEBHOOK_JSON["commonLabels"]}.items()]
        ${slx_list}=    RW.Workspace.Get SLXs with Tag
        ...    tag_list=${common_labels_list}
        Log    Results: ${slx_list}
        FOR    ${slx}    IN    @{slx_list} 
            Log    ${slx["shortName"]} has matched
            ${runrequest}=    RW.Workspace.Run Tasks for SLX
            ...    slx=${slx["shortName"]}
        END
    END