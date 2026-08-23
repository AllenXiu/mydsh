# Agent Note: Recycle mcp-client connections after tools/call transport failures

Status: implemented

English | [中文](2026-08-21-mcp-client-tool-call-reconnect.zh.md)

## Problem

mcp-client only reconnected when the MCP transport itself closed (`onclose`). A server that survived the connection handshake but then died silently left every subsequent `tools/call` failing at the transport layer with no supervisor action: the registered tools stayed up, every call failed, and recovery required an HMR reload or Host restart.

## Decision

The tool bridge now reports a `tools/call` transport failure to the connection supervisor. The executor (`tools.ts`) catches a request that rejects before the server returns a result and invokes an optional `onConnectionError` callback on `ToolBridgeOptions`. The supervisor's callback closes the current generation, which flows through the normal `generationDown` → backoff → reconnect path, re-syncing tools through a fresh generation.

A server-reported business failure (`isError: true`) is delivered through the executor's thrown error for the model and never reaches the callback — the transport is healthy, so no reconnect happens.

## Alternatives considered

**Detect specific error codes (e.g. ECONNREFUSED / fetch failed).** Rejected because the MCP SDK's Streamable HTTP transport surfaces failure through generic fetch errors that vary by platform and undici version; closing the generation on any transport-layer failure is simpler and covers every failure mode the supervisor already handles.

**Attempt one call on the new generation before recycling.** Rejected because the supervisor owns generation lifecycle; a tools/call failure means the current generation is suspect, and the backoff loop already tolerates flapping servers through `maxAttempts`.

## Consequences

A server that dies between calls is reconnected automatically instead of failing every future call. Business errors never cause wasteful reconnects. The same `maxAttempts` budget governs tools/call-triggered reconnects, so a crash-looping server still exhausts the cap. The executor's `onConnectionError` is a fire-and-forget notification; it never throws and never affects the tool result delivered to the model.