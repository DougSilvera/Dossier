<p align="center">
  <img src="assets/logo.svg" alt="Dossier: one sealed Claude Code home per client" width="600">
</p>

One Claude Code config home per client engagement, picked by folder. Each client's instructions, memory, skills and MCP servers stay in its own home, and other homes are kept out of an enterprise-seat client's files. Windows, PowerShell 7.

Why it works this way: [DESIGN.md](DESIGN.md).

That separation stops accidents and honest mistakes, not a determined session or another program on the machine. On native Windows, Claude Code's sandbox doesn't run, so shell commands are checked by reading their text. Read [what this does not stop](DESIGN.md#what-this-does-not-stop) before you promise a client anything on the strength of it.

## Daily use

```powershell
cd ~\workspace\clients\<client>\<repo>
cc                      # starts Claude in that client's home, logged in as that client's account
cc -a <key>             # a specific home; refused in an enterprise client's folder unless it's that client
```

For an enterprise-seat client, `cc` refuses to start when the home is logged in to the wrong account, or when an API key, base URL, Bedrock or Vertex is configured, since the work would run under other terms. Fix the cause, or pass `--dossier-override` when you mean it. It also refuses to cross accounts from inside a Claude session; start those from your own terminal.

Plain `claude` is routed the same way, so typing it out of habit, or in VS Code's terminal, still lands in the right home. Set `DOSSIER_NO_CLAUDE_SHIM=1` before your profile loads to turn that off.

At session start, `dossier-guard` stays silent when the home matches the folder. A CRITICAL message means relaunch with `cc`. During the session, `dossier-shellguard` denies shell commands that would reach a folder the home is kept out of, which deny rules alone don't cover on Windows.

## Setup

1. Copy `dossier.example.json` to `~/.dossier.json` and fill it in. The `firm` section is your own consultancy: its `key` is what `cc -a <key>` uses for your home. `seat` is `enterprise` when the client gives you a seat in their own Claude org, and `none` when the work runs on your firm's account.
2. Write your personal rules (true in every home) to the file named by `personalRules`.
3. Dry run, then apply:
   ```powershell
   pwsh -NoProfile -File windows\Sync-Dossier.ps1
   pwsh -NoProfile -File windows\Sync-Dossier.ps1 -Apply
   ```
4. Load `cc`: add `. <repo>\windows\Dossier.ps1` to `$PROFILE`, and `source <repo>/dossier.bash` to `~/.bashrc` for Git Bash.
5. Log in to each client home: `cc -a <key>`, then `/login` as the account the registry expects.
6. Check: `pwsh -NoProfile -File windows\Test-Dossier.ps1` should print `No FAIL.`

Fill in each client's rules in `~/workspace/clients/<client>/CLAUDE.md`, which Sync creates as a stub.

## Changing things

| To | Do |
|---|---|
| Add a client | Add it to the registry, run `Sync-Dossier -Apply`, then `cc -a <key>` and `/login` |
| Add a product | Add it under `products` with its `repos`, then `Import-Dossier -Key <key> -Apply`, then `cc -a <key>` and `/login` as the firm. List the paths clients may read in `clientRead`, and the product in each such client's `basedOn`; an enterprise-seat client also needs the product's `enterpriseRead: true`. |
| Bring your own agents | Put one Claude Code agent file per agent in a folder (your own git repo), give each `memory: user`, and add `"agents": { "source": "<folder>", "roles": { "lead": "<name>", "builder": "<name>", "reviewer": "<name>", "researcher": "<name>", "ops": "<name>", "hr": "<name>" } }` to the registry. Fill only the roles you want. `Sync-Dossier -Apply` installs them, each with its role's contract from `roles/`, in your firm home, links every other home on your firm's account to them, and gives each outside enterprise seat its own copies. |
| Change an agent | Edit it in your roster (or ask your `hr` agent to), commit, then `Sync-Dossier -Apply`. |
| Fork a product repo for a client | The product repo must be inside the product's `clientRead`. Clone or fork it into the client root, add it to the client's `repos` with `"from": { "product": "<key>", "repo": "<dir>" }`, then `Sync-Dossier -Apply`. Client sessions then get a note on how far the fork is behind, and the `dossier-product` skill for bringing changes forward. |
| Pull new folders into a product clients read | Rerun `Sync-Dossier -Apply`: the rules that hide everything outside `clientRead` are listed from disk, and the doctor fails until they're current. |
| Clone a client's or product's repos | List them in the entry's `repos`, then `Import-Dossier -Key <key> -Apply` (dry run without `-Apply`). For an enterprise-seat client, run it from your own terminal. |
| Change personal rules | Edit the `personalRules` file, then run `Sync-Dossier -Apply`. Never edit a home's `CLAUDE.md` directly. |
| Add an MCP server for one client | Inside that client's session: `claude mcp add --scope user ...` |
| Move existing repos into a client root | Close every session, IDE and terminal using them, then move with `[IO.Directory]::Move` from your own terminal. See DESIGN.md, "Lessons". |

## Tests

```powershell
pwsh -NoProfile -File windows\tests\Test-Kit.ps1
```

They run against a throwaway `USERPROFILE` and a stub `claude`, never your real homes.
