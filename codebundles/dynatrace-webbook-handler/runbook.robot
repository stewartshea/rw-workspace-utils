*** Settings ***
Metadata          Author    stewartshea
Documentation     This CodeBundle inspects the dynatrace webhook payload data (stored in the RunWhen Platform) and starts a RunSession from the available data. 
Metadata          Display Name     Dynatrace Webhook Handler
Suite Setup       Suite Initialization
Library           BuiltIn
Library           RW.Core
Library           RW.platform
Library           OperatingSystem
Library           RW.CLI
Library           RW.Workspace
Library           Collections

*** Keywords ***
Suite Initialization
    ${WEBHOOK_DATA}=     RW.Workspace.Import Memo Variable    
    ...    key=webhookJson
    ${WEBHOOK_JSON}=    Evaluate    json.loads(r'''${WEBHOOK_DATA}''')    json
    Set Suite Variable    ${WEBHOOK_JSON}    ${WEBHOOK_JSON}
    ## Local test data
    # ${WEBHOOK_DATA}=     RW.Core.Import User Variable    WEBHOOK_DATA
    # ${WEBHOOK_JSON}=    Evaluate    json.loads(r'''${WEBHOOK_DATA}''')    json
    # Set Suite Variable    ${WEBHOOK_JSON}

*** Tasks ***
Start RunSession Dynatrace Webhook Contents
    [Documentation]    Parse the dynatrace webhook  and route and SLX where commonLabels match SLX tags
    [Tags]    webhook    dynatrace    alert    runwhen

    RW.Core.Add To Report    Dynatrace Problem Details:\n ${WEBHOOK_JSON["problemDetailsMarkdown"]}
    RW.Core.Add Pre To Report    Full payload:\n ${WEBHOOK_JSON}

    IF    '${WEBHOOK_JSON["state"]}' == 'OPEN'
        # 1) Gather the impacted entities list that came in the webhook
        ${impacted_entities}=    Get From Dictionary    ${WEBHOOK_JSON}    impactedEntities
        Log    ${impacted_entities}

        # 2) Build a Python list with just the "name" field of each entity
        ${entity_names}=    Evaluate    [e['name'] for e in ${impacted_entities}]

        # 3) Find any slxs that might reference those entity names
        ${slx_list}=    RW.Workspace.Get Slxs With Entity Reference    ${entity_names}

        Log    Results: ${slx_list}
        # 4) Add those SLXs to the RunSession
        IF  len(${slx_list}) > 0
            FOR    ${slx}    IN    @{slx_list} 
                Log    ${slx["shortName"]} has matched
                ${runrequest}=    RW.Workspace.Run Tasks for SLX
                ...    slx=${slx["shortName"]}
            END
        END
    END