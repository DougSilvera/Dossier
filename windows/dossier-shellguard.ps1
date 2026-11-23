# dossier-shellguard.ps1 - PreToolUse hook for Bash and PowerShell: holds shell commands to the
# home's own Read/Edit deny rules. Sync-Dossier.ps1 wires it into every home's settings.json.
#
# Claude Code's sandbox would enforce those rules on shell commands at the OS level, but it doesn't
# run on native Windows, and without it deny rules only cover the file tools and a few recognized
# Bash commands (cat, head, tail, sed, tee). This is a tripwire for honest mistakes, not a
# boundary: it reads the command text, so a path built at run time, a script that opens files
# itself, or a link into a denied folder gets past it. It denies a command that
#   - names a denied path, absolute or relative to the session's folder, in Windows, Git Bash or
#     WSL form, through ~, $HOME, $env:USERPROFILE or %USERPROFILE%
#   - has a wildcard whose fixed part is a folder holding a denied path
#   - searches or copies recursively from a folder holding a denied path
# A path with an Edit rule and no Read rule (a product path a client may read) only stops commands
# that look like writes and name it, or run from inside it.
# A delete that passes those checks runs without a prompt when every path it names is inside
# -WorkspaceRoot. One that names a path outside it, a variable, command output or nothing at all
# (xargs, a pipe into Remove-Item) asks the user instead.
# Its own failures let the command through, with a note, except a delete, which asks.

param([string] $WorkspaceRoot)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Dossier.Common.ps1"

function Out-Deny([string] $Reason) {
    $o = [ordered]@{ hookSpecificOutput = [ordered]@{ hookEventName = 'PreToolUse'; permissionDecision = 'deny'; permissionDecisionReason = $Reason } }
    [Console]::Out.Write(($o | ConvertTo-Json -Depth 5 -Compress))
    exit 0
}

function Out-Ask([string] $Reason) {
    $o = [ordered]@{ hookSpecificOutput = [ordered]@{ hookEventName = 'PreToolUse'; permissionDecision = 'ask'; permissionDecisionReason = $Reason } }
    [Console]::Out.Write(($o | ConvertTo-Json -Depth 5 -Compress))
    exit 0
}

function Expand-HomeVars([string] $Text) {
    $userHome = Get-DsrUserHome
    foreach ($v in '${env:USERPROFILE}', '$env:USERPROFILE', '${HOME}', '$HOME', '%USERPROFILE%') {
        $Text = [regex]::Replace($Text, [regex]::Escape($v) + '(?![A-Za-z0-9_])', $userHome.Replace('$', '$$'), 'IgnoreCase')
    }
    return $Text
}

function ConvertTo-PathText([string] $Text) {
    # One spelling for every path form: backslashes, single separators, drive letters.
    $Text = $Text.Replace('/', '\') -replace '\\{2,}', '\'
    return [regex]::Replace($Text, '(?<![A-Za-z0-9:._~-])\\(?:mnt\\)?([A-Za-z])(?=\\|$|[\s"''`;|&)])', '$1:')
}

$deleteVerb = '(?i)^(.*[\\/])?(rm|rmdir|del|erase|rd|ri|Remove-Item|unlink|shred)(\.exe)?$|(\.|::)Delete$'
$cdVerb = '(?i)^(cd|chdir|Set-Location|sl|pushd|Push-Location|popd|Pop-Location|cd\.\.|cd\\)$'
$printer = '(?i)^(echo|printf|Write-Host|Write-Output|grep|rg|Select-String)(\.exe)?$'

function Get-DeleteTargets([string[]] $Tokens, [int] $From, [string] $Verb) {
    $cmdFlags = $Verb -match '(?i)^(del|erase|rd|rmdir)(\.exe)?$'
    $call = $Verb -match '(?i)Delete$'
    $ends = $false
    for ($k = $From; $k -lt $Tokens.Count; $k++) {
        $t = $Tokens[$k]
        if ($t -eq '(') { if (-not $call) { '$(' }; continue }
        if ($t -in ')', '{', '}') { continue }
        if (-not $ends -and $t -eq '--') { $ends = $true; continue }
        if (-not $ends -and $t -match '^-[A-Za-z]+:(.+)$') { $t = $Matches[1] }
        elseif (-not $ends -and $t.StartsWith('-')) { continue }
        if ($cmdFlags -and $t -match '^/[A-Za-z?](:.*)?$') { continue }
        if ($t -match '(?i)^\$(true|false|null)$') { continue }
        $t
    }
}

function Join-Base([string] $Base, [string] $Path) {
    if ([IO.Path]::IsPathRooted($Path) -or $Path -eq '~' -or $Path.StartsWith('~\')) { return $Path }
    return [IO.Path]::Combine($Base, $Path)
}

$unresolved = '[$`%(]|^(//|\\\\)|^~[^/\\]|^[A-Za-z][\w.\\-]+:'

function Move-Base([string] $Base, [string] $To) {
    # Where a cd, git -C or --work-tree to $To leaves relative paths; '' when that isn't known.
    if (-not $To -or $To -eq '-' -or $To -match $unresolved) { return '' }
    $d = ConvertTo-PathText $To
    if (-not $Base -and (Join-Base 'x' $d) -ne $d) { return '' }
    return Join-Base $Base $d
}

function Get-CommandPosition([string[]] $T, [int] $K, [bool] $Loose) {
    # 'yes' where a shell runs the word as a command, 'no' only where it is an argument to a
    # command that prints or searches text (echo rm), 'maybe' everywhere else.
    if ($K -eq 0 -or $T[$K - 1] -match '(?i)^(\{|\(|\.|!|then|do|else|if|while|until|sudo|command|exec|nohup|time|env|eval|iex|Invoke-Expression|xargs|-exec|-execdir|-ok|-okdir|/c|/k|-c|-Command)$') { return 'yes' }
    if (-not $Loose -and $T[0] -match $printer -and -not @($T -eq '--pre').Count) { return 'no' }
    return 'maybe'
}

function Test-DeleteTarget([string] $Token, [string] $Base, [string] $Workspace) {
    if ($Token -match '[$`%]') { return "'$Token' is a variable or command output" }
    if ($Token -match '^(//|\\\\)') { return "'$Token' is a network or device path" }
    if ($Token -match '^~[^/\\]') { return "'$Token' is a ~ form the guard doesn't resolve" }
    if ($Token -match '^[A-Za-z][\w.\\-]+:') { return "'$Token' is not a plain file path" }
    $p = ConvertTo-PathText $Token
    $wild = $p.IndexOfAny([char[]]'*?[')
    if ($wild -ge 0) { $cut = $p.Substring(0, $wild).LastIndexOf('\'); $p = if ($cut -ge 0) { $p.Substring(0, $cut + 1) } else { '.' } }
    if (-not $Base -and (Join-Base 'x' $p) -ne $p) { return "'$Token' is relative to a folder the guard can't follow" }
    try { $p = Resolve-DsrRealPath (Join-Base $Base $p) } catch { return "'$Token' can't be resolved" }
    if (-not $p) { return "'$Token' can't be resolved" }
    foreach ($d in @(@($denied) + @($editOnly) | Where-Object { $_ })) {
        if ((Test-DsrUnder $d $p) -or (Test-DsrUnder $p $d)) { Out-Deny "dossier-shellguard: deleting '$Token' would reach $d, which this home is kept out of or may only read. Don't work around that; tell the user." }
    }
    if (-not $Workspace) { return "no workspace root was given to the guard" }
    if ([string]::Equals($p, $Workspace, [StringComparison]::OrdinalIgnoreCase)) { return "'$Token' is the whole workspace" }
    if (Test-DsrUnder $p $Workspace) { return $null }
    return "'$Token' is outside $Workspace"
}

function Get-DeleteVerdict([string] $Command, [string] $Cwd, [string] $Workspace) {
    # Why the deletes in $Command need the user's OK; nothing when every target is inside $Workspace.
    $statements = (Expand-HomeVars $Command) -replace '[0-9*]?>>?\s*(&[0-9]|[^\s;|&]+)', ' ' -split '[;&\r\n]+'
    $segments = @(foreach ($st in $statements) {
        $parts = $st -split '\|'
        # Text piped into a shell runs as commands, so every word in the statement counts.
        $feeds = @($parts | Select-Object -Skip 1 | Where-Object { ($_.Trim() -split '\s+')[0] -match '(?i)^(sh|bash|zsh|dash|pwsh|powershell|cmd|iex|Invoke-Expression)(\.exe)?$' }).Count -gt 0
        for ($i = 0; $i -lt $parts.Count; $i++) { [pscustomobject]@{ Text = $parts[$i]; Piped = $i -gt 0; Feeds = $feeds } }
    })
    # The folder relative paths resolve against; a cd moves it for the statements after it, and
    # one the guard can't follow leaves it unknown ('').
    $here = $Cwd
    foreach ($s in $segments) {
        $seg = $s.Text
        # rg --pre runs a program on every file it searches, so its value is a command.
        $tokens = @([regex]::Matches($seg, '"[^"]*"|''[^'']*''|[(){}]|[^\s"'',(){}]+') | ForEach-Object { if ($_.Value -match '^--pre=(.*)$') { '--pre'; $Matches[1] } else { $_.Value } } | Where-Object { $_ })
        $t = @($tokens | ForEach-Object { $_.Trim('"', "'") })
        # A quoted command (cmd /c "rd /s /q x", bash -c "rm x") is judged as a command of its own.
        # Text that is only printed or searched is skipped, unless double quotes hold $( or a
        # backtick, which both shells run.
        $printed = $t.Count -and $t[0] -match $printer -and -not $s.Feeds -and -not @($t -eq '--pre').Count
        foreach ($q in $tokens) {
            if ($q -match '^["''].*\s' -and (-not $printed -or $q -match '^".*(\$\(|`)')) { Get-DeleteVerdict $q.Trim('"', "'") $here $Workspace }
        }
        $at = { param($re) for ($k = 0; $k -lt $t.Count; $k++) { if ($t[$k] -match $re) { return $k } }; return -1 }
        $git = & $at '(?i)^git(\.exe)?$'; $find = & $at '(?i)^find(\.exe)?$'; $xargs = & $at '(?i)^xargs(\.exe)?$'
        $loose = { param($k) $s.Feeds -or ($xargs -ge 0 -and $k -gt $xargs) -or ($find -ge 0 -and $k -gt $find) }
        # A quoted word is a command only where one is run: first in the segment (after & or .).
        $verbs = @(for ($k = 0; $k -lt $t.Count; $k++) {
            $w = $tokens[$k].TrimStart('`')
            if ($w -notmatch $deleteVerb) { if ($t[$k] -match $deleteVerb -and ($k -eq 0 -or $t[$k - 1] -in '.', '--pre')) { $k }; continue }
            if ($w -match '(?i)Delete$' -or $tokens[$k].StartsWith('`') -or (Get-CommandPosition $t $k (& $loose $k)) -ne 'no') { $k }
        })

        for ($k = 0; $k -lt $t.Count; $k++) {
            if ($tokens[$k] -notmatch $cdVerb) { continue }
            $pos = Get-CommandPosition $t $k (& $loose $k)
            if ($pos -eq 'no') { continue }
            if ($t[$k] -match '(?i)^cd\.\.$') { $here = if ($pos -eq 'yes') { Move-Base $here '..' } else { '' }; continue }
            if ($t[$k] -match '(?i)^cd\\$') { $here = ''; continue }
            $dest = @(for ($j = $k + 1; $j -lt $t.Count; $j++) {
                if ($t[$j] -in ')', '{', '}') { continue }
                if ($t[$j] -match '^-[A-Za-z]+:(.+)$') { $Matches[1] } elseif ($t[$j] -ne '-' -and $t[$j].StartsWith('-')) { continue } else { $t[$j] }
            })
            if ($pos -eq 'maybe' -or $t[$k] -match '(?i)^(popd|Pop-Location)$' -or -not $dest.Count -or $dest -contains '(') { $here = ''; continue }
            $here = Move-Base $here $dest[-1]
        }

        $targets = @(); $base = $here; $judged = $false
        if ($git -ge 0) {
            if (@($t[0..$git] | Where-Object { $_ -match '^GIT_(DIR|WORK_TREE)=' }).Count) { $base = '' }
            $k = $git + 1
            while ($k -lt $t.Count -and $t[$k].StartsWith('-')) {
                $o = $t[$k]; $v = $null
                if ($o -match '^(--[\w-]+)=(.*)$') { $o = $Matches[1]; $v = $Matches[2] }
                elseif ($o -cin '-C', '-c', '--git-dir', '--work-tree', '--namespace', '--super-prefix', '--config-env' -and $k + 1 -lt $t.Count) { $k++; $v = $t[$k] }
                if ($o -cin '-C', '--work-tree') { $base = Move-Base $base $v }
                elseif ($o -ceq '--git-dir') { $base = '' }
                $k++
            }
            if ($k -lt $t.Count -and $t[$k] -in 'rm', 'clean') {
                $judged = $true
                $targets = @(Get-DeleteTargets $t ($k + 1) 'git')
                if (-not $targets.Count) { $targets = @('.') }
            }
        }
        if (-not $judged -and $find -ge 0 -and ($t -contains '-delete' -or @($verbs | Where-Object { $_ -gt $find }).Count)) {
            $judged = $true
            $k = $find + 1
            while ($k -lt $t.Count -and $t[$k] -cmatch '^-([HLP]|D|O\d*)$') { if ($t[$k] -ceq '-D') { $k++ }; $k++ }
            for (; $k -lt $t.Count -and -not $t[$k].StartsWith('-') -and $t[$k] -notin '!', '\', '('; $k++) { $targets += $t[$k] }
            if (-not $targets.Count) { $targets = @('.') }
        }
        if (-not $judged -and $xargs -ge 0 -and @($verbs | Where-Object { $_ -gt $xargs }).Count) {
            "xargs $($t[$verbs[-1]]) deletes paths it reads from its input"; continue
        }
        if (-not $judged) {
            foreach ($v in $verbs) {
                $named = @(Get-DeleteTargets $t ($v + 1) $t[$v])
                # With no path named, only a pipe or the object a .Delete() is called on supplies one.
                if (-not $named.Count) { if ($s.Piped -or $t[$v] -match '(?i)Delete$') { "$($t[$v]) deletes what it's handed, so its targets aren't known" }; continue }
                $targets += $named
            }
        }
        foreach ($x in $targets) { Test-DeleteTarget $x $base $Workspace }
    }
}

function Complete-Guard {
    $ws = if ($WorkspaceRoot) { Resolve-DsrRealPath $WorkspaceRoot } else { '' }
    $why = @(Get-DeleteVerdict $command $cwd $ws | Where-Object { $_ } | Select-Object -Unique)
    if ($why.Count) { Out-Ask ("dossier-shellguard: this delete reaches past the workspace, so it needs the user's OK: " + ($why -join '; ') + '.') }
    exit 0
}

function ConvertFrom-RulePath([string] $Rule, [string] $Kind) {
    # Read(//c/x/y/**) -> C:\x\y ; Read(~/x) -> <home>\x ; anything else (project-relative, inner wildcards) -> $null
    $m = [regex]::Match($Rule, '^\s*(' + $Kind + ')\((.*)\)\s*$')
    if (-not $m.Success) { return $null }
    $p = $m.Groups[2].Value -replace '/\*\*?$', ''
    if ($p -match '[*?\[]') { return $null }
    if ($p -match '^//([A-Za-z])(/.*)?$') { return Resolve-DsrPath ($Matches[1].ToUpper() + ':' + $(if ($Matches[2]) { $Matches[2] } else { '/' })) }
    if ($p -eq '~' -or $p.StartsWith('~/')) { return Resolve-DsrPath $p }
    return $null
}

try {
    $in = [Console]::In.ReadToEnd() | ConvertFrom-Json
    $command = [string]$in.tool_input.command
    if (-not $command) { exit 0 }
    $cwd = if ($in.cwd) { [string]$in.cwd } else { (Get-Location).ProviderPath }

    $homePath = if ($env:CLAUDE_CONFIG_DIR) { Resolve-DsrPath $env:CLAUDE_CONFIG_DIR } else { Resolve-DsrPath '~/.claude' }
    $settingsFile = Join-Path $homePath 'settings.json'
    if (-not (Test-Path -LiteralPath $settingsFile)) { Complete-Guard }
    $s = [IO.File]::ReadAllText($settingsFile) | ConvertFrom-Json
    $rules = @(); if ($s -and $s.permissions -and $s.permissions.deny) { $rules = @($s.permissions.deny) }
    $denied = @($rules | ForEach-Object { ConvertFrom-RulePath ([string]$_) 'Read' } | Where-Object { $_ } | Select-Object -Unique)
    $editOnly = @($rules | ForEach-Object { ConvertFrom-RulePath ([string]$_) 'Edit' } | Where-Object { $_ } | Select-Object -Unique |
        Where-Object { $p = $_; -not @($denied | Where-Object { Test-DsrUnder $p $_ }).Count })
    if (-not $denied.Count -and -not $editOnly.Count) { Complete-Guard }

    $text = ConvertTo-PathText (Expand-HomeVars $command)

    function Get-Hit([string] $Path) { foreach ($d in $denied) { if (Test-DsrUnder $Path $d) { return $d } }; return $null }
    function Get-Holder([string] $Path) { foreach ($d in $denied) { if ((Test-DsrUnder $d $Path) -and -not (Test-DsrUnder $Path $d)) { return $d } }; return $null }
    $why = 'This home''s deny rules keep it out of {0}. Don''t work around that; tell the user, who can relaunch with cc in the folder that owns it.'

    foreach ($d in $denied) {
        if ($text -match ('(?i)' + [regex]::Escape($d) + '(?=$|[\\\s"''`;|&)>,*?\]])')) { Out-Deny ("dossier-shellguard: the command names $d. " + ($why -f $d)) }
    }

    if (Test-Path -LiteralPath $cwd) { Set-Location -LiteralPath $cwd }

    # Edit-only paths (a product path a client may read) stop commands that look like writes.
    $writes = '(?i)(^|[\s;|&(])((Set-Content|Add-Content|Out-File|New-Item|Remove-Item|Move-Item|Copy-Item|Rename-Item|Clear-Content|ni|rm|rmdir|del|mv|cp|mkdir|touch|tee|truncate|ln|patch|git\s+(-C\s+\S+\s+)?(add|commit|push|pull|merge|rebase|reset|checkout|switch|restore|clean|apply|am|stash|cherry-pick|revert|rm|mv|init|clone))(?=\s|$)|sed\s+[^;|&]*-i)|(?<![0-9])>(?!&)'
    if ($editOnly.Count -and $text -match $writes) {
        $here = Resolve-DsrPath $cwd
        foreach ($d in $editOnly) { if (Test-DsrUnder $here $d) { Out-Deny "dossier-shellguard: this home may read $d but not change it, and this command looks like a write from inside it. Tell the user; changes to it go through its owner's home." } }
        foreach ($t in ($text -split '[\s"''`;|&()<>,=]+')) {
            if (-not $t -or $t.StartsWith('-') -or $t -match '^[A-Za-z][A-Za-z0-9+.-]+:') { continue }
            try { $p = Resolve-DsrPath ($t -replace '[*?\[].*$', '') } catch { continue }
            if (-not $p) { continue }
            foreach ($d in $editOnly) { if (Test-DsrUnder $p $d) { Out-Deny "dossier-shellguard: this home may read $d but not change it, and this command looks like a write to '$t'. Tell the user; changes to it go through its owner's home." } }
        }
    }

    $existing = 0; $holders = @()
    foreach ($t in ($text -split '[\s"''`;|&()<>,=]+')) {
        if (-not $t -or $t.StartsWith('-') -or $t -match '^[A-Za-z][A-Za-z0-9+.-]+:') { continue }
        $wild = $t.IndexOfAny([char[]]'*?[')
        try {
            if ($wild -ge 0) {
                $fixed = $t.Substring(0, $wild); $cut = $fixed.LastIndexOf('\')
                $fixed = if ($cut -ge 0) { $fixed.Substring(0, $cut + 1) } else { '.' }
                $p = Resolve-DsrPath $fixed
                $h = (Get-Hit $p) ?? (Get-Holder $p)
                if ($h) { Out-Deny ("dossier-shellguard: the wildcard in '$t' can reach $h. " + ($why -f $h)) }
                continue
            }
            $p = Resolve-DsrPath $t
        } catch { continue }
        if (-not $p) { continue }
        $h = Get-Hit $p
        if ($h) { Out-Deny ("dossier-shellguard: '$t' is inside $h. " + ($why -f $h)) }
        if (Test-Path -LiteralPath $p) { $existing++; $holders += $p }
    }

    $recursive = '(?i)(^|[\s;|&(])((rg|ag|find|tree|du|robocopy|xcopy|tar|zip|7z|Compress-Archive)(?=\s|$)|Copy-Item\b[^;|&]*-r|cp\s+-[a-zA-Z]*[rR]|grep\s+[^;|&]*-[a-zA-Z]*[rR]|ls\s+[^;|&]*-[a-zA-Z]*R|Get-ChildItem\b[^;|&]*-r|gci\b[^;|&]*-r|dir\b[^;|&]*(-r|\\s\b)|Select-String\b[^;|&]*-r)'
    if ($text -match $recursive) {
        if ($existing -eq 0) { $holders += (Resolve-DsrPath $cwd) }
        foreach ($p in $holders) {
            $h = Get-Holder $p
            if ($h) { Out-Deny ("dossier-shellguard: a recursive command from $p would reach $h. Point it at a narrower folder. " + ($why -f $h)) }
        }
    }
    Complete-Guard
} catch {
    $err = $_.Exception.Message
    if ($command) {
        # With no workspace root, every delete in the command gives a reason.
        $doubt = try { [bool]@(Get-DeleteVerdict $command $cwd '' | Where-Object { $_ }).Count } catch { $true }
        if ($doubt) { Out-Ask "dossier-shellguard could not check this command ($err), and it may delete files, so it needs the user's OK." }
    }
    $o = @{ systemMessage = "[dossier-shellguard] could not check this command ($err); it ran unchecked." }
    [Console]::Out.Write(($o | ConvertTo-Json -Compress))
}
exit 0
