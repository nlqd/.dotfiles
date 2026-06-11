---
name: fast-code-search
description: Use when searching a codebase to answer "where does X happen", "what is related to Y", or to map an unfamiliar area, especially when the semble MCP server is available. Also use when grep is returning too much noise or you do not know the exact symbol to grep for. Skip for: known-symbol lookups, error-string searches, or one-shot reads where the file path is already known.
---

# Fast Code Search

## Iron Rule: Verify Every Citation

Every `file:line` you cite from a semble result MUST be confirmed with the Read tool before quoting. Semble's chunk-header line numbers drift by 5-15 lines and are not source-of-truth. This rule applies regardless of the prompt shape: "map the area", "list the files", "give me an overview" all require verified citations.

No exceptions:
- "The user only asked for a map, not exact lines" — still verify. A map with wrong line numbers is worse than no map.
- "The chunk header looks specific enough" — that's the failure mode. Chunk headers are approximations.
- "I already searched four times, I'm confident" — confidence is not verification.
- "Reading every file would be slow" — Read is cheap. Drifted citations cost more than the Reads.

If you are about to write `file.rs:NNNN-MMMM` in your output and you have not opened that file in this session, STOP and Read first.

## Overview

Pick the right tool for the search question. Semantic search (semble MCP) maps unfamiliar territory and surfaces thematically-related chunks. Literal search (grep/rg) is precise for known symbols, error strings, and exhaustive enumeration. Most non-trivial investigations need both, in order, with Read closing every loop.

## When to Use Semble First

- You don't know what file or function name to look for ("where does session billing happen?")
- The question is cross-cutting ("everything related to X")
- The codebase is unfamiliar
- You want a fast survey before reading any file

## When to Use Grep First

- You already have a function name, constant, error string, or exact filename
- You need every occurrence (semble ranks; grep enumerates)
- The repo doesn't have semble indexed and a one-shot lookup isn't worth the index cost

## Querying Semble Well

The dial that matters is query phrasing, not `top_k`.

- Vague queries ("session time calculation") drown in semantically-adjacent noise no matter how deep you scan.
- Specific queries that name the mechanism (verbs + identifiers, e.g. "advance session_started_at after checkpoint", "UPDATE statement billing") re-rank the right chunks into the top 3.

If your first semble query returns thematic-but-not-mechanistic hits:

- Re-query with mechanism words. Do not bump `top_k`.
- Use `find_related` on a near-hit to pull adjacent chunks.

## Quick Reference

| Question shape | Tool |
|---------------|------|
| "Where does X happen?" / "what is related to Y?" | semble |
| "Where is `funcName` defined / called?" | grep/rg |
| "Find every TODO comment" | grep/rg |
| "Map the auth flow" | semble + Read |
| "Confirm line numbers before quoting" | Read (mandatory) |

## Cost Note

Semble indexes a repo on first query (slow), then caches for the session. For sustained work in one repo: cheap. For one-shot lookups across many repos: grep wins.

## Rationalization Table

| Excuse | Reality |
|--------|---------|
| "User asked for a map, exact lines don't matter" | Wrong lines erode trust. Verify. |
| "I ran 4 parallel semble queries, that's thorough enough" | Thoroughness in search ≠ accuracy in citation. Read. |
| "Semble's chunk header IS the line number" | It's the chunk boundary. Functions don't start there. |
| "Reading is slow" | Read is one tool call. A drifted citation is a bug. |
| "I'll Read only the suspicious ones" | You don't know which are suspicious until you Read. |

## Red Flags

- About to output `file:line` without having Read that file in this session. STOP. Read first.
- Issuing the same vague semble query at higher `top_k`. STOP. Re-phrase with mechanism words.
- Reading five or more unrelated semble chunks. STOP. Your query is too thematic.
- Crafting an elaborate regex because grep keeps missing. STOP. Try semble.
