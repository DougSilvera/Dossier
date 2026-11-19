# Dossier

Status: in use since 2026-11. 164 tests in `windows/tests/Test-Kit.ps1`.

## Problem

Consultants run Claude Code for their own firm and for several clients on one machine. Some clients give you a seat in their own Claude Enterprise or Team org; others don't, and that work runs under the firm's account. We need:

- a firm **hub** that knows every client engagement exists,
- per-client config, memory, skills and MCP servers that never leak into the firm or another client,
- automatic selection of the right account and config by folder,
- a data boundary that follows the client's seat.

## Model

A **home** is a Claude Code config directory (`CLAUDE_CONFIG_DIR`). It holds the login, user settings, the user `CLAUDE.md`, skills, agents, user-scope MCP servers, auto-memory and transcripts. A home is not an account: several homes can be logged in to the same account.

Every client gets its own home, whatever account it bills. Isolation comes from the home; the account only decides billing and whose data terms apply.

| Home | Logged in as | Used for |
|---|---|---|
| `~/.claude` | The firm | Hub, firm-internal work, sandbox |
| `~/.claude-homes/<client>` (seat: enterprise) | The client's org seat | That client only |
| `~/.claude-homes/<client>` (seat: none) | The firm | That client only |

Templates (below) have no home of their own: they run in the firm home.

`~/.claude` is the firm home because Claude Code keeps the default home's state file at `~/.claude.json`, outside the directory, and the launcher can't treat it as just another home.

## Templates

A template is a firm-owned base repo that client repos are built from: team conventions, patterns, scaffolding. Its default is the opposite of a client's. It is fully shared with the hub, and its content flows one way, toward clients.

- **Registry:** a `templates` list beside `clients`, each with `key`, `name`, `root`, `repos`, `enterpriseRead` (default false) and `status`. A client lists the templates it is built from in `basedOn`.
- **Home:** the firm home. Template roots are firm roots, so `cc` in one starts the firm home, its memory sits next to the hub's, and the hub reads its code through `additionalDirectories`. `cc -a <template> --at-root` starts the firm home in the template's root. Each template still gets its own memory, because memory is filed per folder.
- **Folder:** `~/workspace/templates/<key>/`, a sibling of the hub and `clients/`. Inside the hub, the hub's `CLAUDE.md` would load into every template session, and client homes deny the hub.
- **Instructions:** the template root's `CLAUDE.md` (Sync writes a stub) holds working notes about the template. Conventions that should ship to every client copy go in the repo's own `CLAUDE.md`.
- **Client access:** every client home denies every template. A client may read a template only when it lists it in `basedOn`, and an enterprise-seat client only when the template also sets `enterpriseRead: true`, because its sessions run under the client's org terms. A client that may read a template gets it in `additionalDirectories` and an `Edit` deny on it. No client ever edits a template.
- **Promoting from clients:** manual. The hub, template and client `CLAUDE.md` stubs say to report a client pattern worth promoting as a candidate to the user, and to move nothing from a client toward a template unless the user says so in that turn. Client homes can't edit templates, so for them the deny rules enforce it. In the firm home it's an instruction only.

`Import-Dossier -Key <key> -Apply` brings a client or template onto the machine: Sync, clone each listed repo that isn't there yet, then the doctor. It refuses an enterprise-seat client from inside a Claude session.

## Data rule

| Client seat | Hub may | Hub may not |
|---|---|---|
| `enterprise` | Read the registry entry (name, path, contacts, status) | Read the client's files, memory or transcripts; run client MCP servers |
| `none` | Also read the client's code (`additionalDirectories`) | Load the client's `CLAUDE.md` or MCP config into hub sessions |

Enforcement, strongest first:

1. **`cc` refuses** to open an enterprise client's folder, or an `--add-dir` into it, in any home but that client's. It decides ownership on the physical path, so a junction, symlink, `subst` drive, `\\?\` path or local admin share into a client root counts as that root.
2. **`cc` refuses to cross accounts from inside a session.** A Claude session can't start an enterprise client's home, and an enterprise client's session can't start any other home, because the started session's output flows back to the caller. No-seat clients can still be handed work from the hub with `cc -a <client> --at-root -p "..."`.
3. **`cc` refuses an enterprise home on the wrong terms:** logged in to an account other than `expectEmail`/`expectOrg`, or with `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_BASE_URL`, `CLAUDE_CODE_USE_BEDROCK` or `CLAUDE_CODE_USE_VERTEX` set in the shell or the home's settings. `--dossier-override` starts it anyway, deliberately. A home that isn't logged in yet starts, so you can `/login`.
4. **The `dossier-guard` SessionStart hook** flags any session whose home doesn't own its folder, even when the login is the same. It covers launches that bypass `cc`.
5. **Deny rules.** Each home's user `settings.json` gets `Read`/`Edit` deny rules for everything it must not see. The firm home denies every enterprise root and every client home. A client home denies every other client's root and home, the hub, `~/.claude` and `~/.claude.json`. Rules live at user scope, so they apply in every session of that home wherever it starts.
6. **The `dossier-shellguard` PreToolUse hook** holds Bash and PowerShell commands to the same deny rules, read from the home's `settings.json`. Without it, deny rules cover only the file tools and the few Bash commands Claude Code recognizes (`cat`, `head`, `tail`, `sed`, `tee`). It denies a command that names a denied path (absolute, relative to the session folder, Git Bash or WSL form, through `~`, `$HOME`, `$env:USERPROFILE` or `%USERPROFILE%`), has a wildcard that can reach one, or searches recursively from a folder that holds one (`rg` in `~/workspace`). It costs about half a second per shell command.

### What this does not stop

- **Shell reads the shell guard can't see.** It reads the command text, so a path built at run time, a script that opens files on its own (`os.walk('.')` from a parent folder), or a link into a denied folder gets past it. It's a tripwire for honest mistakes. OS-level enforcement is Claude Code's sandbox, which applies `Read` deny rules to every shell command, but the sandbox runs only on macOS, Linux and WSL2. On native Windows `sandbox.enabled` is ignored and commands run unsandboxed, and `sandbox.failIfUnavailable` would stop Claude Code from starting at all, so Sync sets neither.
- **A determined session.** The session checks in 2 rely on `CLAUDECODE`; a session that unsets it, or runs `claude.exe` with its own `CLAUDE_CONFIG_DIR`, gets past them. They stop accidents and honest mistakes, not an adversary on the machine.
- **Clients' lessons reaching a template through the firm home.** The hub may edit templates and may read no-seat clients' code, so nothing but its instructions stops it copying one into the other. It must report candidates and wait for the user's word.
- **Writes the shell guard can't recognize.** For a template a client may read, the shell guard blocks commands that look like writes (common write cmdlets and commands, `>` redirects, `sed -i`, git commands that change files or history) and name it or run from inside it. Anything else that writes gets past it.
- **Shell guard false positives on prose.** It reads the whole command text, so a heredoc or script that merely contains a word like `find` or `tree` can trip the recursive-search check. Write long text with the file tools instead.
- **Deny rules through links.** `cc` and the guard resolve links; whether Claude Code's own deny-rule matching does is untested. Open client work by its real path.

## Folder layout

```
~/workspace/
  hub/                    hub root; CLAUDE.md = engagement registry (generated section)
    dossier/              this repo
  clients/
    <client>/             client root; CLAUDE.md = client-wide rules, never committed to client repos
      <repo>/ ...
  templates/
    <template>/           template root; firm home; CLAUDE.md = working notes, not committed
      <repo>/
  sandbox/                personal experiments; firm home
```

The hub is a sibling of `clients/`, not a parent, because Claude Code loads every ancestor `CLAUDE.md`. Nothing goes in `~/workspace/CLAUDE.md`.

## Instruction layers

| Layer | File | Content |
|---|---|---|
| Personal | each home's `CLAUDE.md`, generated from one personal source | Rules that are true everywhere (git, comments, mentions) |
| Client | `clients/<client>/CLAUDE.md` | Client standing orders: DBs, environments, ticket process, docs |
| Repo | the repo's own `CLAUDE.md` | Team convention, owned by the client's repo |

Settings and `.mcp.json` are not inherited from parent folders, so client-wide MCP servers and settings go in the client's home (user scope), not the client root.

## What's committed vs. local

| Committed (this repo) | Local only |
|---|---|
| Registry schema and `dossier.example.json` | `~/.dossier.json` (the person's real registry) |
| Templates for hub and client `CLAUDE.md` | The person's personal rules source (`~/.dossier/personal.md`) |
| Launcher, guard hooks, sync, doctor, tests | Logins (`.credentials.json`, `.claude.json`) |
| | Memory, transcripts, client secrets, backups |

## Tools (`windows/`, PowerShell 7)

| Tool | What it does |
|---|---|
| `Dossier.ps1` | Dot-source from `$PROFILE`: defines `cc`, `cc-<key>`, and a `claude` that goes through the launcher (opt out with `DOSSIER_NO_CLAUDE_SHIM=1`). Git Bash: `source dossier.bash`. |
| `Invoke-Dossier.ps1` | The launcher. Picks the home that owns the folder, applies the refusals above, clears only the variables a session hands its children, never copies between homes. |
| `Sync-Dossier.ps1` | Makes the machine match the registry: roots, homes, deny rules, `additionalDirectories`, guard hooks, personal `CLAUDE.md`, shared skills, hub table, client stubs. Dry run unless `-Apply`. Only removes rules it added (tracked in `<home>\dossier.managed.json`); never overwrites a `CLAUDE.md` it didn't write. Every file it rewrites keeps a timestamped `.bak`. |
| `Test-Dossier.ps1` | Read-only doctor: logins, cross-home links, ancestor `CLAUDE.md`, deny rules, guard hooks, one entry's or template's memory in another home (including `formerRoots`), unregistered folders, templates blocked for an enterprise client, repos not cloned yet, leftover kit wiring. |
| `Import-Dossier.ps1` | Clones a registered client's or template's `repos` into its root after a Sync, then runs the doctor. Dry run unless `-Apply`. Never touches an existing folder. |
| `dossier-guard.ps1` | SessionStart hook. Silent when everything matches. |
| `dossier-shellguard.ps1` | PreToolUse hook for Bash and PowerShell. Denies commands that reach a path the home's `Read` deny rules cover, and writes to a path it may only read; silent otherwise. |
| `tests/Test-Kit.ps1` | 164 checks against a throwaway `USERPROFILE` and a stub `claude`. |

Setting up a home: `Sync-Dossier -Apply`, then `cc -a <key>` and `/login` as the expected account, then `Test-Dossier`.

## Differences from claude-multi-account-kit

The kit links a canonical home into satellites so everything is shared. That's the right default for one person's several subscriptions and the wrong one for client work. Its launcher also re-copies `~/.claude`'s `settings.json` and `CLAUDE.md` into every other home on each launch, and its guard treats the same login in a different home as OK. Both are wrong here, so this repo has its own launcher and guard. Dossier shares no code with the kit. The kit's ideas (one `CLAUDE_CONFIG_DIR` per account, reading the login from `.claude.json`, clearing inherited variables, choosing by folder) were the model for ours, and its usage tools still work alongside.

## Migrating a machine

Moving an existing machine onto Dossier:

1. Run `Sync-Dossier -Apply`, then log each client home in.
2. From your own terminal, move each client's repos into its root, client assets out of `~/.claude` (`projects/<slug>` renamed to the new path, client skills, the client's `skills/synced` bucket, client-specific settings), and repair git worktrees.
3. Move client rules out of `~/.claude/CLAUDE.md` into the client root, and personal rules into `personalRules`. Delete `~/.claude/CLAUDE.md`, then Sync writes the managed copy.
4. Run `Test-Dossier`. `formerRoots` makes it find leftover memory under old paths.

## Lessons

From setting this up on the first machine:

- **Move folders with `[IO.Directory]::Move`, never `Move-Item`.** When a folder rename is refused (hidden items, a locked file, a sandbox), `Move-Item` falls back to moving the folder's items one by one and stops at the first failure. That split a repo in two, with `.git` and the root files in the new folder and everything else in the old one. `Directory.Move` either renames the whole folder or changes nothing.
- **Don't move or write client content from a Claude session.** It's the wrong account for that data, and a session's file tools are denied inside an enterprise root anyway. Run moves from your own terminal.
- **After any failed move, check both sides** at the level that could have moved: file counts, `.git` internals, `git rev-parse`. "The folder still exists" proves nothing.
- **`pwsh -File` doesn't expand `~`, and it splits `--opt=C:\x` at the drive colon** (it reads `-name:value`). Use full paths in commands you hand to someone; the launcher rejoins the split.
- **`git clone` from a local path hard-links object files**, so cleanup that deletes "links" as if they were folders breaks on them.
- **Org-synced skills live in `skills/synced/<org-uuid>_*`** in the home that was logged in to that org. A home that changes accounts keeps the old org's bucket until you move it.

## Open questions

- Does any client need more than one home (for example, separate engagements)?
- Team use: a shared client list plus personal overrides, once a second person adopts this.
