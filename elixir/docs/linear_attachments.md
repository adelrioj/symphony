# Linear issue attachments

How a Symphony stage agent reads a file attached to its Linear ticket (for
example a `<IDENT>-design.md` design spec uploaded by a sibling tool). This
document records the design decision and its rejected alternatives.

## Problem

A Linear attachment is a **URL, not bytes**. Uploaded files live at
`https://uploads.linear.app/...` and, per Linear's
[file-storage-authentication](https://linear.app/developers/file-storage-authentication)
docs, downloading one requires the **same** `Authorization` header used for the
GraphQL API. Before this change a stage agent could not reach that file by any
path: the poll GraphQL never requested attachments, the normalized `Issue`
carried no field for them, and the agent's environment holds no Linear token.

## Decision: extend the existing Linear auth-broker

Symphony already brokers authenticated Linear access to the stage agent through
the `linear_graphql` tool (Codex via the app-server dynamic tool, Claude via the
`--linear-mcp` bridge). The agent's process never holds a Linear token; Symphony
executes calls on its behalf with the configured `LINEAR_API_KEY`. We close the
attachment gap by fitting the same broker:

1. **Surface metadata.** The poll GraphQL (`@query` and `@query_by_ids`) now
   requests `attachments { nodes { title url } }`, and `Tracker.Issue` carries a
   provider-neutral `attachments` field (default `[]`). The default prompt renders
   the list so the agent deterministically sees what is attached.
2. **Broker the download.** A new `linear_fetch_attachment` provider tool GETs an
   `uploads.linear.app` URL with Symphony's credential and returns the file's
   UTF-8 contents to the agent. The token is never exposed to the child; only the
   content crosses the boundary, exactly like `linear_graphql`.

This adds **no new secret, credential path, or config surface** — it reuses the
credential the broker already uses — and needs no workspace-write path, so it
works identically for local and remote (SSH) workspaces.

### Guardrails

- The fetch tool only accepts `https://uploads.linear.app/...` URLs. It refuses
  any other host so Symphony's credential can never be aimed at an arbitrary
  server (SSRF / token exfiltration).
- Downloads are capped (1 MiB) and must be valid UTF-8; binary or oversized
  attachments return a tool error rather than flooding the agent context.
- No secret is added to `Tracker.Issue`; `attachments` holds only `title` + `url`.
- Provider neutrality is preserved: GitLab/Jira/Asana/GitHub build `Issue`
  without attachments and inherit the empty default.

## Rejected: A — render metadata, agent fetches directly

Put `title` + `url` on the struct/prompt and let the agent download the file
itself. Rejected: the download needs the Linear token, so this requires **a
Linear credential inside the stage environment** — a new secret in a new place.
That also contradicts the existing model where Symphony, not the agent, holds
tracker auth (`Tracker.Issue`'s `native_ref` is explicitly non-secret).

## Rejected: B — Symphony downloads at dispatch into the workspace

Have the orchestrator fetch each attachment and write it into the workspace so
the agent just reads a file. It reuses `LINEAR_API_KEY` (no new secret), but it
is heavier and less aligned with the existing broker:

- It must order after the `after_create` `git clone` (which needs an empty
  directory), adding hook-coordination the orchestrator does not have today.
- It must write bytes into **remote** SSH workspaces, a new failure surface.
- It reintroduces an orchestrator-side fetch even though the agent already has an
  authenticated Linear channel.

B's only advantage over the chosen design is determinism: the file is guaranteed
on disk regardless of agent behavior. The chosen design instead relies on the
agent invoking a tool — the same model it already uses to read the issue and post
comments — and makes discovery deterministic by rendering the attachment list
into the prompt.
