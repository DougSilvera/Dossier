# Sync-Dossier.ps1 - make the machine match ~/.dossier.json. Shows the plan; -Apply does it.
#
#   pwsh -File Sync-Dossier.ps1           # dry run
#   pwsh -File Sync-Dossier.ps1 -Apply
#
# For every entry it ensures:
#   - its roots and home exist
#   - its home's settings.json has the dossier guard SessionStart hook, Read/Edit deny rules for
#     what it must not see (Get-DsrDeniedPaths: the firm denies enterprise-seat roots and every
#     client home; a client denies other clients' roots and homes, the hub, ~/.claude and
#     ~/.claude.json), and for the firm, additionalDirectories for no-seat clients. Only rules this
#     script added before (tracked in <home>\dossier.managed.json) are ever removed.
#   - its home's CLAUDE.md is the personal rules file, if the registry names one. A CLAUDE.md
#     this script didn't write is left alone and reported.
#   - client homes link the registry's sharedSkills from ~/.claude\skills, and nothing else.
# Plus the hub CLAUDE.md (generated section only) and a CLAUDE.md stub in each client root that
# lacks one. Close Claude Code sessions in a home before applying to it.

param([switch] $Apply)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Dossier.Common.ps1"
if (-not (Test-DsrPowerShell7)) { Write-DsrErr 'Sync-Dossier needs PowerShell 7 (pwsh).'; exit 1 }

try { $reg = Read-DsrRegistry } catch { Write-DsrErr $_.Exception.Message; exit 1 }
$templates = Join-Path (Split-Path $PSScriptRoot -Parent) 'templates'
$script:changes = 0

function Step([string] $What, [scriptblock] $Do) {
    $script:changes++
    if ($Apply) { & $Do; Write-Host "  done  $What" } else { Write-Host "  plan  $What" }
}

function Write-TextFile([string] $Path, [string] $Text) {
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if (Test-Path -LiteralPath $Path) { Copy-Item -LiteralPath $Path -Destination ("{0}.{1:yyyyMMdd-HHmmss-fff}.bak" -f $Path, (Get-Date)) -Force }
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Expand-Template([string] $Name, $Entry) {
    $t = [IO.File]::ReadAllText((Join-Path $templates $Name))
    if ($Entry) {
        $t = $t.Replace('{{name}}', $Entry.Name).Replace('{{key}}', $Entry.Key).Replace('{{seat}}', $Entry.Seat)
        $t = $t.Replace('{{home}}', $Entry.Home).Replace('{{expectEmail}}', (Get-DsrExpectText $Entry))
    }
    return $t
}

function Ensure-Dir([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path)) { Step "create $Path" { New-Item -ItemType Directory -Path $Path -Force | Out-Null } }
}

function Sync-Settings($Entry) {
    $file = Join-Path $Entry.Home 'settings.json'
    $managedFile = Join-Path $Entry.Home 'dossier.managed.json'
    $s = [ordered]@{}
    if (Test-Path -LiteralPath $file) { $s = [IO.File]::ReadAllText($file) | ConvertFrom-Json -AsHashtable }
    if ($null -eq $s) { $s = [ordered]@{} }
    $before = $s | ConvertTo-Json -Depth 32
    $old = @{ deny = @(); additionalDirectories = @() }
    if (Test-Path -LiteralPath $managedFile) {
        $m = [IO.File]::ReadAllText($managedFile) | ConvertFrom-Json -AsHashtable
        if ($m) { $old.deny = @($m.deny | Where-Object { $_ }); $old.additionalDirectories = @($m.additionalDirectories | Where-Object { $_ }) }
    }

    $deny = @(Get-DsrDenyRules $reg $Entry)
    $dirs = @(Get-DsrReadableRoots $reg $Entry | ForEach-Object { $_.Replace('\', '/') })

    if (-not $s.Contains('permissions') -or $null -eq $s.permissions) { $s.permissions = [ordered]@{} }
    foreach ($pair in @(@('deny', $deny), @('additionalDirectories', $dirs))) {
        $name = $pair[0]; $want = @($pair[1])
        $cur = @(); if ($s.permissions.Contains($name)) { $cur = @($s.permissions[$name] | Where-Object { $null -ne $_ }) }
        $kept = @($cur | Where-Object { $_ -notin $old[$name] -or $_ -in $want })
        $next = @($kept) + @($want | Where-Object { $_ -notin $kept })
        if ($next.Count) { $s.permissions[$name] = $next } elseif ($s.permissions.Contains($name)) { $s.permissions.Remove($name) }
    }
    if ($s.permissions.Count -eq 0) { $s.Remove('permissions') }

    $cmd = Get-DsrGuardCommand
    if (-not $s.Contains('hooks') -or $null -eq $s.hooks) { $s.hooks = [ordered]@{} }
    $groups = @(); if ($s.hooks.Contains('SessionStart')) { $groups = @($s.hooks.SessionStart | Where-Object { $null -ne $_ }) }
    $has = $false
    foreach ($g in $groups) { foreach ($h in @($g.hooks)) { if ([string]$h.command -like '*dossier-guard.ps1*') { $has = $true; $h.command = $cmd } } }
    if (-not $has) { $groups += [ordered]@{ hooks = @([ordered]@{ type = 'command'; command = $cmd }) } }
    $s.hooks.SessionStart = $groups

    $after = $s | ConvertTo-Json -Depth 32
    $managed = [ordered]@{ deny = $deny; additionalDirectories = $dirs } | ConvertTo-Json -Depth 4
    $managedNow = if (Test-Path -LiteralPath $managedFile) { [IO.File]::ReadAllText($managedFile) } else { '' }
    if ($after -ne $before -or $managed -ne $managedNow) {
        $what = "update $file ($($deny.Count) deny rules, $($dirs.Count) additional dirs, guard hook)"
        Step $what { Write-TextFile $file $after; Write-TextFile $managedFile $managed }
    }
}

function Sync-HomeClaudeMd($Entry) {
    if (-not $reg.PersonalRules) { return }
    if (-not (Test-Path -LiteralPath $reg.PersonalRules)) { Write-Host "  warn  personal rules file $($reg.PersonalRules) doesn't exist; home CLAUDE.md files left alone"; return }
    $file = Join-Path $Entry.Home 'CLAUDE.md'
    $want = $script:DsrManagedMarker + "`n<!-- source: $($reg.PersonalRules) - edit that, then run Sync-Dossier -->`n`n" + [IO.File]::ReadAllText($reg.PersonalRules)
    if (Test-Path -LiteralPath $file) {
        $cur = [IO.File]::ReadAllText($file)
        if ($cur -eq $want) { return }
        if (-not $cur.StartsWith($script:DsrManagedMarker)) { Write-Host "  skip  $file was not written by dossier; move its content into the personal rules or a client CLAUDE.md, then delete it"; return }
    }
    Step "write $file from personal rules" { Write-TextFile $file $want }
}

function Sync-SharedSkills($Entry) {
    if ($Entry.Kind -ne 'client') { return }
    $src = Join-Path (Get-DsrDefaultHome) 'skills'
    $dst = Join-Path $Entry.Home 'skills'
    foreach ($name in $reg.SharedSkills) {
        $s = Join-Path $src $name; $d = Join-Path $dst $name
        if (-not (Test-Path -LiteralPath $s)) { Write-Host "  warn  shared skill $s doesn't exist"; continue }
        if (-not (Test-Path -LiteralPath $d)) { Step "link $d -> $s" { New-Item -ItemType Directory -Path $dst -Force | Out-Null; New-Item -ItemType Junction -Path $d -Target $s | Out-Null } }
    }
    if (Test-Path -LiteralPath $dst) {
        foreach ($i in @(Get-ChildItem -LiteralPath $dst -Force)) {
            if ($i.LinkType -and $i.Name -notin $reg.SharedSkills -and (Test-DsrUnder ([string]@($i.Target)[0]) $src)) {
                Step "unlink $($i.FullName) (no longer in sharedSkills)" { [IO.Directory]::Delete($i.FullName) }
            }
        }
    }
}

function Sync-HubClaudeMd {
    $f = Find-DsrFirm $reg
    $file = Join-Path $f.HubRoot 'CLAUDE.md'
    $cur = if (Test-Path -LiteralPath $file) { [IO.File]::ReadAllText($file) } else { Expand-Template 'hub.CLAUDE.md' $null }
    $rows = @('| Key | Client | Seat | Root | Home | Login | Hub access | Contacts | Status |', '|---|---|---|---|---|---|---|---|---|')
    foreach ($e in @($reg.Entries | Where-Object Kind -eq 'client')) {
        $access = if ($e.Seat -eq 'enterprise') { 'metadata only' } else { 'read code' }
        $rows += "| $($e.Key) | $($e.Name) | $($e.Seat) | ``$($e.Roots[0])`` | ``$($e.Home)`` | $(Get-DsrExpectText $e) | $access | $($e.Contacts -join '; ') | $($e.Status) |"
    }
    $begin = '<!-- BEGIN GENERATED: Sync-Dossier -->'; $end = '<!-- END GENERATED -->'
    $i = $cur.IndexOf($begin); $j = $cur.IndexOf($end)
    if ($i -lt 0 -or $j -lt $i) { Write-Host "  skip  $file has no generated-section markers"; return }
    $next = $cur.Substring(0, $i + $begin.Length) + "`n" + ($rows -join "`n") + "`n" + $cur.Substring($j)
    if (-not (Test-Path -LiteralPath $file) -or $next -ne $cur) { Step "write engagement table in $file" { Write-TextFile $file $next } }
}

Write-Host "Registry: $($reg.Path)$(if (-not $Apply) { '  (dry run; -Apply to make changes)' })"
foreach ($e in $reg.Entries) {
    Write-Host "[$($e.Key)] home $($e.Home)"
    foreach ($r in $e.Roots) { Ensure-Dir $r }
    Ensure-Dir $e.Home
    if (-not $Apply -and -not (Test-Path -LiteralPath $e.Home)) { Write-Host "  plan  (settings and CLAUDE.md for the new home)"; continue }
    Sync-Settings $e
    Sync-HomeClaudeMd $e
    Sync-SharedSkills $e
    if ($e.Kind -eq 'client') {
        $md = Join-Path $e.Roots[0] 'CLAUDE.md'
        if (-not (Test-Path -LiteralPath $md)) { $t = Expand-Template 'client.CLAUDE.md' $e; Step "create $md from template" { Write-TextFile $md $t } }
    }
}
Write-Host '[hub]'
Sync-HubClaudeMd

if ($script:changes -eq 0) { Write-Host 'In sync.' }
elseif (-not $Apply) { Write-Host "$($script:changes) change(s) planned. Run with -Apply." }
foreach ($e in @($reg.Entries | Where-Object Kind -eq 'client')) {
    if ($Apply -and (Read-DsrIdentity $e.Home).Status -ne 'ok') { Write-Host "Next for '$($e.Key)': cc -a $($e.Key), then /login as $(Get-DsrExpectText $e)." }
}
