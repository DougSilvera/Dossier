# Sync-Dossier.ps1 - make the machine match ~/.dossier.json. Shows the plan; -Apply does it.
#
#   pwsh -File Sync-Dossier.ps1           # dry run
#   pwsh -File Sync-Dossier.ps1 -Apply
#
# For every entry it ensures:
#   - its roots and home exist
#   - its home's settings.json has the dossier guard SessionStart hook, the shell guard PreToolUse
#     hook for Bash and PowerShell, Read/Edit deny rules for what it must not see
#     (Get-DsrDeniedPaths), and additionalDirectories (Get-DsrReadableRoots). A client based on a
#     product gets Read denied on everything in the product outside clientRead, listed from
#     disk, so rerun Sync after a product's folders change. Also the registry's shared
#     permissions.allow and permissions.ask rules, unless the entry sets sharedPermissions: false.
#     Only rules this script added before (tracked in <home>\dossier.managed.json) are ever
#     removed; a shared rule the home already had stays the user's.
#   - its home's CLAUDE.md is the personal rules file, if the registry names one. A CLAUDE.md
#     this script didn't write is left alone and reported.
#   - client and product homes link the registry's sharedSkills from ~/.claude\skills, and
#     nothing else.
# Plus the hub CLAUDE.md (generated section only) and a CLAUDE.md stub in each client and product
# root that lacks one. Close Claude Code sessions in a home before applying to it.
#
# Inside a Claude session (Test-DsrInsideClaude) nothing is written into an enterprise-seat
# entry's home or root: those steps print as skipped, and Sync exits 2. Run it from your own
# terminal to apply them.

param([switch] $Apply)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Dossier.Common.ps1"
if (-not (Test-DsrPowerShell7)) { Write-DsrErr 'Sync-Dossier needs PowerShell 7 (pwsh).'; exit 1 }

try { $reg = Read-DsrRegistry } catch { Write-DsrErr $_.Exception.Message; exit 1 }
$templates = Join-Path (Split-Path $PSScriptRoot -Parent) 'templates'
$script:changes = 0
$script:inside = Test-DsrInsideClaude
$script:blocked = $false
$script:skipped = @()

function Step([string] $What, [scriptblock] $Do) {
    if ($script:blocked) { $script:skipped += $script:entryKey; Write-Host "  skip  $What (enterprise seat, Claude session)"; return }
    $script:changes++
    if ($Apply) { & $Do; Write-Host "  done  $What" } else { Write-Host "  plan  $What" }
}

function Write-TextFile([string] $Path, [string] $Text, [switch] $NoBackup) {
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if (-not $NoBackup -and (Test-Path -LiteralPath $Path)) { Copy-Item -LiteralPath $Path -Destination ("{0}.{1:yyyyMMdd-HHmmss-fff}.bak" -f $Path, (Get-Date)) -Force }
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Expand-Template([string] $Name, $Entry) {
    $t = [IO.File]::ReadAllText((Join-Path $templates $Name))
    if ($Entry) {
        $t = $t.Replace('{{name}}', $Entry.Name).Replace('{{key}}', $Entry.Key).Replace('{{seat}}', $Entry.Seat)
        $t = $t.Replace('{{home}}', $Entry.Home).Replace('{{expectEmail}}', (Get-DsrExpectText $Entry))
        $t = $t.Replace('{{products}}', ($script:ProductsBegin + "`n" + (Get-ClientProductsSection $Entry) + $script:ProductsEnd + "`n`n"))
    }
    return $t
}

$script:ProductsBegin = '<!-- BEGIN GENERATED: Sync-Dossier products -->'
$script:ProductsEnd = '<!-- END GENERATED: Sync-Dossier products -->'

function Get-ClientProductsSection($Entry) {
    $based = @(Get-DsrProducts $reg | Where-Object { $_.Key -cin $Entry.BasedOn })
    if (-not $based.Count) { return '' }
    $list = ($based | ForEach-Object {
        $p = $_
        $paths = if (Test-DsrProductReadable $Entry $p) { (Get-DsrClientReadPaths $p | ForEach-Object { "``$_``" }) -join ', ' } else { 'nothing readable from this home yet' }
        $forks = @($Entry.Repos | Where-Object { $_.From -and $_.From.Product -ceq $p.Key } | ForEach-Object { "`n  - Repo ``$($_.Dir)`` is a fork of ``$(Join-Path $p.Roots[0] $_.From.Repo)``" })
        "- $($p.Name): $paths$($forks -join '')"
    }) -join "`n"
    return "## Products`n`nBuilt on these firm products. Only the paths listed are readable from this home, and none are editable. The session-start note and the dossier-product skill say how far each fork is behind.`n`n$list`n`nIf something here looks worth promoting back into a product, describe it to the user as a candidate and stop. Never copy this client's code, memory or tickets toward a product.`n"
}

function Sync-ClientProductsMd($Entry) {
    $file = Join-Path $Entry.Roots[0] 'CLAUDE.md'
    if (-not (Test-Path -LiteralPath $file)) { return }
    $cur = [IO.File]::ReadAllText($file)
    $i = $cur.IndexOf($script:ProductsBegin); $j = $cur.IndexOf($script:ProductsEnd)
    if ($i -lt 0 -or $j -lt $i) {
        if ($Entry.BasedOn.Count) { Write-Host "  note  $file has no products markers; add $($script:ProductsBegin) and $($script:ProductsEnd) to keep its Products section current" }
        return
    }
    $next = $cur.Substring(0, $i + $script:ProductsBegin.Length) + "`n" + (Get-ClientProductsSection $Entry) + $cur.Substring($j)
    if ($next -ne $cur) { Step "write Products section in $file" { Write-TextFile $file $next } }
}

$script:status = @{}
function Sync-ProductStatus($Entry) {
    $file = Get-DsrStatusFile $Entry
    if (-not $Entry.BasedOn.Count) {
        if (Test-Path -LiteralPath $file) { Step "remove $file (no longer based on a product)" { Remove-Item -LiteralPath $file } }
        return
    }
    # Working this out reads the client's repos; for an enterprise seat that happens only outside
    # a Claude session.
    if ($Entry.Seat -eq 'enterprise' -and $script:inside) { $script:skipped += $Entry.Key; Write-Host "  skip  product status for '$($Entry.Key)': an enterprise client's repos are read only from your own terminal"; return }
    $data = @(Get-DsrProductStatus $reg $Entry)
    $script:status[$Entry.Key] = $data
    $text = [ordered]@{ syncedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm'); products = $data } | ConvertTo-Json -Depth 10
    $stamp = '"syncedAt": "[^"]*"'
    if ((Test-Path -LiteralPath $file) -and ([IO.File]::ReadAllText($file) -replace $stamp, '') -eq ($text -replace $stamp, '')) { return }
    Step "write $file (product status)" { Write-TextFile $file $text -NoBackup }
}

function Sync-Agents($Entry) {
    if (Test-DsrSharesFirmAgents $Entry) { Sync-AgentsLink $Entry; return }
    $dir = Join-Path $Entry.Home 'agents'
    $want = @(Get-DsrEntryAgents $reg $Entry)
    $keep = @()
    foreach ($a in $want) {
        if (-not (Test-Path -LiteralPath $a.Source)) { Write-Host "  warn  agent '$($a.Name)' for role $($a.Role) has no file at $($a.Source)"; continue }
        $fm = Get-DsrAgentFrontmatter ([IO.File]::ReadAllText($a.Source))
        if ($fm['name'] -cne $a.Name) { Write-Host "  warn  $($a.Source) says name: '$($fm['name'])', but the registry calls it '$($a.Name)'; skipped"; continue }
        $dst = Join-Path $dir "$($a.Name).md"; $keep += $dst
        $text = Get-DsrInstalledAgent $a
        if (-not (Test-Path -LiteralPath $dst) -or [IO.File]::ReadAllText($dst) -ne $text) { Step "write $dst ($($a.Role))" { Write-TextFile $dst $text -NoBackup } }
    }
    if (Test-Path -LiteralPath $dir) {
        foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.md' -File)) {
            if ($f.FullName -notin $keep -and [IO.File]::ReadAllText($f.FullName).Contains($script:DsrAgentMarker)) {
                Step "remove $($f.FullName) (no longer in this home's roles)" { Remove-Item -LiteralPath $f.FullName }
            }
        }
    }
}

function Sync-AgentsLink($Entry) {
    $dir = Join-Path $Entry.Home 'agents'
    $target = Get-DsrFirmAgentsDir
    $item = Get-Item -LiteralPath $dir -Force -ErrorAction SilentlyContinue
    $isOurLink = $item -and $item.LinkType -and (Test-DsrSamePath ([string]@($item.Target)[0]) $target)
    if (-not $reg.Agents) {
        if ($isOurLink) { Step "unlink $dir (no agents in the registry)" { [IO.Directory]::Delete($dir) } }
        return
    }
    if ($isOurLink) { return }
    if ($item -and $item.LinkType) { Write-Host "  warn  $dir links to $(@($item.Target)[0]), not $target; left alone"; return }
    if ($item) {
        $files = @(Get-ChildItem -LiteralPath $dir -Force)
        $own = @($files | Where-Object { $_.PSIsContainer -or -not [IO.File]::ReadAllText($_.FullName).Contains($script:DsrAgentMarker) })
        if ($own.Count) { Write-Host "  warn  $dir has agents of its own ($(($own | ForEach-Object Name) -join ', ')); move them to your roster, then rerun Sync to link it"; return }
        Step "replace $dir with a link to $target" {
            foreach ($f in $files) { Remove-Item -LiteralPath $f.FullName }
            [IO.Directory]::Delete($dir)
            New-Item -ItemType Directory -Path $target -Force | Out-Null
            New-Item -ItemType Junction -Path $dir -Target $target | Out-Null
        }
        return
    }
    Step "link $dir -> $target" {
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        New-Item -ItemType Junction -Path $dir -Target $target | Out-Null
    }
}

$script:SkillName = 'dossier-product'
function Sync-ProductSkill($Entry) {
    $src = Join-Path (Split-Path $PSScriptRoot -Parent) "skills\$($script:SkillName)\SKILL.md"
    $dir = Join-Path $Entry.Home "skills\$($script:SkillName)"
    $dst = Join-Path $dir 'SKILL.md'
    $want = [IO.File]::ReadAllText($src)
    if ($Entry.BasedOn.Count) {
        if (-not (Test-Path -LiteralPath $dst) -or [IO.File]::ReadAllText($dst) -ne $want) { Step "write $dst" { Write-TextFile $dst $want -NoBackup } }
    } elseif ((Test-Path -LiteralPath $dst) -and [IO.File]::ReadAllText($dst).Contains($script:DsrManagedMarker)) {
        Step "remove $dir (no longer based on a product)" { Remove-Item -LiteralPath $dir -Recurse -Force }
    }
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
    $old = @{ deny = @(); additionalDirectories = @(); allow = @(); ask = @() }
    if (Test-Path -LiteralPath $managedFile) {
        $m = [IO.File]::ReadAllText($managedFile) | ConvertFrom-Json -AsHashtable
        if ($m) { foreach ($k in @($old.Keys)) { $old[$k] = @($m[$k] | Where-Object { $_ }) } }
    }

    $deny = @(Get-DsrDenyRules $reg $Entry)
    $dirs = @(Get-DsrReadableRoots $reg $Entry | ForEach-Object { $_.Replace('\', '/') })
    $allow = @(); $ask = @()
    if ($Entry.SharedPermissions) { $allow = @($reg.Permissions.Allow); $ask = @($reg.Permissions.Ask) }

    # The lead agent runs as the home's main session through the 'agent' setting. Only an
    # 'agent' value this script set is ever removed.
    $lead = @(Get-DsrEntryAgents $reg $Entry | Where-Object Role -eq 'lead' | ForEach-Object Name) | Select-Object -First 1
    $oldAgent = if (Test-Path -LiteralPath $managedFile) { [string](([IO.File]::ReadAllText($managedFile) | ConvertFrom-Json -AsHashtable).agent) } else { '' }
    if ($lead) { $s.agent = $lead }
    elseif ($oldAgent -and $s.Contains('agent') -and $s.agent -eq $oldAgent) { $s.Remove('agent') }

    if (-not $s.Contains('permissions') -or $null -eq $s.permissions) { $s.permissions = [ordered]@{} }
    $claimed = @{}
    foreach ($pair in @(@('deny', $deny), @('additionalDirectories', $dirs), @('allow', $allow), @('ask', $ask))) {
        $name = $pair[0]; $want = @($pair[1])
        $cur = @(); if ($s.permissions.Contains($name)) { $cur = @($s.permissions[$name] | Where-Object { $null -ne $_ }) }
        # A shared rule the home already had by hand stays the user's, so Sync never removes it.
        $claimed[$name] = @($want | Where-Object { $_ -in $old[$name] -or $_ -notin $cur })
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

    $cmd = (Get-DsrShellGuardCommand) + ' -WorkspaceRoot "' + $reg.WorkspaceRoot.Replace('\', '/') + '"'
    $groups = @(); if ($s.hooks.Contains('PreToolUse')) { $groups = @($s.hooks.PreToolUse | Where-Object { $null -ne $_ }) }
    $has = $false
    foreach ($g in $groups) { foreach ($h in @($g.hooks)) { if ([string]$h.command -like '*dossier-shellguard.ps1*') { $has = $true; $h.command = $cmd; $g.matcher = 'Bash|PowerShell' } } }
    if (-not $has) { $groups += [ordered]@{ matcher = 'Bash|PowerShell'; hooks = @([ordered]@{ type = 'command'; command = $cmd }) } }
    $s.hooks.PreToolUse = $groups

    $after = $s | ConvertTo-Json -Depth 32
    $m = [ordered]@{ deny = $deny; additionalDirectories = $dirs }
    foreach ($k in 'allow', 'ask') { if ($claimed[$k].Count) { $m[$k] = $claimed[$k] } }
    if ($lead) { $m.agent = $lead }
    $managed = $m | ConvertTo-Json -Depth 4
    $managedNow = if (Test-Path -LiteralPath $managedFile) { [IO.File]::ReadAllText($managedFile) } else { '' }
    if ($after -ne $before -or $managed -ne $managedNow) {
        $what = "update $file ($($deny.Count) deny rules, $($dirs.Count) additional dirs, $(if ($allow.Count -or $ask.Count) { "$($allow.Count) allow and $($ask.Count) ask rules, " })guard hooks$(if ($lead) { ", main agent $lead" }))"
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
    if ($Entry.Kind -eq 'firm') { return }
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
    $products = @(Get-DsrProducts $reg)
    if ($products.Count) {
        $rows += @('', '## Products', '', 'Firm-owned products, each with its own home. The hub reads and edits them and reads their memory. Clients based on one read only its clientRead paths, and never edit it.', '')
        $rows += @('| Key | Product | Root | Home | Login | Client read | Enterprise read | Based on by | Status |', '|---|---|---|---|---|---|---|---|---|')
        foreach ($p in $products) {
            $users = @($reg.Entries | Where-Object { $p.Key -cin $_.BasedOn } | ForEach-Object {
                $c = $_
                if (Test-DsrProductBlocked $c $p) { return "$($c.Key) (blocked: enterprise)" }
                $known = @($script:status[$c.Key] | Where-Object { $_.key -ceq $p.Key } | ForEach-Object { $_.forks })
                $forks = @($c.Repos | Where-Object { $_.From -and $_.From.Product -ceq $p.Key } | ForEach-Object {
                    $f = $_; $s = $known | Where-Object { $_.dir -ceq $f.Dir } | Select-Object -First 1
                    # The hub keeps enterprise clients to metadata: which product repo, not where they are on it.
                    if ($c.Seat -eq 'enterprise' -or -not $s) { "``$($f.Dir)`` from ``$($f.From.Repo)``" }
                    elseif ($s.state -eq 'ok') { "``$($f.Dir)`` @ $($s.base.Substring(0, 7)), $($s.behind) behind" }
                    else { "``$($f.Dir)`` $($s.state)" }
                })
                if ($forks.Count) { "$($c.Key) ($($forks -join '; '))" } else { $c.Key }
            })
            $read = if ($p.ClientRead.Count) { ($p.ClientRead | ForEach-Object { "``$_``" }) -join ', ' } else { 'nothing' }
            $rows += "| $($p.Key) | $($p.Name) | ``$($p.Roots[0])`` | ``$($p.Home)`` | $(Get-DsrExpectText $p) | $read | $(if ($p.EnterpriseRead) { 'yes' } else { 'no' }) | $($users -join ', ') | $($p.Status) |"
        }
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
    $script:entryKey = $e.Key
    $script:blocked = $e.Seat -eq 'enterprise' -and $script:inside
    foreach ($r in $e.Roots) { Ensure-Dir $r }
    Ensure-Dir $e.Home
    if ((-not $Apply -or $script:blocked) -and -not (Test-Path -LiteralPath $e.Home)) { Write-Host "  $(if ($script:blocked) { 'skip' } else { 'plan' })  (settings and CLAUDE.md for the new home)"; continue }
    Sync-Settings $e
    Sync-HomeClaudeMd $e
    Sync-SharedSkills $e
    Sync-Agents $e
    if ($e.Kind -ne 'firm') {
        $md = Join-Path $e.Roots[0] 'CLAUDE.md'
        if (-not (Test-Path -LiteralPath $md)) { $t = Expand-Template "$($e.Kind).CLAUDE.md" $e; Step "create $md from template" { Write-TextFile $md $t } }
    }
    if ($e.Kind -eq 'client') {
        Sync-ClientProductsMd $e
        Sync-ProductStatus $e
        Sync-ProductSkill $e
    }
    if ($e.Kind -eq 'product') {
        foreach ($c in @($reg.Entries | Where-Object { Test-DsrProductBlocked $_ $e })) {
            Write-Host "  warn  '$($c.Key)' is based on '$($e.Key)', but it is an enterprise seat and the product doesn't set enterpriseRead; it gets no access"
        }
    }
}
$script:blocked = $false
Write-Host '[hub]'
Sync-HubClaudeMd

if ($script:changes -eq 0 -and -not $script:skipped.Count) { Write-Host 'In sync.' }
elseif ($script:changes -and -not $Apply) { Write-Host "$($script:changes) change(s) planned. Run with -Apply." }
foreach ($e in @($reg.Entries | Where-Object Kind -ne 'firm')) {
    if ($Apply -and (Read-DsrIdentity $e.Home).Status -ne 'ok') { Write-Host "Next for '$($e.Key)': cc -a $($e.Key), then /login as $(Get-DsrExpectText $e)." }
}
if ($script:skipped.Count) {
    Write-Host "$($script:skipped.Count) change(s) skipped for $((@($script:skipped | Select-Object -Unique)) -join ', '): enterprise homes aren't written from a Claude session. Run Sync-Dossier from your own terminal."
    exit 2
}
