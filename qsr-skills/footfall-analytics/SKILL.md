---
name: footfall-analytics
description: "Answer zone-level footfall, traffic, and busy-hour questions using the EdgeMart footfall-service MCP service. Read-only — no actions."
version: 1.0.0
platforms: [linux]
metadata:
  hermes:
    tags: [QSR, Footfall, Traffic, Analytics]
---

# Footfall Analytics

Use the `footfall-service` MCP service for zone-level people-count
and density questions (entrance, counter, seating). This service is read-only
— it has no action tools, and no menu/table/order context; use
`cafe-operations` or `table-management` for those.

## Tool Routing

| User intent or question | Tool | Fields to use | Answer rule |
|---|---|---|---|
| Total traffic / footfall over a period | `get_total_footfall` | `total_footfall`, `event_count`, `by_zone[]` | Pass `zone` only when the user named one, and `start_date`/`end_date` only when the user named a period; otherwise omit them (never pass `"all"` or a guessed date, which returns 0). "By zone" or "per zone" is not a zone name: call with no arguments, because `by_zone[]` already breaks down every zone. State the period used. |
| When is the busiest time of day / rush hour | `get_busy_time_patterns` | `hour`, `total_footfall`, `days_observed`, `avg_footfall_per_day` | Omit `start_date`/`end_date` (a pattern needs several days). Report using `avg_footfall_per_day`, not raw `total_footfall`, so the answer isn't skewed by how many days were observed. |
| List known event types | `list_event_types` | `event_type`, `description` | — |

Call the tool again for every footfall question; never reuse a number from an
earlier turn. Pass `experience` only if the user named one, and never pass
filters the user did not ask for to `get_busy_time_patterns` (the `zone`
example `entrance` in the tool schema is not a default; "busiest hours" needs
a single call with no arguments, and nothing from `store-activity-service`). The service
returns every hour in hour order, unranked: when asked for the busiest
periods, rank by `avg_footfall_per_day` and quote that value. When asked "by
zone", report every entry of `by_zone[]`, not a subset.

## Complex Questions

For "is it busier than usual" or staffing-style questions, call
`get_busy_time_patterns` once and reason over the hourly averages rather than
guessing. If the question also depends on orders or table turnover, use the
`cafe-operations` or `table-management` skill and its tool before combining
the answer.

## Owner Extension

Service owners should add specialized question mappings to the Tool Routing
table. Follow [`../../docs/adding-a-service.md`](../../docs/adding-a-service.md).
