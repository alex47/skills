# Native consultation runner for Windows PowerShell 5.1 and PowerShell 7.
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8
$isWindowsPlatform = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT

function Write-Text($Path, [string]$Text) { [IO.File]::WriteAllText($Path, $Text, $utf8) }
function Read-Text($Path) { [IO.File]::ReadAllText($Path, $utf8) }
function Full-Path($Path) { $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path) }
function Valid-Id([string]$Value) { $Value -cmatch '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$' }
function Quote-Argument([string]$Value) {
    # Quote arguments for ProcessStartInfo.Arguments.
    '"' + [regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
}
function Check-Outside([string]$Path) {
    $prefix = $repo.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $comparison = [StringComparison]::Ordinal
    if ($isWindowsPlatform) { $comparison = [StringComparison]::OrdinalIgnoreCase }
    if ($Path.Equals($repo, $comparison) -or $Path.StartsWith($prefix, $comparison)) {
        throw 'Keep diagnostic files outside the project.'
    }
}
function Stop-Tree($Process) {
    if (!$Process -or $Process.HasExited) { return }
    if ($isWindowsPlatform) {
        & taskkill.exe /PID $Process.Id /T /F > $null 2>&1
    } else {
        # The Windows runner is also exercised under PowerShell on Unix in tests.
        $children = & ps -ax -o pid= -o ppid=
        foreach ($entry in $children) {
            if ($entry -match '^\s*(\d+)\s+(\d+)\s*$' -and [int]$Matches[2] -eq $Process.Id) {
                try { Stop-Tree ([Diagnostics.Process]::GetProcessById([int]$Matches[1])) } catch {}
            }
        }
        $Process.Kill()
    }
}
function Run-Process($Executable, $Arguments, $Directory, [string]$InputText, [int]$Timeout, $Diagnostics = '') {
    $start = New-Object Diagnostics.ProcessStartInfo
    if ([IO.Path]::GetExtension($Executable) -eq '.ps1') {
        # Launch PowerShell wrappers with the current PowerShell executable.
        $Arguments = @('-NoProfile', '-NonInteractive', '-File', $Executable) + $Arguments
        $Executable = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    }
    $start.FileName = $Executable
    $start.Arguments = (($Arguments | ForEach-Object { Quote-Argument $_ }) -join ' ')
    $start.WorkingDirectory = $Directory
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = $utf8
    $start.StandardErrorEncoding = $utf8
    $start.EnvironmentVariables['CONSULT_CONSULTANT'] = '1'
    # Independent Claude sessions must not inherit its nested-session marker.
    $start.EnvironmentVariables.Remove('CLAUDECODE')
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    $started = $false
    try {
        [void]$process.Start()
        $started = $true
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        # Async input avoids deadlock when a CLI exits early or produces output first.
        # Writing UTF-8 bytes also works on Windows PowerShell's .NET Framework.
        $inputBytes = $utf8.GetBytes($InputText)
        $inputTask = $process.StandardInput.BaseStream.WriteAsync($inputBytes, 0, $inputBytes.Length)
        $watch = [Diagnostics.Stopwatch]::StartNew()
        while (!$inputTask.IsCompleted -and !$process.HasExited) {
            if ($watch.Elapsed.TotalSeconds -ge $Timeout) { throw 'Turn timed out.' }
            [Threading.Thread]::Sleep(20)
        }
        if (!$process.HasExited) { $inputTask.GetAwaiter().GetResult(); $process.StandardInput.BaseStream.Close() }
        $remaining = [Math]::Max(1, [int](1000 * ($Timeout - $watch.Elapsed.TotalSeconds)))
        if (!$process.WaitForExit($remaining)) { throw 'Turn timed out.' }
        $process.WaitForExit()
        return @{ Code = $process.ExitCode; Out = $stdout.GetAwaiter().GetResult(); Err = $stderr.GetAwaiter().GetResult() }
    } finally {
        if ($started) { Stop-Tree $process }
        if ($started -and $Diagnostics) {
            [void]$process.WaitForExit(5000)
            if ($stdout.IsCompleted) { Write-Text (Join-Path $Diagnostics 'stdout.txt') $stdout.GetAwaiter().GetResult() }
            if ($stderr.IsCompleted) { Write-Text (Join-Path $Diagnostics 'stderr.txt') $stderr.GetAwaiter().GetResult() }
        }
        $process.Dispose()
    }
}

$settings = @{}
$lockStream = $null
$lockPath = $null
$turn = $null
try {
    if ($env:CONSULT_CONSULTANT -eq '1') { throw 'Consultants must not invoke consult.' }
    for ($index = 0; $index -lt $args.Count; $index++) {
        $option = [string]$args[$index]
        if ($option -in @('--help', '-h')) {
            [Console]::Out.WriteLine('Usage: runner.ps1 --message FILE [--resume SESSION.txt]')
            [Console]::Out.WriteLine('Options: --provider claude|codex --repo DIR --timeout SECONDS')
            [Console]::Out.WriteLine('Advanced: --host --model --effort --cli --artifacts')
            exit 0
        }
        if ($option -notin @('--host', '--provider', '--repo', '--resume', '--message', '--model', '--effort', '--cli', '--artifacts', '--timeout')) {
            throw "Unknown option: $option"
        }
        $index++
        if ($index -ge $args.Count -or [string]::IsNullOrWhiteSpace($args[$index])) { throw "$option needs a nonempty value." }
        $value = [string]$args[$index]
        if ($value.Contains("`n") -or $value.Contains("`r")) { throw 'Options cannot contain line breaks.' }
        $settings[$option.Substring(2)] = $value
    }
    if (!$settings.message -or !(Test-Path -LiteralPath $settings.message -PathType Leaf)) { throw '--message must name a text file.' }
    $messageText = Read-Text (Full-Path $settings.message)
    if ([string]::IsNullOrWhiteSpace($messageText)) { throw 'Message is empty.' }
    $timeout = 600
    if ($settings.ContainsKey('timeout') -and (![int]::TryParse($settings.timeout, [ref]$timeout) -or $timeout -lt 1 -or $timeout -gt 2147483)) {
        throw '--timeout must be a positive integer below 2147484.'
    }
    foreach ($name in @('provider', 'host')) {
        if ($settings[$name] -and $settings[$name] -cnotin @('claude', 'codex')) { throw "Unknown $name." }
    }
    if ($settings.effort -and $settings.effort -cnotin @('low', 'medium', 'high', 'xhigh', 'max')) { throw 'Unknown effort.' }
    $session = ''
    $conversation = ''
    if ($settings.resume) {
        if ($settings.artifacts) { throw '--artifacts is only valid for a new conversation.' }
        $resume = Full-Path $settings.resume
        $fields = [IO.File]::ReadAllLines($resume, $utf8)
        if ($fields.Count -ne 8 -or $fields[0] -cne 'consult-session-1' -or $fields[1] -cnotin @('claude', 'codex') -or !(Valid-Id $fields[2])) {
            throw 'Invalid session file.'
        }
        foreach ($pair in @(@('provider', 1), @('model', 4), @('effort', 5), @('cli', 6), @('host', 7))) {
            if ($settings[$pair[0]] -and $settings[$pair[0]] -cne $fields[$pair[1]]) { throw "$($pair[0]) differs from the saved session." }
            $settings[$pair[0]] = $fields[$pair[1]]
        }
        if ($settings.repo -and (Full-Path $settings.repo) -ne $fields[3]) { throw 'Working directory differs from the saved session.' }
        $settings.repo = $fields[3]
        if (![IO.Path]::IsPathRooted($settings.repo)) { throw 'Invalid saved working directory.' }
        $session = $fields[2]
        if ([IO.Path]::GetFileName($resume) -cne 'session.txt') { throw 'Invalid session path.' }
        $conversation = [IO.Directory]::GetParent([IO.Path]::GetDirectoryName($resume)).FullName
    } else {
        if (!$settings.host) {
            $claudeHost = $env:CLAUDECODE -in @('1', 'true')
            $codexHost = ![string]::IsNullOrWhiteSpace($env:CODEX_THREAD_ID + $env:CODEX_SESSION_ID)
            if ($claudeHost -and !$codexHost) { $settings.host = 'claude' }
            if ($codexHost -and !$claudeHost) { $settings.host = 'codex' }
        }
        if (!$settings.provider) {
            switch ($settings.host) {
                'claude' { $settings.provider = 'codex' }
                'codex' { $settings.provider = 'claude' }
                default { throw 'Cannot identify the caller; specify --provider claude or codex.' }
            }
        }
        if (!$settings.repo) { $settings.repo = (Get-Location).Path }
        $settings.repo = Full-Path $settings.repo
        if (Get-Command git -ErrorAction SilentlyContinue) {
            $git = (Get-Command git -CommandType Application | Select-Object -First 1).Source
            $top = Run-Process $git @('-C', $settings.repo, 'rev-parse', '--show-toplevel') $settings.repo '' 30
            if ($top.Code -eq 0) { $settings.repo = Full-Path $top.Out.Trim() }
        }
    }
    $repo = Full-Path $settings.repo
    if (!(Test-Path -LiteralPath $repo -PathType Container)) { throw 'Working directory does not exist.' }
    if (!$settings.cli) {
        $found = Get-Command $settings.provider -CommandType Application,ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1
        if (!$found) { throw "$($settings.provider) is not on PATH." }
        $settings.cli = $found.Source
    }
    if (![IO.Path]::IsPathRooted($settings.cli) -or !(Test-Path -LiteralPath $settings.cli -PathType Leaf)) { throw '--cli must be an absolute executable path.' }
    if ([IO.Path]::GetExtension($settings.cli) -in @('.cmd', '.bat')) {
        throw 'Expected a native CLI executable. Put it on PATH or select it with --cli.'
    }
    if (!$conversation) {
        $parent = [IO.Path]::GetTempPath()
        if ($settings.artifacts) { $parent = Full-Path $settings.artifacts }
        Check-Outside $parent
        $conversation = Join-Path $parent ('consult.' + [guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($conversation)
    }
    Check-Outside $conversation
    $lockPath = Join-Path $conversation 'lock'
    try { $lockStream = [IO.File]::Open($lockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None) }
    catch { $lockPath = $null; throw 'Conversation has an active or interrupted turn.' }
    $latest = Join-Path $conversation 'latest.txt'
    if ($settings.resume -and (!(Test-Path -LiteralPath $latest) -or (Read-Text $latest).TrimEnd("`r", "`n") -cne $resume)) {
        throw 'Session is stale; use only the latest successful turn.'
    }
    $turn = Join-Path $conversation ('turn.' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($turn)
    $sessionPath = Join-Path $turn 'session.txt'
    Write-Text $latest ($sessionPath + "`n")
    $instructions = Read-Text (Join-Path $PSScriptRoot 'consultant.txt')
    $prompt = $instructions + "`nHOST MESSAGE:`n" + $messageText
    Write-Text (Join-Path $turn 'prompt.txt') $prompt
    $reply = Join-Path $turn 'reply.txt'
    if ($settings.provider -eq 'claude') {
        $cliArgs = @('-p', '--output-format', 'text', '--tools', 'Read,Glob,Grep', '--allowedTools', 'Read,Glob,Grep', '--permission-mode', 'dontAsk')
        if ($session) { $cliArgs += @('--resume', $session) }
        else { $session = [guid]::NewGuid().ToString(); $cliArgs += @('--session-id', $session) }
        if ($settings.model) { $cliArgs += @('--model', $settings.model) }
        if ($settings.effort) { $cliArgs += @('--effort', $settings.effort) }
    } else {
        $cliArgs = @('exec')
        if ($session) { $cliArgs += @('resume', $session) }
        $cliArgs += @('-c', 'sandbox_mode="read-only"', '-c', 'approval_policy="never"', '--disable', 'multi_agent', '--json', '-o', $reply, '--skip-git-repo-check')
        if ($settings.model) { $cliArgs += @('-m', $settings.model) }
        if ($settings.effort) { $cliArgs += @('-c', ('model_reasoning_effort="' + $settings.effort + '"')) }
        $cliArgs += '-'
    }
    Write-Text (Join-Path $turn 'command.txt') ((@($settings.cli) + $cliArgs) -join "`n")
    $result = Run-Process $settings.cli $cliArgs $repo $prompt $timeout $turn
    if ($result.Code -ne 0) { throw "$($settings.provider) exited $($result.Code); inspect stderr.txt." }
    if ($settings.provider -eq 'claude') { Write-Text $reply $result.Out }
    else {
        $events = @($result.Out -split '\r?\n' | Where-Object { $_.Trim() } | ForEach-Object { ConvertFrom-Json $_ })
        $started = @($events | Where-Object { $_.type -eq 'thread.started' })
        $completed = @($events | Where-Object { $_.type -eq 'turn.completed' })
        if ($started.Count -ne 1 -or !(Valid-Id $started[0].thread_id) -or $completed.Count -ne 1) { throw 'Missing or ambiguous Codex conversation/completion event.' }
        if (@($events | Where-Object { $_.type -in @('error', 'turn.failed') }).Count) { throw 'Codex reported a failed turn.' }
        if ($session -and $session -cne $started[0].thread_id) { throw 'Codex resumed a different conversation.' }
        $session = $started[0].thread_id
    }
    if (!(Test-Path -LiteralPath $reply) -or [string]::IsNullOrWhiteSpace((Read-Text $reply))) { throw 'CLI returned an empty reply.' }
    $record = @('consult-session-1', $settings.provider, $session, $repo, [string]$settings.model, [string]$settings.effort, $settings.cli, [string]$settings.host)
    Write-Text $sessionPath (($record -join "`n") + "`n")
    [Console]::Out.WriteLine('Reply: ' + $reply)
    [Console]::Out.WriteLine('Resume: ' + $sessionPath)
    exit 0
} catch {
    [Console]::Error.WriteLine('consult: ' + $_.Exception.Message)
    if ($turn) { [Console]::Error.WriteLine('Diagnostics: ' + $turn) }
    exit 1
} finally {
    if ($lockStream) { $lockStream.Dispose(); [IO.File]::Delete($lockPath) }
}
