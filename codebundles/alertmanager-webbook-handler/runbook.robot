*** Settings ***
Metadata          Author    stewartshea
Documentation     This CodeBundle will inspect alertmanager webhook payload data (stored in the RunWhen Platform), parse the data for SLX hints, and add Tasks to the RunSession
Metadata          Supports     AlertManager   Webhook
Metadata          Display Name     AlertManager Webhook Handler
Suite Setup       Suite Initialization
Library           BuiltIn
Library           RW.Core
Library           RW.platform
Library           OperatingSystem
Library           RW.CLI
Library           RW.Workspace
Library           RW.RunSession
Library           Collections

*** Keywords ***
Suite Initialization
    ${DRY_RUN_MODE}=    RW.Core.Import User Variable    DRY_RUN_MODE
    ...    description=Whether to capture the webhook details in dry-run mode, reporting what tasks will be run but not executing them. True or False  
    ...    enum=[true,false]
    ...    default=true
    Set Suite Variable    ${DRY_RUN_MODE}    ${DRY_RUN_MODE}
    ${CURRENT_SESSION}=      RW.Workspace.Import Runsession Details
    ${CURRENT_SESSION_JSON}=    Evaluate    json.loads(r'''${CURRENT_SESSION}''')    json
    Set Suite Variable    ${CURRENT_SESSION_JSON}

    ${WEBHOOK_DATA}=     RW.Workspace.Import Memo Variable    
    ...    key=webhookJson
    ${WEBHOOK_JSON}=    Evaluate    json.loads(r'''${WEBHOOK_DATA}''')    json
    Set Suite Variable    ${WEBHOOK_JSON}    ${WEBHOOK_JSON}

    # # Local test data
    # ${WEBHOOK_DATA}=     RW.Core.Import User Variable    WEBHOOK_DATA
    # ${WEBHOOK_JSON}=    Evaluate    json.loads(r'''${WEBHOOK_DATA}''')    json
    # Set Suite Variable    ${WEBHOOK_JSON}

*** Tasks ***
Add Tasks to RunSession from AlertManager Webhook Details
    [Documentation]    Parse the alertmanager webhook commonLabels and route and SLX where commonLabels match SLX tags
    [Tags]    webhook    grafana    alertmanager    alert    runwhen

    RW.Core.Add To Report    Webhook received with state: ${WEBHOOK_JSON["status"]}
    RW.Core.Add Pre To Report   ${WEBHOOK_JSON["status"]}

    IF    $WEBHOOK_JSON["status"] == "firing"
        Log    Parsing webhook data ${WEBHOOK_JSON}
        ${persona}=    RW.RunSession.Get Persona Details
        ...    persona=${CURRENT_SESSION_JSON["personaShortName"]}
        ${run_confidence}=    Set Variable     ${persona["spec"]["run"]["confidenceThreshold"]}
        ${common_labels_list}=    Evaluate
        ...    [f"{k}:{v}" for k, v in ${WEBHOOK_JSON["commonLabels"]}.items()]
        
        RW.Core.Add To Report    RunSession assigned to ${CURRENT_SESSION_JSON["personaShortName"]}, with run confidence ${run_confidence}, looking to scope search to the following commonLabels ${common_labels_list}
        
        ${slx_list}=    RW.Workspace.Get Slxs With Tag
        ...    tag_list=${common_labels_list}
        
        IF  len(${slx_list}) == 0
            RW.Core.Add To Report    Could not match commonLabels to any SLX tags. Cannot continue with RunSession.
        ELSE
            RW.Core.Add To Report    Found SLX matches..continuing on with search. 
            ${slx_scopes}=    Create List
            FOR    ${slx}    IN    @{slx_list}
                Append To List    ${slx_scopes}    ${slx["shortName"]}
            END

            # Get persona / confidence threshold
            ${persona}=    RW.RunSession.Get Persona Details
            ...    persona=${CURRENT_SESSION_JSON["personaShortName"]}
            ${run_confidence}=    Set Variable    ${persona["spec"]["run"]["confidenceThreshold"]}

            # Extract entity data from commonLabels for improved search
            ${entity_data}=    Create List
            FOR    ${key}    ${value}    IN    &{WEBHOOK_JSON["commonLabels"]}
                Append To List    ${entity_data}    ${value}
            END

            # Ensure entity_data is not empty to prevent search issues
            IF    len(${entity_data}) == 0
                RW.Core.Add To Report    Warning: No entity data extracted from commonLabels, using fallback search
                ${entity_data}=    Create List    health
            END

            # Use improved search strategy
            ${persona_search}    ${search_strategy}    ${final_slx_scopes}    ${search_query}=    RW.Workspace.Perform Improved Task Search
            ...    entity_data=${entity_data}
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
                ...    entity_data=${entity_data}
                ...    persona=${CURRENT_SESSION_JSON["personaShortName"]}
                ...    confidence_threshold=${run_confidence}
                ...    slx_scope=${expanded_slx_scopes}
                RW.Core.Add To Report    Re-searched with expanded scope: ${expanded_slx_scopes}
            END

            # Perform search with Admin permissions - These tasks will never be run
            ${admin_search}=    RW.Workspace.Perform Task Search
            ...    query=health
            ...    slx_scope=${final_slx_scopes}

            ${admin_tasks_md}    ${admin_tasks_total}=    RW.Workspace.Build Task Report Md 
            ...    search_response=${admin_search}
            ...    score_threshold=0
            RW.Core.Add To Report    \# Tasks found with Admin permissions (these will NOT be run)
            RW.Core.Add Pre To Report    ${admin_tasks_md}

            RW.Core.Add To Report    \# Tasks found with Engineering Assistant permissions (${CURRENT_SESSION_JSON["personaShortName"]})

            ${tasks_md}    ${total_persona_tasks}=    RW.Workspace.Build Task Report Md 
            ...    search_response=${persona_search}
            ...    score_threshold=${run_confidence}
            RW.Core.Add Pre To Report    ${tasks_md}

            IF    ${total_persona_tasks} == 0
                RW.Core.Add To Report    No tasks cleared confidence threshold – cannot create RunSession.
            ELSE
                IF    '${DRY_RUN_MODE}' == 'false'
                    RW.Core.Add To Report    Dry-run disabled – creating Runsession …
                    ${runsession}=    RW.RunSession.Create RunSession from Task Search
                    ...    search_response=${persona_search}
                    ...    persona_shortname=${CURRENT_SESSION_JSON["personaShortName"]}
                    ...    score_threshold=${run_confidence}
                    ...    runsession_prefix=AlertManager-${WEBHOOK_JSON["groupLabels"]["alertname"]}
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
        RW.Core.Add To Report    Problem state '${WEBHOOK_JSON["state"]}' – handler only processes "firing" events.
    END