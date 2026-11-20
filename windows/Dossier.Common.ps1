# Dossier.Common.ps1 - helpers shared by every dossier tool. Dot-source it; don't run it.
# Keep it ASCII: Windows PowerShell 5.1 misreads UTF-8 without a BOM, and hooks are sometimes
# wired to `powershell` by mistake.

$script:DsrGuardScript = Join-Path $PSScriptRoot 'dossier-guard.ps1'
$script:DsrShellGuardScript = Join-Path $PSScriptRoot 'dossier-shellguard.ps1'
$script:DsrManagedMarker = '<!-- managed by dossier -->'
$script:DsrAgentMarker = '<!-- managed by dossier: role contract below. Edit the agent in your roster, then run Sync-Dossier. -->'
$script:DsrRoles = @('lead', 'builder', 'reviewer', 'researcher', 'ops', 'hr')

# Variables a Claude Code session hands to its children. Everything else CLAUDE_* is the
# user's own configuration and must reach the child untouched.
$script:DsrSessionVars = '^(CLAUDECODE|CLAUDE_CONFIG_DIR|CLAUDE_PID|CLAUDE_CODE_(CHILD_SESSION|ENTRYPOINT|SESSION_ID|SESSION_ATTENDED|SSE_PORT|MESSAGING_SOCKET|MESSAGING_TOKEN|OAUTH_TOKEN))$'

# CLAUDECODE is set in every process a Claude Code session starts. A process that clears it, or
# one started outside the session (Explorer, Task Scheduler) on the session's behalf, isn't seen.
function Test-DsrInsideClaude { return [bool]$env:CLAUDECODE }

function Test-DsrPowerShell7 { return ($PSVersionTable.PSVersion.Major -ge 7) }

function Write-DsrErr([string] $Message) { [Console]::Error.WriteLine($Message) }

function Get-DsrUserHome {
    # Claude Code (Node's os.homedir) uses USERPROFILE on Windows. Tests point it at a temp dir.
    if ($env:USERPROFILE) { return $env:USERPROFILE.TrimEnd('\') }
    return $HOME
}

function Resolve-DsrPath([string] $Path) {
    # Textual: expands ~, makes relative paths absolute against the current folder, normalizes.
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $p = $Path.Trim()
    if ($p -eq '~') { $p = Get-DsrUserHome }
    elseif ($p.StartsWith('~/') -or $p.StartsWith('~\')) { $p = Join-Path (Get-DsrUserHome) $p.Substring(2) }
    $p = $p.Replace('/', '\')
    if (-not [IO.Path]::IsPathRooted($p)) {
        $p = Join-Path $ExecutionContext.SessionState.Path.CurrentFileSystemLocation.ProviderPath $p
    }
    $p = [IO.Path]::GetFullPath($p)
    if ($p.Length -gt 3) { $p = $p.TrimEnd('\') }
    return $p
}

function ConvertFrom-DsrDevicePath([string] $Path) {
    # \\?\C:\x -> C:\x, \\?\UNC\h\s -> \\h\s, and this machine's admin shares back to drive letters.
    $p = $Path
    if ($p.StartsWith('\\?\UNC\')) { $p = '\\' + $p.Substring(8) }
    elseif ($p.StartsWith('\\?\') -or $p.StartsWith('\\.\')) { $p = $p.Substring(4) }
    $local = @('localhost', '127.0.0.1', '::1', '[::1]', $env:COMPUTERNAME) | Where-Object { $_ } | ForEach-Object { [regex]::Escape($_) }
    $m = [regex]::Match($p, '^\\\\(' + ($local -join '|') + ')\\([A-Za-z])\$(\\.*)?$', 'IgnoreCase')
    if ($m.Success) { $p = $m.Groups[2].Value + ':' + $(if ($m.Groups[3].Value) { $m.Groups[3].Value } else { '\' }) }
    return $p
}

function Initialize-DsrNative {
    if ('DsrNative' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
public static class DsrNative {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr sa, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern uint GetFinalPathNameByHandleW(SafeFileHandle handle, StringBuilder buffer, uint length, uint flags);
    public static string FinalPath(string path) {
        // access 0 = attributes only; share all; OPEN_EXISTING; BACKUP_SEMANTICS so directories open.
        using (SafeFileHandle h = CreateFileW(path, 0, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero)) {
            if (h.IsInvalid) return null;
            StringBuilder sb = new StringBuilder(32768);
            uint n = GetFinalPathNameByHandleW(h, sb, 32768, 0);
            return (n == 0 || n >= 32768) ? null : sb.ToString();
        }
    }
}
'@
}

function Resolve-DsrRealPath([string] $Path) {
    # The physical path: junctions, symlinks, subst drives, 8.3 names and local admin shares
    # resolved through the deepest existing ancestor; the part that doesn't exist is kept as
    # written. Ownership is decided on this, so a link into a client root counts as that root.
    $p = Resolve-DsrPath (ConvertFrom-DsrDevicePath $Path)
    if (-not $p) { return $p }
    $existing = $p; $rest = ''
    while ($existing -and -not (Test-Path -LiteralPath $existing)) {
        $parent = Split-Path $existing -Parent
        $rest = (Split-Path $existing -Leaf) + $(if ($rest) { '\' + $rest } else { '' })
        if (-not $parent -or $parent -eq $existing) { return $p }
        $existing = $parent
    }
    Initialize-DsrNative
    $final = [DsrNative]::FinalPath($existing)
    if (-not $final) { return $p }
    $final = ConvertFrom-DsrDevicePath $final
    if ($rest) { $final = Join-Path $final $rest }
    return (Resolve-DsrPath $final)
}

function Test-DsrSamePath([string] $A, [string] $B) {
    if (-not $A -or -not $B) { return $false }
    return [string]::Equals((Resolve-DsrRealPath $A), (Resolve-DsrRealPath $B), [StringComparison]::OrdinalIgnoreCase)
}

function Test-DsrUnder([string] $Path, [string] $Prefix) {
    # Textual, on whole segments: C:\w\clients\acme does not cover C:\w\clients\acme-old.
    # Callers pass paths already resolved with Resolve-DsrRealPath.
    $a = Resolve-DsrPath $Path; $b = Resolve-DsrPath $Prefix
    if (-not $a -or -not $b) { return $false }
    if ([string]::Equals($a, $b, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $a.StartsWith($b.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Get-DsrDefaultHome { return (Resolve-DsrRealPath '~/.claude') }

function Test-DsrDefaultHome([string] $HomePath) { return (Test-DsrSamePath $HomePath (Get-DsrDefaultHome)) }

function Get-DsrProjectSlug([string] $Path) {
    # How Claude Code names a folder under <home>\projects: every non-alphanumeric becomes '-'.
    return ((Resolve-DsrPath $Path) -replace '[^A-Za-z0-9]', '-')
}

function ConvertTo-DsrRulePath([string] $Path) {
    # Permission rules use POSIX form; '//' marks an absolute path. C:\x\y -> //c/x/y
    $p = Resolve-DsrPath $Path
    return '//' + $p.Substring(0, 1).ToLower() + $p.Substring(2).Replace('\', '/')
}

function Get-DsrRegistryPath {
    if ($env:DOSSIER_CONFIG) {
        if (-not ([IO.Path]::IsPathRooted($env:DOSSIER_CONFIG) -or $env:DOSSIER_CONFIG.StartsWith('~'))) { throw "DOSSIER_CONFIG must be an absolute path, not '$($env:DOSSIER_CONFIG)'" }
        return (Resolve-DsrPath $env:DOSSIER_CONFIG)
    }
    return (Join-Path (Get-DsrUserHome) '.dossier.json')
}

function Resolve-DsrRegistryPath([string] $Value, [string] $What) {
    # Registry paths must be ~/... or an absolute local drive path, so ownership never depends
    # on the folder a tool happens to run in.
    if ([string]::IsNullOrWhiteSpace($Value)) { throw "$What is empty" }
    $v = $Value.Trim()
    if (-not ($v -eq '~' -or $v.StartsWith('~/') -or $v.StartsWith('~\') -or $v -match '^[A-Za-z]:[\\/]')) {
        throw "$What must start with ~/ or a drive letter, not '$Value'"
    }
    $p = Resolve-DsrRealPath $v
    if ($p -notmatch '^[A-Za-z]:\\') { throw "$What resolves to $p, which is not on a local drive" }
    return $p
}

function Read-DsrRepos($Raw, [string] $What) {
    return @(foreach ($r in @($Raw)) {
        if ($null -eq $r) { continue }
        $remote = [string]$r.remote
        if ([string]::IsNullOrWhiteSpace($remote) -or $remote.StartsWith('-')) { throw "$What repos: remote '$remote' is empty or starts with -" }
        $dir = [string]($r.dir ?? (($remote.TrimEnd('/') -split '[/:\\]')[-1] -replace '\.git$', ''))
        if ($dir -notmatch '^[A-Za-z0-9._-]+$' -or $dir -in @('.', '..')) { throw "$What repos: folder name '$dir' for $remote is not a plain name; set dir" }
        $from = $null
        if ($null -ne $r.from) {
            if (-not $r.from.product -or -not $r.from.repo) { throw "$What repos: '$dir' from needs both product and repo" }
            $from = [pscustomobject]@{ Product = [string]$r.from.product; Repo = [string]$r.from.repo }
        }
        [pscustomobject]@{ Remote = $remote; Dir = $dir; From = $from }
    })
}

function Read-DsrRegistry {
    # Returns the registry with paths resolved and one Entries list: the firm first, then
    # products, then clients. Throws a readable message on any problem.
    $path = Get-DsrRegistryPath
    if (-not (Test-Path -LiteralPath $path)) { throw "no registry at $path (copy dossier.example.json there, or set DOSSIER_CONFIG)" }
    try { $raw = [IO.File]::ReadAllText($path) | ConvertFrom-Json }
    catch { throw "cannot parse $path : $($_.Exception.Message)" }
    if ($null -eq $raw) { throw "$path is empty" }

    if (-not $raw.workspaceRoot) { throw "$path has no workspaceRoot" }
    if (-not $raw.firm) { throw "$path has no firm section" }
    $f = $raw.firm
    $firmKey = [string]($f.key ?? 'firm')
    if ($firmKey -cnotmatch '^[a-z0-9][a-z0-9-]*\z') { throw "firm.key '$firmKey' must be lowercase letters, digits and -" }
    if ($f.home -and -not (Test-DsrDefaultHome ([string]$f.home))) {
        throw "firm.home must be ~/.claude: Claude Code keeps that home's state file at ~/.claude.json, outside the directory, so it can only be the default home."
    }
    if (-not $f.hubRoot) { throw "$path has no firm.hubRoot" }

    $entries = New-Object System.Collections.Generic.List[object]
    $hub = Resolve-DsrRegistryPath ([string]$f.hubRoot) 'firm.hubRoot'
    $firmRoots = @($hub)
    if ($f.sandboxRoot) { $firmRoots += Resolve-DsrRegistryPath ([string]$f.sandboxRoot) 'firm.sandboxRoot' }

    $agents = $null
    if ($null -ne $raw.agents) {
        if (-not $raw.agents.source) { throw "agents has no source (the folder holding your agent files)" }
        $roles = [ordered]@{}
        foreach ($prop in @(if ($raw.agents.roles) { $raw.agents.roles.PSObject.Properties })) {
            if ($prop.Name -cnotin $script:DsrRoles) { throw "agents.roles '$($prop.Name)' is not a role; roles are $($script:DsrRoles -join ', ')" }
            $n = [string]$prop.Value
            if ($n -cnotmatch '^[a-z0-9][a-z0-9-]*\z') { throw "agents.roles.$($prop.Name) '$n' must be an agent name: lowercase letters, digits and -" }
            if ($n -in @($roles.Values)) { throw "agent '$n' fills two roles; give each role its own agent" }
            $roles[$prop.Name] = $n
        }
        $agents = [pscustomobject]@{ Source = (Resolve-DsrRegistryPath ([string]$raw.agents.source) 'agents.source'); Roles = $roles }
    }
    function Read-AgentRoles($Raw, [string] $Kind, [string] $What) {
        if ($null -eq $Raw.PSObject.Properties['agentRoles']) { return $null }
        $list = @(@($Raw.agentRoles) | Where-Object { $_ } | ForEach-Object { [string]$_ })
        foreach ($r in $list) {
            if ($r -cnotin $script:DsrRoles) { throw "$What agentRoles '$r' is not a role" }
            if ($r -eq 'hr' -and $Kind -ne 'firm') { throw "$What agentRoles can't include hr: hr edits your roster and lives only in the firm home" }
        }
        return $list
    }
    function Read-AgentNames($Raw, [string] $Kind, [string] $Seat, [string] $What) {
        if ($null -eq $Raw.agentNames) { return $null }
        if ($Kind -ne 'client' -or $Seat -ne 'enterprise') { throw "$What agentNames needs an enterprise-seat client: other homes link to the firm's agents, so they can't have agents of their own" }
        if ($Raw.agentNames -isnot [System.Management.Automation.PSCustomObject]) { throw "$What agentNames must map roles to agent names" }
        $names = [ordered]@{}
        foreach ($prop in $Raw.agentNames.PSObject.Properties) {
            $role = $prop.Name; $n = [string]$prop.Value
            if ($role -cnotin $script:DsrRoles) { throw "$What agentNames '$role' is not a role" }
            if ($role -eq 'hr') { throw "$What agentNames can't include hr: hr edits your roster and lives only in the firm home" }
            if ($n -cnotmatch '^[a-z0-9][a-z0-9-]*\z') { throw "$What agentNames.$role '$n' must be an agent name: lowercase letters, digits and -" }
            if ($agents) { foreach ($k in $agents.Roles.Keys) { if ($k -ne $role -and $agents.Roles[$k] -eq $n) { throw "$What agentNames.$role '$n' is the roster's $k; give each role its own agent" } } }
            if ($n -in @($names.Values)) { throw "$What agentNames: agent '$n' fills two roles; give each role its own agent" }
            $names[$role] = $n
        }
        return $names
    }
    function Read-SharedPermissions($Raw, [string] $What) {
        $v = $Raw.sharedPermissions
        if ($null -eq $v) { return $true }
        if ($v -isnot [bool]) { throw "$What sharedPermissions must be true or false" }
        return $v
    }
    $perms = [pscustomobject]@{ Allow = @(); Ask = @() }
    if ($null -ne $raw.permissions) {
        foreach ($prop in $raw.permissions.PSObject.Properties) {
            if ($prop.Name -cnotin @('allow', 'ask')) { throw "permissions.$($prop.Name) is not shared by Sync; only allow and ask are" }
            $perms.($prop.Name) = @(@($prop.Value) | Where-Object { $_ } | ForEach-Object { [string]$_ })
        }
    }

    if ($null -ne $raw.PSObject.Properties['templates']) { throw "$path has a 'templates' section; templates are now 'products', each with its own home and a clientRead list" }

    $entries.Add([pscustomobject]@{
        Key = $firmKey; Name = [string]($f.name ?? 'Firm'); Kind = 'firm'; Seat = 'firm'
        Home = (Get-DsrDefaultHome); Roots = $firmRoots; FormerRoots = @(); HubRoot = $hub
        ExpectEmail = [string]$f.expectEmail; ExpectOrg = [string]$f.expectOrg
        Contacts = @(); Status = 'active'; BasedOn = @(); Repos = @(); ClientRead = @(); EnterpriseRead = $false
        AgentRoles = (Read-AgentRoles $f 'firm' 'firm'); AgentNames = (Read-AgentNames $f 'firm' 'firm' 'firm'); SharedPermissions = (Read-SharedPermissions $f 'firm')
    })

    foreach ($p in @($raw.products)) {
        if ($null -eq $p) { continue }
        $key = [string]$p.key
        if ($key -cnotmatch '^[a-z0-9][a-z0-9-]*\z') { throw "product key '$key' must be lowercase letters, digits and -" }
        if ($key -eq $firmKey) { throw "product key '$key' is the firm's key" }
        if (@($entries | Where-Object { $_.Key -eq $key }).Count) { throw "product key '$key' appears twice" }
        if (-not $p.root) { throw "product '$key' has no root" }
        if ($null -ne $p.enterpriseRead -and $p.enterpriseRead -isnot [bool]) { throw "product '$key' enterpriseRead must be true or false" }
        $homePath = Resolve-DsrRegistryPath ([string]($p.home ?? "~/.claude-homes/$key")) "product '$key' home"
        if (Test-DsrUnder $homePath (Get-DsrDefaultHome)) { throw "product '$key' home cannot be ~/.claude or inside it; that is the firm home" }
        $clientRead = @(foreach ($cr in @($p.clientRead)) {
            if ($null -eq $cr) { continue }
            $v = ([string]$cr).Trim().Replace('/', '\').Trim('\')
            if (-not $v -or $v -match '^[A-Za-z]:' -or $v.StartsWith('~') -or $v -match '[*?\[\]]' -or @($v -split '\\' | Where-Object { $_ -in @('', '.', '..') }).Count) {
                throw "product '$key' clientRead '$cr' must be a plain relative path inside the product root"
            }
            $v
        })
        $entries.Add([pscustomobject]@{
            Key = $key; Name = [string]($p.name ?? $key); Kind = 'product'; Seat = 'firm'
            Home = $homePath; Roots = @(Resolve-DsrRegistryPath ([string]$p.root) "product '$key' root")
            FormerRoots = @(); HubRoot = $null
            ExpectEmail = [string]($p.expectEmail ?? $f.expectEmail); ExpectOrg = [string]($p.expectOrg ?? $f.expectOrg)
            Contacts = @(@($p.contacts) | Where-Object { $_ }); Status = [string]($p.status ?? 'active')
            BasedOn = @(); Repos = @(Read-DsrRepos $p.repos "product '$key'")
            ClientRead = $clientRead; EnterpriseRead = [bool]$p.enterpriseRead
            AgentRoles = (Read-AgentRoles $p 'product' "product '$key'"); AgentNames = (Read-AgentNames $p 'product' 'firm' "product '$key'"); SharedPermissions = (Read-SharedPermissions $p "product '$key'")
        })
    }

    foreach ($c in @($raw.clients)) {
        if ($null -eq $c) { continue }
        $key = [string]$c.key
        if ($key -cnotmatch '^[a-z0-9][a-z0-9-]*\z') { throw "client key '$key' must be lowercase letters, digits and -" }
        if ($key -eq $firmKey) { throw "client key '$key' is the firm's key" }
        if (@($entries | Where-Object { $_.Key -eq $key }).Count) { throw "client key '$key' appears twice" }
        $basedOn = @(@($c.basedOn) | Where-Object { $_ } | ForEach-Object { [string]$_ })
        foreach ($b in $basedOn) { if (-not @($entries | Where-Object { $_.Kind -eq 'product' -and $_.Key -ceq $b }).Count) { throw "client '$key' basedOn '$b', which is not a product in the registry" } }
        if ($c.seat -notin @('enterprise', 'none')) { throw "client '$key' seat must be 'enterprise' or 'none', not '$($c.seat)'" }
        if (-not $c.root) { throw "client '$key' has no root" }
        $homePath = Resolve-DsrRegistryPath ([string]($c.home ?? "~/.claude-homes/$key")) "client '$key' home"
        if (Test-DsrUnder $homePath (Get-DsrDefaultHome)) { throw "client '$key' home cannot be ~/.claude or inside it; that is the firm home" }
        if ($c.seat -eq 'enterprise' -and -not ($c.expectEmail -or $c.expectOrg)) {
            throw "client '$key' has an enterprise seat but no expectEmail or expectOrg, so a wrong login could not be detected"
        }
        $entries.Add([pscustomobject]@{
            Key = $key; Name = [string]($c.name ?? $key); Kind = 'client'; Seat = [string]$c.seat
            Home = $homePath; Roots = @(Resolve-DsrRegistryPath ([string]$c.root) "client '$key' root")
            FormerRoots = @(@($c.formerRoots) | Where-Object { $_ } | ForEach-Object { Resolve-DsrRegistryPath ([string]$_) "client '$key' formerRoots" })
            HubRoot = $null
            ExpectEmail = [string]$c.expectEmail; ExpectOrg = [string]$c.expectOrg
            Contacts = @(@($c.contacts) | Where-Object { $_ }); Status = [string]($c.status ?? 'active')
            BasedOn = $basedOn; Repos = @(Read-DsrRepos $c.repos "client '$key'"); ClientRead = @(); EnterpriseRead = $false
            AgentRoles = (Read-AgentRoles $c 'client' "client '$key'"); AgentNames = (Read-AgentNames $c 'client' ([string]$c.seat) "client '$key'"); SharedPermissions = (Read-SharedPermissions $c "client '$key'")
        })
    }

    foreach ($e in @($entries | Where-Object Kind -eq 'client')) {
        foreach ($rp in @($e.Repos | Where-Object From)) {
            $p = $entries | Where-Object { $_.Kind -eq 'product' -and $_.Key -ceq $rp.From.Product } | Select-Object -First 1
            if (-not $p) { throw "client '$($e.Key)' repo '$($rp.Dir)' is from '$($rp.From.Product)', which is not a product in the registry" }
            if ($p.Key -cnotin $e.BasedOn) { throw "client '$($e.Key)' repo '$($rp.Dir)' is from '$($p.Key)', but the client isn't basedOn it" }
            if ($rp.From.Repo -cnotin @($p.Repos | ForEach-Object Dir)) { throw "client '$($e.Key)' repo '$($rp.Dir)' is from '$($p.Key)/$($rp.From.Repo)', which is not one of that product's repos" }
        }
    }

    $workspace = Resolve-DsrRegistryPath ([string]$raw.workspaceRoot) 'workspaceRoot'
    $all = @(foreach ($e in $entries) { foreach ($r in $e.Roots) { [pscustomobject]@{ Key = $e.Key; Root = $r } } })
    foreach ($x in $all) {
        foreach ($y in $all) {
            if ($x.Key -ne $y.Key -and (Test-DsrUnder $x.Root $y.Root)) { throw "root $($x.Root) ('$($x.Key)') is inside $($y.Root) ('$($y.Key)'); roots must not nest" }
        }
    }
    foreach ($e in $entries) {
        if ($e.Kind -ne 'firm') {
            foreach ($r in $e.Roots) { if ((Test-DsrUnder $e.Home $r) -or (Test-DsrUnder $r $e.Home)) { throw "home of '$($e.Key)' overlaps its own root; a home holds credentials and must sit outside every root" } }
        }
        foreach ($o in $entries) {
            if ($o.Key -eq $e.Key) { continue }
            if ((Test-DsrUnder $e.Home $o.Home) -or (Test-DsrUnder $o.Home $e.Home)) { throw "homes of '$($e.Key)' and '$($o.Key)' overlap; every entry needs its own" }
            foreach ($r in $o.Roots) {
                if ($e.Kind -ne 'firm' -and ((Test-DsrUnder $e.Home $r) -or (Test-DsrUnder $r $e.Home))) { throw "home of '$($e.Key)' overlaps the root of '$($o.Key)'" }
                foreach ($fr in $e.FormerRoots) { if (Test-DsrUnder $r $fr) { throw "formerRoots $fr of '$($e.Key)' covers the root of '$($o.Key)'" } }
            }
        }
        foreach ($fr in $e.FormerRoots) { if (Test-DsrUnder $workspace $fr) { throw "formerRoots $fr of '$($e.Key)' covers the whole workspace" } }
    }

    return [pscustomobject]@{
        Path          = $path
        WorkspaceRoot = $workspace
        PersonalRules = if ($raw.personalRules) { Resolve-DsrRegistryPath ([string]$raw.personalRules) 'personalRules' } else { $null }
        SharedSkills  = @(@($raw.sharedSkills) | Where-Object { $_ } | ForEach-Object { [string]$_ })
        Agents        = $agents
        Permissions   = $perms
        Entries       = $entries.ToArray()
    }
}

function Get-DsrEntryAgents($Reg, $Entry) {
    # The agents a home gets, as @{ Role; Name; Source }. By default the firm home gets every
    # role the roster fills; other homes get all but lead (it replaces the main session's
    # prompt, so it is opt-in) and hr (it edits the roster, so it stays in the firm home).
    # Homes that share the firm's agents see all of them through the link; for those this
    # list only decides the lead. An enterprise entry's agentNames puts its own agent in a role.
    if (-not $Reg.Agents) { return @() }
    $names = $Entry.AgentNames
    $filled = @($Reg.Agents.Roles.Keys) + @(if ($null -ne $names) { $names.Keys })
    $want = if ($null -ne $Entry.AgentRoles) { $Entry.AgentRoles }
            elseif ($Entry.Kind -eq 'firm') { $filled }
            else { @($filled | Where-Object { $_ -notin @('lead', 'hr') }) }
    return @(foreach ($role in $script:DsrRoles) {
        if ($role -notin $want -or $role -notin $filled) { continue }
        $name = if ($null -ne $names -and $names.Contains($role)) { $names[$role] } else { $Reg.Agents.Roles[$role] }
        [pscustomobject]@{ Role = $role; Name = $name; Source = (Join-Path $Reg.Agents.Source "$name.md") }
    })
}

function Test-DsrSharesFirmAgents($Entry) {
    # Homes on the firm's own account (products, no-seat clients) link to the firm home's agents:
    # one definition of each agent, memory still per home. Only an outside enterprise seat gets
    # its own copies.
    return ($Entry.Kind -ne 'firm' -and $Entry.Seat -ne 'enterprise')
}

function Get-DsrFirmAgentsDir { return (Join-Path (Get-DsrDefaultHome) 'agents') }

function Get-DsrAgentFrontmatter([string] $Text) {
    $m = [regex]::Match($Text, '\A﻿?---\r?\n(.*?)\r?\n---', 'Singleline')
    $out = @{}
    if (-not $m.Success) { return $out }
    foreach ($line in ($m.Groups[1].Value -split '\r?\n')) {
        $kv = [regex]::Match($line, '^([A-Za-z][A-Za-z0-9_-]*):\s*(.*)$')
        if ($kv.Success) { $out[$kv.Groups[1].Value] = $kv.Groups[2].Value.Trim().Trim('"', "'") }
    }
    return $out
}

function Get-DsrInstalledAgent($Agent) {
    # The agent file a home gets: the roster's file as written, then the role contract and the
    # rules common to every role, after a marker so Sync knows the file is its own.
    $roles = Join-Path (Split-Path $PSScriptRoot -Parent) 'roles'
    $src = [IO.File]::ReadAllText($Agent.Source).TrimEnd()
    $contract = [IO.File]::ReadAllText((Join-Path $roles "$($Agent.Role).md")).TrimEnd()
    $common = [IO.File]::ReadAllText((Join-Path $roles '_common.md')).TrimEnd()
    return "$src`n`n$($script:DsrAgentMarker)`n`n$contract`n`n$common`n"
}

function Find-DsrEntry($Reg, [string] $Key) {
    return ($Reg.Entries | Where-Object { $_.Key -ieq $Key } | Select-Object -First 1)
}

function Get-DsrProducts($Reg) { return @($Reg.Entries | Where-Object Kind -eq 'product') }

function Test-DsrProductReadable($Client, $Product) {
    # A client may read a product's clientRead paths only if it is based on the product, and an
    # enterprise-seat client only if the product allows enterprise reads. Only the firm and the
    # product's own home may edit a product.
    if ($Client.Kind -ne 'client' -or $Product.Key -cnotin $Client.BasedOn -or -not $Product.ClientRead.Count) { return $false }
    return ($Client.Seat -eq 'none' -or $Product.EnterpriseRead)
}

function Test-DsrProductBlocked($Client, $Product) {
    return ($Client.Kind -eq 'client' -and $Product.Key -cin $Client.BasedOn -and $Client.Seat -eq 'enterprise' -and -not $Product.EnterpriseRead)
}

function Get-DsrClientReadPaths($Product) {
    return @($Product.ClientRead | ForEach-Object { Join-Path $Product.Roots[0] $_ })
}

function Test-DsrRepoClientReadable($Product, [string] $Dir) {
    # A product repo a client forks must be readable in full: the fork carries its whole history.
    $path = Join-Path $Product.Roots[0] $Dir
    return [bool]@(Get-DsrClientReadPaths $Product | Where-Object { Test-DsrUnder $path $_ }).Count
}

function Get-DsrStatusFile($Entry) { return (Join-Path $Entry.Home 'dossier.products.json') }

function Get-DsrForkStatus([string] $ClientRepo, [string] $ProductRepo) {
    # The base is the newest product commit in the client repo's history (not merely its object
    # store, which a fetch fills without merging).
    $o = [ordered]@{ state = ''; base = $null; behind = 0; changed = @() }
    if (-not (Test-Path -LiteralPath (Join-Path $ClientRepo '.git'))) { $o.state = 'not-cloned'; return $o }
    if (-not (Test-Path -LiteralPath (Join-Path $ProductRepo '.git'))) { $o.state = 'product-not-cloned'; return $o }
    $mine = [Collections.Generic.HashSet[string]]::new([string[]]@(git -C $ClientRepo rev-list HEAD 2>$null))
    foreach ($sha in @(git -C $ProductRepo rev-list HEAD 2>$null)) { if ($mine.Contains($sha)) { $o.base = $sha; break } }
    if (-not $o.base) { $o.state = 'no-shared-commit'; return $o }
    $o.behind = [int](git -C $ProductRepo rev-list --count "$($o.base)..HEAD")
    $o.changed = @(git -C $ProductRepo diff --name-only $o.base HEAD)
    $o.state = 'ok'
    return $o
}

function Get-DsrProductStatus($Reg, $Client) {
    # What a client home may know about the products it is based on: only readable paths, heads
    # of fully readable repos, and for each fork its base, distance and changed file names.
    # Never commit messages.
    return @(foreach ($p in @(Get-DsrProducts $Reg | Where-Object { $_.Key -cin $Client.BasedOn })) {
        $x = [ordered]@{ key = $p.Key; name = $p.Name; readable = (Test-DsrProductReadable $Client $p) }
        if ($x.readable) {
            $x.paths = @(Get-DsrClientReadPaths $p)
            $x.repos = @(foreach ($r in $p.Repos) {
                if (-not (Test-DsrRepoClientReadable $p $r.Dir)) { continue }
                $rp = Join-Path $p.Roots[0] $r.Dir
                [ordered]@{ dir = $r.Dir; path = $rp; head = $(if (Test-Path -LiteralPath (Join-Path $rp '.git')) { [string](git -C $rp rev-parse HEAD 2>$null) } else { $null }) }
            })
            $x.forks = @(foreach ($cr in @($Client.Repos | Where-Object { $_.From -and $_.From.Product -ceq $p.Key })) {
                $f = [ordered]@{ dir = $cr.Dir; productRepo = $cr.From.Repo }
                $s = if (Test-DsrRepoClientReadable $p $cr.From.Repo) { Get-DsrForkStatus (Join-Path $Client.Roots[0] $cr.Dir) (Join-Path $p.Roots[0] $cr.From.Repo) } else { [ordered]@{ state = 'product-repo-not-readable' } }
                foreach ($k in $s.Keys) { $f[$k] = $s[$k] }
                $f
            })
        }
        $x
    })
}

function Get-DsrProductReadDenies($Product) {
    # Deny rules always beat allow rules, so a client's view of a product is everything under the
    # root that isn't on, or above, a clientRead path, listed from disk: siblings at each level
    # down to each clientRead path. A clientRead path or registered repo that doesn't exist yet
    # is denied at its first missing folder. Anything else added later stays readable until the
    # next Sync; the doctor catches that as missing deny rules.
    $root = $Product.Roots[0]
    $allowed = @(Get-DsrClientReadPaths $Product)
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return @(@{ Path = $root; IsFile = $false; EditOnly = $false }) }
    $out = New-Object System.Collections.Generic.List[object]
    $queue = [Collections.Generic.Queue[string]]::new(); $queue.Enqueue($root)
    while ($queue.Count) {
        foreach ($i in @(Get-ChildItem -LiteralPath $queue.Dequeue() -Force -ErrorAction SilentlyContinue | Sort-Object Name)) {
            $p = $i.FullName
            if (@($allowed | Where-Object { Test-DsrUnder $p $_ }).Count) { continue }
            if ($i.PSIsContainer -and -not $i.LinkType -and @($allowed | Where-Object { Test-DsrUnder $_ $p }).Count) { $queue.Enqueue($p); continue }
            $out.Add(@{ Path = $p; IsFile = -not $i.PSIsContainer; EditOnly = $false })
        }
    }
    foreach ($r in $Product.Repos) {
        $d = Join-Path $root $r.Dir
        if (-not (Test-Path -LiteralPath $d) -and -not @($allowed | Where-Object { (Test-DsrUnder $_ $d) -or (Test-DsrUnder $d $_) }).Count) { $out.Add(@{ Path = $d; IsFile = $false; EditOnly = $false }) }
    }
    foreach ($a in $allowed) {
        if (Test-Path -LiteralPath $a) { continue }
        $c = $a
        while (-not (Test-Path -LiteralPath (Split-Path $c -Parent))) { $c = Split-Path $c -Parent }
        if (-not @($out | Where-Object { Test-DsrUnder $c $_.Path }).Count) { $out.Add(@{ Path = $c; IsFile = $false; EditOnly = $false }) }
    }
    return $out.ToArray()
}

function Find-DsrFirm($Reg) {
    return ($Reg.Entries | Where-Object { $_.Kind -eq 'firm' } | Select-Object -First 1)
}

function Find-DsrEntryByHome($Reg, [string] $HomePath) {
    $h = Resolve-DsrRealPath $HomePath
    return ($Reg.Entries | Where-Object { [string]::Equals($_.Home, $h, [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1)
}

function Find-DsrOwner($Reg, [string] $Cwd) {
    # Who owns a folder: @{ Entry; State; Path } with State = owned | unregistered | outside.
    $real = Resolve-DsrRealPath $Cwd
    foreach ($e in $Reg.Entries) {
        foreach ($r in $e.Roots) { if (Test-DsrUnder $real $r) { return @{ Entry = $e; State = 'owned'; Path = $real } } }
    }
    if (Test-DsrUnder $real $Reg.WorkspaceRoot) { return @{ Entry = $null; State = 'unregistered'; Path = $real } }
    return @{ Entry = $null; State = 'outside'; Path = $real }
}

function Get-DsrStateFile([string] $HomePath) {
    if (Test-DsrDefaultHome $HomePath) { return ((Get-DsrDefaultHome) + '.json') }
    return (Join-Path $HomePath '.claude.json')
}

function Read-DsrIdentity([string] $HomePath) {
    # Which account a home is logged in to, from oauthAccount in its state file.
    # Status: ok | no-state-file | unreadable | no-login
    $file = Get-DsrStateFile $HomePath
    $out = [pscustomobject]@{ Status = ''; File = $file; Email = ''; Org = ''; OrgName = '' }
    if (-not (Test-Path -LiteralPath $file)) { $out.Status = 'no-state-file'; return $out }
    try { $j = [IO.File]::ReadAllText($file) | ConvertFrom-Json } catch { $out.Status = 'unreadable'; return $out }
    if ($null -eq $j -or -not $j.PSObject.Properties['oauthAccount'] -or -not $j.oauthAccount) { $out.Status = 'no-login'; return $out }
    $out.Email = [string]$j.oauthAccount.emailAddress
    $out.Org = [string]$j.oauthAccount.organizationUuid
    $out.OrgName = [string]$j.oauthAccount.organizationName
    $out.Status = 'ok'
    return $out
}

function Test-DsrIdentityMatches($Entry, $Identity) {
    # $true / $false, or $null when the entry sets no expectation.
    if (-not $Entry.ExpectEmail -and -not $Entry.ExpectOrg) { return $null }
    if ($Identity.Status -ne 'ok') { return $false }
    if ($Entry.ExpectEmail -and -not [string]::Equals($Entry.ExpectEmail, $Identity.Email, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    if ($Entry.ExpectOrg -and -not [string]::Equals($Entry.ExpectOrg, $Identity.Org, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    return $true
}

function Get-DsrExpectText($Entry) { return (@($Entry.ExpectEmail, $Entry.ExpectOrg | Where-Object { $_ }) -join ' / ') }

function Get-DsrDeniedPaths($Reg, $Entry) {
    # What a home must not read or edit, as @{ Path; IsFile; EditOnly }.
    #   The firm: enterprise-seat client roots, every client's home, edits to product homes, and
    #   product logins. It reads products, and their homes' memory, in full.
    #   A client or product: every other client's and product's root and home, the hub, and the
    #   firm home and state file. A client reading a product (Test-DsrProductReadable) instead
    #   gets Edit denied on its root and Read denied on everything outside clientRead.
    $out = New-Object System.Collections.Generic.List[object]
    function Add([string] $Path, [bool] $IsFile = $false, [bool] $EditOnly = $false) { $out.Add(@{ Path = $Path; IsFile = $IsFile; EditOnly = $EditOnly }) }
    foreach ($e in $Reg.Entries) {
        if ($e.Key -eq $Entry.Key) { continue }
        if ($e.Kind -eq 'firm') {
            Add $e.HubRoot; Add $e.Home; Add (Get-DsrStateFile $e.Home) $true
        } elseif ($e.Kind -eq 'client') {
            if ($Entry.Kind -ne 'firm' -or $e.Seat -eq 'enterprise') { foreach ($r in $e.Roots) { Add $r } }
            Add $e.Home
        } elseif ($Entry.Kind -eq 'firm') {
            Add $e.Home $false $true
            Add (Join-Path $e.Home '.credentials.json') $true; Add (Get-DsrStateFile $e.Home) $true
        } else {
            Add $e.Home
            if (Test-DsrProductReadable $Entry $e) {
                Add $e.Roots[0] $false $true
                foreach ($d in (Get-DsrProductReadDenies $e)) { $out.Add($d) }
            } else { Add $e.Roots[0] }
        }
    }
    return $out.ToArray()
}

function Get-DsrDenyRules($Reg, $Entry) {
    return @(foreach ($d in (Get-DsrDeniedPaths $Reg $Entry)) {
        $p = ConvertTo-DsrRulePath $d.Path
        if (-not $d.IsFile) { $p += '/**' }
        if (-not $d.EditOnly) { "Read($p)" }
        "Edit($p)"
    })
}

function Get-DsrReadableRoots($Reg, $Entry) {
    # Extra folders a home may read without --add-dir. The firm: no-seat clients, every product
    # root and every product home's memory. A client: the clientRead paths of products it may
    # read that exist. A product: none.
    if ($Entry.Kind -eq 'firm') {
        return @(
            @($Reg.Entries | Where-Object { $_.Seat -eq 'none' } | ForEach-Object { $_.Roots })
            foreach ($p in (Get-DsrProducts $Reg)) { $p.Roots[0]; Join-Path $p.Home 'projects' }
        )
    }
    if ($Entry.Kind -ne 'client') { return @() }
    return @(foreach ($p in (Get-DsrProducts $Reg)) {
        if (Test-DsrProductReadable $Entry $p) { Get-DsrClientReadPaths $p | Where-Object { Test-Path -LiteralPath $_ } }
    })
}

function Get-DsrGuardCommand { return 'pwsh -NoProfile -File "' + $script:DsrGuardScript.Replace('\', '/') + '"' }

function Get-DsrShellGuardCommand { return 'pwsh -NoProfile -File "' + $script:DsrShellGuardScript.Replace('\', '/') + '"' }

function Test-DsrHooked($Settings, [string] $Event, [string] $Script) {
    if (-not $Settings -or -not $Settings.hooks -or -not $Settings.hooks.$Event) { return $false }
    foreach ($g in @($Settings.hooks.$Event)) { foreach ($h in @($g.hooks)) { if ([string]$h.command -like "*$Script*") { return $true } } }
    return $false
}
