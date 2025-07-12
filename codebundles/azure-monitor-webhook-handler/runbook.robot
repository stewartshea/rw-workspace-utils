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
Library           RW.RunSession
Library           Collections
Library           String
 
*** Keywords ***
Suite Initialization
    ${DRY_RUN_MODE}=    RW.Core.Import User Variable    DRY_RUN_MODE
    ...    description=Whether to capture the webhook details in dry-run mode, reporting what tasks will be run but not executing them. True or False  
    ...    enum=[true,false]
    ...    default=true
    Set Suite Variable    ${DRY_RUN_MODE}    ${DRY_RUN_MODE}

    ${WEBHOOK_DATA}=     RW.Workspace.Import Memo Variable    key=webhookJson
    ${WEBHOOK_JSON}=    Evaluate    json.loads(r'''${WEBHOOK_DATA}''')    json
    Set Suite Variable    ${WEBHOOK_JSON}    ${WEBHOOK_JSON}

    # Local test data
    # ${WEBHOOK_DATA}=     RW.Core.Import User Variable    WEBHOOK_DATA
    # ${WEBHOOK_JSON}=    Evaluate    json.loads(r'''${WEBHOOK_DATA}''')    json
    # Set Suite Variable    ${WEBHOOK_JSON}

    ${CURRENT_SESSION}=      RW.Workspace.Import Runsession Details
    ${CURRENT_SESSION_JSON}=    Evaluate    json.loads(r'''${CURRENT_SESSION}''')    json
    Set Suite Variable    ${CURRENT_SESSION_JSON}

*** Tasks ***
Start RunSession From Azure Monitor Webhook Details
    [Documentation]    Parse the azure monitor webhook  and route and SLX where with matching SLX tags
    [Tags]    webhook    azuremonitor    alert    runwhen

    RW.Core.Add Pre To Report    Full payload:\n ${WEBHOOK_JSON["data"]}

    ${essentials}=    Set Variable    ${WEBHOOK_JSON["data"]["essentials"]}

    ${severity}=         Set Variable    ${essentials["severity"]}
    ${alert_rule}=       Set Variable    ${essentials["alertRule"]}
    ${description}=      Set Variable    ${essentials["description"]}
    ${monitor_condition}=    Set Variable    ${essentials["monitorCondition"]}

    ${target_ids}=    Set Variable    ${essentials["alertTargetIDs"]}
    ${target_id}=     Set Variable    ${target_ids[0]}
    ${parts}=            Split String    ${target_id}    /
    ${subscription_id}=  Set Variable    ${parts[2]}
    ${resource_group}=   Set Variable    ${parts[4]}
    ${resource_name}=    Set Variable    ${parts[-1]}

    RW.Core.Add Pre To Report    SEVERITY: ${severity}
    RW.Core.Add Pre To Report    RULE: ${alert_rule}
    RW.Core.Add Pre To Report    DESC: ${description}
    RW.Core.Add Pre To Report    MONITOR CONDITION: ${monitor_condition}
    RW.Core.Add Pre To Report    SUBSCRIPTION ID: ${subscription_id}
    RW.Core.Add Pre To Report    RESOURCE GROUP: ${resource_group}
    RW.Core.Add Pre To Report    RESOURCE NAME: ${resource_name}


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

        # Ensure resource_names is not empty to prevent search issues
        IF    len(${resource_names}) == 0
            RW.Core.Add To Report    Warning: No resource names extracted from webhook, using fallback search
            ${resource_names}=    Create List    health
        END

        # 3) find SLXs that reference any of those names
        ${slx_list}=    RW.Workspace.Get Slxs With Entity Reference    ${resource_names}
        Log    Results: ${slx_list}
        IF    len(${slx_list}) == 0
            RW.Core.Add To Report    No SLX matched impacted entities – stopping handler.
        ELSE
            ${slx_scopes}=    Create List
            FOR    ${slx}    IN    @{slx_list}
                Append To List    ${slx_scopes}    ${slx["shortName"]}
            END

            # Get persona / confidence threshold
            ${persona}=    RW.RunSession.Get Persona Details
            ...    persona=${CURRENT_SESSION_JSON["personaShortName"]}
            ${run_confidence}=    Set Variable    ${persona["spec"]["run"]["confidenceThreshold"]}

            # Use improved search strategy
            ${persona_search}    ${search_strategy}    ${final_slx_scopes}    ${search_query}=    RW.Workspace.Perform Improved Task Search
            ...    entity_data=${resource_names}
            ...    persona=${CURRENT_SESSION_JSON["personaShortName"]}
            ...    confidence_threshold=${run_confidence}
            ...    slx_scope=${slx_scopes}

            RW.Core.Add To Report    Search strategy used: ${search_strategy}
            RW.Core.Add To Report    Search query used: ${search_query}
            RW.Core.Add To Report    SLX scopes used: ${final_slx_scopes}

            # A scope of a single SLX tends to present search issues. Add all SLXs from the same group if we only have one SLX.
            ${scope_expanded}=    Set Variable    False
            ${expanded_slx_scopes}=    Set Variable    ${final_slx_scopes}
            IF    len(${final_slx_scopes}) == 1
                ${config}=    RW.Workspace.Get Workspace Config

                ${nearby_slxs}=    RW.Workspace.Get Nearby Slxs
                ...    workspace_config=${config}
                ...    slx_name=${final_slx_scopes[0]}
                @{nearby_slx_list}    Convert To List    ${nearby_slxs}
                FOR    ${slx}    IN    @{nearby_slx_list}
                    Append To List    ${expanded_slx_scopes}    ${slx}
                END
                Add Pre To Report    Expanding scope to include the following SLXs: ${expanded_slx_scopes}
                ${scope_expanded}=    Set Variable    True
            END

            # If scope was expanded, perform a new search with the expanded scope
            IF    ${scope_expanded}
                ${persona_search}    ${search_strategy}    ${final_slx_scopes}    ${search_query}=    RW.Workspace.Perform Improved Task Search
                ...    entity_data=${resource_names}
                ...    persona=${CURRENT_SESSION_JSON["personaShortName"]}
                ...    confidence_threshold=${run_confidence}
                ...    slx_scope=${expanded_slx_scopes}
                RW.Core.Add To Report    Re-searched with expanded scope: ${expanded_slx_scopes}
            END

            #  Admin-level discovery (report only)
            # ${admin_search}=    RW.Workspace.Perform Task Search
            # ...                query=${qry}
            # ...                slx_scope=${slx_scopes}
            # ${admin_tasks_md}    ${admin_tasks_total}=       RW.Workspace.Build Task Report Md
            # ...    search_response=${admin_search}
            # ...    score_threshold=0

            RW.Core.Add To Report    \# Tasks meeting confidence ≥${run_confidence}
            ${tasks_md}    ${total_persona_tasks}=          RW.Workspace.Build Task Report Md
            ...                    search_response=${persona_search}
            # ...                    score_threshold=${run_confidence}
            ...                    score_threshold=0

            RW.Core.Add Pre To Report    ${tasks_md}

            IF    ${total_persona_tasks} == 0
                RW.Core.Add To Report    No tasks cleared confidence threshold – cannot create RunSession.
            ELSE
                IF    '${DRY_RUN_MODE}' == 'false'
                    RW.Core.Add To Report    Dry-run disabled – creating Runsession …
                    ${runsession}=    RW.RunSession.Create RunSession from Task Search
                    ...    search_response=${persona_search}
                    ...    persona_shortname=${CURRENT_SESSION_JSON["personaShortName"]}
                    # ...    score_threshold=${run_confidence}
                    ...     score_threshold=0
                    ...    runsession_prefix=Azure-Monitor-Alert-${alert_rule}
                    ...    notes=${CURRENT_SESSION_JSON["notes"]}
                    ...    source=${CURRENT_SESSION_JSON["source"]}
                    IF    $runsession != {}
                        ${runsession_url}=     RW.RunSession.Get RunSession Url
                        ...    rw_runsession=${runsession["id"]}         
                        RW.Core.Add To Report    Started runsession [${runsession["id"]}](${runsession_url})
                    ELSE
                        RW.Core.Add To Report    RunSession did not create successfully.
                        RW.Core.Add Issue
                        ...    severity=2
                        ...    expected=RunSession should be created successfully
                        ...    actual=RunSession was not created properly
                        ...    title=Could create RunSession from `${CURRENT_SESSION_JSON["source"]}`
                        ...    reproduce_hint=Try to create new RunSession
                        ...    details=See debug logs or backend response body.
                        ...    next_steps=Inspect runrequest logs or contact RunWhen support.
                    END
                ELSE
                    RW.Core.Add To Report    Dry-run mode active – no RunSession created.
                END
            END
        END
    ELSE
        RW.Core.Add To Report    Problem state '${monitor_condition}' – handler only processes Fired events.
    END
