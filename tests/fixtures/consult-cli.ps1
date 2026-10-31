# An offline Claude/Codex CLI fixture.
$ErrorActionPreference = 'Stop'
$utf8 = New-Object Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8
[Console]::InputEncoding = $utf8
function Save($Name, $Value) { [IO.File]::WriteAllText((Join-Path $env:FAKE_CAPTURE $Name), [string]$Value, $utf8) }
Save 'cwd.txt' ([Environment]::CurrentDirectory)
Save 'args.txt' ($args -join "`n")
Save 'consultant.txt' $env:CONSULT_CONSULTANT
$provider = 'claude'
$session = ''
$output = ''
if ($args[0] -eq 'exec') {
    $provider = 'codex'
    if ($args[1] -eq 'resume') { $session = $args[2] }
}
for ($i = 0; $i -lt $args.Count; $i++) {
    switch ($args[$i]) {
        { $_ -in @('--session-id', '--resume') } { $session = $args[++$i] }
        '-o' { $output = $args[++$i] }
    }
}
if (!$session) { $session = [guid]::NewGuid().ToString() }
Save 'id.txt' $session
if ($args -contains '--input-format') {
    $previous = ''
    $turns = @()
    Save 'live-pid.txt' $PID
    while ($null -ne ($line = [Console]::In.ReadLine())) {
        $frame = ConvertFrom-Json $line
        Save 'prompt.txt' $frame.message.content
        $turns += $frame.message.content
        Save 'turn-count.txt' $turns.Count
        Save 'history.json' (ConvertTo-Json $turns -Compress)
        $case = $env:FAKE_CASE
        $control = Join-Path $env:FAKE_CAPTURE 'stream-control.txt'
        if (Test-Path -LiteralPath $control) { $case = [IO.File]::ReadAllText($control).Trim() }
        switch ($case) {
            'exit' { [Console]::Error.WriteLine('provider failure'); exit 7 }
            'sleep' { Start-Sleep -Seconds 30 }
            'malformed' { [Console]::Out.WriteLine('not an event'); continue }
            'no-result' { exit 0 }
        }
        $body = $env:FAKE_REPLY
        if (!$body) { $body = 'Independent finding' }
        if ($case -eq 'memory') {
            if (!$previous) { $previous = 'MEMORY_' + [guid]::NewGuid().ToString() }
            $body = $previous
        }
        if ($case -eq 'empty') { $body = '  ' }
        $responseId = $session
        if ($case -eq 'wrong-id') { $responseId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' }
        $event = @{ type = 'result'; is_error = ($case -eq 'error-event'); result = $body; session_id = $responseId }
        $encoded = ConvertTo-Json $event -Compress
        if ($case -eq 'escaped') {
            $encoded = [regex]::Replace($encoded, '[^\u0000-\u007f]', { param($match) '\u{0:x4}' -f [int][char]$match.Value })
        }
        [Console]::Out.WriteLine($encoded)
    }
    exit 0
}
Save 'prompt.txt' ([Console]::In.ReadToEnd())
switch ($env:FAKE_CASE) {
    'exit' { [Console]::Error.WriteLine('provider failure'); exit 7 }
    'throw' { throw 'fixture exception' }
    'sleep' { Start-Sleep -Seconds 30 }
    'nested' {
        $start = New-Object Diagnostics.ProcessStartInfo
        $start.FileName = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $start.Arguments = '-NoProfile -NonInteractive -File "' + $env:FAKE_RUNNER + '" --provider claude --message "' + (Join-Path $env:FAKE_CAPTURE 'prompt.txt') + '"'
        $start.UseShellExecute = $false
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $nested = [Diagnostics.Process]::Start($start)
        Save 'nested-out.txt' $nested.StandardOutput.ReadToEnd()
        Save 'nested-err.txt' $nested.StandardError.ReadToEnd()
        $nested.WaitForExit()
        $nestedCode = $nested.ExitCode
        $nested.Dispose()
        if ($nestedCode -eq 0) { exit 9 }
    }
}
$body = $env:FAKE_REPLY
if (!$body) { $body = 'Independent finding' }
if ($env:FAKE_CASE -eq 'empty') { $body = '   ' }
if ($env:FAKE_CASE -eq 'wrong-id') { $session = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' }
if ($provider -eq 'claude') { [Console]::Out.Write($body); exit 0 }
if ($env:FAKE_CASE -eq 'malformed') { [Console]::Out.WriteLine('not an event'); exit 0 }
if ($env:FAKE_CASE -ne 'no-id') {
    [Console]::Out.WriteLine('{"type":"thread.started","thread_id":"' + $session + '"}')
}
if ($env:FAKE_CASE -eq 'duplicate-id') { [Console]::Out.WriteLine('{"type":"thread.started","thread_id":"' + $session + '"}') }
if ($env:FAKE_CASE -eq 'failed-event') { [Console]::Out.WriteLine('{"type":"turn.failed","error":{"message":"failed"}}') }
if ($env:FAKE_CASE -ne 'no-completion') { [Console]::Out.WriteLine('{"type":"turn.completed","usage":{}}') }
if ($env:FAKE_CASE -eq 'duplicate-completion') { [Console]::Out.WriteLine('{"type":"turn.completed","usage":{}}') }
[IO.File]::WriteAllText($output, $body, $utf8)
