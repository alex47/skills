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
$serverShell = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$serverPrefix = @('-NoProfile', '-NonInteractive', '-File', (Join-Path $root 'skills/engineering/consult/scripts/mcp-server.ps1'))
if ($Runner -eq 'Bash') {
    $serverShell = '/bin/bash'
    $serverPrefix = @(Join-Path $root 'skills/engineering/consult/scripts/mcp-server')
}
$count = 0
function Save($Path, [string]$Value) { [IO.File]::WriteAllText($Path, $Value, $utf8) }
function Read($Path) { [IO.File]::ReadAllText($Path, $utf8) }
function Assert($Condition, $Because) { if (!$Condition) { throw $Because } }
function Quote([string]$Value) {
    '"' + [regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
}
function Start-Call($Arguments, $Directory = $repo) {
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
    Assert ($lines.Count -eq 2 -and $lines[0].StartsWith('Reply: ') -and $lines[1].StartsWith('Session: ')) 'Success must print only two labeled paths.'
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
    $env:FAKE_REPLY_FILE = ''
    & $Body
    $script:count++
    [Console]::Out.WriteLine('ok ' + $script:count + ' - ' + $Name)
}

# A minimal MCP client over the server's stdin and stdout.
function Start-Server($Extra = @(), $ServerHost = 'codex') {
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $serverShell
    $serverArgs = $serverPrefix + @('--host', $ServerHost, '--cli', $fixture, '--artifacts', $artifacts) + $Extra
    $start.Arguments = (($serverArgs | ForEach-Object { Quote $_ }) -join ' ')
    $start.WorkingDirectory = $temp
    $start.UseShellExecute = $false
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = $utf8
    $start.StandardErrorEncoding = $utf8
    # Job directories go in the system temporary directory, so keep them inside the test's.
    foreach ($name in @('TMPDIR', 'TEMP', 'TMP')) { $start.EnvironmentVariables[$name] = $temp }
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    [void]$process.Start()
    return @{ Process = $process; Pending = $process.StandardOutput.ReadLineAsync(); Err = $process.StandardError.ReadToEndAsync(); Next = 0; Responses = @{} }
}
function Request($Server, $Method, $Params) {
    $Server.Next++
    $id = $Server.Next
    $json = ConvertTo-Json -Compress -Depth 10 -InputObject ([ordered]@{ jsonrpc = '2.0'; id = $id; method = $Method; params = $Params })
    $bytes = $utf8.GetBytes($json + "`n")
    $Server.Process.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
    $Server.Process.StandardInput.BaseStream.Flush()
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while (!$Server.Responses.ContainsKey($id)) {
        $left = 30000 - [int]$watch.Elapsed.TotalMilliseconds
        if ($left -le 0 -or !$Server.Pending.Wait($left)) { throw "No response to $Method." }
        $line = $Server.Pending.GetAwaiter().GetResult()
        if ($null -eq $line) { throw "Server exited during ${Method}: " + $Server.Err.GetAwaiter().GetResult() }
        $Server.Pending = $Server.Process.StandardOutput.ReadLineAsync()
        $message = ConvertFrom-Json $line
        $Server.Responses[[int]$message.id] = $message
    }
    $response = $Server.Responses[$id]
    $Server.Responses.Remove($id)
    return $response
}
function Tool($Server, $Name, $Arguments) {
    $response = Request $Server 'tools/call' ([ordered]@{ name = $Name; arguments = $Arguments })
    return @{ Text = [string]$response.result.content[0].text; IsError = [bool]$response.result.isError }
}
function Stop-Server($Server) {
    $Server.Process.StandardInput.Close()
    try {
        if (!$Server.Process.WaitForExit(15000)) { $Server.Process.Kill(); throw 'Server did not exit after its host disconnected.' }
    } finally { $Server.Process.Dispose() }
}
function Start-Consult($Server, $Arguments) {
    $result = Tool $Server 'consult' $Arguments
    Assert (!$result.IsError -and $result.Text -match '^Job: (.+)') ('consult did not return a job: ' + $result.Text)
    return $Matches[1].TrimEnd("`r")
}
function Collect($Server, $Job) {
    $reply = New-Object Text.StringBuilder
    $offset = $null
    for ($pages = 1; $pages -le 50; $pages++) {
        $arguments = [ordered]@{ job = $Job }
        if ($null -ne $offset) { $arguments.offset = $offset }
        $result = Tool $Server 'consult_wait' $arguments
        if ($result.IsError) { return @{ IsError = $true; Text = $result.Text } }
        if ($result.Text.StartsWith('The consultant is still working.')) { $pages--; continue }
        $footer = $result.Text.LastIndexOf("`n---`nSession: ")
        Assert ($footer -ge 0) ('Page has no session footer: ' + $result.Text)
        [void]$reply.Append($result.Text.Substring(0, $footer))
        $tail = $result.Text.Substring($footer + 5).Split("`n")
        $session = $tail[0].Substring(9)
        if ($tail[1] -eq 'End of reply.') {
            return @{ IsError = $false; Reply = $reply.ToString(); Session = $session; Pages = $pages; Fields = [IO.File]::ReadAllLines($session, $utf8) }
        }
        Assert ($tail[1] -match 'offset (\d+)\.$') ('Page footer has no offset: ' + $tail[1])
        $offset = [int]$Matches[1]
    }
    throw 'Reply did not end.'
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
    foreach ($provider in @('claude', 'codex')) {
        Case "$provider starts and resumes the exact conversation in the project directory" {
            $chosenModel = 'chosen "model" $() \ end'
            $first = Success (Fresh $provider @('--model', $chosenModel, '--effort', 'high'))
            Assert ($first.Fields.Count -eq 8 -and $first.Fields[0] -eq 'consult-session-1') 'Session is not the expected plain-text format.'
            Assert ($first.Fields[1] -eq $provider) 'Wrong provider.'
            if ($provider -eq 'claude') {
                Assert ($first.Fields[2] -match '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$') 'Assigned Claude ID is not a version 4 UUID.'
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
    Case 'MCP server lists the consultation tools' {
        $server = Start-Server
        try {
            $init = Request $server 'initialize' ([ordered]@{ protocolVersion = '2025-06-18'; capabilities = @{}; clientInfo = @{ name = 'test'; version = '0' } })
            Assert ($init.result.protocolVersion -eq '2025-06-18') 'Server did not answer initialize.'
            $tools = @((Request $server 'tools/list' @{}).result.tools)
            Assert ((@($tools | ForEach-Object { $_.name }) -join ',') -eq 'consult,consult_wait,consult_cancel') 'Unexpected tools.'
            Assert ($tools[0].annotations.readOnlyHint -and $tools[1].annotations.readOnlyHint) 'Consult and wait must be read-only.'
            Assert (!$tools[2].annotations.destructiveHint -and !$tools[2].annotations.openWorldHint) 'Cancel must be non-destructive and closed-world.'
        } finally { Stop-Server $server }
    }
    foreach ($serverHost in @('codex', 'claude')) {
        Case "MCP from $serverHost starts at once, returns the reply and continues the conversation" {
            $server = Start-Server @() $serverHost
            try {
                $job = Start-Consult $server ([ordered]@{ message = $message; repo = $repo })
                $first = Collect $server $job
                Assert (!$first.IsError) ('Consultation failed: ' + $first.Text)
                Assert ($first.Reply -ceq 'Independent finding' -and $first.Pages -eq 1) 'Reply text changed.'
                Assert ($first.Fields[1] -ne $serverHost -and $first.Fields[7] -eq $serverHost) 'Server did not consult the counterpart.'
                Save $message 'Clarify the earlier finding.'
                $second = Collect $server (Start-Consult $server ([ordered]@{ message = $message; session = $first.Session }))
                Assert (!$second.IsError -and $second.Fields[2] -eq $first.Fields[2]) 'Follow-up changed conversation.'
                Assert ((Read (Join-Path $capture 'prompt.txt')).Contains('Clarify the earlier finding.')) 'Follow-up message missing.'
                $other = Collect $server (Start-Consult $server ([ordered]@{ message = $message; repo = $repo; provider = $serverHost }))
                Assert ($other.Fields[1] -eq $serverHost) 'Explicit provider ignored.'
            } finally {
                Save $message 'Assess the same task independently.'
                Stop-Server $server
            }
        }
    }
    Case 'MCP returns long replies in complete pages' {
        $text = New-Object Text.StringBuilder
        for ($line = 1; $line -le 1500; $line++) { [void]$text.Append("Line $line $([char]0x03bb)$([char]0x65e5) `"quoted`" \ end`n") }
        [void]$text.Append(([string]([char]0x65e5) * 20000) + "`nlast line")
        $replyFile = Join-Path $temp 'long-reply.txt'
        Save $replyFile $text.ToString()
        $env:FAKE_REPLY_FILE = $replyFile
        $server = Start-Server
        try {
            $result = Collect $server (Start-Consult $server ([ordered]@{ message = $message; repo = $repo }))
            Assert (!$result.IsError -and $result.Pages -gt 3) 'Long reply was not paged.'
            Assert ($result.Reply -ceq $text.ToString()) 'Pages did not reassemble the exact reply.'
        } finally { Stop-Server $server }
    }
    Case 'MCP reports a failed consultation' {
        $env:FAKE_CASE = 'exit'
        $server = Start-Server
        try {
            $result = Collect $server (Start-Consult $server ([ordered]@{ message = $message; repo = $repo }))
            Assert ($result.IsError -and $result.Text.Contains('consult:') -and $result.Text.Contains('Diagnostics:')) 'Failure not reported.'
        } finally { Stop-Server $server }
    }
    Case 'MCP wait returns while the consultant works, and cancel stops it' {
        $env:FAKE_CASE = 'sleep'
        $server = Start-Server @('--wait-limit', '1')
        try {
            $job = Start-Consult $server ([ordered]@{ message = $message; repo = $repo })
            $running = Tool $server 'consult_wait' ([ordered]@{ job = $job })
            Assert (!$running.IsError -and $running.Text.StartsWith('The consultant is still working.')) 'Wait did not return while running.'
            $cancel = Tool $server 'consult_cancel' ([ordered]@{ job = $job })
            Assert (!$cancel.IsError -and $cancel.Text -eq 'Consultation cancelled.') 'Cancel failed.'
            $watch = [Diagnostics.Stopwatch]::StartNew()
            do { $after = Tool $server 'consult_wait' ([ordered]@{ job = $job }) } while ($after.Text.StartsWith('The consultant is still working.') -and $watch.Elapsed.TotalSeconds -lt 15)
            Assert ($after.IsError -and $after.Text.Contains('cancelled')) ('Cancelled job not reported: ' + $after.Text)
            Assert ($watch.Elapsed.TotalSeconds -lt 15) 'Cancel did not stop the consultation promptly.'
            Assert ((Tool $server 'consult_cancel' ([ordered]@{ job = $job })).Text -eq 'The consultation had already finished.') 'Second cancel misreported.'
        } finally { Stop-Server $server }
    }
    Case 'MCP server stops its consultations when the host disconnects' {
        $env:FAKE_CASE = 'sleep'
        $started = Join-Path $capture 'id.txt'
        if ($Runner -eq 'Bash') { $started = Join-Path $capture 'child.txt' }
        Remove-Item -LiteralPath $started -ErrorAction SilentlyContinue
        $server = Start-Server
        $job = Start-Consult $server ([ordered]@{ message = $message; repo = $repo })
        $watch = [Diagnostics.Stopwatch]::StartNew()
        while (!(Test-Path -LiteralPath $started) -and $watch.Elapsed.TotalSeconds -lt 10) { Start-Sleep -Milliseconds 50 }
        Stop-Server $server
        Assert (Test-Path -LiteralPath (Join-Path $job 'cancelled')) 'Running consultation was not stopped.'
        if ($Runner -eq 'Bash') {
            $child = [int](Read (Join-Path $capture 'child.txt')).Trim()
            $watch.Restart()
            while ((Get-Process -Id $child -ErrorAction SilentlyContinue) -and $watch.Elapsed.TotalSeconds -lt 10) { Start-Sleep -Milliseconds 100 }
            Assert (!(Get-Process -Id $child -ErrorAction SilentlyContinue)) 'Consultant process survived the disconnect.'
        }
    }
    Case 'MCP rejects invalid calls and consultants' {
        $server = Start-Server
        try {
            Assert (Tool $server 'consult_wait' ([ordered]@{ job = (Join-Path $temp 'missing') })).IsError 'Unknown job accepted.'
            Assert (Tool $server 'consult' ([ordered]@{ message = $message })).IsError 'New conversation without repo accepted.'
            Assert (Tool $server 'consult' ([ordered]@{ repo = $repo })).IsError 'Call without message accepted.'
            Assert (Tool $server 'unknown' @{}).IsError 'Unknown tool accepted.'
            if ($Runner -eq 'Bash') {
                $escaped = Tool $server 'consult' ([ordered]@{ message = ($message + '"'); repo = $repo })
                Assert ($escaped.IsError -and $escaped.Text.Contains('escaped')) 'Escaped argument was not refused.'
            }
        } finally { Stop-Server $server }
        $env:CONSULT_CONSULTANT = '1'
        $server = Start-Server
        try {
            $nested = Tool $server 'consult' ([ordered]@{ message = $message; repo = $repo })
            Assert ($nested.IsError -and $nested.Text.Contains('Consultants must not invoke consult')) 'Consultant started a consultation.'
        } finally {
            Stop-Server $server
            $env:CONSULT_CONSULTANT = ''
        }
    }
    [Console]::Out.WriteLine("Passed $count $Runner scenarios.")
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
