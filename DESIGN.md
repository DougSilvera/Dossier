# Dossier

Status: in use since 2026-11. 244 tests in `windows/tests/Test-Kit.ps1`.

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
| `~/.claude-homes/<product>` | The firm | One firm product |

`~/.claude` is the firm home because Claude Code keeps the default home's state file at `~/.claude.json`, outside the directory, and the launcher can't treat it as just another home.

## Products

A product is firm-owned work that client work is built on: a reusable codebase, a methods library, or both in one repo. It is its own engagement, with its own home, memory, skills and MCP servers, and its defaults are the opposite of a client's. The hub sees all of it, clients see only what the product lists, and content flows one way, toward clients.

- **Registry:** a `products` list beside `clients`, each with `key`, `name`, `root`, optional `home` (default `~/.claude-homes/<key>`), `expectEmail`/`expectOrg` (default: the firm's), `repos`, `clientRead`, `enterpriseRead` (default false) and `status`. A client lists the products it is built on in `basedOn`.
- **Folder:** `~/workspace/products/<key>/`, a sibling of the hub and `clients/`. Inside the hub, the hub's `CLAUDE.md` would load into every product session, and client homes deny the hub.
- **Hub access:** the firm home reads and edits every product root, and reads each product home's memory and transcripts (`<home>/projects`, through `additionalDirectories`). It may not edit a product home, or read its login.
- **Product home:** denied every client's root and home (no-seat clients included), the hub and the firm home. Client lessons reach a product only when the user carries them there.
- **Client access:** a client reads a product's `clientRead` paths (relative to the product root) only when it lists the product in `basedOn`, and an enterprise-seat client only when the product also sets `enterpriseRead: true`, because its sessions run under the client's org terms. An empty `clientRead` means clients read nothing. No client ever edits a product or reads its home.
- **How `clientRead` is enforced:** Claude Code's deny rules always beat allow rules, and the `!` exception syntax isn't documented for absolute paths, so a client can't be denied the root and allowed a subfolder. Sync instead lists the product from disk and denies `Read` on everything outside `clientRead`: at each level from the root down to each `clientRead` path, every sibling folder and file, including `.git`, `.claude` and the root `CLAUDE.md`. A `clientRead` path or registered repo that doesn't exist yet is denied at its first missing folder. `Edit` is denied on the whole root. The `clientRead` paths go in the client's `additionalDirectories`.
- **Drift:** anything added at a listed level after Sync (a folder from a `git pull`, say) is readable by based-on clients until the next Sync. The doctor recomputes the rules from disk and fails with "product changed on disk since the last Sync", so rerun Sync after pulling a product that clients read.
- **Instructions:** the product root's `CLAUDE.md` (Sync writes a stub) holds working notes about the product; each repo's own `CLAUDE.md` holds its conventions. A based-on client's stub lists the product and the paths it may read.
- **Promoting from clients:** manual. The hub, product and client `CLAUDE.md` stubs say to report a client pattern worth promoting as a candidate to the user, and to move nothing from a client toward a product unless the user says so in that turn. Client and product homes are kept apart by deny rules. The firm home can read no-seat clients and edit products, so there it's an instruction only.

### Client repos built on a product

A client repo starts from scratch, or as a clone or fork of a product code repo. A fork carries that repo's whole history, so the product repo must sit entirely inside `clientRead`; the doctor fails a fork of a repo that doesn't.

- **Registry:** a client repo that forks a product repo says so with `"from": { "product": "<key>", "repo": "<product repo dir>" }`. The product must be in the client's `basedOn`, and the repo one of the product's `repos`. Nothing about the product goes into the client's own repo.
- **Base, detected:** Sync takes the newest product commit in the client repo's history (not merely its object store, which a fetch fills without merging) as the fork's base, a bare commit hash. Bringing product changes forward moves it with no registry edit. A squashed import shares no commit; the doctor warns instead of guessing.
- **Status file:** Sync writes `<client home>/dossier.products.json`: per product, the readable paths, the heads of fully readable product repos, and per fork its base, the number of product commits since and the names of files changed since. Never commit messages, which can name prospects. Sync reads both sides' git data as a script outside the client's deny rules, and only these results cross. For an enterprise seat it does this only outside a Claude session.
- **Session note:** the guard gives a based-on client session a model-only note from the status file: its products, readable paths, and how far each fork is behind as of the last Sync.
- **Client `CLAUDE.md`:** Sync keeps a Products section between `<!-- BEGIN GENERATED: Sync-Dossier products -->` and `<!-- END GENERATED: Sync-Dossier products -->`. New client stubs have the markers; an existing file gets a note on how to add them.
- **Skill:** Sync copies `skills/dossier-product` into based-on client homes, and removes it when `basedOn` empties. It covers reading the status file, comparing with the product, and bringing product changes forward (`git fetch <product repo path>`, a merge left uncommitted for the user), and never writing toward the product.
- **Hub table:** "Based on by" lists each client's forks. For a no-seat client it shows the base and distance; for an enterprise client only which product repo, since the hub keeps enterprise clients to metadata.

`Import-Dossier -Key <key> -Apply` brings a client or product onto the machine: Sync, clone each listed repo that isn't there yet, then the doctor. It refuses an enterprise-seat client from inside a Claude session.

## Agents

Dossier defines a small team of **roles**. Each person brings their own **agents** to fill them: their names, voices and working habits live in that person's own roster, not in Dossier.

| Role | Job |
|---|---|
| `lead` | The home's main session: takes requests, briefs teammates, checks what they return. |
| `builder` | Changes code in small tested steps and stops at a reviewable diff. |
| `reviewer` | Reviews for correctness; never reviews its own work. |
| `researcher` | Finds out what's true, with sources. |
| `ops` | Runs and watches local services. |
| `hr` | Creates and changes the agents themselves, in the roster only. |

- **Roster:** a folder of Claude Code agent files, one per agent, ideally the person's own git repo. The registry's `agents` section names it and maps roles to agents: `"agents": { "source": "~/.dossier/agents", "roles": { "lead": "<name>", "builder": "<name>", ... } }`. An agent's file name and its frontmatter `name` must match the mapping.
- **Role contracts:** Dossier ships one per role in `roles/`, plus `roles/_common.md` for every role (the three memory layers, boundaries, no commits or comments without the user's word). Sync installs each agent into a home as the roster's file followed by its role's contract and the common rules, after a marker. Agents load the session's `CLAUDE.md` files too, so personal and engagement rules apply to them.
- **One team per account:** Sync installs every agent the roster fills into the firm home. Every other home on the firm's own account (products, no-seat clients) links its `agents` folder to the firm home's: one definition of each agent, no copies, and an edit there is live everywhere at once. Only an outside enterprise seat gets its own copies, Sync-maintained: all roles but `lead` and `hr` by default, or the entry's `agentRoles`. Sync replaces a linked home's old Dossier copies with the link, and leaves a home with agent files of its own unlinked, with a warning. The doctor accepts this one link into the firm home and flags a home that should have it.
- **`hr`:** accepted in `agentRoles` only on the firm, since it edits the roster and a client home must never write to it. Linked homes can still see its definition, so its contract tells it to stop when its memory folder shows it isn't in the user's own home.
- **Lead:** Sync sets the home's `agent` setting to the lead, so the main session runs as it. A custom agent's prompt likely replaces Claude Code's default system prompt, so the lead is opt-in outside the firm home (`agentRoles` with `lead`). Sync removes only an `agent` value it set.
- **`agentNames`:** an enterprise seat can fill a role with its own agent from the roster, such as a different lead, with `"agentNames": { "lead": "<name>" }`; the firm and every other home keep the roster's. Only an enterprise seat accepts it, since other homes link to the firm's agents. A name can't be the roster's agent for another role, one name can't fill two roles, and `hr` can't be renamed. `agentRoles` still decides which roles the home gets, so a renamed lead needs `lead` there too.
- **Memory follows the home** (checked on Windows with Claude Code 2.1.328: an agent with `memory: user` in a home set by `CLAUDE_CONFIG_DIR` writes to `<home>/agent-memory/<name>/`). Linked homes share definitions, not memory, so what an agent learns for one client stays in that client's home. The doctor warns about an agent without `memory: user`.
- **Dispatch follows `cc`:** the lead hands work to teammates inside its own home, and to a no-seat client's home with `cc -a <key> --at-root -p`, where the same agents use that home's memory. An enterprise client's team is started by the user in that client's home; nothing dispatches into it.
- **Memory layers:** an agent writes its own memory freely; it proposes engagement conventions (that root's `CLAUDE.md`) and personal rules, and waits for the user's OK.

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
5. **Deny rules.** Each home's user `settings.json` gets `Read`/`Edit` deny rules for everything it must not see. The firm home denies every enterprise root and every client home. A client or product home denies every other client's and product's root and home, the hub, `~/.claude` and `~/.claude.json`, except a based-on client's `clientRead` paths (see Products). Rules live at user scope, so they apply in every session of that home wherever it starts.
6. **The `dossier-shellguard` PreToolUse hook** holds Bash and PowerShell commands to the same deny rules, read from the home's `settings.json`. Without it, deny rules cover only the file tools and the few Bash commands Claude Code recognizes (`cat`, `head`, `tail`, `sed`, `tee`). It denies a command that names a denied path (absolute, relative to the session folder, Git Bash or WSL form, through `~`, `$HOME`, `$env:USERPROFILE` or `%USERPROFILE%`), has a wildcard that can reach one, or searches recursively from a folder that holds one (`rg` in `~/workspace`). It costs about half a second per shell command.

### What this does not stop

- **Shell reads the shell guard can't see.** It reads the command text, so a path built at run time, a script that opens files on its own (`os.walk('.')` from a parent folder), or a link into a denied folder gets past it. It's a tripwire for honest mistakes. OS-level enforcement is Claude Code's sandbox, which applies `Read` deny rules to every shell command, but the sandbox runs only on macOS, Linux and WSL2. On native Windows `sandbox.enabled` is ignored and commands run unsandboxed, and `sandbox.failIfUnavailable` would stop Claude Code from starting at all, so Sync sets neither.
- **A determined session.** The session checks in 2 rely on `CLAUDECODE`; a session that unsets it, or runs `claude.exe` with its own `CLAUDE_CONFIG_DIR`, gets past them. They stop accidents and honest mistakes, not an adversary on the machine.
- **Clients' lessons reaching a product through the firm home.** The hub may edit products and may read no-seat clients' code, so nothing but its instructions stops it copying one into the other. It must report candidates and wait for the user's word.
- **Product folders added since the last Sync.** See "Drift" under Products. The doctor catches them; nothing blocks them in between.
- **Writes the shell guard can't recognize.** For a product path a client may read, the shell guard blocks commands that look like writes (common write cmdlets and commands, `>` redirects, `sed -i`, git commands that change files or history) and name it or run from inside it. Anything else that writes gets past it.
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
  products/
    <product>/            product root; its own home; CLAUDE.md = working notes, not committed
      <repo>/
  sandbox/                personal experiments; firm home
```

The hub is a sibling of `clients/`, not a parent, because Claude Code loads every ancestor `CLAUDE.md`. Nothing goes in `~/workspace/CLAUDE.md`.

## Instruction layers

| Layer | File | Content |
|---|---|---|
| Personal | each home's `CLAUDE.md`, generated from one personal source | Rules that are true everywhere (git, comments, mentions) |
| Client | `clients/<client>/CLAUDE.md` | Client standing orders: DBs, environments, ticket process, docs |
| Product | `products/<product>/CLAUDE.md` | Working notes on a firm product: what clients may read, open decisions |
| Repo | the repo's own `CLAUDE.md` | Team convention, owned by the client's repo |

Settings and `.mcp.json` are not inherited from parent folders, so client-wide MCP servers and settings go in the client's home (user scope), not the client root.

## What's committed vs. local

| Committed (this repo) | Local only |
|---|---|
| Registry schema and `dossier.example.json` | `~/.dossier.json` (the person's real registry) |
| Templates for hub, client and product `CLAUDE.md` | The person's personal rules source (`~/.dossier/personal.md`) |
| Launcher, guard hooks, sync, doctor, tests | Logins (`.credentials.json`, `.claude.json`) |
| | Memory, transcripts, client secrets, backups |

## Tools (`windows/`, PowerShell 7)

| Tool | What it does |
|---|---|
| `Dossier.ps1` | Dot-source from `$PROFILE`: defines `cc`, `cc-<key>`, and a `claude` that goes through the launcher (opt out with `DOSSIER_NO_CLAUDE_SHIM=1`). Git Bash: `source dossier.bash`. |
| `Invoke-Dossier.ps1` | The launcher. Picks the home that owns the folder, applies the refusals above, clears only the variables a session hands its children, never copies between homes. |
| `Sync-Dossier.ps1` | Makes the machine match the registry: roots, homes, deny rules, `additionalDirectories`, shared allow and ask rules, guard hooks, personal `CLAUDE.md`, shared skills, hub tables, client and product stubs. Dry run unless `-Apply`. Only removes rules it added (tracked in `<home>\dossier.managed.json`); never overwrites a `CLAUDE.md` it didn't write. Every file it rewrites keeps a timestamped `.bak`. |
| `Test-Dossier.ps1` | Read-only doctor: logins, cross-home links, ancestor `CLAUDE.md`, deny rules, shared allow and ask rules, guard hooks, one entry's memory in another's home (including `formerRoots`), unregistered folders, product folders added since the last Sync, products blocked for an enterprise client, repos not cloned yet, leftover kit wiring. |
| `Import-Dossier.ps1` | Clones a registered client's or product's `repos` into its root after a Sync, then runs the doctor. Dry run unless `-Apply`. Never touches an existing folder. |
| `dossier-guard.ps1` | SessionStart hook. Silent to the person when everything matches; gives a based-on client session a model-only product note. |
| `dossier-shellguard.ps1` | PreToolUse hook for Bash and PowerShell. Denies commands that reach a path the home's `Read` deny rules cover, and writes to a path it may only read; silent otherwise. |
| `tests/Test-Kit.ps1` | 244 checks against a throwaway `USERPROFILE` and a stub `claude`. |

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
