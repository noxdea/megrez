# ADR 001: Encode stop generations in variable references

- Status: Accepted
- Date: 2026-09-15

## Context

DAP variable references are valid only while execution remains stopped. An
adapter may reuse the same integer after the next stop, so retaining only a
set of seen integers cannot reliably identify stale UI state.

## Decision

Expose zero unchanged and encode the current stop generation with every
positive adapter reference. Decode and verify it before sending requests.

## Consequences

References remain integers and stale values are rejected deterministically.
They are opaque handles; callers must not interpret their numeric value.
