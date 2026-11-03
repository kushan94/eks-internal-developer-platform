# ADR 0002: Self-host Backstage

**Status:** Accepted (2026-11-03)

## Context
The platform needs a portal for the service catalog and for creating services from templates. SaaS portals need less maintenance but hide most of the implementation.

## Decision
Self-host Backstage using its New Frontend System. Its templates open pull requests rather than calling cloud APIs, so Git stays the only path to change.

## Consequences
- We own the Backstage upgrades, database, authentication and any plugins.
- Build it after the first golden path works, so that the portal has something real to expose.
