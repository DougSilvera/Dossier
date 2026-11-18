# Test-Dossier.ps1 - read-only doctor. Exit 0 when nothing is FAIL, 1 otherwise.
#
#   pwsh -File Test-Dossier.ps1
#
# FAIL  a home logged in to the wrong account; a home that links into another home; a CLAUDE.md
#       above a client root (it would load into every session there); missing deny rules or
#       guard hook; an enterprise root readable from the firm home; one entry's memory or transcripts
#       stored in another entry's home.
# WARN  a home not logged in yet; folders under the workspace in no registered root; leftover
#       claude-multi-account-kit wiring.

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Dossier.Common.ps1"
if (-not (Test-DsrPowerShell7)) { Write-DsrErr 'Test-Dossier needs PowerShell 7 (pwsh).'; exit 1 }

$script:fails = 0
function Report([string] $Level, [string] $Text) {
    if ($Level -eq 'FAIL') { $script:fails++ }
    Write-Host ('{0,-5} {1}' -f $Level, $Text)
}

try { $reg = Read-DsrRegistry } catch { Report 'FAIL' "registry: $($_.Exception.Message)"; exit 1 }
Report 'ok' "registry $($reg.Path): $($reg.Entries.Count) entries"
$homes = @($reg.Entries | ForEach-Object Home)

foreach ($e in $reg.Entries) {
    $tag = "[$($e.Key)]"
    if (-not (Test-Path -LiteralPath $e.Home)) { Report 'FAIL' "$tag home $($e.Home) doesn't exist (Sync-Dossier -Apply)"; continue }

    $id = Read-DsrIdentity $e.Home
    $match = Test-DsrIdentityMatches $e $id
    if ($id.Status -ne 'ok') { Report 'WARN' "$tag not logged in ($($id.Status)); cc -a $($e.Key), then /login as $(Get-DsrExpectText $e)" }
    elseif ($match -eq $false) { Report 'FAIL' "$tag logged in as $($id.Email) ($($id.OrgName)), expected $(Get-DsrExpectText $e)" }
    elseif ($null -eq $match) { Report 'WARN' "$tag logged in as $($id.Email); no expectEmail/expectOrg, so a wrong login can't be detected" }
    else { Report 'ok' "$tag logged in as $($id.Email) ($($id.OrgName))" }

    foreach ($i in @(Get-ChildItem -LiteralPath $e.Home -Force -ErrorAction SilentlyContinue)) {
        if (-not $i.LinkType) { continue }
        $t = [string]@($i.Target)[0]
        foreach ($h in $homes) { if ($h -ne $e.Home -and (Test-DsrUnder $t $h)) { Report 'FAIL' "$tag $($i.FullName) links into another home ($t)" } }
    }

    $settingsFile = Join-Path $e.Home 'settings.json'
    $s = $null
    if (Test-Path -LiteralPath $settingsFile) { try { $s = [IO.File]::ReadAllText($settingsFile) | ConvertFrom-Json -AsHashtable } catch { Report 'FAIL' "$tag $settingsFile doesn't parse" } }
    $deny = @(); if ($s -and $s.permissions -and $s.permissions.deny) { $deny = @($s.permissions.deny) }
    $missing = @(Get-DsrDenyRules $reg $e | Where-Object { $_ -notin $deny })
    if ($missing.Count) { Report 'FAIL' "$tag missing deny rules: $($missing -join ', ')" } else { Report 'ok' "$tag deny rules in place" }
    $hooked = $false
    if ($s -and $s.hooks -and $s.hooks.SessionStart) { foreach ($g in @($s.hooks.SessionStart)) { foreach ($h in @($g.hooks)) { if ([string]$h.command -like '*dossier-guard.ps1*') { $hooked = $true } } } }
    if (-not $hooked) { Report 'FAIL' "$tag guard hook not wired in $settingsFile" }
    if ($e.Kind -eq 'firm' -and $s -and $s.permissions -and $s.permissions.additionalDirectories) {
        foreach ($d in @($s.permissions.additionalDirectories)) {
            foreach ($c in @($reg.Entries | Where-Object Seat -eq 'enterprise')) {
                if ((Test-DsrUnder $d $c.Roots[0]) -or (Test-DsrUnder $c.Roots[0] $d)) { Report 'FAIL' "[$($e.Key)] additionalDirectories includes $d, which covers enterprise client '$($c.Key)'" }
            }
        }
    }

    # Memory and transcripts are filed under <home>\projects\<slug of the folder>.
    $proj = Join-Path $e.Home 'projects'
    if (Test-Path -LiteralPath $proj) {
        # Slugs lose the separators, so a folder belongs to the entry with the longest matching
        # slug: acme-labs' folders also start with acme's slug.
        $slugs = @(foreach ($o in $reg.Entries) { foreach ($r in @($o.Roots) + @($o.FormerRoots)) { [pscustomobject]@{ Key = $o.Key; Slug = (Get-DsrProjectSlug $r) } } }) |
            Sort-Object { $_.Slug.Length } -Descending
        $wrong = @{}
        foreach ($d in @(Get-ChildItem -LiteralPath $proj -Directory -Force | ForEach-Object Name)) {
            $hit = $slugs | Where-Object { $d -ieq $_.Slug -or $d.StartsWith("$($_.Slug)-", [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
            if ($hit -and $hit.Key -ne $e.Key) { $wrong[$hit.Key] = 1 + [int]$wrong[$hit.Key] }
        }
        foreach ($k in $wrong.Keys) { Report 'FAIL' "$tag holds $($wrong[$k]) project folder(s) for '$k': its memory or transcripts are in the wrong home" }
    }
}

foreach ($c in @($reg.Entries | Where-Object Kind -eq 'client')) {
    $p = Split-Path $c.Roots[0] -Parent
    while ($p) {
        if (Test-Path -LiteralPath (Join-Path $p 'CLAUDE.md')) { Report 'FAIL' "[$($c.Key)] $p\CLAUDE.md is above the client root and loads into every session there" }
        $parent = Split-Path $p -Parent
        if (-not $parent -or $parent -eq $p) { break }
        $p = $parent
    }
}

if (Test-Path -LiteralPath $reg.WorkspaceRoot) {
    $roots = @($reg.Entries | ForEach-Object { $_.Roots })
    $loose = @(Get-ChildItem -LiteralPath $reg.WorkspaceRoot -Force | Where-Object {
        $x = $_.FullName
        -not @($roots | Where-Object { (Test-DsrUnder $x $_) -or (Test-DsrUnder $_ $x) }).Count
    } | ForEach-Object Name)
    if ($loose.Count) { Report 'WARN' "$($loose.Count) item(s) under $($reg.WorkspaceRoot) in no registered root (run in the firm home): $(($loose | Select-Object -First 12) -join ', ')$(if ($loose.Count -gt 12) { ', ...' })" }
}

$kit = Join-Path (Get-DsrUserHome) '.claude-accounts.json'
if (Test-Path -LiteralPath $kit) { Report 'WARN' "$kit (claude-multi-account-kit) still exists; its cc copies ~/.claude settings and CLAUDE.md into other homes. Retire it." }

if ($script:fails) { Write-Host "$($script:fails) FAIL"; exit 1 }
Write-Host 'No FAIL.'
exit 0
