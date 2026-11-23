# Dossier Console: design

Approved by the user 2026-11-19 (revision 2), with corrections from the v0 spike applied the same day (sandbox: `~/workspace/sandbox/dossier-console-spike`). Nothing built yet. Phases in section 8.

## Decisions

- One console, two leads. The firm's lead (hub, firm account) leads every firm-account home: hub, product, no-seat client. The enterprise lead leads the enterprise client's home on the client's account and directs the team there.
- Chat panes: hub (firm lead) and enterprise client (enterprise lead). Product and no-seat client panes show board, sessions and teammates, with an "Ask <firm lead>" button.
- The top screen shows the hub board and the whole enterprise board. Other boards stay in their panes.
- No separate Windows account for enterprise work. The residual risk in section 7 is accepted.
- Read-only plus the two chats. The GUI never edits STATUS.md or anything else.
- Event retention 7 days.
- Name "Dossier Console", launched by a Start-menu shortcut and a `dossier-console` command that refuses inside Claude sessions.
- Background leads, if used, ignore project MCP servers (`--strict-mcp-config`).
- Still open, decided before v2: Agent SDK (C1) vs pure PowerShell (C2); GUI-hosted vs background leads; Remote Control link-out and browser profiles; turning off UI Automation for content; whether to tell the enterprise client's admins.

## Principle

The GUI adds no new place where client data lives and no new way to reach it. Data stays in the home it came from, under that home's deny rules. The GUI opens no listeners and no shared store, and nothing is started from inside a Claude session. (Claude Code itself already runs a named pipe per session, `messagingSocketPath` in `<home>\sessions\<pid>.json`, and a daemon with a `control.key`; those aren't the GUI's.)

The shell may show enterprise board text but has no way to pass it on: content travels one way, pane to shell. A shell bug can at worst show text in the wrong column.

## 1. Facts the design rests on

- Hub, product and no-seat client homes allow `Bash` and `PowerShell`, so any localhost listener could be curled by a hub agent. Hence no ports.
- Boards follow the firm lead's format: `STATUS.md` at the engagement root, sections "Needs you", "In progress", "Done", one dated line per item.
- The enterprise client gets its own lead through a per-entry lead override (section 4.6).
- Deletes are decided by the shell guard (`windows/dossier-shellguard.ps1`), a PreToolUse hook for Bash and PowerShell that Sync installs in every home, the enterprise client's included, with `-WorkspaceRoot` set to the registry's `workspaceRoot`. Its deny checks run first: a delete that would reach a path the home's deny rules cover is denied. Otherwise a delete runs without a prompt when every target is inside `workspaceRoot`, and gets `ask` when a target is outside it, is the whole workspace, or can't be resolved (a variable, command output, piped input). Without `-WorkspaceRoot` every delete asks. The registry carries no delete ask rules. Each pane checks its own home's hook.
- Hub agents can edit this repo, so any code that holds enterprise content (the enterprise pane and the shell) runs from a pinned copy firm sessions can't edit.
- pwsh 7.7 on .NET 11 loads WPF. Node is present because Claude Code runs on it. pwsh is the Microsoft Store build: its exe lives under `C:\Program Files\WindowsApps\...` and its hash changes with every Store update.
- Parent process, ancestry and environment are all forgeable by any process running as the user. The spike started a child with a forged parent (`PROC_THREAD_ATTRIBUTE_PARENT_PROCESS`) from inside a Claude session. Every process-identity check in this design is accident prevention, not a boundary.

## 2. Architecture

```
 The user's desktop (shortcut → pinned shell; refuses if launched from any Claude session)
 └─ Shell  (pwsh -STA, WPF, runs from %LOCALAPPDATA%\Dossier\console\bin, Edit-denied in every home)
     │  reads ~/.dossier.json + layout file only; no Claude/node child; no text input; nothing to disk
     │  shell→pane : enum commands only {show|hide|focus|quit|focusChat}
     │  pane→shell : status (counts/enums) + board (validated sections), one way
     ├─ PaneHost[firm]         ~/.claude            board, sessions, teammates, chat → firm lead (v2)
     ├─ PaneHost[base-app]                         board, sessions, teammates
     ├─ PaneHost[widgetco]                         board, sessions, teammates, firm lead's -p runs
     └─ PaneHost[acme]         ~/.claude-homes/acme, runs from <home>\dossier-gui\bin
          board, sessions, teammates, chat → enterprise lead (v2) on the enterprise login
          gatekeeper: sends board text only to the verified pinned shell
 Claude sessions in each home → async command hooks → <own home>\dossier-gui\events.ndjson
```

### 2.1 Processes

| Process | Started by | Context | Holds content |
|---|---|---|---|
| Shell | The user (shortcut or `dossier-console`) | No home. Refuses if `CLAUDECODE` or `CLAUDE_CONFIG_DIR` is set or any ancestor is Claude Code (`Test-DsrInsideClaude`). | Registry metadata, counts, hub and enterprise board text, in memory only |
| Pane host, one per home | Shell; stays running hidden when its window is closed | Environment built like `Invoke-Dossier`: clears `$DsrSessionVars`, sets `CLAUDE_CONFIG_DIR` (unset for `~/.claude`), cwd `Roots[0]`. Runs `Test-DsrLaunchable` (login matches `expectEmail`/`expectOrg`; no API key, base URL, Bedrock or Vertex). No override in the GUI. | Its own home only |
| Chat sidecar (v2), hub and enterprise panes | Pane host | The pane's clean environment | Its own home only |
| Claude Code chat session (v2) | Sidecar | The firm lead on the firm login, the enterprise lead on the enterprise login | Its own home only |
| Hook script | Each home's sessions | Home from its own `CLAUDE_CONFIG_DIR`, never from input | Writes its own home only |

Named mutexes: one per user for the shell, one per home key for panes.

### 2.2 Communication

- No TCP or HTTP listener anywhere, including `type: "http"` hooks. Only anonymous stdio pipes between parent and child. No secrets needed.
- Shell to pane: one function, `Send-PaneCommand([PaneCmd] $c)`, writing `{"cmd":"<enum>"}`. Nothing else in the shell writes to a pane's stdin.
- Pane to shell:
  - `status`: `{key, ts, interactive:{busy,shell,idle,waiting}, background:{running,blocked,stopped,done,failed}, waiting, subagentsRunning, needsUser, permissionPending, identityOk, error:enum}`. Interactive sessions have no done/failed state: they leave the list when they end.
  - `board`: `{key, ts, sections:[{kind: needsUser|inProgress|done|other, items:[string]}]}`, at most 200 items of 500 characters, plain text, control characters stripped. Only panes for homes in `gui.onTop` send it.
  - The shell drops anything that fails the schema.

### 2.3 Storage

- Per home, `<home>\dossier-gui\`: `events.ndjson` (rotated, 7 days), `sessions.json`, `locks\`, `pane.log` (errors only, never content), `bin\` (pinned pane code). Every other home's deny rules already cover it.
- Shell: `%LOCALAPPDATA%\Dossier\console\layout.json` (positions and home keys only) and `bin\` (pinned shell code).
- Nowhere else: no content in `%TEMP%`, toasts, crash dumps, clipboard history or any shared store.

### 2.4 Registry and Sync

- Registry: `"gui": { "enabled": true, "retentionDays": 7, "onTop": ["firm", "acme"] }`; `"gui": false` on an entry opts out.
- `Sync-GuiHooks` in `Sync-Settings`: `SubagentStart`, `SubagentStop`, `Stop`, `Notification`, `SessionStart`, `SessionEnd` hooks, each `type: "command"`, `async: true`, running `pwsh -NoProfile -File "<home>/dossier-gui/bin/dossier-gui-hook.ps1"`. Hook commands run under Git Bash on Windows: forward-slash paths like the existing guard hooks, never `cmd /c`. Only in GUI-enabled homes, tracked in `dossier.managed.json`. Never a `PermissionRequest` hook.
- Hook script: appends one trimmed record (ts, event, session id, agent id/type, notification type, message cut to 2,000 characters, subagent transcript path, background tasks) to its own home's `events.ndjson`. Prints nothing, always exits 0. It takes its home from the session's `CLAUDE_CONFIG_DIR` (confirmed). Each run is a ~400 ms pwsh process that doesn't block the session.
- `Stop` is lossy: the async hook was dropped in 2 of 3 `-p` runs. Take background tasks from `SubagentStop` too, and never infer completion from `Stop` alone.
- "Needs attention" notification types: `permission_prompt`, `worker_permission_prompt`, `agent_needs_input`, `idle_prompt`. Others seen in the binary: `agent_completed`, `elicitation_complete`, `elicitation_response`, `auth_success`, `auth_storage_failure`, `push_notification`, `plugin_notification`, `computer_use_exit`.
- `Sync-GuiBin`: pane code into each home's `dossier-gui\bin\` with `hashes.json`; shell code into `%LOCALAPPDATA%\Dossier\console\bin\` with hashes, plus `Edit(//<%LOCALAPPDATA% resolved, as //c/...>/Dossier/console/**)` in every home's deny rules. Enterprise-home and shell copies are written only outside a Claude session.
- Test-Dossier: GUI hooks in exactly the enabled homes; no `PermissionRequest` hook (FAIL if it names the GUI, WARN otherwise); each `dossier-gui` folder covered by every other home's deny rules; console folder Edit-denied everywhere; pinned hashes match; WER LocalDumps off for `pwsh.exe`/`node.exe`; WARN if PowerShell script-block or transcription logging is on.

### 2.5 Code integrity

The enterprise pane and the shell both run only from pinned copies. The enterprise pane checks its own hashes at start and refuses on mismatch. The shell warns if the repo's `gui\` or `windows\` has uncommitted changes. Gap: Sync on a tampered repo pins the tampering. Pinning the existing guard hooks the same way is a follow-up.

### 2.6 The enterprise board on the top screen

The enterprise pane reads `<root>\STATUS.md`, parses and caps it, and sends it to the shell over its pipe. The shell never opens an engagement root. The hub board reaches the shell the same way.

- One reader per home, in that home's context, from pinned code.
- Login gate: the board appears only when the home passes `Test-DsrLaunchable`; otherwise the shell shows "Acme Health: login mismatch, use cc".
- Only capped board sections leave the pane; never raw files, transcripts or events.
- Gatekeeper (accident prevention only): before sending, the pane checks its parent's image name is `pwsh.exe` under the Store or Program Files path pattern (no pinned pwsh hash; it changes on Store updates), running `%LOCALAPPDATA%\Dossier\console\bin\Console.ps1`, whose hash matches the one Sync recorded inside the enterprise home; and re-checks `Test-DsrInsideClaude`. Compare process creation times to catch reused pids. On any failure it sends `status` with `error: gateRefused` and no board. A same-user process can forge all of this; the real control is that the shell spawns the pane and owns its stdio.

Shell rules: no chat or text input; no Claude or Node child; clicking a card sends `focus`; each board column carries its account band (email, org, colour); copies from the enterprise column are tagged `Dossier.SourceHome=acme`, kept out of clipboard history and cloud sync, cleared after 60 s, and the chats refuse cross-account pastes unless confirmed; window title "Dossier Console"; toasts "Acme Health needs you" / "Your Firm needs you"; board text in memory only; unhandled exceptions caught without writing content.

## 3. Data feeds per pane

| Area | Source | Panes |
|---|---|---|
| Account banner | `Read-DsrIdentity(home)` | All |
| Board | `Roots[0]\STATUS.md`, watched, parsed into the three sections, unparsed lines raw | All; hub and enterprise also to the shell |
| Sessions | `<home>\sessions\*.json` read directly with a pid-liveness check, plus `<home>\jobs\*\state.json` for background sessions; `claude agents --json` (~0.5 s per call, no login or network needed) as a slower cross-check. Interactive: `{pid, cwd, kind, startedAt, sessionId, name, status ∈ busy|shell|idle|waiting, waitingFor?}`. Background: `{id, kind, startedAt, sessionId, name, state}` plus `pid`, `status`, `waitingFor` while running. `jobs\...\needs` and `claude logs` carry content: pane only. | All; the no-seat client shows the firm lead's `cc -a widgetco --at-root -p` runs |
| Teammates | `SubagentStart`/`SubagentStop` paired by agent id, plus `<home>\agents\*.md` | All |
| Background work | `Stop` background tasks | All |
| Needs attention | `Notification` events plus `waitingFor` | All, and counts in the shell |
| Safety badges | The home's `settings.json`: shell guard PreToolUse hook present and passing `-WorkspaceRoot` with the registry's `workspaceRoot` (the check `Test-Dossier` makes), no `PermissionRequest` hook, GUI hooks present. The badge shows the wiring, not that a given command was checked. | All |
| Chat | Sidecar | Hub and enterprise only |
| Transcript tail (v3) | `<home>\projects\...\*.jsonl`, labelled unstable | Optional |

## 4. Chat (v2)

### 4.1 Sidecars

One in the hub pane (firm lead), one in the enterprise pane (enterprise lead). The GUI is the only writer to its own session; it never attaches to a terminal's session.

- C1 (recommended): Agent SDK TypeScript, pinned lockfile, stdio to the pane. Uses `canUseTool` for permission prompts.
- C2: pwsh drives `claude -p` stream-json directly, with `--permission-prompt-tool` and a custom PowerShell MCP bridge.

### 4.2 Required sidecar settings, checked at start

- `settingSources: ['user','project','local']` explicitly (omitting it now loads all sources too, but stay explicit), so deny rules, permission rules, guard hooks and `agent` load. Spike: the hub run loaded the firm lead, an ask rule reached `canUseTool`, deny rules and the shell guard held. The spike ran before the shell guard decided deletes, so confirm before v2 that the guard's `ask` reaches `canUseTool` the same way.
- After init, confirm the main agent is the firm lead or the enterprise lead and the guard hooks are active; otherwise refuse input. The init message has no main-agent field and the SDK's in-process `SessionStart` callback didn't fire, so read `agent_type` from the GUI's own `SessionStart` hook record in `events.ndjson` (or pass the agent explicitly if the SDK's main-thread `agent` option proves out).
- Leave `CLAUDE_CONFIG_DIR` unset for `~/.claude`: setting it explicitly changed the loaded tools and agents.
- `pathToClaudeCodeExecutable` = the binary `cc` resolves (match `\@anthropic-ai\claude-code\`, not a fixed prefix; nvm links `Program Files\nodejs` to `C:\ProgramData\nvm\...`); cwd `Roots[0]`.
- Default permission mode; no `allowedTools`; never bypass or accept-edits; never `updatedPermissions`.
- Input only from that pane's input box.

### 4.3 One writer per session

GUI sessions recorded in `sessions.json` and locked in `locks\<id>.lock` with the owner pid. The GUI won't resume a session `claude agents` shows running elsewhere. `Invoke-Dossier`: `cc --resume <id>` refuses a live-locked id; `-c`/`--continue` refuses while a GUI chat is live in that folder. Hand off: end the session, release the lock, open `wt -d <root> pwsh -NoProfile -Command "cc -a <key> --resume <id>"`. Stale locks cleared.

### 4.4 `claude --bg`

Without it, each chat pane hosts its lead and prompts come to the GUI. With it, the lead survives the GUI and shows in `claude agents`, but the GUI can't type into it (`-p --resume` and SDK `resume` are refused while it runs) and its prompts are answerable only through `claude attach`; the pane shows the prompt from `Notification permission_prompt` plus `waitingFor` and offers "Open attached terminal" (`claude attach <id>`) or Remote Control. Background sessions run in auto mode; whether the shell guard's `ask` still prompts there is unchecked, so confirm it before choosing `--bg` for a lead. Start background leads with `--strict-mcp-config`. Choice per lead, before v2.

### 4.5 Remote Control link-out (v3, off by default)

Each home maps to a browser profile (`gui.browserProfile`), so the enterprise client's Remote Control never opens in a browser logged in to the firm's claude.ai.

### 4.6 Per-entry lead

Delivered separately: a per-entry `agentNames` override, enterprise-seat entries only, so the enterprise client gets its own lead and the firm keeps the roster's lead. The enterprise lead's file in `~/.dossier/agents` holds habits only; client specifics belong in the client's root `CLAUDE.md`.

## 5. Permission prompts (the user approves every delete the shell guard asks about)

Deletes inside `workspaceRoot` run without a prompt (section 1). The prompts below are the shell guard's `ask` and any other permission prompt.

1. GUI chat: `canUseTool` sends the request to the pane, which shows a card (tool, full command, folder, account band) with Allow once and Deny only. Allow is sent only from that click handler with the matching id. Timeout (10 min), closed pane or wrong id → deny.
2. Terminal sessions: `Notification permission_prompt` or `waitingFor` raises a banner, a content-free toast and a shell count. "Focus terminal" brings the window forward. Answered only in the terminal.
3. Never auto-approve: no `PermissionRequest` hooks (doctor checks); one "allow" site in the code (static test); no bypass, accept-edits or `allowedTools`.

## 6. UI technology

PowerShell 7 + WPF (XAML), no new runtime for v1. `pwsh -NoProfile -STA`; runspaces marshalled to the Dispatcher; small C# helpers via `Add-Type`; a small Markdown renderer. Two rules from the spike:

- Never attach a scriptblock handler to a .NET event raised off the UI thread (e.g. `FileSystemWatcher.add_Changed`): it killed the process ("There is no Runspace available"). Run a blocking `WaitForChanged` loop in its own runspace instead.
- Create Dispatcher delegates in the UI runspace (`[Action[object]]{ param($n) ... }`) and pass only data from background runspaces. Delegates created in a background runspace stalled the UI ~300 ms per call.

`Test-DsrInsideClaude` exists in `Dossier.Common.ps1` as a `CLAUDECODE` check shared by cc, Sync and Import. v1 widens it to `CLAUDECODE`, `CLAUDE_PID`, `CLAUDE_CODE_SESSION_ID`, `CLAUDE_CODE_ENTRYPOINT`, plus one process snapshot walked for an `\@anthropic-ai\claude-code\` ancestor with creation-time checks. Widening it changes cc, Sync and Import at once; check those callers when it lands. A forged parent defeats it (risk 4). Not WebView2 (vendored DLLs, its own disk cache). Not Electron or Tauri. Node only for the v2 sidecar. Shell and enterprise pane hygiene as in 2.6.

## 7. Residual risks

1. Same-user processes: hub agents run unsandboxed as the user and could read the shell's or enterprise pane's memory (including the enterprise board), scrape text through UI Automation, duplicate a pipe handle, or build a path at run time into the enterprise home. Same class as enterprise transcripts and terminals today. Accepted; no separate Windows account.
2. Two processes hold enterprise content (shell, enterprise pane), both pinned and gated; a tampered repo that the user syncs gets pinned.
3. The user is the bridge: retyping enterprise text into the firm lead's chat can't be prevented. Account bands, separate columns, the paste gate and no chat in the shell make it unlikely by accident.
4. Indirect launch (Explorer, scheduled task) defeats the ancestor check. Deliberate, not accidental.
5. Async hooks can drop events; status comes from `claude agents --json`.
6. Unstable formats (transcripts, possibly `claude agents`); unknown shapes show as "unknown".
7. Remote Control is only as separate as the browser profiles.
8. Policy-enabled PowerShell logging records what the pane and shell handle; the doctor warns.

## 8. Phases

| Phase | Scope | Size |
|---|---|---|
| v0 spike | Done 2026-11-19. All seven questions answered; corrections folded in above. Window embedding (HwndHost + SetParent) works; focus, tabbing, DPI and a hung pane are untested, so v3 needs a short spike before choosing tabs. | done |
| v1 read-only | `Test-DsrLaunchable`/`Test-DsrInsideClaude` refactor; hook script; `gui` registry section; Sync hooks, pinned copies, console Edit-deny; doctor checks; shell with both boards and counts; panes; gatekeeper; clipboard tagging; tests B1–B9, B12–B17 | ~2,100 lines PS/XAML, ~85 tests; 2–2.5 weeks |
| v2 chat | Firm lead and enterprise lead sidecars; permission card; locks and `cc` resume guard; hand-off; paste gate; "Ask <firm lead>"; tests B10–B11 | ~900 lines + ~300-line sidecar; 1.5–2 weeks |
| v3 polish | Panes as tabs in one window; transcript tail; Remote Control link-out; background-lead mode; UI Automation hardening | 1–2 weeks |

## 9. Tests

`windows\tests\Test-Gui.ps1`, in the style of `Test-Kit.ps1`: throwaway `USERPROFILE`, stub `claude` with `agents --json` fixtures, stub SDK/stream-json CLI, fixture registry with an enterprise client (lead override), a no-seat client, a product and the firm.

- B1 No TCP/UDP listeners owned by shell, pane or sidecar pids.
- B2 Canary confinement: `ENT-CANARY-<guid>` in the enterprise board, a hook event and chat; `FIRM-CANARY-<guid>` in the hub board and chat; run everything including a shell crash; scan `USERPROFILE`, `%TEMP%`, `%LOCALAPPDATA%` (layout, console, CrashDumps), toasts and the clipboard after 60 s. Each canary appears only under its own root and home. The enterprise canary may be in shell memory only from the board, never from events or chat.
- B3 No channel out of the shell: (a) every byte to pane stdin parses as `{"cmd":<enum>}` with no canary; (b) the hub sidecar never receives the enterprise canary and vice versa; (c) static: the shell starts only pinned pane scripts, `Send-PaneCommand` is its only stdin writer, no text input controls, only reads registry and layout; dynamic: with non-existent roots the shell still shows boards from panes; (d) schema violations dropped, including a `board` from a home not on top.
- B4 Shell refuses with `CLAUDECODE=1`, `CLAUDE_CONFIG_DIR` set, or a Claude ancestor.
- B5 Enterprise pane refuses a wrong email/org, API key or provider setting; sends no board; shell shows "login mismatch".
- B6 Children have only their own `CLAUDE_CONFIG_DIR` and none of the parent session's variables.
- B7 Hook in the firm home with input naming enterprise paths writes only to `~/.claude\dossier-gui`, nothing to stdout.
- B8 Sync: hooks only in enabled homes, removed on opt-out; no `PermissionRequest`; pinned copies and hashes; console Edit-deny everywhere; enterprise and shell copies skipped inside a Claude session; lead override only in the enterprise home, firm keeps the roster's lead.
- B9 From the firm home, the shell guard denies reading the enterprise `dossier-gui` and writing the console `bin`.
- B10 Permissions: timeout, closed pane, wrong id deny; allow only after click; one allow site; no `updatedPermissions`; settings-loaded check fails closed.
- B11 Two writers: refuses to resume a live session; `cc --resume` of a locked id and `cc -c` during a live chat refuse; stale locks cleared.
- B12 Clipboard gate both ways.
- B13 Titles and toasts match a fixed content-free pattern.
- B14 Changed pinned file → enterprise pane refuses to start.
- B15 Gatekeeper refuses (no board, `gateRefused`) when the parent is the repo shell script, the shell hash differs, the parent is a test harness, or a Claude ancestor is present.
- B16 With LocalDumps on, the doctor fails; after killing the shell, no `.dmp` files.
- B17 The firm lead in the hub chat tries every path to the enterprise board (file tools, shell, curl to localhost, the console folder); all denied or empty.

Manual after v1: `Test-Dossier` no FAIL; from a hub terminal, curl and `Get-Content` against enterprise GUI data and the console folder are denied or empty; an enterprise delete of a path outside `workspaceRoot` prompts, and the prompt shows as a shell count and "Focus terminal", answerable only in the terminal.
