param([ValidateSet('Bash', 'PowerShell')][string]$Runner = 'PowerShell')
# Shared black-box tests using simulated CLI processes.
$ErrorActionPreference = 'Stop'
$utf8 = New-Object Text.UTF8Encoding($false)
$root = Split-Path $PSScriptRoot
$temp = Join-Path ([IO.Path]::GetTempPath()) ('consult-tests.' + [guid]::NewGuid().ToString('N'))
if ($Runner -eq 'Bash') {
    [void][IO.Directory]::CreateDirectory($temp)
    # macOS temporary paths can begin with /var, whose physical path is /private/var.
    $bash = '/bin/bash'
    $temp = & $bash -c 'cd "$1" && pwd -P' _ $temp
}
$repo = Join-Path $temp ('project with spaces ' + [char]0x03bb)
$capture = Join-Path $temp 'capture'
$artifacts = Join-Path $temp 'artifacts'
$claudeConfig = Join-Path $temp 'Claude config'
$message = Join-Path $temp 'message.txt'
$shell = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$script = Join-Path $root 'skills/engineering/consult/scripts/runner.ps1'
$fixture = Join-Path $PSScriptRoot 'fixtures/consult-cli.ps1'
$prefix = @('-NoProfile', '-NonInteractive', '-File', $script)
if ($Runner -eq 'Bash') {
    $shell = '/bin/bash'
    $script = Join-Path $root 'skills/engineering/consult/scripts/runner.sh'
    $fixture = Join-Path $PSScriptRoot 'fixtures/consult-cli.sh'
    $prefix = @($script)
    & chmod +x $fixture
}
$count = 0
function Save($Path, [string]$Value) { [IO.File]::WriteAllText($Path, $Value, $utf8) }
function Read($Path) { [IO.File]::ReadAllText($Path, $utf8) }
function Assert($Condition, $Because) { if (!$Condition) { throw $Because } }
function Quote([string]$Value) {
    '"' + [regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
}
function Start-Call($Arguments, $Directory = $repo, $Live = $false) {
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $shell
    $start.Arguments = (($prefix + $Arguments | ForEach-Object { Quote $_ }) -join ' ')
    $start.WorkingDirectory = $Directory
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = $utf8
    $start.StandardErrorEncoding = $utf8
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    [void]$process.Start()
    if ($Live) { return @{ Process = $process; Out = $process.StandardOutput.ReadLineAsync(); Err = $process.StandardError.ReadToEndAsync() } }
    return @{ Process = $process; Out = $process.StandardOutput.ReadToEndAsync(); Err = $process.StandardError.ReadToEndAsync() }
}
function Finish-Call($Call) {
    try {
        if (!$Call.Process.WaitForExit(45000)) { $Call.Process.Kill(); throw 'Test runner did not exit.' }
        return @{ Code = $Call.Process.ExitCode; Out = $Call.Out.GetAwaiter().GetResult(); Err = $Call.Err.GetAwaiter().GetResult() }
    } finally { $Call.Process.Dispose() }
}
function Invoke-Call($Arguments, $Directory = $repo) { Finish-Call (Start-Call $Arguments $Directory) }
function Fresh($Provider = 'claude', $Extra = @()) {
    Invoke-Call (@('--provider', $Provider, '--repo', $repo, '--message', $message, '--cli', $fixture, '--artifacts', $artifacts) + $Extra)
}
function Continue-Session($Session, $Extra = @()) { Invoke-Call (@('--session', $Session, '--message', $message) + $Extra) }
function Success($Result) {
    $failure = 'Failed: ' + $Result.Err
    if ($Result.Code -ne 0 -and $Result.Err -match '(?m)^Diagnostics: (.+)\r?$') {
        $diagnostics = $Matches[1].TrimEnd("`r")
        $cliStderr = Join-Path $diagnostics 'stderr.txt'
        if (Test-Path -LiteralPath $cliStderr) { $failure += "`nCLI stderr:`n" + (Read $cliStderr) }
    }
    Assert ($Result.Code -eq 0) $failure
    Assert ($Result.Err -eq '') ('Unexpected stderr: ' + $Result.Err)
    $lines = $Result.Out.TrimEnd("`r", "`n") -split '\r?\n'
    Assert ($lines.Count -eq 2 -and $lines[0].StartsWith('Reply: ') -and $lines[1].StartsWith('Session: ')) ('Success must print only two labeled paths. Actual: ' + $Result.Out)
    $reply = $lines[0].Substring(7)
    $session = $lines[1].Substring(9)
    Assert ([IO.Path]::IsPathRooted($reply) -and [IO.Path]::IsPathRooted($session)) 'Output paths must be absolute.'
    Assert ((Test-Path -LiteralPath $reply) -and (Test-Path -LiteralPath $session)) 'Output files are missing.'
    return @{ Reply = $reply; Session = $session; Fields = [IO.File]::ReadAllLines($session, $utf8) }
}
function Failure($Result) {
    Assert ($Result.Code -ne 0) 'Failure returned exit code zero.'
    Assert ($Result.Out -eq '') ('Failure leaked stdout: ' + $Result.Out)
    Assert ($Result.Err.Contains('consult:')) ('Failure has no error: ' + $Result.Err)
}
function Case($Name, [scriptblock]$Body) {
    $env:FAKE_CASE = ''
    $env:FAKE_REPLY = 'Independent finding'
    & $Body
    $script:count++
    [Console]::Out.WriteLine('ok ' + $script:count + ' - ' + $Name)
}
function Start-Live($Extra = @()) {
    $arguments = @('--provider', 'claude', '--repo', $repo, '--message', $message, '--cli', $fixture, '--artifacts', $artifacts) + $Extra
    $call = Start-Call $arguments $repo $true
    try {
        Assert ($call.Out.Wait(15000)) 'Live conversation did not report its first reply.'
        $firstLine = $call.Out.GetAwaiter().GetResult()
        if ($null -eq $firstLine) {
            [void](Success @{ Code = 1; Out = ''; Err = $call.Err.GetAwaiter().GetResult() })
        }
        $secondLine = $call.Process.StandardOutput.ReadLineAsync()
        Assert ($secondLine.Wait(15000)) 'Live conversation did not report its session.'
        $paths = Success @{ Code = 0; Out = $firstLine + "`n" + $secondLine.GetAwaiter().GetResult() + "`n"; Err = '' }
        return @{ Call = $call; Paths = $paths }
    } catch {
        $cause = $_
        try { if (!$call.Process.HasExited) { $call.Process.Kill() } } catch {}
        $call.Process.Dispose()
        throw $cause
    }
}
function Stop-Live($Live) {
    $closed = Invoke-Call @('--close', $Live.Paths.Session)
    try {
        Assert ($closed.Code -eq 0 -and $closed.Out -eq '') ('Live close failed: ' + $closed.Err)
        if (!$Live.Call.Process.WaitForExit(10000)) { $Live.Call.Process.Kill(); throw 'Live conversation did not stop.' }
        $Live.ExitCode = $Live.Call.Process.ExitCode
    } finally { $Live.Call.Process.Dispose() }
}

try {
    foreach ($path in @($repo, $capture, $artifacts)) { [void][IO.Directory]::CreateDirectory($path) }
    Save $message 'Assess the same task independently.'
    Save (Join-Path $repo 'original.txt') 'untouched'
    $env:FAKE_CAPTURE = $capture
    $env:FAKE_RUNNER = $script
    $env:CLAUDECODE = ''
    $env:CODEX_THREAD_ID = ''
    $env:CODEX_SESSION_ID = ''
    $env:CONSULT_CONSULTANT = ''
    $env:CLAUDE_CONFIG_DIR = $claudeConfig
    $env:FAKE_PWSH = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    foreach ($provider in @('claude', 'codex')) {
        Case "$provider starts and resumes the exact conversation in the project directory" {
            $chosenModel = 'chosen "model" $() \ end'
            $first = Success (Fresh $provider @('--model', $chosenModel, '--effort', 'high'))
            Assert ($first.Fields.Count -eq 8 -and $first.Fields[0] -eq 'consult-session-1') 'Session is not the expected plain-text format.'
            Assert ($first.Fields[1] -eq $provider) 'Wrong provider.'
            if ($provider -eq 'claude') {
                Assert ($first.Fields[2] -cmatch '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$') 'Assigned Claude ID is not a canonical version 4 UUID.'
            }
            Assert ((Read (Join-Path $capture 'cwd.txt')).Trim() -eq $repo) 'CLI launched in the wrong directory.'
            $prompt = Read (Join-Path $capture 'prompt.txt')
            Assert ($prompt.Contains('You are the consultant') -and $prompt.Contains('Do not delegate, invoke the consult skill') -and $prompt.Contains('Assess the same task')) 'Consultant role or task missing.'
            Assert ((Read (Join-Path $capture 'consultant.txt')).Trim() -eq '1') 'Consultant process marker missing.'
            Save $message 'Clarify the earlier finding.'
            $second = Success (Continue-Session $first.Session)
            Assert ($second.Fields[2] -eq $first.Fields[2]) 'Follow-up changed conversation ID.'
            Assert ($second.Fields[1] -eq $first.Fields[1] -and $second.Fields[3] -eq $repo) 'Follow-up changed provider or project.'
            Assert ($second.Fields[4] -eq $chosenModel -and $second.Fields[5] -eq 'high') 'Follow-up lost model overrides.'
            Assert ($first.Reply -ne $second.Reply -and (Read $first.Reply) -eq 'Independent finding') 'Follow-up overwrote the earlier reply.'
            Assert ((Read (Join-Path $capture 'prompt.txt')).Contains('Clarify the earlier finding.')) 'Follow-up message missing.'
            $cliArgs = Read (Join-Path $capture 'args.txt')
            Assert (($cliArgs -split '\r?\n') -ccontains $chosenModel) 'CLI argument quoting changed the model value.'
            if ($provider -eq 'claude') {
                Assert ($cliArgs.Contains('Read,Glob,Grep') -and $cliArgs.Contains('dontAsk') -and !$cliArgs.Contains('--safe-mode')) 'Claude restrictions or customization policy wrong.'
                Assert (($cliArgs -split '\r?\n') -ccontains '--resume') 'Claude continuation option missing.'
            } else {
                Assert ($cliArgs.Contains('sandbox_mode="read-only"') -and $cliArgs.Contains('approval_policy="never"') -and $cliArgs.Contains('multi_agent')) 'Codex restrictions missing.'
                Assert (($cliArgs -split '\r?\n') -ccontains 'resume') 'Codex continuation command missing.'
                $argumentLines = $cliArgs.TrimEnd("`r", "`n") -split '\r?\n'
                Assert (@($argumentLines | Where-Object { $_ -ceq '-c' }).Count -eq 3) 'Repeated Codex config arguments changed.'
                Assert ($argumentLines[-1] -ceq '-') 'Codex stdin argument changed.'
            }
            Failure (Continue-Session $first.Session)
            Save $message 'Assess the same task independently.'
        }
        Case "$provider saves arbitrary UTF-8 replies without echoing them" {
            $env:FAKE_REPLY = "# Finding`nQuotes: `"yes`", literal `$() and backticks ``.`nUnicode: $([char]0x03bb)$([char]0x65e5)`nReply: fake`nSession: fake"
            $result = Success (Fresh $provider)
            Assert ((Read $result.Reply) -ceq $env:FAKE_REPLY) 'Reply text changed.'
        }
        Case "$provider reports failures and invalidates an older successful session" {
            $first = Success (Fresh $provider)
            $env:FAKE_CASE = 'exit'
            $failed = Continue-Session $first.Session
            Failure $failed
            Assert ($failed.Err.Contains('Diagnostics:')) 'Failed turn diagnostics missing.'
            $env:FAKE_CASE = ''
            Failure (Continue-Session $first.Session)
            Assert ((Read $first.Reply) -eq 'Independent finding') 'Failure overwrote earlier reply.'
        }
        Case "$provider rejects empty replies" {
            $env:FAKE_CASE = 'empty'
            Failure (Fresh $provider)
        }
        Case "$provider stops on timeout" {
            $env:FAKE_CASE = 'sleep'
            $watch = [Diagnostics.Stopwatch]::StartNew()
            $result = Fresh $provider @('--timeout', '1')
            Failure $result
            Assert ($watch.Elapsed.TotalSeconds -lt 15) 'Timeout did not terminate the CLI promptly.'
            Assert ($result.Err -match 'timed out') 'Timeout cause missing.'
            $diagnostics = ($result.Err -split '\r?\n' | Where-Object { $_.StartsWith('Diagnostics: ') }).Substring(13)
            Assert ((Test-Path -LiteralPath (Join-Path $diagnostics 'stderr.txt'))) 'Timeout discarded stderr diagnostics.'
        }
    }
    $blocked = Join-Path $temp 'blocked-profile'
    Save $blocked 'not a directory'
    $env:CLAUDE_CONFIG_DIR = $blocked
    Case 'Claude keeps one native process and context when session storage is blocked' {
        $env:FAKE_CASE = 'memory'
        $chosenModel = 'chosen "model" $() \ end'
        $live = Start-Live @('--model', $chosenModel, '--effort', 'high')
        try {
            $first = $live.Paths
            Save $message 'Repeat your previous reply exactly.'
            $second = Success (Continue-Session $first.Session)
            Assert ((Read $second.Reply) -eq (Read $first.Reply)) 'Live follow-up lost its conversation memory.'
            Assert ((Read (Join-Path $capture 'turn-count.txt')) -eq '2') 'Follow-up started a new CLI process.'
            Assert ($first.Fields[2] -eq $second.Fields[2]) 'Live follow-up changed the native session ID.'
            Assert ($second.Fields[4] -ceq $chosenModel -and $second.Fields[5] -ceq 'high') 'Live follow-up lost its model or effort.'
            $cliArgs = Read (Join-Path $capture 'args.txt')
            Assert ($cliArgs.Contains('--no-session-persistence') -and $cliArgs.Contains('stream-json')) 'Live mode depended on protected session storage.'
            Assert (($cliArgs -split '\r?\n') -ccontains $chosenModel) 'Live CLI argument quoting changed the model value.'
            Assert ($cliArgs.Contains('Read,Glob,Grep') -and $cliArgs.Contains('dontAsk') -and !$cliArgs.Contains('--safe-mode')) 'Live Claude lost its read-only tools or settings policy.'
            Assert ((Read $blocked) -eq 'not a directory') 'Runner changed the original profile.'
            Failure (Continue-Session $first.Session)
        } finally { Stop-Live $live }
        Assert ($live.ExitCode -eq 0) 'Closing a healthy live conversation failed.'
    }
    Case 'parallel live consultations retain separate native contexts' {
        $env:FAKE_CASE = 'memory'
        $first = Start-Live
        $second = $null
        try {
            $second = Start-Live
            Assert ($first.Paths.Fields[2] -ne $second.Paths.Fields[2]) 'Live conversations shared a native ID.'
            $a = Success (Continue-Session $first.Paths.Session)
            $b = Success (Continue-Session $second.Paths.Session)
            Assert ((Read $a.Reply) -eq (Read $first.Paths.Reply)) 'First live context was mixed with the second.'
            Assert ((Read $b.Reply) -eq (Read $second.Paths.Reply)) 'Second live context was mixed with the first.'
            Assert ((Read $a.Reply) -ne (Read $b.Reply)) 'Parallel live contexts were not independent.'
        } finally {
            Stop-Live $first
            if ($second) { Stop-Live $second }
        }
    }
    Case 'live conversations allow only one active follow-up' {
        $live = Start-Live
        try {
            Save (Join-Path $capture 'stream-control.txt') 'sleep'
            $running = Start-Call @('--session', $live.Paths.Session, '--message', $message, '--timeout', '2')
            $lock = Join-Path (Split-Path (Split-Path $live.Paths.Session)) 'lock'
            $watch = [Diagnostics.Stopwatch]::StartNew()
            while (!(Test-Path -LiteralPath $lock) -and $watch.Elapsed.TotalSeconds -lt 8) { Start-Sleep -Milliseconds 30 }
            Assert (Test-Path -LiteralPath $lock) 'Live follow-up did not acquire its lock.'
            Failure (Continue-Session $live.Paths.Session)
            Failure (Finish-Call $running)
        } finally {
            Remove-Item -LiteralPath (Join-Path $capture 'stream-control.txt') -Force -ErrorAction SilentlyContinue
            Stop-Live $live
        }
    }
    Case 'live Claude preserves UTF-8, escaped Unicode and literal JSON-looking text' {
        $env:FAKE_CASE = 'escaped'
        $env:FAKE_REPLY = "Quotes: `"yes`", backslash \, newline`n$([char]0x03bb)$([char]0x65e5)$([char]::ConvertFromUtf32(0x1f680))`n{`"type`":`"result`"}`n"
        Save $message $env:FAKE_REPLY
        $live = Start-Live
        try {
            Assert ((Read $live.Paths.Reply) -ceq $env:FAKE_REPLY) 'Live reply decoding changed the text.'
            Assert ((Read (Join-Path $capture 'prompt.txt')).EndsWith($env:FAKE_REPLY)) 'Live prompt encoding changed the message.'
        } finally { Stop-Live $live }
    }
    foreach ($problem in @('exit', 'malformed', 'empty', 'wrong-id', 'error-event', 'no-result', 'sleep')) {
        Case "live Claude reports $problem and invalidates the previous turn" {
            $live = Start-Live
            try {
                Save (Join-Path $capture 'stream-control.txt') $problem
                $result = Continue-Session $live.Paths.Session @('--timeout', '1')
                Failure $result
                Failure (Continue-Session $live.Paths.Session)
                Assert ((Read $live.Paths.Reply) -eq 'Independent finding') 'Live failure overwrote an earlier reply.'
            } finally {
                Remove-Item -LiteralPath (Join-Path $capture 'stream-control.txt') -Force -ErrorAction SilentlyContinue
                Stop-Live $live
            }
        }
    }
    Case 'an ended live conversation fails without silently restarting' {
        $live = Start-Live
        $savedSession = $live.Paths.Session
        Stop-Live $live
        $result = Continue-Session $savedSession
        Failure $result
        Assert ($result.Err.Contains('live Claude conversation has ended')) 'Ended conversation was silently replaced.'
    }
    $env:CLAUDE_CONFIG_DIR = $claudeConfig
    Save $message 'Assess the same task independently.'
    Case 'CLI exceptions appear in unexpected-failure diagnostics' {
        $env:FAKE_CASE = 'throw'
        $result = Fresh 'codex'
        Failure $result
        $errorText = ''
        try { [void](Success $result) } catch { $errorText = $_.Exception.Message }
        Assert ($errorText.Contains('CLI stderr:') -and $errorText.Contains('fixture exception')) 'Fixture stderr was omitted from the failure report.'
    }
    foreach ($problem in @('malformed', 'no-id', 'duplicate-id', 'no-completion', 'duplicate-completion', 'failed-event')) {
        Case "Codex rejects $problem events" {
            $env:FAKE_CASE = $problem
            Failure (Fresh 'codex')
        }
    }
    Case 'Codex rejects a different ID on resume' {
        $first = Success (Fresh 'codex')
        $env:FAKE_CASE = 'wrong-id'
        Failure (Continue-Session $first.Session)
    }
    Case 'explicit provider works without host detection and supports the same provider' {
        $env:CLAUDECODE = '1'
        $result = Success (Fresh 'claude')
        Assert ($result.Fields[1] -eq 'claude') 'Explicit same-provider request ignored.'
        $env:CLAUDECODE = ''
    }
    Case 'counterpart detection and ambiguous environment' {
        foreach ($hostProvider in @('claude', 'codex')) {
            $env:CLAUDECODE = ''
            $env:CODEX_THREAD_ID = ''
            if ($hostProvider -eq 'claude') { $env:CLAUDECODE = '1' } else { $env:CODEX_THREAD_ID = 'host-thread' }
            $result = Success (Invoke-Call @('--message', $message, '--cli', $fixture, '--artifacts', $artifacts))
            Assert ($result.Fields[1] -ne $hostProvider) 'Default did not select counterpart.'
        }
        $env:CLAUDECODE = '1'
        $env:CODEX_THREAD_ID = 'host-thread'
        Failure (Invoke-Call @('--message', $message, '--cli', $fixture))
        $env:CLAUDECODE = ''
        $env:CODEX_THREAD_ID = ''
        Failure (Invoke-Call @('--message', $message, '--cli', $fixture))
    }
    Case 'consultants cannot invoke the runner' {
        $env:CONSULT_CONSULTANT = '1'
        $result = Fresh
        Failure $result
        Assert ($result.Err.Contains('Consultants must not invoke consult')) 'Nested consultation was not blocked.'
        $env:CONSULT_CONSULTANT = ''
    }
    Case 'a consultant subprocess cannot start a nested consultation' {
        $env:FAKE_CASE = 'nested'
        [void](Success (Fresh))
        $nestedOut = Read (Join-Path $capture 'nested-out.txt')
        $nestedError = Read (Join-Path $capture 'nested-err.txt')
        Assert ([string]::IsNullOrWhiteSpace($nestedOut)) 'Nested invocation printed success output.'
        Assert ($nestedError.Contains('Consultants must not invoke consult')) 'Child process bypassed the consultant guard.'
    }
    Case 'resume rejects missing, malformed and changed settings' {
        Failure (Continue-Session (Join-Path $temp 'missing.txt'))
        $bad = Join-Path $temp 'invalid.txt'
        Save $bad ''
        Failure (Continue-Session $bad)
        Save $bad "consult-session-1`ncodex`ninvalid`n"
        Failure (Continue-Session $bad)
        $first = Success (Fresh)
        foreach ($change in @(@('--provider', 'codex'), @('--repo', $temp), @('--model', 'different'), @('--effort', 'low'))) {
            Failure (Continue-Session $first.Session $change)
        }
        [void](Success (Continue-Session $first.Session))
    }
    Case 'invalid input fails before running a CLI' {
        foreach ($arguments in @(@('--session', ''), @('--resume', 'unused'), @('--timeout', '0'), @('--timeout', 'bad'), @('--unknown', 'value'))) {
            Failure (Fresh 'claude' $arguments)
        }
        Save $message " `n`t"
        Failure (Fresh)
        Save $message 'Assess the same task independently.'
        Failure (Fresh 'claude' @('--artifacts', $repo))
        $inside = Join-Path $repo 'unexpected-diagnostics'
        Failure (Fresh 'claude' @('--artifacts', $inside))
        Assert (!(Test-Path -LiteralPath $inside)) 'Invalid diagnostics directory changed the project.'
    }
    Case 'parallel consultations keep their files and follow-ups separate' {
        $arguments = @('--repo', $repo, '--message', $message, '--cli', $fixture, '--artifacts', $artifacts)
        $a = Start-Call (@('--provider', 'claude') + $arguments)
        $b = Start-Call (@('--provider', 'codex') + $arguments)
        $first = Success (Finish-Call $a)
        $second = Success (Finish-Call $b)
        Assert ($first.Reply -ne $second.Reply -and $first.Session -ne $second.Session) 'Parallel calls shared output files.'
        Assert ($first.Fields[2] -ne $second.Fields[2]) 'Parallel calls shared a conversation.'
        [void](Success (Continue-Session $first.Session))
        [void](Success (Continue-Session $second.Session))
    }
    Case 'an active turn blocks a concurrent follow-up' {
        $first = Success (Fresh)
        $env:FAKE_CASE = 'sleep'
        $running = Start-Call @('--session', $first.Session, '--message', $message, '--timeout', '2')
        $lock = Join-Path (Split-Path (Split-Path $first.Session)) 'lock'
        $watch = [Diagnostics.Stopwatch]::StartNew()
        while (!(Test-Path -LiteralPath $lock) -and $watch.Elapsed.TotalSeconds -lt 8) { Start-Sleep -Milliseconds 30 }
        Assert (Test-Path -LiteralPath $lock) 'First follow-up did not acquire its lock.'
        $env:FAKE_CASE = ''
        Failure (Continue-Session $first.Session)
        Failure (Finish-Call $running)
        Failure (Continue-Session $first.Session)
    }
    Case 'checkout root is used when called from a subdirectory' {
        if (Get-Command git -ErrorAction SilentlyContinue) {
            & git -C $repo init -q
            $sub = Join-Path $repo 'subdirectory'
            [void][IO.Directory]::CreateDirectory($sub)
            $result = Success (Invoke-Call @('--provider', 'claude', '--message', $message, '--cli', $fixture, '--artifacts', $artifacts) $sub)
            Assert ($result.Fields[3] -eq $repo) 'Checkout root was not selected.'
            Assert ((Read (Join-Path $capture 'cwd.txt')).Trim() -eq $repo) 'CLI was not launched at checkout root.'
        }
        Assert ((Read (Join-Path $repo 'original.txt')) -eq 'untouched') 'Project file changed.'
    }
    [Console]::Out.WriteLine("Passed $count $Runner scenarios.")
} catch {
    if ($env:GITHUB_ACTIONS -eq 'true') {
        $detail = $_.Exception.Message.Replace('%', '%25').Replace("`r", '%0D').Replace("`n", '%0A')
        [Console]::Out.WriteLine('::error::' + $detail)
    }
    throw
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
