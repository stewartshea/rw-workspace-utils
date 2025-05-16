*** Settings ***
Metadata          Author    stewartshea
Documentation     This CodeBundle inspects the azure monitor alert group webhook payload data (stored in the RunWhen Platform) and starts a RunSession from the available data. 
Metadata          Supports     Azure   AzureMonitor   Webhook
Metadata          Display Name     Azure Monitor Webhook Handler
Suite Setup       Suite Initialization
Library           BuiltIn
Library           RW.Core
Library           RW.platform
Library           OperatingSystem
Library           RW.CLI
Library           RW.Azure
Library           RW.Workspace
Library           Collections
Library           String
 
*** Keywords ***
Suite Initialization
    ${WEBHOOK_DATA}=     RW.Workspace.Import Memo Variable    
    ...    key=webhookJson
    ${WEBHOOK_JSON}=    Evaluate    json.loads(r'''${WEBHOOK_DATA}''')    json
    Set Suite Variable    ${WEBHOOK_JSON}    ${WEBHOOK_JSON}
    # # Local test data
    # ${WEBHOOK_DATA}=     RW.Core.Import User Variable    WEBHOOK_DATA
    # ${WEBHOOK_JSON}=    Evaluate    json.loads(r'''${WEBHOOK_DATA}''')    json
    # Set Suite Variable    ${WEBHOOK_JSON}

*** Tasks ***
Start RunSession From Azure Monitor Webhook Details
    [Documentation]    Parse the azure monitor webhook  and route and SLX where with matching SLX tags
    [Tags]    webhook    azuremonitor    alert    runwhen

    RW.Core.Add Pre To Report    Full payload:\n ${WEBHOOK_JSON["data"]}

    # ${essentials}=    Set Variable    ${WEBHOOK_JSON["data"]["essentials"]}

    # ${severity}=         Set Variable    ${essentials["severity"]}
    # ${alert_rule}=       Set Variable    ${essentials["alertRule"]}
    # ${description}=      Set Variable    ${essentials["description"]}
    # ${monitor_condition}=    Set Variable    ${essentials["monitorCondition"]}

    # ${target_ids}=    Set Variable    ${essentials["alertTargetIDs"]}
    # ${target_id}=     Set Variable    ${target_ids[0]}
    # ${parts}=            Split String    ${target_id}    /
    # ${subscription_id}=  Set Variable    ${parts[2]}
    # ${resource_group}=   Set Variable    ${parts[4]}
    # ${resource_name}=    Set Variable    ${parts[-1]}

    # Log To Console    SEVERITY: ${severity}
    # Log To Console    RULE: ${alert_rule}
    # Log To Console    DESC: ${description}
    # Log To Console    MONITOR CONDITION: ${monitor_condition}
    # Log To Console    SUBSCRIPTION ID: ${subscription_id}
    # Log To Console    RESOURCE GROUP: ${resource_group}
    # Log To Console    RESOURCE NAME: ${resource_name}


    ${parsed_data}=    RW.Azure.Parse Alert    ${WEBHOOK_JSON}
    ${urls}=    Get From Dictionary    ${parsed_data}    portal_urls

    # Add deep links if they exist
    ${alert_url}=        Get From Dictionary    ${urls}    alert_rule    default=None
    ${resource_url}=     Get From Dictionary    ${urls}    resource      default=None
    ${sub_cost_url}=     Get From Dictionary    ${urls}    subscription_cost    default=None

    IF    '${alert_url}' != 'None'
        RW.Core.Add To Report    [Portal Alert Rule](${alert_url})
    END
    IF    '${resource_url}' != 'None'
        RW.Core.Add To Report    [Target Resource](${resource_url})
    END
    IF    '${sub_cost_url}' != 'None'
        RW.Core.Add To Report    [Subscription Cost](${sub_cost_url})
    END

    Log To Console    Parsed Data: ${parsed_data}


    IF    '${parsed_data["monitor_condition"]}' == 'Fired'
        # 1) full list of impacted targets
        ${impacted_entities}=    Set Variable    ${parsed_data["resources"]}
        Log To Console    Impacted entities: ${impacted_entities}

        # 2) build a list of just the resource names
        ${resource_names}=    Create List
        FOR    ${e}    IN    @{impacted_entities}
            Append To List    ${resource_names}    ${e["resource_name"]}
        END
        Log To Console    Resource names: ${resource_names}

        # 3) find SLXs that reference any of those names
        ${slx_list}=    RW.Workspace.Get Slxs With Entity Reference    ${resource_names}
        Log    Results: ${slx_list}

        # 4) launch run-requests for each matching SLX
        FOR    ${slx}    IN    @{slx_list}
            Log    ${slx["shortName"]} has matched
            ${runrequest}=    RW.Workspace.Run Tasks for SLX
            ...    slx=${slx["shortName"]}
        END
    END