"""
azure_alert_parser.py
---------------------

Parse Azure Monitor common-schema webhook payloads from *any* alert type
and expose a Robot-Framework keyword library.

Supported alert types
---------------------
- activity_log          (Activity Log Alerts)
- availability          (App Insights availability tests)
- budget                (Cost Management budget actuals)
- cost_budget           (Cost budget threshold reached)
- forecast_budget       (Forecasted-cost budget threshold)
- log_v1                (Log Analytics classic alerts)
- log_v2                (Log Analytics scheduled alerts – LA v2)
- metric                (Metric alert – static or dynamic)
- resource_health       (Azure Resource Health alerts)
- service_health        (Service Health advisories/incidents)
- smart                 (App Insights Smart Detection)
"""

from __future__ import annotations

import json
import re
from typing import Any, Dict, List, Tuple, Union

# ──────────────────────────────────────────────────────────────────────────────
#  Constants / Look-ups
# ──────────────────────────────────────────────────────────────────────────────

SEVERITY_MAP: Dict[str, int] = {
    "sev0": 1, "critical": 1,
    "sev1": 1, "error": 1,
    "sev2": 2, "warning": 2,
    "sev3": 3, "informational": 3,
    "sev4": 4,
}

NEXT_STEPS: Dict[str, List[str]] = {
    "activity_log": [
        "Open the Activity Log record in the Azure Portal to review who performed the operation.",
        "Verify the caller’s role assignments and RBAC permissions.",
        "If the action was unexpected, initiate an access review or revert the change.",
    ],
    "availability": [
        "Open Application Insights ➜ Availability and inspect test results around the alert time.",
        "Validate DNS/SSL certificates and firewall rules for the public endpoint.",
        "Deploy to a staging slot and run synthetic tests before live roll-out.",
    ],
    "budget": [
        "Open Cost Management + Billing ➜ Budgets for this subscription.",
        "Drill into Cost Analysis to identify the biggest spend drivers.",
        "Consider Azure Advisor recommendations for cost optimisation.",
    ],
    "cost_budget": [
        "Review the current burn rate and compare with historic usage.",
        "Evaluate scaling policies or shut down unused resources.",
        "If spend is justified, raise the budget threshold accordingly.",
    ],
    "forecast_budget": [
        "Open Cost Management forecasts and confirm projection accuracy.",
        "Investigate cost spikes in the forecast period.",
        "Enable alerts at lower thresholds for earlier notification.",
    ],
    "log_v1": [
        "Open the Log Analytics query referenced in the alert and inspect the results.",
        "Validate that the query still returns the intended data.",
        "Tune thresholds or filtering to reduce noise if this alert fires frequently.",
    ],
    "log_v2": [
        "Open the Log Analytics workspace ➜ Alerts (v2) ➜ Fired alerts and inspect the run results.",
        "Check ‘Opened’ and ‘Closed’ times to see if the condition auto-resolved.",
        "Optimise the KQL query or evaluation frequency if needed.",
    ],
    "metric": [
        "Open Metrics Explorer for the resource and plot the relevant metric.",
        "Correlate metric spikes with recent deployments or load events.",
        "Consider autoscale rules or adjust SLOs if thresholds are too aggressive.",
    ],
    "resource_health": [
        "Open Azure Resource Health for the resource to check current status.",
        "If the summary is platform-initiated, subscribe to Service Health updates.",
        "Plan fail-over or redundancy if this is mission-critical.",
    ],
    "service_health": [
        "Open Azure Service Health and follow the incident/advisory for live updates.",
        "Assess impact on workloads and communicate to stakeholders.",
        "Implement region redundancy or delay deployments until resolved.",
    ],
    "smart": [
        "Open Application Insights ➜ Smart Detection for full diagnostics.",
        "Review code traces, dependency calls and performance counters.",
        "Deploy a mitigation or code fix, then mark the detection as ‘Acknowledged’.",
    ],
    "unknown": [
        "Investigate the alert payload manually; alert type could not be determined."
    ],
}

# ──────────────────────────────────────────────────────────────────────────────
#  Helper functions
# ──────────────────────────────────────────────────────────────────────────────

def _split_resource_id(rid: str) -> Tuple[str | None, str | None, str | None]:
    """Return (subscription_id, resource_group, resource_name) from a resource ID."""
    try:
        parts = rid.strip("/").split("/")
        return parts[1], parts[3], parts[-1]
    except Exception:                           # noqa: BLE001
        return None, None, None


def _map_severity(raw: str | None) -> int | None:
    return SEVERITY_MAP.get((raw or "").lower(), 4)


def _detect_alert_type(es: Dict[str, Any]) -> str:
    signal = (es.get("signalType") or "").lower()
    msvc   = (es.get("monitoringService") or "").lower()
    rule   = (es.get("alertRule") or "").lower()

    if "activity log" in signal:
        return "activity_log"
    if "budget" in signal:
        if "forecast" in rule:
            return "forecast_budget"
        return "cost_budget" if "cost" in rule else "budget"
    if signal == "log":
        return "log_v2" if es.get("essentialsVersion") == "2.0" else "log_v1"
    if signal == "metric":
        return "metric"
    if "resource health" in msvc:
        return "resource_health"
    if "service health" in msvc:
        return "service_health"
    if "smart detector" in msvc or "smart" in rule:
        return "smart"
    if "availability" in rule or "availability" in msvc:
        return "availability"
    return "unknown"


def _portal_urls(sub: str | None, alert_id: str | None,
                 target_id: str | None) -> Dict[str, str]:
    urls: Dict[str, str] = {}
    if alert_id:
        urls["alert_rule"] = f"https://portal.azure.com/#resource{alert_id}"
    if target_id:
        urls["resource"]   = f"https://portal.azure.com/#resource{target_id}"
    if sub:
        urls["subscription_cost"] = (
            "https://portal.azure.com/#blade/"
            "Microsoft_Azure_CostManagement/Menu/~/costanalysis"
            f"?subscriptionId={sub}"
        )
    return urls

# ──────────────────────────────────────────────────────────────────────────────
#  Core parser
# ──────────────────────────────────────────────────────────────────────────────

def parse_azure_monitor_alert(
    payload: Union[str, Dict[str, Any]]
) -> Dict[str, Any]:
    if isinstance(payload, str):
        payload = json.loads(payload)
    if payload.get("schemaId") != "azureMonitorCommonAlertSchema":
        raise ValueError("Unsupported or missing schemaId")

    essentials: Dict[str, Any] = payload["data"]["essentials"]
    context:    Dict[str, Any] = payload["data"].get("alertContext", {})

    alert_type  = _detect_alert_type(essentials)
    severity    = _map_severity(essentials.get("severity"))

    target_ids: List[str] = essentials.get("alertTargetIDs", [])
    resources: List[Dict[str, Any]] = []

    for rid in target_ids:
        sub, rg, res = _split_resource_id(rid)
        resources.append({
            "subscription_id": sub,
            "resource_group":  rg,
            "resource_name":   res,
            "resource_id":     rid,
        })

    # Back-compatibility – keep the first resource under legacy key
    first = resources[0] if resources else {}
    sub_id  = first.get("subscription_id")
    rg_name = first.get("resource_group")
    res_name= first.get("resource_name")

    summary: Dict[str, Any] = {
        "alert_type": alert_type,
        "severity":   severity,
        "title":      essentials.get("alertRule") or essentials.get("monitoringService"),
        "description": essentials.get("description")
                       or context.get("description")
                       or "No description provided.",
        # legacy single-target field:
        "resource":   {
            "subscription_id": sub_id,
            "resource_group":  rg_name,
            "resource_name":   res_name,
        },
        # NEW multi-target list:
        "resources":  resources,
        "monitor_condition": essentials.get("monitorCondition"),
        "portal_urls": _portal_urls(sub_id, essentials.get("alertId"),
                                   target_ids[0] if target_ids else None),
        "next_steps": NEXT_STEPS.get(alert_type, NEXT_STEPS["unknown"]),
        "details":    {},   # ← populated further down (metric / log / etc.)
    }


    # ── signal-specific enrichment ────────────────────────────────────────────
    if alert_type in {"metric", "availability"}:
        summary["details"] = context.get("condition", {})
    elif alert_type.startswith("log_"):
        summary["details"] = {
            "searchQuery":         context.get("searchQuery"),
            "resultCount":         context.get("resultCount"),
            "linkToSearchResults": context.get("linkToSearchResults"),
        }
    elif alert_type == "activity_log":
        summary["details"] = {
            "operationName": context.get("operationName"),
            "caller":        context.get("caller"),
            "status":        context.get("status"),
            "eventSource":   context.get("eventSource"),
            "message":       context.get("properties", {}).get("message"),
        }
    elif alert_type in {"budget", "cost_budget", "forecast_budget"}:
        summary["details"] = {
            "budgetName":   context.get("budgetName") or es.get("alertRule"),
            "threshold":    context.get("threshold"),
            "budgetAmount": context.get("budgetAmount"),
            "currentSpend": context.get("currentSpend"),
            "timeGrain":    context.get("timeGrain"),
        }
    elif alert_type == "resource_health":
        summary["details"] = context
    elif alert_type == "service_health":
        summary["details"] = {
            "incidentType":     context.get("incidentType"),
            "trackingId":       context.get("trackingId"),
            "title":            context.get("title"),
            "impactedServices": context.get("services"),
        }
    elif alert_type == "smart":
        summary["details"] = {
            "problemId":        context.get("problemId"),
            "problemStartTime": context.get("problemStartTime"),
            "problemEndTime":   context.get("problemEndTime"),
        }
    else:
        summary["details"] = context

    return summary

# ──────────────────────────────────────────────────────────────────────────────
#  Robot-Framework library class
# ──────────────────────────────────────────────────────────────────────────────

class Azure:                   # Robot will pick up this class
    """Robot library exposing keyword **Parse Alert**."""

    def parse_alert(self, payload: str | Dict[str, Any]):
        """Return normalised summary dict from raw webhook JSON/text."""
        return parse_azure_monitor_alert(payload)

    def extract_kql_entities(self, payload: str | Dict[str, Any]) -> List[str]:
        """
        Extract useful entity names from KQL queries in Azure Monitor webhooks.
        Returns a list of entity names found in the KQL query patterns.
        """
        if isinstance(payload, str):
            payload = json.loads(payload)

        entity_names = []
        
        # Try to extract searchQuery from webhook structure
        try:
            alert_context = payload["data"].get("alertContext", {})
            if alert_context:
                condition = alert_context.get("condition", {})
                if condition:
                    all_of = condition.get("allOf", [])
                    if len(all_of) > 0:
                        search_query = all_of[0].get("searchQuery", "")
                        if search_query:
                            # Log the query for debugging - use Robot Framework logging
                            try:
                                from robot.api import logger
                                logger.info(f"[KQL EXTRACTION] Processing query:\n{search_query}")
                            except ImportError:
                                # Fallback if Robot Framework is not available
                                print(f"[KQL EXTRACTION] Processing query:\n{search_query}")
                            # Extract entity names from common KQL patterns
                            query_entities = self._parse_kql_query_for_entities(search_query)
                            entity_names.extend(query_entities)
        except Exception as error:
            # Log error but don't fail completely
            pass
        
        # Remove duplicates and filter out common non-entity terms
        return self._filter_and_deduplicate_entities(entity_names)

    def extract_kql_entities_with_query(self, payload: str | Dict[str, Any]) -> tuple:
        """
        Extract useful entity names from KQL queries in Azure Monitor webhooks.
        Returns a tuple of (entity_names, query_text) for better logging.
        """
        if isinstance(payload, str):
            payload = json.loads(payload)

        entity_names = []
        query_text = ""
        
        # Try to extract searchQuery from webhook structure
        try:
            alert_context = payload["data"].get("alertContext", {})
            if alert_context:
                condition = alert_context.get("condition", {})
                if condition:
                    all_of = condition.get("allOf", [])
                    if len(all_of) > 0:
                        query_text = all_of[0].get("searchQuery", "")
                        if query_text:
                            # Extract entity names from common KQL patterns
                            query_entities = self._parse_kql_query_for_entities(query_text)
                            entity_names.extend(query_entities)
        except Exception as error:
            # Log error but don't fail completely
            pass
        
        # Remove duplicates and filter out common non-entity terms
        filtered_entities = self._filter_and_deduplicate_entities(entity_names)
        return filtered_entities, query_text

    def _parse_kql_query_for_entities(self, query: str) -> List[str]:
        """Parse KQL query text to extract useful entity names."""
        entities = []
        query_lower = query.lower()
        
        # Split query into lines for processing
        lines = query.split('\n')
        
        for line in lines:
            line_trimmed = line.strip()
            line_lower = line_trimmed.lower()
            
            # Pattern 1: where name contains "entity" or where name has "entity"
            if 'contains "' in line_lower:
                entity = self._extract_entity_from_contains_pattern(line)
                if entity:
                    entities.append(entity)
            
            # Pattern 2: where cloud_RoleName has "entity" or similar role patterns
            if 'rolename' in line_lower and ('"' in line):
                entity = self._extract_entity_from_role_pattern(line)
                if entity:
                    entities.append(entity)
            
            # Pattern 3: where serviceName == "entity" or similar service patterns
            if 'servicename' in line_lower and ('"' in line):
                entity = self._extract_entity_from_service_pattern(line)
                if entity:
                    entities.append(entity)
            
            # Pattern 4: where containerName startswith "entity" or similar container patterns
            if 'containername' in line_lower and ('"' in line):
                entity = self._extract_entity_from_container_pattern(line)
                if entity:
                    entities.append(entity)
                    
            # Pattern 5: where podName patterns
            if 'podname' in line_lower and ('"' in line):
                entity = self._extract_entity_from_pod_pattern(line)
                if entity:
                    entities.append(entity)
                    
            # Pattern 6: where deployment or app patterns
            if ('deployment' in line_lower or 'appname' in line_lower) and ('"' in line):
                entity = self._extract_entity_from_deployment_pattern(line)
                if entity:
                    entities.append(entity)
        
        return entities

    def _extract_entity_from_contains_pattern(self, line: str) -> str:
        """Extract entity name from 'contains "entity"' pattern."""
        try:
            # Look for pattern: contains "something"
            if 'contains "' in line:
                parts1 = line.split('contains "')
                if len(parts1) > 1:
                    parts2 = parts1[1].split('"')
                    if len(parts2) > 0:
                        return parts2[0].strip()
            
            # Also check for 'has "something"' pattern
            if 'has "' in line:
                parts1 = line.split('has "')
                if len(parts1) > 1:
                    parts2 = parts1[1].split('"')
                    if len(parts2) > 0:
                        return parts2[0].strip()
        except:
            pass
        return ""

    def _extract_entity_from_role_pattern(self, line: str) -> str:
        """Extract entity name from cloud_RoleName patterns."""
        try:
            quote_patterns = ['has "', 'contains "', '== "', 'startswith "']
            for pattern in quote_patterns:
                if pattern in line:
                    parts1 = line.split(pattern)
                    if len(parts1) > 1:
                        parts2 = parts1[1].split('"')
                        if len(parts2) > 0:
                            return parts2[0].strip()
        except:
            pass
        return ""

    def _extract_entity_from_service_pattern(self, line: str) -> str:
        """Extract entity name from serviceName patterns."""
        try:
            quote_patterns = ['== "', 'has "', 'contains "', 'startswith "']
            for pattern in quote_patterns:
                if pattern in line:
                    parts1 = line.split(pattern)
                    if len(parts1) > 1:
                        parts2 = parts1[1].split('"')
                        if len(parts2) > 0:
                            return parts2[0].strip()
        except:
            pass
        return ""

    def _extract_entity_from_container_pattern(self, line: str) -> str:
        """Extract entity name from containerName patterns."""
        try:
            quote_patterns = ['startswith "', 'has "', 'contains "', '== "']
            for pattern in quote_patterns:
                if pattern in line:
                    parts1 = line.split(pattern)
                    if len(parts1) > 1:
                        parts2 = parts1[1].split('"')
                        if len(parts2) > 0:
                            return parts2[0].strip()
        except:
            pass
        return ""

    def _extract_entity_from_pod_pattern(self, line: str) -> str:
        """Extract entity name from podName patterns."""
        try:
            quote_patterns = ['startswith "', 'has "', 'contains "', '== "']
            for pattern in quote_patterns:
                if pattern in line:
                    parts1 = line.split(pattern)
                    if len(parts1) > 1:
                        parts2 = parts1[1].split('"')
                        if len(parts2) > 0:
                            return parts2[0].strip()
        except:
            pass
        return ""

    def _extract_entity_from_deployment_pattern(self, line: str) -> str:
        """Extract entity name from deployment/app patterns."""
        try:
            quote_patterns = ['== "', 'has "', 'contains "', 'startswith "']
            for pattern in quote_patterns:
                if pattern in line:
                    parts1 = line.split(pattern)
                    if len(parts1) > 1:
                        parts2 = parts1[1].split('"')
                        if len(parts2) > 0:
                            return parts2[0].strip()
        except:
            pass
        return ""

    def _filter_and_deduplicate_entities(self, entities: List[str]) -> List[str]:
        """Remove duplicates and filter out common non-entity terms."""
        filtered_entities = []
        seen = set()
        
        # Common terms to exclude (not useful as entity names)
        exclude_terms = {'true', 'false', 'null', 'empty', 'test', 'debug', 'log', 'error', 'info', 'warn', 'http', 'https', 'www'}
        
        for entity in entities:
            entity_lower = entity.lower()
            entity_clean = entity.strip()
            
            # Skip if empty, too short, or common term
            if not entity_clean or len(entity_clean) < 2 or entity_lower in exclude_terms:
                continue
                
            # Skip if already seen
            if entity_lower in seen:
                continue
                
            filtered_entities.append(entity_clean)
            seen.add(entity_lower)
        
        return filtered_entities

# ──────────────────────────────────────────────────────────────────────────────
#  CLI helper for ad-hoc testing
# ──────────────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    import argparse
    from pathlib import Path
    import pprint

    ap = argparse.ArgumentParser(description="Parse an Azure alert JSON file")
    ap.add_argument("file", type=Path, help="Path to alert JSON")
    ns = ap.parse_args()

    data = ns.file.read_text(encoding="utf-8")
    pprint.pp(parse_azure_monitor_alert(data), width=120, sort_dicts=False)
