*** Settings ***
Metadata          Author    stewartshea
Documentation     This CodeBundle will inspect pagerduty webhook payload data (stored in the RunWhen Platform), parse the data for SLX hints, and add Tasks to the RunSession
Metadata          Supports     PagerDuty
Suite Setup       Suite Initialization
Library           BuiltIn
Library           RW.Core
Library           RW.platform
Library           OperatingSystem
Library           RW.CLI
Library           RW.Workspace
Library           RW.PagerDuty

*** Keywords ***
Suite Initialization
    ${WEBHOOK_DATA}=     RW.Workspace.Import Memo Variable    
    ...    key=webhookJson
    ${WEBHOOK_JSON}=    Evaluate    json.loads(r'''${WEBHOOK_DATA}''')    json
    Set Suite Variable    ${WEBHOOK_JSON}    ${WEBHOOK_JSON}
    Run Keyword And Ignore Error    Import PD API Key

Import PD API Key
    ${PD_API_KEY}=    RW.Core.Import Secret    PD_API_KEY
    ...    type=string
    ...    description=PagerDuty API Key for Updating Incidents
    ...    pattern=\w*
    ...    example=Token token=aaabbbccc
    Set Suite Variable    ${PD_API_KEY}    ${PD_API_KEY}

*** Tasks ***
Run SLX Tasks with matching PagerDuty Webhook Service ID
    [Documentation]    Parse the webhook details and route to the right SLX
    [Tags]    webhook    grafana    alertmanager    alert    runwhen
    IF    $WEBHOOK_JSON["event"]["eventType"] == "incident.triggered"
        Log    Running SLX Tasks that match PagerDuty Service ID ${WEBHOOK_JSON["event"]["data"]["service"]["id"]}
        ${slx_list}=    RW.Workspace.Get SLXs with Tag
        ...    tag_list=[{"name": "pagerduty_service", "value": "${WEBHOOK_JSON["event"]["data"]["service"]["id"]}"}]
        Log    Results: ${slx_list}
        FOR    ${slx}    IN    @{slx_list} 
            Log    ${slx["shortName"]} has matched
            ${runrequest}=    RW.Workspace.Run Tasks for SLX
            ...    slx=${slx["shortName"]}
        END
        Run Keyword If    '${PD_API_KEY}' != ''    Add RunSession Note To Incident
    END

*** Keywords ***
Add RunSession Note To Incident
    ${note_rsp}=    RW.PagerDuty.Add RunSession Note To Incident
    ...    data=${WEBHOOK_JSON}
    ...    secret_token=${PD_API_KEY}
    Log    ${note_rsp}
