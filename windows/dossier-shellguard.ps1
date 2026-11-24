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
# The quoted pattern of grep, rg, sed or Select-String is only checked for a named denied path,
# and the delete and recursive checks skip the body of a quoted-marker heredoc fed to python and
# the like. What that script prints into a file that a later command runs (> x.sh && sh x.sh)
# isn't followed. Text whose quoting or structure the guard can't read for certain gets the full check.
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
$shellWord = '(?i)^(.*[\\/])?(sh|bash|zsh|dash|pwsh|powershell|cmd|wsl|iex|Invoke-Expression)(\.exe)?$'
$wrapper = '(?i)^(.*[\\/])?(sudo|command|exec|nohup|time|env|xargs)(\.exe)?$'
$interpreter = '(?i)^(.*[\\/])?(python[0-9.]*|py|node|perl|ruby|php|Rscript|lua)(\.exe)?$'
$shellOut = '(?i)os\.(system|popen|exec|spawn)|subprocess|popen|pty\.spawn|child_process|execSync|spawnSync|shell_exec|passthru|proc_open|Open3|\bsystem\s*\(|\bexec\s*\(|\bqx\b|%x[^\w\s]|`'
$searcher = '(?i)^(.*[\\/])?(grep|egrep|fgrep|rg|sed|Select-String|sls)(\.exe)?$'
$sedCmd = '(?:(?:\d+|\$|/(?:[^/\\]|\\.)*/)(?:\s*,\s*(?:\d+|\$|/(?:[^/\\]|\\.)*/))?\s*!?\s*)?(?:[pdPDnNgGhHxlq=]|s(?<d>[^\s\w\\])(?:(?!\k<d>)[^\\]|\\.)*\k<d>(?:(?!\k<d>)[^\\]|\\.)*\k<d>[gpiImM0-9]*)'
# A sed script the guard may hide: only addresses, s/// without the e or w flag, and commands
# that read or write no file and run nothing.
$plainSed = "^\s*$sedCmd(?:\s*;\s*$sedCmd)*\s*;?\s*$"

function Test-ShellFeed([string] $Text) {
    # Whether text piped into this command runs as shell commands: a shell, or a wrapper (sudo, env) running one.
    $words = @([regex]::Matches($Text, '"[^"]*"|''[^'']*''|\S+') | ForEach-Object { $_.Value.Trim('"', "'") })
    if (-not $words.Count) { return $false }
    if ($words[0] -match $shellWord) { return $true }
    return $words[0] -match $wrapper -and @($words | Select-Object -Skip 1 | Where-Object { $_ -match $shellWord }).Count -gt 0
}

function Hide-HeredocBody([string] $Command) {
    # The body of a heredoc fed to an interpreter (python - <<'EOF') is its script, not shell
    # commands, when the marker is quoted so the shell expands nothing in it. A body fed to a
    # shell, piped anywhere, that shells out itself, or that never ends, stays in. Anything this
    # scan can't read for certain keeps every body: a tool other than Bash, a << it can't parse,
    # or a body inside ( ), { }, a loop or an if, or after $( ${ $[ (( <( >( @( or a backtick.
    if ($in.tool_name -ne 'Bash') { return $Command }
    $quoted = '\\[\s\S]|\$''(?:[^''\\]|\\[\s\S])*''|"(?:[^"\\]|\\[\s\S])*"|''[^'']*'''
    $scan = [regex]"$quoted|(?<![^\s;&|(])#[^\n]*|(?<!<)<<(?!<)(?<dash>-?)[ \t]*(?:(?:'(?<q>[^']+)'|`"(?<q>[^`"\\$``]+)`"|\\(?<q>[\w.-]+)|(?<u>[\w.-]+))(?=[\s;&|<>()]|$))?|[;&|()]|\n"
    $unsure = '\$[({\[]|[<>@!+*?]\(|\(\(|`|(^|[\s;&|(])(\{|do|then|else|elif)(?=\s|$)'
    $pending = @(); $cut = @(); $sep = 0; $pos = 0; $shown = ''; $depth = 0
    while ($pos -lt $Command.Length) {
        $m = $scan.Match($Command, $pos)
        if (-not $m.Success) { break }
        $shown += $Command.Substring($pos, $m.Index + $m.Length - $pos)
        $pos = $m.Index + $m.Length
        $v = $m.Value
        if ($v.StartsWith('<<')) {
            if (-not $m.Groups['q'].Success -and -not $m.Groups['u'].Success) { return $Command }
            $before = [regex]::Replace($Command.Substring($sep, $m.Index - $sep), $quoted, 'Q')
            # Only when the interpreter reads its script from the heredoc: python flags that take no
            # value, then nothing or - and the script's own arguments.
            $fed = @($before.Trim() -split '\s+')
            $words = @($fed | Select-Object -Skip 1)
            $dash = [array]::IndexOf($words, '-')
            $flags = if ($dash -ge 0) { @($words | Select-Object -First $dash) } else { $words }
            $ok = $m.Groups['q'].Success -and $depth -eq 0 -and $fed[0] -match $interpreter -and
                -not @($flags | Where-Object { $_ -ne '-u' -and -not ($fed[0] -match '(?i)python|(^|[\\/])py(\.exe)?$' -and $_ -cmatch '^-[IuBEsSOqbd]+$') }).Count
            $pending += [pscustomobject]@{ Marker = if ($m.Groups['q'].Success) { $m.Groups['q'].Value } else { $m.Groups['u'].Value }; Dash = [bool]$m.Groups['dash'].Value; Ok = $ok; At = $m.Index + $m.Length }
        }
        elseif ($v -match '^[;&|()]$') { $sep = $pos; if ($v -eq '(') { $depth++ } elseif ($v -eq ')') { $depth-- } }
        elseif ($v -eq "`n") {
            foreach ($h in $pending) {
                $rest = ($Command.Substring($h.At, $m.Index - $h.At) -replace '\\\r?\n', ' ').TrimEnd()
                $end = -1; $at = $pos
                while ($at -le $Command.Length) {
                    $nl = $Command.IndexOf("`n", $at); $stop = if ($nl -lt 0) { $Command.Length } else { $nl }
                    $l = $Command.Substring($at, $stop - $at).TrimEnd("`r")
                    if ($h.Dash) { $l = $l.TrimStart("`t") }
                    if ($l -ceq $h.Marker) { $end = $at; break }
                    if ($nl -lt 0) { break }
                    $at = $nl + 1
                }
                if ($end -lt 0) { return $Command }
                $body = $Command.Substring($pos, $end - $pos)
                # Any pipe out of it can run what it prints (| sh, | source /dev/stdin, | while read).
                if ($h.Ok -and $rest -notmatch '\|' -and $body -notmatch $shellOut -and $shown -notmatch $unsure) { $cut += , @($pos, $end) }
                else { $shown += $body }
                $nl = $Command.IndexOf("`n", $end); $pos = if ($nl -lt 0) { $Command.Length } else { $nl + 1 }
                $shown += $Command.Substring($end, $pos - $end)
            }
            $pending = @(); $sep = $pos
        }
    }
    if ($pending.Count) { return $Command }
    for ($i = $cut.Count - 1; $i -ge 0; $i--) { $Command = $Command.Remove($cut[$i][0], $cut[$i][1] - $cut[$i][0]) }
    return $Command
}

function Hide-Pattern([string] $Command) {
    # The quoted pattern of grep, rg, sed or Select-String is text to match, not a path. Where the
    # masker can't read the command for certain it masks nothing: a tool other than Bash or
    # PowerShell, a heredoc, or $( ${ $[ <( >( or a backtick (in PowerShell $( @( or a here-string).
    # A sed script that reads, writes or runs stays in too.
    $ps = $in.tool_name -eq 'PowerShell'
    if (-not $ps -and $in.tool_name -ne 'Bash') { return $Command }
    if ($ps -and $Command -match '[$@]\(|@[''"]') { return $Command }
    if (-not $ps -and $Command -match '\$[({\[]|[<>]\(|`|(?<!<)<<(?!<)') { return $Command }
    $esc = if ($ps) { '`' } else { '\\' }
    $words = if ($ps) { '(?:`[\s\S]|"(?:[^"`]|`[\s\S])*"|''[^'']*''|[^\s;&|"''`])+|[;&|\r\n]' } else { '(?:\\[\s\S]|\$''(?:[^''\\]|\\[\s\S])*''|"(?:[^"\\]|\\[\s\S])*"|''[^'']*''|[^\s;&|"''\\])+|[;&|\r\n]' }
    $tokens = @([regex]::Matches($Command, $words))
    $isSls = { param($c) $c -match '(?i)(^|[\\/])(Select-String|sls)$' }
    # GNU long options may be cut to any prefix (--rege=x is --regexp=x).
    $isLong = { param($v, $names) $v -cmatch '^--([a-z][a-z-]*)(=|$)' -and @($names | Where-Object { $_.StartsWith($Matches[1]) }).Count }
    # A statement that names its pattern by an option anywhere has no positional pattern: grep and
    # rg reorder options, and Select-String binds a positional to -Path once -Pattern is named.
    # rg --files and --type-list take no pattern, so every word in that statement is a path.
    $named = @{}; $noPattern = @{}; $id = 0; $cmd = $null; $ended = $false
    foreach ($w in $tokens) {
        $v = $w.Value
        if ($v -match '^[;&|\r\n]$') { $id++; $cmd = $null; $ended = $false; continue }
        if ($null -eq $cmd) { $cmd = $v.TrimStart('('); continue }
        if ($v -ceq '--') { $ended = $true }
        if ($ended) { continue }
        if ($cmd -match '(?i)(^|[\\/])rg(\.exe)?$' -and $v -cin '--files', '--type-list') { $noPattern[$id] = $true }
        if (& $isSls $cmd) { if ($v -match '(?i)^-Patt') { $named[$id] = $true } }
        elseif ($v -cmatch '^-[A-Za-z]*[ef]' -or (& $isLong $v 'regexp', 'expression', 'file')) { $named[$id] = $true }
    }
    $chars = $Command.ToCharArray()
    $searching = $false; $start = $true; $id = 0
    foreach ($w in $tokens) {
        $v = $w.Value
        if ($v -match '^[;&|\r\n]$') { $start = $true; $id++; continue }
        if ($start) { $start = $false; $cmd = $v.TrimStart('('); $searching = $cmd -match $searcher -and -not $noPattern[$id]; $sls = & $isSls $cmd; $sed = $cmd -match '(?i)(^|[\\/])sed(\.exe)?$'; $given = [bool]$named[$id]; $next = ''; $ended = $false; continue }
        if (-not $searching) { continue }
        # A redirection is no pattern, and a bare < or > takes the next word.
        if ($v -match '^\d*[<>]') { $next = if ($v -match '^\d*[<>]+$') { 'skip' } else { '' }; continue }
        $mask = $false
        if ($next -eq 'skip') { $next = ''; continue }
        if ($next -eq 'pattern') { $next = ''; $mask = $true }
        elseif ($ended) { if (-not $given) { $mask = $true; $given = $true } }
        elseif ($v -ceq '--') { $ended = $true; continue }
        elseif ($sls) {
            if ($v -match '(?i)^-Patt(e|er|ern)?$') { $next = 'pattern'; $given = $true; continue }
            elseif ($v -match '(?i)^-Patt(e|er|ern)?:') { $mask = $true; $given = $true }
            elseif ($v -match '(?i)^-(\w+)$' -and @('Path', 'PSPath', 'LP', 'LiteralPath', 'Encoding' | Where-Object { $_.StartsWith($Matches[1], 'OrdinalIgnoreCase') }).Count) { $next = 'skip'; continue }
            elseif ($v.StartsWith('-')) { continue }
            elseif (-not $given) { $mask = $true; $given = $true }
        }
        elseif ((& $isLong $v 'regexp', 'expression') -and $v -notmatch '=') { $next = 'pattern'; $given = $true; continue }
        elseif (& $isLong $v 'regexp', 'expression') { $mask = $true; $given = $true }
        elseif ((& $isLong $v 'file') -and $v -notmatch '=') { $next = 'skip'; $given = $true; continue }
        elseif ((& $isLong $v 'file') -or $v -cmatch '^-[ef].|^-[A-Za-z]*[ef][A-Za-z]*$') {
            # -e or -f alone, in a cluster (-ve) or with its value attached (-efoo): the pattern is given.
            $given = $true
            if ($v -cmatch '^-[a-dg-zA-Z]*[ef]$') { $next = if ($v[-1] -ceq 'e') { 'pattern' } else { 'skip' } }
            continue
        }
        elseif ($v.StartsWith('-')) { if ($v -cmatch '^-[ABCmgtT]$' -or ($v -notmatch '=' -and (& $isLong $v 'glob', 'iglob', 'type', 'type-not', 'max-count', 'exclude-from', 'ignore-file', 'pre'))) { $next = 'skip' }; continue }
        elseif (-not $given) { $mask = $true; $given = $true }
        $plain = $v -replace ($esc + '[\s\S]'), ''
        if (-not $mask -or $plain -notmatch '["'']' -or ($plain -replace '"[^"]*"|''[^'']*''', '') -match '[<>]' -or $v -match '\$\(|`') { continue }
        if ($sed -and -not ($v -match '^''(.*)''$|^"(.*)"$' -and ($Matches[1] + $Matches[2]) -match $plainSed)) { continue }
        for ($c = $w.Index; $c -lt $w.Index + $w.Length; $c++) { $chars[$c] = ' ' }
    }
    return [string]::new($chars)
}

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
        $feeds = @($parts | Select-Object -Skip 1 | Where-Object { Test-ShellFeed $_ }).Count -gt 0
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
    $why = @(Get-DeleteVerdict (Hide-HeredocBody $command) $cwd $ws | Where-Object { $_ } | Select-Object -Unique)
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
    $text = ConvertTo-PathText (Expand-HomeVars (Hide-Pattern $command))

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
    }

    $recursive = '(?i)(^|[\s;|&(])((rg|ag|find|tree|du|robocopy|xcopy|tar|zip|7z|Compress-Archive)(?=\s|$)|Copy-Item\b[^;|&]*-r|cp\s+-[a-zA-Z]*[rR]|grep\s+[^;|&]*-[a-zA-Z]*[rR]|ls\s+[^;|&]*-[a-zA-Z]*R|Get-ChildItem\b[^;|&]*-r|gci\b[^;|&]*-r|dir\b[^;|&]*(-r|\\s\b)|Select-String\b[^;|&]*-r)'
    # Only what the shell runs can be recursive: not an interpreter's heredoc script.
    $shellText = ConvertTo-PathText (Expand-HomeVars (Hide-Pattern (Hide-HeredocBody $command)))
    if ($shellText -match $recursive) {
        $holders = @(foreach ($t in ($shellText -split '[\s"''`;|&()<>,=]+')) {
            if (-not $t -or $t.StartsWith('-') -or $t -match '^[A-Za-z][A-Za-z0-9+.-]+:' -or $t.IndexOfAny([char[]]'*?[') -ge 0) { continue }
            try { $p = Resolve-DsrPath $t } catch { continue }
            if ($p -and (Test-Path -LiteralPath $p)) { $p }
        })
        if (-not $holders.Count) { $holders = @(Resolve-DsrPath $cwd) }
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
        $doubt = try { [bool]@(Get-DeleteVerdict (Hide-HeredocBody $command) $cwd '' | Where-Object { $_ }).Count } catch { $true }
        if ($doubt) { Out-Ask "dossier-shellguard could not check this command ($err), and it may delete files, so it needs the user's OK." }
    }
    $o = @{ systemMessage = "[dossier-shellguard] could not check this command ($err); it ran unchecked." }
    [Console]::Out.Write(($o | ConvertTo-Json -Compress))
}
exit 0
