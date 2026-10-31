# Keep a live Claude process when its normal session directory is unavailable.
function Get-LiveProcessStamp($ProcessId) {
    if (!$isWindowsPlatform) { return ((& ps -p $ProcessId -o lstart=) -join '').Trim() }
    $owner = [Diagnostics.Process]::GetProcessById($ProcessId)
    try { return $owner.StartTime.ToUniversalTime().Ticks.ToString() }
    finally { $owner.Dispose() }
}
function Test-LiveClaude($Conversation) {
    $marker = Join-Path $Conversation 'live-process.txt'
    if (!(Test-Path -LiteralPath $marker)) { return $false }
    try {
        $identity = [IO.File]::ReadAllLines($marker, $utf8)
        return (Get-LiveProcessStamp ([int]$identity[0])) -eq $identity[1]
    } catch { return $false }
}
function Write-StreamPaths($Turn) {
    [Console]::Out.WriteLine('Reply: ' + (Join-Path $Turn 'reply.txt'))
    [Console]::Out.WriteLine('Session: ' + (Join-Path $Turn 'session.txt'))
}
function Close-ClaudeStream($Conversation) {
    Write-Text (Join-Path $Conversation 'stop') ''
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ((Test-LiveClaude $Conversation) -and $watch.Elapsed.TotalSeconds -lt 2) { [Threading.Thread]::Sleep(20) }
    if (Test-LiveClaude $Conversation) {
        $identity = [IO.File]::ReadAllLines((Join-Path $Conversation 'live-process.txt'), $utf8)
        $owner = [Diagnostics.Process]::GetProcessById([int]$identity[0])
        try { Stop-Tree $owner } finally { $owner.Dispose() }
    }
}
function Request-ClaudeStream($Conversation, $Turn, $Timeout) {
    if (!(Test-LiveClaude $Conversation)) { throw 'The live Claude conversation has ended.' }
    $pending = Join-Path $Conversation 'request.tmp'
    Write-Text $pending ($Turn + "`n" + $Timeout + "`n")
    [IO.File]::Move($pending, (Join-Path $Conversation 'request.txt'))
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while (!(Test-Path -LiteralPath (Join-Path $Turn 'completed'))) {
        if (!(Test-LiveClaude $Conversation)) { throw 'The live Claude conversation ended before replying.' }
        if ($watch.Elapsed.TotalSeconds -ge $Timeout + 5) {
            Write-Text (Join-Path $Conversation 'stop') ''
            throw 'Turn timed out.'
        }
        [Threading.Thread]::Sleep(20)
    }
    $errorFile = Join-Path $Turn 'error.txt'
    if (Test-Path -LiteralPath $errorFile) { throw (Read-Text $errorFile) }
    Write-StreamPaths $Turn
}
function Serve-ClaudeStream($Conversation, $Turn, $Timeout, $Settings, $CliArguments) {
    $process = $null
    $errors = $null
    $marker = Join-Path $Conversation 'live-process.txt'
    $state = Read-Text (Join-Path $Conversation 'live-state.txt')
    $sessionId = ($state -split '\r?\n')[2]
    try {
        $process = Run-Process $Settings.cli $CliArguments $Settings.repo '' $Timeout '' $true
        $errors = $process.StandardError.ReadToEndAsync()
        $nextLine = $process.StandardOutput.ReadLineAsync()
        Write-Text $marker ($PID.ToString() + "`n" + (Get-LiveProcessStamp $PID) + "`n")
        $first = $true
        while ($true) {
            $script:turn = $Turn
            $failed = $null
            try {
                Write-Text (Join-Path $Turn 'command.txt') ((@($Settings.cli) + $CliArguments) -join "`n")
                Write-Text (Join-Path $Turn 'stdout.txt') ''
                $frame = @{ type = 'user'; message = @{ role = 'user'; content = (Read-Text (Join-Path $Turn 'prompt.txt')) }; parent_tool_use_id = $null; session_id = $sessionId }
                $bytes = $utf8.GetBytes((ConvertTo-Json $frame -Compress -Depth 10) + "`n")
                $inputTask = $process.StandardInput.BaseStream.WriteAsync($bytes, 0, $bytes.Length)
                $flushing = $false
                $watch = [Diagnostics.Stopwatch]::StartNew()
                while ($true) {
                    if ($watch.Elapsed.TotalSeconds -ge $Timeout) { throw 'Turn timed out.' }
                    if ($inputTask.IsFaulted) { [void]$inputTask.GetAwaiter().GetResult() }
                    if (!$flushing -and $inputTask.IsCompleted) {
                        [void]$inputTask.GetAwaiter().GetResult()
                        $inputTask = $process.StandardInput.BaseStream.FlushAsync()
                        $flushing = $true
                    }
                    if (!$nextLine.IsCompleted) { [Threading.Thread]::Sleep(20); continue }
                    $line = $nextLine.GetAwaiter().GetResult()
                    if ($null -eq $line) { throw 'Claude exited before replying; inspect stderr.txt.' }
                    $nextLine = $process.StandardOutput.ReadLineAsync()
                    [IO.File]::AppendAllText((Join-Path $Turn 'stdout.txt'), $line + "`n", $utf8)
                    $event = ConvertFrom-Json $line
                    if ($event.type -ne 'result') { continue }
                    if ($event.session_id -cne $sessionId) { throw 'Claude returned a different conversation ID.' }
                    if ($event.is_error -ne $false) { throw 'Claude reported an unsuccessful turn.' }
                    if ([string]::IsNullOrWhiteSpace($event.result)) { throw 'CLI returned an empty reply.' }
                    Write-Text (Join-Path $Turn 'reply.txt') $event.result
                    Write-Text (Join-Path $Turn 'session.txt') $state
                    break
                }
            } catch {
                $failed = $_.Exception.Message
                Write-Text (Join-Path $Turn 'error.txt') $failed
            }
            if ($failed) {
                Stop-Tree $process
                if ($errors.Wait(5000)) { Write-Text (Join-Path $Turn 'stderr.txt') $errors.GetAwaiter().GetResult() }
            } else { Write-Text (Join-Path $Turn 'stderr.txt') '' }
            Write-Text (Join-Path $Turn 'completed') ''
            if ($failed) { throw $failed }
            if ($first) { Write-StreamPaths $Turn; $first = $false }
            $request = Join-Path $Conversation 'request.txt'
            while (!(Test-Path -LiteralPath $request)) {
                if (Test-Path -LiteralPath (Join-Path $Conversation 'stop')) { return }
                [Threading.Thread]::Sleep(20)
            }
            $requestFields = [IO.File]::ReadAllLines($request, $utf8)
            [IO.File]::Delete($request)
            $Turn = $requestFields[0]
            $Timeout = [int]$requestFields[1]
        }
    } finally {
        if ($process) {
            Stop-Tree $process
            if ($errors -and $errors.Wait(5000)) { Write-Text (Join-Path $Turn 'stderr.txt') $errors.GetAwaiter().GetResult() }
            $process.Dispose()
        }
        [IO.File]::Delete($marker)
    }
}
