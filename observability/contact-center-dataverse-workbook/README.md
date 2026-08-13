# Contact Center and Dataverse Operations workbook

This package deploys one shared Azure Monitor workbook that combines Contact Center conversation diagnostics with Dataverse operational telemetry. It is intended for operations, support, and incident investigation rather than as a billing or SLA source.

The package contains:

- `Contact-Center-Dataverse-Operations.workbook`: portable Azure Workbook JSON with no tenant-specific resource IDs.
- `Install-ContactCenterDataverseWorkbook.ps1`: an idempotent Azure CLI deployment script.

## Scope

The workbook provides a single entry point for:

- voice call lifecycle and unsuccessful-call diagnostics;
- messaging and live-chat health;
- unified routing, queue assignment, overflow, and fallback;
- Dataverse API volume, latency, HTTP 429 responses, and query throttling;
- plug-in, SDK, form-load, exception, and outbound dependency performance;
- cross-table investigation by conversation or Application Insights correlation ID.

It reads telemetry only. Deploying the workbook does not enable telemetry exports, change diagnostic settings, or modify Contact Center or Dataverse configuration.

## Prerequisites

- PowerShell 7 or Windows PowerShell 5.1.
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) authenticated with `az login`.
- Permission to read the target Application Insights component and resource group.
- Permission to create or update `Microsoft.Insights/workbooks` resources in the target resource group.
- The `Microsoft.Insights` resource provider registered in the target subscription.
- An Application Insights component receiving the exports described below.

The deployment subscription and Application Insights subscription may differ. The caller must have access to both resources.

## Telemetry and export requirements

The workbook expects Dataverse and Contact Center telemetry to be exported to the selected Application Insights component. Configure the applicable Dataverse Application Insights export and Contact Center conversation diagnostics export before using the workbook.

Export availability and field population depend on the enabled workload and feature. Initial telemetry can take up to 24 hours to arrive after export is configured.

| Application Insights table | Workbook use |
| --- | --- |
| `traces` | Contact Center conversation, channel, voice, messaging, routing, and query-throttling events |
| `requests` | Dataverse API volume, success, HTTP status, duration, caller, and correlation |
| `dependencies` | Dataverse plug-in, SDK, and outbound dependency execution |
| `exceptions` | Dataverse exception counts, trends, source, entity, and plug-in context |
| `pageViews` | Model-driven app form and page-load performance |
| `customEvents` | Query-throttling events when emitted outside `traces` |

The Contact Center queries normalize these `customDimensions` fields:

| Normalized value | Accepted source fields |
| --- | --- |
| Organization | `powerplatform.analytics.resource.organization.id`, `environmentId`, `EnvironmentId`, or `organizationUrl` |
| Conversation ID | `powerplatform.analytics.resource.id` |
| Scenario | `powerplatform.analytics.scenario` |
| Subscenario | `powerplatform.analytics.subscenario` |
| Channel | `omnichannel.channel.type`, `ChannelType`, or `channelType` |
| Description | `omnichannel.description` or `Omnichannel.description` |
| Agent ID | `omnichannel.target_agent.id` or `omnichannel.agent.id` |
| Call ID | `omnichannel.call.id` |
| Queue/result data | `omnichannel.result` |
| Overflow and supplemental data | `omnichannel.additional_info` |

Query-throttling panels additionally recognize `CdsQueryHash`, `throttlingAction`, `throttleReason`, `throttlingDelayMilliseconds`, `throttleProbabilityPercentage`, `throttleExpiryTime`, and `Command`, including the casing variants used by existing Dataverse exports.

If a field is absent, panels that depend on it can be empty while panels based on standard Application Insights columns continue to work.

## Deploy or update the workbook

Run the installer from this directory:

```powershell
.\Install-ContactCenterDataverseWorkbook.ps1 `
    -SubscriptionId '<workbook-subscription-guid>' `
    -ResourceGroupName '<workbook-resource-group>' `
    -ApplicationInsightsResourceId '/subscriptions/<source-subscription-guid>/resourceGroups/<source-resource-group>/providers/Microsoft.Insights/components/<component-name>'
```

`SubscriptionId`, `ResourceGroupName`, and `ApplicationInsightsResourceId` are required and validated. The workbook location defaults to the target resource group's location. Use `-Location` only when the workbook must use another supported Azure region.

Optional parameters:

| Parameter | Behavior |
| --- | --- |
| `DisplayName` | Changes the workbook display name; defaults to `Contact Center and Dataverse Operations`. |
| `WorkbookId` | Updates that workbook resource ID directly. Use this when duplicate display names already exist. |
| `Location` | Overrides the target resource group's location. |
| `WorkbookPath` | Deploys another compatible local `Notebook/1.0` definition. |

On each run, the script:

1. Validates Azure CLI access, the target resource group, and the Application Insights resource type.
2. Parses the workbook JSON and injects the selected Application Insights resource into both the resource parameter and fallback resource list.
3. Searches only the target resource group for an exact, case-sensitive display-name match.
4. Updates that one workbook, or creates one new workbook when no match exists.
5. Fails if duplicate exact-name workbooks make the update ambiguous, unless `-WorkbookId` is supplied.
6. Removes only its temporary request file.

The script never changes the active Azure CLI subscription and never deletes any workbook. Every subscription-sensitive Azure operation is explicitly scoped by resource ID, request URI, or `--subscription`.

## Global parameters and KQL substitution

Azure Workbooks substitutes parameter tokens before sending KQL to Application Insights:

| Parameter | Purpose |
| --- | --- |
| `SelectedPage` | Controls conditional page visibility through the tab links. |
| `TimeRange` | Supplies the KQL time predicate and `{TimeRange:grain}` chart bin size. Default: seven days. |
| `ApplicationInsightsResource` | Selects the Application Insights component used by every query. |
| `Organization` | Filters normalized organization/environment values; `*` means all. |
| `Channel` | Filters normalized Contact Center channels; `*` means all. |
| `Queue` | Filters queue display names extracted from `omnichannel.result`; `*` means all. |
| `InvestigationId` | Matches conversation and Application Insights correlation identifiers. |
| `SlowThresholdMs` | Sets the duration threshold for slow requests, form loads, and dependencies. Default: 5000 ms. |

All query items use `crossComponentResources` with `{ApplicationInsightsResource}`, so changing the resource picker reruns the workbook against the selected component. Query items also use `timeContextFromParameter` to keep the workbook time picker and KQL predicates aligned.

## Shared KQL patterns

### Conversation normalization

Most Contact Center panels start from `traces`, parse `customDimensions` once, and project stable names such as `ConversationId`, `Organization`, `Channel`, `Subscenario`, `AgentId`, and `CallId`. The shared filter keeps events where:

```kusto
Scenario == "ConversationDiagnosticsScenario" or isnotempty(Subscenario)
```

It then applies the organization and channel parameters. This deliberately accepts events that have a known subscenario even when the scenario field is unavailable.

### Environment filtering

Dataverse queries normalize the environment identity with `coalesce(...)` across the known export field names. This permits the same organization selector to filter `requests`, `dependencies`, and `exceptions`.

### Queue filtering

Routing events parse `omnichannel.result` as dynamic JSON and use its `DisplayName` as `QueueName`. A queue filter therefore requires `RouteToQueue`-style telemetry with a populated result object.

### Query-throttling union

Query-throttling KQL uses `union isfuzzy=true` over `traces` and `customEvents`. `isfuzzy=true` allows the query to run when one table is unavailable. Events are included when they are named `QueryThrottled`, have a throttle action, or contain a query hash.

### Correlation

The Investigator unions Application Insights tables with `withsource=TelemetryTable`. It matches the supplied ID against:

- `operation_Id`;
- `operation_ParentId`;
- `itemId`;
- `requestId` and `serviceRequestId` custom dimensions;
- the Contact Center conversation resource ID.

Results are ordered chronologically to reconstruct an end-to-end sequence. The raw-dimensions panel expands each custom-dimension bag into key/value rows so new or workload-specific fields remain inspectable.

## Workbook pages

### Overview

Summarizes conversation events, distinct conversations, HTTP 429 responses, and Dataverse failures. A union with `withsource` shows telemetry arrival by table. Additional panels group conversations by channel and highlight failure, timeout, disconnect, and rejection subscenarios.

Use this page first to confirm data readiness and identify which operational area needs investigation.

### Conversation Lifecycle

Turns one conversation's exported diagnostic events into a presentation-friendly journey. Enter a conversation or correlation ID in the global filter to see:

- a summary card with channel, start/end timestamps, duration, event count, and final observed stage;
- ordered event cards that show the original event name, a simplified journey stage, event time, and time since the previous event;
- a detailed chronological table retaining queue, agent, call, event, action, description, and operation identifiers.

The lifecycle KQL sorts and serializes the trace stream before assigning step numbers and calculating the gap from `prev(timestamp)`. It classifies known subscenarios into Arrival, Routing, Assignment, Engagement, Transfer / consult, and Closure. Unknown events remain visible as `Journey event`; the classification does not discard telemetry.

This page intentionally returns no data until `InvestigationId` is populated, avoiding a misleading lifecycle assembled from multiple conversations.

### Voice

Filters voice channels and voice-specific subscenarios. It reports distinct voice conversations, call connections, unsuccessful calls, lifecycle trends, outcome codes, media/control events, transfer and consult issues, and unsuccessful call details.

An unsuccessful call is identified from call-end diagnostic events where `CallStatusCode != 0`, or where failure/disconnect text is present in the details panel.

### Messaging

Selects chat, messaging, SMS, WhatsApp, Facebook, and Teams channels plus recognized messaging subscenarios. It reports authentication issues, timeout events, lifecycle distribution, error categories, and recent issue details.

Text matching uses error, failure, timeout, invalid, and disconnect terms. The detail table retains `customDimensions` for follow-up.

### Routing

Tracks processed conversations, rejected assignments, queue distribution, non-assignment reasons, overflow/fallback events, and state flows.

Assignment latency joins `RouteToQueue` events to `CSRAccepted` events by `ConversationId`. It keeps routes that occurred before acceptance, selects the latest qualifying route, calculates seconds to acceptance, and reports P50/P95 trends. Missing either event prevents that conversation from contributing to latency.

The state-flow panel orders events before using `make_list(Subscenario)`, producing a readable lifecycle such as `RouteToQueue -> CSRAccepted`.

### APIs and Throttling

Uses `requests` for API totals, failures, slow calls, HTTP 429 counts, latency trends, throttled operations, successful callers by occupied execution time, and recent 429 details.

It uses `traces` and `customEvents` for Dataverse query-throttling reasons, delay percentiles, query hashes, actions, and sample commands. Successful occupied time is included because service-protection pressure can be driven by successful but expensive traffic as well as failed calls.

Durations are Application Insights duration values and are compared with `SlowThresholdMs`.

### Failures and Performance

Combines:

- `exceptions` for exception trends and top problem IDs;
- `dependencies` with `type == "Plugin"` for plug-in reliability and occupied time;
- `dependencies` with `type startswith "SDK"` for SDK performance;
- `pageViews` for model-driven app form-load percentiles;
- other dependencies for failed or slow outbound calls.

The performance tables rank by occupied time or P95 duration rather than count alone, exposing low-volume but expensive operations.

### Investigator

Provides three chronological views:

1. Contact Center conversation lifecycle from `traces`.
2. Correlated telemetry across `requests`, `dependencies`, `exceptions`, `traces`, `customEvents`, and `pageViews`.
3. Expanded raw custom dimensions across the principal telemetry tables.

Enter the most specific known conversation, operation, parent, item, request, or service-request ID. Leaving `InvestigationId` empty returns broad results capped by each panel's `take` limit, so a specific ID is recommended.

## Empty-data behavior

Every query displays `No matching telemetry has arrived for this selection.` when it returns no rows. Empty results are not converted to synthetic success values.

Before treating an empty panel as healthy, check:

1. The selected Application Insights resource is correct.
2. The time range includes data after export enablement.
3. The Overview telemetry-arrival panel shows the required table.
4. Organization, channel, and queue filters are set to all.
5. The required workload export and feature are enabled.
6. The expected custom dimensions exist in a sample telemetry record.

Some tile queries use `summarize count()` and can display zero even when no source rows match. Charts and detail tables generally show the explicit no-data message. A zero or empty result means only that the query found no matching exported telemetry for the current selection.

## Customization guidance

- Keep the shared normalization expressions consistent across pages when adding field aliases.
- Apply `{TimeRange}` before expensive parsing, joins, or expansion.
- Preserve organization and channel filters on new Contact Center panels.
- Use `isfuzzy=true` only where a missing optional table should not fail the entire query.
- Cap raw detail views with `take` and sort before truncation.
- Avoid embedding tenant, subscription, resource group, or component IDs in the workbook source.
- Test new KQL directly against representative Application Insights data before committing workbook JSON.

Workbook JSON is the deployable source artifact. If it is edited in the Azure portal, export the updated workbook definition, remove resource-specific defaults, and validate the JSON before replacing the repository copy.
