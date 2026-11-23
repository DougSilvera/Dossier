# Test-Dossier.ps1 - read-only doctor. Exit 0 when nothing is FAIL, 1 otherwise.
#
#   pwsh -File Test-Dossier.ps1
#
# FAIL  a home logged in to the wrong account; a home that links into another home; a CLAUDE.md
#       above a client or product root (it would load into every session there); missing deny
#       rules (including product folders added since the last Sync), shared ask rules or guard
#       hooks; an enterprise root readable from the firm home; one entry's memory or transcripts
#       stored in another entry's home; a client repo forked from a product repo clients can't
#       read in full.
# WARN  a home not logged in yet; missing shared allow rules; folders under the workspace in no
#       registered root; an enterprise client based on a product that doesn't allow enterprise
#       reads; registered repos not cloned yet; a based-on client with no product status; a fork
#       that shares no commit with its product repo; leftover claude-multi-account-kit wiring.

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
        if ((Test-DsrSharesFirmAgents $e) -and $i.Name -eq 'agents' -and (Test-DsrSamePath $t (Get-DsrFirmAgentsDir))) { continue }
        foreach ($h in $homes) { if ($h -ne $e.Home -and (Test-DsrUnder $t $h)) { Report 'FAIL' "$tag $($i.FullName) links into another home ($t)" } }
    }

    $settingsFile = Join-Path $e.Home 'settings.json'
    $s = $null
    if (Test-Path -LiteralPath $settingsFile) { try { $s = [IO.File]::ReadAllText($settingsFile) | ConvertFrom-Json -AsHashtable } catch { Report 'FAIL' "$tag $settingsFile doesn't parse" } }
    $deny = @(); if ($s -and $s.permissions -and $s.permissions.deny) { $deny = @($s.permissions.deny) }
    $missing = @(Get-DsrDenyRules $reg $e | Where-Object { $_ -notin $deny })
    if ($missing.Count) {
        $changed = @(Get-DsrProducts $reg | Where-Object { $pr = ConvertTo-DsrRulePath $_.Roots[0]; @($missing | Where-Object { $_ -like "Read($pr/*" }).Count } | ForEach-Object Key)
        $hint = if ($changed.Count) { " (product $($changed -join ', ') changed on disk since the last Sync; clients can read the new items until Sync-Dossier -Apply)" } else { '' }
        Report 'FAIL' "$tag missing deny rules: $($missing -join ', ')$hint"
    } else { Report 'ok' "$tag deny rules in place" }
    if ($e.SharedPermissions -and ($reg.Permissions.Allow.Count -or $reg.Permissions.Ask.Count)) {
        $ask = @(); if ($s -and $s.permissions -and $s.permissions.ask) { $ask = @($s.permissions.ask) }
        $allow = @(); if ($s -and $s.permissions -and $s.permissions.allow) { $allow = @($s.permissions.allow) }
        $missingAsk = @($reg.Permissions.Ask | Where-Object { $_ -notin $ask })
        $missingAllow = @($reg.Permissions.Allow | Where-Object { $_ -notin $allow })
        if ($missingAsk.Count) { Report 'FAIL' "$tag missing shared ask rules: $($missingAsk -join ', ') (these run without asking until Sync-Dossier -Apply)" }
        if ($missingAllow.Count) { Report 'WARN' "$tag missing shared allow rules: $($missingAllow -join ', ') (Sync-Dossier -Apply)" }
        if (-not $missingAsk.Count -and -not $missingAllow.Count) { Report 'ok' "$tag shared allow and ask rules in place" }
    }
    if (-not (Test-DsrHooked $s 'SessionStart' 'dossier-guard.ps1')) { Report 'FAIL' "$tag guard hook not wired in $settingsFile" }
    if (-not (Test-DsrHooked $s 'PreToolUse' 'dossier-shellguard.ps1')) { Report 'FAIL' "$tag shell guard hook not wired in $settingsFile" }
    elseif (-not (Test-DsrHooked $s 'PreToolUse' "dossier-shellguard.ps1`" -WorkspaceRoot `"$($reg.WorkspaceRoot.Replace('\', '/'))`"")) { Report 'WARN' "$tag shell guard hook doesn't pass -WorkspaceRoot $($reg.WorkspaceRoot), so every delete asks (Sync-Dossier -Apply)" }

    $agents = @(Get-DsrEntryAgents $reg $e)
    $stale = @()
    if ($reg.Agents -and (Test-DsrSharesFirmAgents $e)) {
        $li = Get-Item -LiteralPath (Join-Path $e.Home 'agents') -Force -ErrorAction SilentlyContinue
        if ($li -and $li.LinkType -and (Test-DsrSamePath ([string]@($li.Target)[0]) (Get-DsrFirmAgentsDir))) { Report 'ok' "$tag agents: shared with the firm home" }
        else { Report 'WARN' "$tag agents folder isn't linked to the firm home's (Sync-Dossier -Apply)" }
        $agents = @($agents | Where-Object Role -eq 'lead')
    }
    foreach ($a in @($agents | Where-Object { -not (Test-DsrSharesFirmAgents $e) })) {
        if (-not (Test-Path -LiteralPath $a.Source)) { Report 'WARN' "$tag agent '$($a.Name)' ($($a.Role)) has no file at $($a.Source)"; continue }
        $fm = Get-DsrAgentFrontmatter ([IO.File]::ReadAllText($a.Source))
        if ($fm['name'] -cne $a.Name) { Report 'WARN' "$tag $($a.Source) says name: '$($fm['name'])', not '$($a.Name)'"; continue }
        if ($a.Role -ne 'lead' -and $fm['memory'] -ne 'user') { Report 'WARN' "$tag agent '$($a.Name)' has no 'memory: user', so it keeps no memory in this home" }
        $dst = Join-Path $e.Home "agents\$($a.Name).md"
        if (-not (Test-Path -LiteralPath $dst) -or [IO.File]::ReadAllText($dst) -ne (Get-DsrInstalledAgent $a)) { $stale += $a.Name }
    }
    if ($stale.Count) { Report 'WARN' "$tag agents out of date: $($stale -join ', ') (Sync-Dossier -Apply)" }
    elseif ($agents.Count -and -not (Test-DsrSharesFirmAgents $e)) { Report 'ok' "$tag agents: $(($agents | ForEach-Object { "$($_.Name) ($($_.Role))" }) -join ', ')" }
    $lead = @($agents | Where-Object Role -eq 'lead' | ForEach-Object Name) | Select-Object -First 1
    if ($lead -and (-not $s -or $s.agent -ne $lead)) { Report 'WARN' "$tag main session should run as '$lead', but $settingsFile doesn't set it (Sync-Dossier -Apply)" }
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

foreach ($c in @($reg.Entries | Where-Object Kind -ne 'firm')) {
    $p = Split-Path $c.Roots[0] -Parent
    while ($p) {
        if (Test-Path -LiteralPath (Join-Path $p 'CLAUDE.md')) { Report 'FAIL' "[$($c.Key)] $p\CLAUDE.md is above the $($c.Kind) root and loads into every session there" }
        $parent = Split-Path $p -Parent
        if (-not $parent -or $parent -eq $p) { break }
        $p = $parent
    }
}

foreach ($p in (Get-DsrProducts $reg)) {
    foreach ($c in @($reg.Entries | Where-Object { Test-DsrProductBlocked $_ $p })) {
        Report 'WARN' "[$($c.Key)] is based on product '$($p.Key)', but it is an enterprise seat and the product doesn't set enterpriseRead; it has no access"
    }
}

foreach ($c in @($reg.Entries | Where-Object { $_.Kind -eq 'client' -and $_.BasedOn.Count })) {
    foreach ($r in @($c.Repos | Where-Object From)) {
        $p = Find-DsrEntry $reg $r.From.Product
        if (-not (Test-DsrRepoClientReadable $p $r.From.Repo)) {
            Report 'FAIL' "[$($c.Key)] repo '$($r.Dir)' is a fork of '$($p.Key)/$($r.From.Repo)', but clientRead doesn't cover all of that repo; a fork carries its whole history to the client"
        }
    }
    $file = Get-DsrStatusFile $c
    if (-not (Test-Path -LiteralPath $file)) { Report 'WARN' "[$($c.Key)] no product status yet; run Sync-Dossier -Apply$(if ($c.Seat -eq 'enterprise') { ' from your own terminal' })"; continue }
    try { $st = [IO.File]::ReadAllText($file) | ConvertFrom-Json } catch { Report 'WARN' "[$($c.Key)] $file doesn't parse; run Sync-Dossier -Apply"; continue }
    foreach ($f in @($st.products | ForEach-Object { @($_.forks) } | Where-Object { $_ -and $_.state -eq 'no-shared-commit' })) {
        Report 'WARN' "[$($c.Key)] repo '$($f.dir)' is registered as a fork of '$($f.productRepo)', but shares no commit with it (a squashed import, or the wrong repo)"
    }
}

foreach ($o in @($reg.Entries | Where-Object Kind -ne 'firm')) {
    $missing = @($o.Repos | Where-Object { -not (Test-Path -LiteralPath (Join-Path (Join-Path $o.Roots[0] $_.Dir) '.git')) } | ForEach-Object Dir)
    if ($missing.Count) { Report 'WARN' "[$($o.Key)] repos not cloned yet: $($missing -join ', ') (Import-Dossier -Key $($o.Key) -Apply)" }
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
