# Test-Dossier.ps1 - read-only doctor. Exit 0 when nothing is FAIL, 1 otherwise.
#
#   pwsh -File Test-Dossier.ps1
#
# FAIL  a home logged in to the wrong account; a home that links into another home; a CLAUDE.md
#       above a client or template root (it would load into every session there); missing deny
#       rules (including a client that could edit a template) or guard hooks; an enterprise root
#       readable from the firm home; one entry's or template's memory or transcripts stored in
#       another home.
# WARN  a home not logged in yet; folders under the workspace in no registered root; an
#       enterprise client based on a template that doesn't allow enterprise reads; registered
#       repos not cloned yet; leftover claude-multi-account-kit wiring.

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
    if (-not (Test-DsrHooked $s 'SessionStart' 'dossier-guard.ps1')) { Report 'FAIL' "$tag guard hook not wired in $settingsFile" }
    if (-not (Test-DsrHooked $s 'PreToolUse' 'dossier-shellguard.ps1')) { Report 'FAIL' "$tag shell guard hook not wired in $settingsFile" }
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
        $tplRoots = @($reg.Templates | ForEach-Object Root)
        $slugs = @(
            foreach ($o in $reg.Entries) { foreach ($r in @($o.Roots) + @($o.FormerRoots)) { if ($r -notin $tplRoots) { [pscustomobject]@{ Key = $o.Key; Home = $o.Home; Slug = (Get-DsrProjectSlug $r) } } } }
            foreach ($t in $reg.Templates) { [pscustomobject]@{ Key = "template $($t.Key)"; Home = (Get-DsrDefaultHome); Slug = (Get-DsrProjectSlug $t.Root) } }
        ) | Sort-Object { $_.Slug.Length } -Descending
        $wrong = @{}
        foreach ($d in @(Get-ChildItem -LiteralPath $proj -Directory -Force | ForEach-Object Name)) {
            $hit = $slugs | Where-Object { $d -ieq $_.Slug -or $d.StartsWith("$($_.Slug)-", [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
            if ($hit -and $hit.Home -ne $e.Home) { $wrong[$hit.Key] = 1 + [int]$wrong[$hit.Key] }
        }
        foreach ($k in $wrong.Keys) { Report 'FAIL' "$tag holds $($wrong[$k]) project folder(s) for '$k': its memory or transcripts are in the wrong home" }
    }
}

$aboveChecks = @($reg.Entries | Where-Object Kind -eq 'client' | ForEach-Object { @{ Tag = $_.Key; Root = $_.Roots[0]; What = 'client' } }) +
    @($reg.Templates | ForEach-Object { @{ Tag = "template $($_.Key)"; Root = $_.Root; What = 'template' } })
foreach ($c in $aboveChecks) {
    $p = Split-Path $c.Root -Parent
    while ($p) {
        if (Test-Path -LiteralPath (Join-Path $p 'CLAUDE.md')) { Report 'FAIL' "[$($c.Tag)] $p\CLAUDE.md is above the $($c.What) root and loads into every session there" }
        $parent = Split-Path $p -Parent
        if (-not $parent -or $parent -eq $p) { break }
        $p = $parent
    }
}

foreach ($t in $reg.Templates) {
    foreach ($c in @($reg.Entries | Where-Object { $t.Key -cin $_.BasedOn -and -not (Test-DsrTemplateReadable $_ $t) })) {
        Report 'WARN' "[$($c.Key)] is based on template '$($t.Key)', but it is an enterprise seat and the template doesn't set enterpriseRead; it has no access"
    }
}

$repoOwners = @($reg.Entries | Where-Object Kind -eq 'client' | ForEach-Object { @{ Tag = $_.Key; Root = $_.Roots[0]; Repos = $_.Repos } }) +
    @($reg.Templates | ForEach-Object { @{ Tag = $_.Key; Root = $_.Root; Repos = $_.Repos } })
foreach ($o in $repoOwners) {
    $missing = @($o.Repos | Where-Object { -not (Test-Path -LiteralPath (Join-Path (Join-Path $o.Root $_.Dir) '.git')) } | ForEach-Object Dir)
    if ($missing.Count) { Report 'WARN' "[$($o.Tag)] repos not cloned yet: $($missing -join ', ') (Import-Dossier -Key $($o.Tag) -Apply)" }
}

if (Test-Path -LiteralPath $reg.WorkspaceRoot) {
    $roots = @($reg.Entries | ForEach-Object { $_.Roots })
    $loose = @()
    $scan = [Collections.Generic.Queue[string]]::new(); $scan.Enqueue($reg.WorkspaceRoot)
    while ($scan.Count) {
        foreach ($i in @(Get-ChildItem -LiteralPath $scan.Dequeue() -Force -ErrorAction SilentlyContinue)) {
            $x = $i.FullName
            if (@($roots | Where-Object { Test-DsrUnder $x $_ }).Count) { continue }
            if ($i.PSIsContainer -and -not $i.LinkType -and @($roots | Where-Object { Test-DsrUnder $_ $x }).Count) { $scan.Enqueue($x); continue }
            $loose += [IO.Path]::GetRelativePath($reg.WorkspaceRoot, $x)
        }
    }
    if ($loose.Count) { Report 'WARN' "$($loose.Count) item(s) under $($reg.WorkspaceRoot) in no registered root (run in the firm home): $(($loose | Select-Object -First 12) -join ', ')$(if ($loose.Count -gt 12) { ', ...' })" }
}

$kit = Join-Path (Get-DsrUserHome) '.claude-accounts.json'
if (Test-Path -LiteralPath $kit) { Report 'WARN' "$kit (claude-multi-account-kit) still exists; its cc copies ~/.claude settings and CLAUDE.md into other homes. Retire it." }

if ($script:fails) { Write-Host "$($script:fails) FAIL"; exit 1 }
Write-Host 'No FAIL.'
exit 0
