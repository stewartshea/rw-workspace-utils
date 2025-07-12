*** Settings ***
Metadata          Author    stewartshea
Documentation     This CodeBundle inspects the dynatrace webhook payload data (stored in the RunWhen Platform) and starts a RunSession from the available data. 
Metadata          Supports     Dynatrace   Webhook
Metadata          Display Name     Dynatrace Webhook Handler
Suite Setup       Suite Initialization
Library           BuiltIn
Library           RW.Core
Library           RW.platform
Library           OperatingSystem
Library           RW.CLI
Library           RW.Workspace
Library           RW.RunSession
Library           RW.Dynatrace
Library           Collections

*** Keywords ***
Suite Initialization
    ${DRY_RUN_MODE}=    RW.Core.Import User Variable    DRY_RUN_MODE
    ...    description=Whether to capture the webhook details in dry-run mode, reporting what tasks will be run but not executing them. True or False  
    ...    enum=[true,false]
    ...    default=true
    Set Suite Variable    ${DRY_RUN_MODE}    ${DRY_RUN_MODE}

    ${WEBHOOK_DATA}=     RW.Workspace.Import Memo Variable    
    ...    key=webhookJson
    ${WEBHOOK_JSON}=    Evaluate    json.loads(r'''${WEBHOOK_DATA}''')    json
    Set Suite Variable    ${WEBHOOK_JSON}    ${WEBHOOK_JSON}

    # # Local test data
    # ${WEBHOOK_DATA}=     RW.Core.Import User Variable    WEBHOOK_DATA
    # ${WEBHOOK_JSON}=    Evaluate    json.loads(r'''${WEBHOOK_DATA}''')    json
    # Set Suite Variable    ${WEBHOOK_JSON}

    ${CURRENT_SESSION}=      RW.Workspace.Import Runsession Details
    ${CURRENT_SESSION_JSON}=    Evaluate    json.loads(r'''${CURRENT_SESSION}''')    json
    Set Suite Variable    ${CURRENT_SESSION_JSON}


*** Tasks ***
Start RunSession From Dynatrace Webhook Details
    [Documentation]    Parse webhook ➜ match SLXs ➜ search tasks ➜ (optionally) new RunSession
    [Tags]    webhook    dynatrace    alert    runwhen

    RW.Core.Add To Report    Dynatrace problem state: ${WEBHOOK_JSON["state"]}
    RW.Core.Add Pre To Report    Full payload:\n${WEBHOOK_JSON}

    IF    '${WEBHOOK_JSON["state"]}' == 'OPEN'
        # 1) Extract impacted entities
        ${entity_names}=    RW.Dynatrace.Parse Dynatrace Entities    ${WEBHOOK_JSON}
        RW.Core.Add To Report    Impacted entities: ${entity_names}

        # Ensure entity_names is not empty to prevent search issues
        IF    len(${entity_names}) == 0
            RW.Core.Add To Report    Warning: No entities extracted from webhook, using fallback search
            ${entity_names}=    Create List    health
        END

        # 2) Resolve SLXs
        ${slx_list}=    RW.Workspace.Get Slxs With Entity Reference    ${entity_names}
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
            ...    entity_data=${entity_names}
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
                ...    entity_data=${entity_names}
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
            ...                    score_threshold=${run_confidence}
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
                    ...    runsession_prefix=dynatrace-${WEBHOOK_JSON["problemId"]}
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
        RW.Core.Add To Report    Problem state '${WEBHOOK_JSON["state"]}' – handler only processes OPEN events.
    END