# KQL Entity Extraction for Azure Monitor Webhooks

## Overview

This enhancement adds intelligent entity extraction from KQL queries in Azure Monitor webhook payloads. Instead of relying solely on target resource names (which may be too broad, like cluster names), the system now analyzes the actual KQL query to find more specific entity names that are likely to match your SLX configurations.

## How It Works

### 1. Priority-Based Entity Selection
- **Primary**: Extract entities from KQL queries (more specific)
- **Fallback**: Use target resource names (broader scope)

### 2. Supported KQL Patterns

The system recognizes and extracts entities from these common KQL patterns:

- `where name contains "rxf"` → extracts `rxf`
- `where cloud_RoleName has "frontend"` → extracts `frontend`
- `where serviceName == "payment-service"` → extracts `payment-service`
- `where containerName startswith "webapp"` → extracts `webapp`
- `where podName contains "worker"` → extracts `worker`
- `where deployment/appname patterns` → extracts deployment names

### 3. Smart Filtering

- Removes duplicates
- Filters out common non-entity terms (`true`, `false`, `null`, `test`, etc.)
- Requires minimum length (2+ characters)

## Example

Given your webhook example with the KQL query:
```kql
requests
| where name contains "rxf"
| where cloud_RoleName has "rxf"
| summarize avg_duration=sum(itemCount * duration) / sum(itemCount) by url
| where avg_duration > 2000
| project url
```

The system will:
1. Extract `rxf` as the primary entity
2. Use `rxf` to search for matching SLXs instead of the broader target resource name
3. Fall back to target resource if no SLXs match `rxf`

## Benefits

- **More Precise Matching**: Container/service names from queries often match SLX configurations better than cluster names
- **Better SLX Discovery**: Finds relevant runbooks that target specific services/containers
- **Graceful Fallback**: Still works with existing alerts that don't have useful KQL queries
- **Enhanced Reporting**: Clear visibility into which entities are being used for matching

## Technical Implementation

The KQL entity extraction functionality is now properly implemented as part of the `RW.Azure` library:

- **Library**: `libraries/RW/Azure/azure_alert_parser.py`
- **Keyword**: `Extract KQL Entities`
- **Usage**: `${entities}=    RW.Azure.Extract KQL Entities    ${webhook_json}`

## Files Modified

- `libraries/RW/Azure/azure_alert_parser.py`: Added `extract_kql_entities` method to the Azure class
- `runbook.robot`: Updated main workflow to use `RW.Azure.Extract KQL Entities`
- `.test/test_kql_extraction.robot`: Tests using the proper library integration

## Testing

Run the tests to verify functionality:
```bash
robot .test/test_kql_extraction.robot
```

The tests cover:
- Extraction from your example webhook
- Handling of missing KQL queries
- Multiple entity pattern recognition

## Integration

The functionality integrates seamlessly with the existing RunWhen platform architecture:
- Uses the standard `RW.Azure` library pattern
- Follows Robot Framework keyword conventions
- Maintains backward compatibility with existing webhook handlers
- Provides proper error handling and logging 