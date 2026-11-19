# Dossier.Common.ps1 - helpers shared by every dossier tool. Dot-source it; don't run it.
# Keep it ASCII: Windows PowerShell 5.1 misreads UTF-8 without a BOM, and hooks are sometimes
# wired to `powershell` by mistake.

$script:DsrGuardScript = Join-Path $PSScriptRoot 'dossier-guard.ps1'
$script:DsrShellGuardScript = Join-Path $PSScriptRoot 'dossier-shellguard.ps1'
$script:DsrManagedMarker = '<!-- managed by dossier -->'

# Variables a Claude Code session hands to its children. Everything else CLAUDE_* is the
# user's own configuration and must reach the child untouched.
$script:DsrSessionVars = '^(CLAUDECODE|CLAUDE_CONFIG_DIR|CLAUDE_PID|CLAUDE_CODE_(CHILD_SESSION|ENTRYPOINT|SESSION_ID|SESSION_ATTENDED|SSE_PORT|MESSAGING_SOCKET|MESSAGING_TOKEN|OAUTH_TOKEN))$'

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

function Read-DsrRegistry {
    # Returns the registry with paths resolved and one Entries list (the firm first, then
    # clients). Throws a readable message on any problem.
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
    $entries.Add([pscustomobject]@{
        Key = $firmKey; Name = [string]($f.name ?? 'Firm'); Kind = 'firm'; Seat = 'firm'
        Home = (Get-DsrDefaultHome); Roots = $firmRoots; FormerRoots = @(); HubRoot = $hub
        ExpectEmail = [string]$f.expectEmail; ExpectOrg = [string]$f.expectOrg
        Contacts = @(); Status = 'active'
    })

    foreach ($c in @($raw.clients)) {
        if ($null -eq $c) { continue }
        $key = [string]$c.key
        if ($key -cnotmatch '^[a-z0-9][a-z0-9-]*\z') { throw "client key '$key' must be lowercase letters, digits and -" }
        if ($key -eq $firmKey) { throw "client key '$key' is the firm's key" }
        if (@($entries | Where-Object { $_.Key -eq $key }).Count) { throw "client key '$key' appears twice" }
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
        })
    }

    $workspace = Resolve-DsrRegistryPath ([string]$raw.workspaceRoot) 'workspaceRoot'
    $all = @(foreach ($e in $entries) { foreach ($r in $e.Roots) { [pscustomobject]@{ Key = $e.Key; Root = $r } } })
    foreach ($x in $all) {
        foreach ($y in $all) {
            if ($x.Key -ne $y.Key -and (Test-DsrUnder $x.Root $y.Root)) { throw "root $($x.Root) ('$($x.Key)') is inside $($y.Root) ('$($y.Key)'); roots must not nest" }
        }
    }
    foreach ($e in $entries) {
        if ($e.Kind -eq 'client') {
            foreach ($r in $e.Roots) { if ((Test-DsrUnder $e.Home $r) -or (Test-DsrUnder $r $e.Home)) { throw "home of '$($e.Key)' overlaps its own root; a home holds credentials and must sit outside every root" } }
        }
        foreach ($o in $entries) {
            if ($o.Key -eq $e.Key) { continue }
            if ((Test-DsrUnder $e.Home $o.Home) -or (Test-DsrUnder $o.Home $e.Home)) { throw "homes of '$($e.Key)' and '$($o.Key)' overlap; every entry needs its own" }
            foreach ($r in $o.Roots) {
                if ($e.Kind -eq 'client' -and ((Test-DsrUnder $e.Home $r) -or (Test-DsrUnder $r $e.Home))) { throw "home of '$($e.Key)' overlaps the root of '$($o.Key)'" }
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
        Entries       = $entries.ToArray()
    }
}

function Find-DsrEntry($Reg, [string] $Key) {
    return ($Reg.Entries | Where-Object { $_.Key -ieq $Key } | Select-Object -First 1)
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
    # What a home must not read or edit, as @{ Path; IsFile }.
    #   The firm: enterprise-seat client roots, and every client's home.
    #   A client: every other client's root and home, the hub, and the firm home and state file.
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($e in $Reg.Entries) {
        if ($e.Key -eq $Entry.Key) { continue }
        if ($e.Kind -eq 'client') {
            if ($Entry.Kind -eq 'client' -or $e.Seat -eq 'enterprise') { foreach ($r in $e.Roots) { $out.Add(@{ Path = $r; IsFile = $false }) } }
            $out.Add(@{ Path = $e.Home; IsFile = $false })
        } else {
            $out.Add(@{ Path = $e.HubRoot; IsFile = $false })
            $out.Add(@{ Path = $e.Home; IsFile = $false })
            $out.Add(@{ Path = (Get-DsrStateFile $e.Home); IsFile = $true })
        }
    }
    return $out.ToArray()
}

function Get-DsrDenyRules($Reg, $Entry) {
    return @(foreach ($d in (Get-DsrDeniedPaths $Reg $Entry)) {
        $p = ConvertTo-DsrRulePath $d.Path
        if ($d.IsFile) { "Read($p)"; "Edit($p)" } else { "Read($p/**)"; "Edit($p/**)" }
    })
}

function Get-DsrReadableRoots($Reg, $Entry) {
    # Extra roots the firm home may read: no-seat clients.
    if ($Entry.Kind -ne 'firm') { return @() }
    return @($Reg.Entries | Where-Object { $_.Seat -eq 'none' } | ForEach-Object { $_.Roots })
}

function Get-DsrGuardCommand { return 'pwsh -NoProfile -File "' + $script:DsrGuardScript.Replace('\', '/') + '"' }

function Get-DsrShellGuardCommand { return 'pwsh -NoProfile -File "' + $script:DsrShellGuardScript.Replace('\', '/') + '"' }

function Test-DsrHooked($Settings, [string] $Event, [string] $Script) {
    if (-not $Settings -or -not $Settings.hooks -or -not $Settings.hooks.$Event) { return $false }
    foreach ($g in @($Settings.hooks.$Event)) { foreach ($h in @($g.hooks)) { if ([string]$h.command -like "*$Script*") { return $true } } }
    return $false
}
