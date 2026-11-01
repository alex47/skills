# Stdio MCP server that exposes consultations as start, wait and cancel tools.
# Each consultation runs runner.ps1 as a background job outside the host's sandbox.
# Windows PowerShell 5.1 and PowerShell 7.
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$isWindowsPlatform = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
$runner = Join-Path $PSScriptRoot 'runner.ps1'
$shell = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$pageBytes = 16000

$settings = @{ 'wait-limit' = '100' }
for ($index = 0; $index -lt $args.Count; $index += 2) {
    $option = [string]$args[$index]
    if ($option -notin @('--host', '--cli', '--artifacts', '--wait-limit') -or $index + 1 -ge $args.Count) {
        [Console]::Error.WriteLine("consult: Invalid option: $option"); exit 1
    }
    $settings[$option.Substring(2)] = [string]$args[$index + 1]
}
$waitLimit = 0
if ($settings.host -cnotin @('claude', 'codex') -or ![int]::TryParse($settings['wait-limit'], [ref]$waitLimit) -or $waitLimit -lt 1) {
    [Console]::Error.WriteLine('consult: --host must be claude or codex, and --wait-limit a positive integer.'); exit 1
}
$jobsRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
$jobs = @{}
$waits = New-Object Collections.ArrayList

function Quote-Argument([string]$Value) {
    '"' + [regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
}
function Send($Message) {
    [Console]::Out.Write((ConvertTo-Json -InputObject $Message -Compress -Depth 10) + "`n")
    [Console]::Out.Flush()
}
function Reply($Id, [string]$Text, [bool]$IsError) {
    Send ([ordered]@{ jsonrpc = '2.0'; id = $Id; result = [ordered]@{ content = @([ordered]@{ type = 'text'; text = $Text }); isError = $IsError } })
}
function Stop-Tree($Process) {
    if (!$Process -or $Process.HasExited) { return }
    if ($isWindowsPlatform) {
        & taskkill.exe /PID $Process.Id /T /F > $null 2>&1
    } else {
        # The Windows server is also exercised under PowerShell on Unix in tests.
        $children = & ps -ax -o pid= -o ppid=
        foreach ($entry in $children) {
            if ($entry -match '^\s*(\d+)\s+(\d+)\s*$' -and [int]$Matches[2] -eq $Process.Id) {
                try { Stop-Tree ([Diagnostics.Process]::GetProcessById([int]$Matches[1])) } catch {}
            }
        }
        $Process.Kill()
    }
}
function Valid-Job([string]$Job) {
    $Job -and [IO.Path]::GetFileName($Job) -match '^consult-job\.[0-9a-f]{32}$' -and
        [IO.Path]::GetDirectoryName($Job) -eq $jobsRoot -and (Test-Path -LiteralPath (Join-Path $Job 'job') -PathType Leaf)
}

function Start-Consultation($Id, $Arguments) {
    if ($env:CONSULT_CONSULTANT -eq '1') { Reply $Id 'consult: Consultants must not invoke consult.' $true; return }
    if (!$Arguments.message) { Reply $Id 'consult: message is required.' $true; return }
    if (!$Arguments.project -and !$Arguments.session) { Reply $Id 'consult: project is required for a new conversation.' $true; return }
    $runnerArgs = @('--host', $settings.host, '--message', [string]$Arguments.message)
    # The tool's project argument is the runner's --repo.
    foreach ($pair in @(@('project', 'repo'), @('session', 'session'), @('provider', 'provider'), @('timeout', 'timeout'))) {
        $value = $Arguments.($pair[0])
        if ($null -ne $value -and [string]$value -ne '') { $runnerArgs += @("--$($pair[1])", [string]$value) }
    }
    if ($settings.cli) { $runnerArgs += @('--cli', $settings.cli) }
    if ($settings.artifacts -and !$Arguments.session) { $runnerArgs += @('--artifacts', $settings.artifacts) }
    $job = Join-Path $jobsRoot ('consult-job.' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($job)
    [IO.File]::WriteAllText((Join-Path $job 'job'), '', $utf8)
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $shell
    $start.Arguments = ((@('-NoProfile', '-NonInteractive', '-File', $runner) + $runnerArgs | ForEach-Object { Quote-Argument $_ }) -join ' ')
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = $utf8
    $start.StandardErrorEncoding = $utf8
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    [void]$process.Start()
    $process.StandardInput.Close()
    $jobs[$job] = @{ Process = $process; Out = $process.StandardOutput.ReadToEndAsync(); Err = $process.StandardError.ReadToEndAsync() }
    Reply $Id ("Job: $job`nThe consultant is working. Continue your own work, then call consult_collect with this job.") $false
}

# Record finished jobs on disk, so a wait reads the same files however the job ended.
function Update-Jobs {
    foreach ($job in @($jobs.Keys)) {
        $entry = $jobs[$job]
        if (!$entry.Process.HasExited) { continue }
        $entry.Process.WaitForExit()
        [IO.File]::WriteAllText((Join-Path $job 'out.txt'), $entry.Out.GetAwaiter().GetResult(), $utf8)
        [IO.File]::WriteAllText((Join-Path $job 'err.txt'), $entry.Err.GetAwaiter().GetResult(), $utf8)
        [IO.File]::WriteAllText((Join-Path $job 'exit'), [string]$entry.Process.ExitCode, $utf8)
        $entry.Process.Dispose()
        $jobs.Remove($job)
    }
}

# One page of the reply, cut at a line break and kept within the byte budget.
function Get-Page([string]$ReplyFile, [int]$Offset, [string]$Session) {
    $text = [IO.File]::ReadAllText($ReplyFile, $utf8)
    $Offset = [Math]::Min($Offset, $text.Length)
    $length = [Math]::Min($pageBytes, $text.Length - $Offset)
    while ($utf8.GetByteCount($text.Substring($Offset, $length)) -gt $pageBytes) {
        $length -= [Math]::Max(1, [int](($utf8.GetByteCount($text.Substring($Offset, $length)) - $pageBytes) / 3))
    }
    if ($Offset + $length -lt $text.Length) {
        $cut = $text.LastIndexOf([char]10, $Offset + $length - 1, $length)
        if ($cut -ge $Offset) { $length = $cut - $Offset + 1 }
        elseif ([char]::IsHighSurrogate($text[$Offset + $length - 1])) { $length-- }
    }
    $chunk = $text.Substring($Offset, $length)
    $Offset += $length
    $footer = 'End of reply.'
    if ($Offset -lt $text.Length) { $footer = "More of the reply remains. Call consult_collect again with this job and offset $Offset." }
    return $chunk + "`n---`nSession: " + $Session + "`n" + $footer
}

function Answer-Waits {
    foreach ($wait in @($waits)) {
        $job = $wait.Job
        if (!(Test-Path -LiteralPath (Join-Path $job 'exit'))) {
            if ([DateTime]::UtcNow -lt $wait.Deadline) { continue }
            Reply $wait.Id 'The consultant is still working. Call consult_collect again with this job.' $false
        } elseif (Test-Path -LiteralPath (Join-Path $job 'cancelled')) {
            Reply $wait.Id 'consult: Consultation cancelled.' $true
        } elseif ([IO.File]::ReadAllText((Join-Path $job 'exit'), $utf8).Trim() -ne '0') {
            Reply $wait.Id ([IO.File]::ReadAllText((Join-Path $job 'err.txt'), $utf8)) $true
        } else {
            $out = [IO.File]::ReadAllText((Join-Path $job 'out.txt'), $utf8)
            $replyFile = [regex]::Match($out, '(?m)^Reply: (.+?)\r?$').Groups[1].Value
            $session = [regex]::Match($out, '(?m)^Session: (.+?)\r?$').Groups[1].Value
            Reply $wait.Id (Get-Page $replyFile $wait.Offset $session) $false
        }
        $waits.Remove($wait)
    }
}

function Stop-Consultation([string]$Job) {
    if (Test-Path -LiteralPath (Join-Path $Job 'exit')) { return $false }
    [IO.File]::WriteAllText((Join-Path $Job 'cancelled'), '', $utf8)
    if ($jobs.ContainsKey($Job)) { Stop-Tree $jobs[$Job].Process }
    return $true
}

$tools = @(
    [ordered]@{ name = 'consult_start'; description = 'Start a turn with a separate read-only consultant. Returns a job immediately while the consultant works; collect the reply with consult_collect.'
        annotations = @{ readOnlyHint = $true }
        inputSchema = [ordered]@{ type = 'object'; required = @('message'); properties = [ordered]@{
            message = @{ type = 'string'; description = 'Absolute path to a UTF-8 text file containing your message' }
            project = @{ type = 'string'; description = 'Absolute path to the project folder; required for a new conversation' }
            session = @{ type = 'string'; description = 'Session path from the latest reply, to continue that conversation' }
            provider = @{ type = 'string'; enum = @('claude', 'codex'); description = 'Consultant provider for a new conversation; defaults to the other provider' }
            timeout = @{ type = 'integer'; description = 'Turn timeout in seconds; defaults to 600' } } } },
    [ordered]@{ name = 'consult_collect'; description = 'Collect the reply to a consultation job, waiting while the consultant works, page by page, followed by the session path for follow-ups.'
        annotations = @{ readOnlyHint = $true }
        inputSchema = [ordered]@{ type = 'object'; required = @('job'); properties = [ordered]@{
            job = @{ type = 'string'; description = 'Job returned by consult_start' }
            offset = @{ type = 'integer'; description = 'Offset given by the previous page; omit for the first page' } } } },
    [ordered]@{ name = 'consult_cancel'; description = 'Stop a running consultation job. A cancelled turn ends its conversation.'
        annotations = [ordered]@{ readOnlyHint = $false; destructiveHint = $false; openWorldHint = $false }
        inputSchema = [ordered]@{ type = 'object'; required = @('job'); properties = [ordered]@{
            job = @{ type = 'string'; description = 'Job returned by consult_start' } } } }
)

function Handle([string]$Line) {
    try { $request = ConvertFrom-Json $Line } catch { return }
    if ($null -eq $request.id -or !$request.method) { return }
    $id = $request.id
    switch ($request.method) {
        'initialize' {
            $version = '2025-06-18'
            if ($request.params.protocolVersion) { $version = [string]$request.params.protocolVersion }
            Send ([ordered]@{ jsonrpc = '2.0'; id = $id; result = [ordered]@{ protocolVersion = $version; capabilities = @{ tools = @{} }; serverInfo = @{ name = 'consult'; version = '1.0.0' } } })
        }
        'ping' { Send ([ordered]@{ jsonrpc = '2.0'; id = $id; result = @{} }) }
        'tools/list' { Send ([ordered]@{ jsonrpc = '2.0'; id = $id; result = @{ tools = $tools } }) }
        'tools/call' {
            $arguments = $request.params.arguments
            if ($null -eq $arguments) { $arguments = New-Object PSObject }
            switch ([string]$request.params.name) {
                'consult_start' { Start-Consultation $id $arguments }
                'consult_collect' {
                    $offset = 0
                    if (!(Valid-Job ([string]$arguments.job))) { Reply $id 'consult: Unknown job.' $true }
                    elseif ($null -ne $arguments.offset -and (![int]::TryParse([string]$arguments.offset, [ref]$offset) -or $offset -lt 0)) {
                        Reply $id 'consult: offset must be an integer.' $true
                    } else {
                        [void]$waits.Add(@{ Id = $id; Job = [string]$arguments.job; Offset = $offset; Deadline = [DateTime]::UtcNow.AddSeconds($waitLimit) })
                    }
                }
                'consult_cancel' {
                    if (!(Valid-Job ([string]$arguments.job))) { Reply $id 'consult: Unknown job.' $true }
                    elseif (Stop-Consultation ([string]$arguments.job)) { Reply $id 'Consultation cancelled.' $false }
                    else { Reply $id 'The consultation had already finished.' $false }
                }
                default { Reply $id 'consult: Unknown tool.' $true }
            }
        }
        default { Send ([ordered]@{ jsonrpc = '2.0'; id = $id; error = [ordered]@{ code = -32601; message = 'Method not found' } }) }
    }
}

# One loop reads requests and settles jobs and waits, so a pending wait never blocks other calls.
try {
    $reader = New-Object IO.StreamReader([Console]::OpenStandardInput(), $utf8)
    $pending = $reader.ReadLineAsync()
    while ($true) {
        if ($pending.Wait(100)) {
            $line = $pending.GetAwaiter().GetResult()
            if ($null -eq $line) { break }
            Handle $line
            $pending = $reader.ReadLineAsync()
        }
        Update-Jobs
        Answer-Waits
    }
} finally {
    foreach ($job in @($jobs.Keys)) { [void](Stop-Consultation $job) }
}
