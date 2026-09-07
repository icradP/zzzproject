<!-- CODEGRAPH_START -->
## CodeGraph

In repositories indexed by CodeGraph (a `.codegraph/` directory exists at the repo root), reach for it BEFORE grep/find or reading files when you need to understand or locate code:

- **MCP tool** (when available): `codegraph_explore` answers most code questions in one call — the relevant symbols' verbatim source plus the call paths between them, including dynamic-dispatch hops grep can't follow. Name a file or symbol in the query to read its current line-numbered source. If it's listed but deferred, load it by name via tool search.
- **Shell** (always works): `codegraph explore "<symbol names or question>"` prints the same output.

If there is no `.codegraph/` directory, skip CodeGraph entirely — indexing is the user's decision.
<!-- CODEGRAPH_END -->

## ZZZ project scope

- This repository contains the complete ZZZ IM product: the Flutter client under `lib/src/im/**` and the Go service under `server/**`. Do not treat the server as a separate checkout, and do not fetch another ZZZ IM repository.
- Keep ZZZTerm integration changes in this repository limited to shared IM components, protocol definitions, and Fairy/server behavior that are required by the local contract. The ZZZTerm client itself lives in `../zzzterm`.
- Use the deployment scripts in `deploy/zzz-im/**` for IM/server builds. Scripts must not pull or clone source repositories implicitly.
- Before staging, separate product changes from untracked `dist/`, agent metadata, IDE state, and other local artifacts. Preserve unrelated user modifications.

## Fairy and ZZZTerm contract

- A ZZZ IM conversation with Fairy is the remote-control entry point for an online ZZZTerm client.
- Fairy may request host discovery or a command through the server, but the server only validates, forwards, and persists protocol messages. It never opens SSH, chooses credentials, or executes commands.
- ZZZTerm performs command execution in an already connected SSH session and owns the local Allow/Deny approval. Read-only host discovery does not require approval.
- Keep `docs/ZZZTERM.md`, `docs/FAIRY.md`, and `docs/FAIRY_AGENT_ARCHITECTURE.md` synchronized with protocol or approval changes, and add focused tests for both the server and client boundary.
