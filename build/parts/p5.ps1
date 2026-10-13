
# =============================================================================
# Region: workload (the "now use what's left" step)
# =============================================================================

function Get-WorkloadCpuList {
    <#
        Which logical CPUs the workload is allowed to use.

        * No game CPU cap: the workload gets every CPU in the group except the
          ones pinned to the game. Hard spatial separation.
        * Game CPU cap set: the workload also gets the game's core, because the
          game is already limited to a fraction of it by the job's rate control.
          That is the only honest way to "share one core" between two programs.
    #>
    param([Parameter(Mandatory)] $Topology, [Parameter(Mandatory)] $State)

    $all = @(0..($Topology.Group0Logical - 1))
    if ($State.CpuRateUnits -gt 0) { return $all }

    $free = New-Object System.Collections.Generic.List[int]
    foreach ($cpu in $all) {
        if ($State.CpuList -notcontains $cpu) { $free.Add($cpu) }
    }
    if ($free.Count -eq 0) {
        Write-Log -Level WARN -Message 'every logical CPU is pinned to the game; the workload will share the pinned core'
        return $all
    }
    return $free.ToArray()
}

function Split-CommandLine {
    <#
        Minimal Windows command-line tokenizer: splits on whitespace, respects
        double quotes. Good enough for launching .exe/.ps1/.bat/.py/.lua with
        arguments, and it refuses to guess about anything exotic.
    #>
    param([Parameter(Mandatory)][string] $CommandLine)

    $tokens = New-Object System.Collections.Generic.List[string]
    $current = New-Object System.Text.StringBuilder
    $inQuotes = $false
    $hasContent = $false

    foreach ($ch in $CommandLine.ToCharArray()) {
        if ($ch -eq '"') {
            $inQuotes = -not $inQuotes
            $hasContent = $true
            continue
        }
        if (-not $inQuotes -and [char]::IsWhiteSpace($ch)) {
            if ($hasContent) {
                $tokens.Add($current.ToString())
                [void]$current.Clear()
                $hasContent = $false
            }
            continue
        }
        [void]$current.Append($ch)
        $hasContent = $true
    }
    if ($hasContent) { $tokens.Add($current.ToString()) }
    return $tokens.ToArray()
}

function Resolve-WorkloadProgram {
    <#
        Turns what the operator typed into an executable plus an argument string.
    #>
    param([Parameter(Mandatory)][string] $CommandLine)

    $tokens = @(Split-CommandLine -CommandLine $CommandLine)
    if ($tokens.Count -eq 0) { throw 'the command line is empty' }

    $first = $tokens[0]
    $rest = @()
    if ($tokens.Count -gt 1) { $rest = $tokens[1..($tokens.Count - 1)] }
    $restText = ($rest -join ' ')

    $ext = [System.IO.Path]::GetExtension($first).ToLowerInvariant()
    $isFile = Test-Path -LiteralPath $first -PathType Leaf

    if ($isFile -or ($ext -in @('.ps1', '.bat', '.cmd', '.py', '.lua', '.exe'))) {
        if ($isFile) { $first = (Resolve-Path -LiteralPath $first).ProviderPath }
        switch ($ext) {
            '.ps1' {
                $shell = 'powershell.exe'
                if (Get-Command 'pwsh' -ErrorAction SilentlyContinue) { $shell = 'pwsh' }
                return [pscustomobject]@{
                    FilePath = $shell
                    Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$first`" $restText"
                    Kind = 'PowerShell script'
                }
            }
            '.bat' {
                return [pscustomobject]@{ FilePath = 'cmd.exe'; Arguments = "/c `"$first`" $restText"; Kind = 'batch file' }
            }
            '.cmd' {
                return [pscustomobject]@{ FilePath = 'cmd.exe'; Arguments = "/c `"$first`" $restText"; Kind = 'command script' }
            }
            '.py' {
                $py = 'python.exe'
                if (Get-Command 'py' -ErrorAction SilentlyContinue) { $py = 'py' }
                elseif (Get-Command 'python' -ErrorAction SilentlyContinue) { $py = 'python' }
                return [pscustomobject]@{ FilePath = $py; Arguments = "`"$first`" $restText"; Kind = 'python script' }
            }
            '.lua' {
                $lua = $null
                foreach ($cand in @('luau', 'lua54', 'lua5.4', 'lua', 'lua5.1')) {
                    if (Get-Command $cand -ErrorAction SilentlyContinue) { $lua = $cand; break }
                }
                if (-not $lua) {
                    throw 'no lua/luau interpreter on PATH. Note: the roblox/*.lua reporter is meant to be pasted into Studio or a Roblox executor, not run from here.'
                }
                return [pscustomobject]@{ FilePath = $lua; Arguments = "`"$first`" $restText"; Kind = 'lua script' }
            }
            default {
                return [pscustomobject]@{ FilePath = $first; Arguments = $restText; Kind = 'executable' }
            }
        }
    }

    # Not a file: trust CreateProcess to find it on PATH (a bare "notepad" or
    # "obs64.exe" resolves through the standard search order).
    return [pscustomobject]@{ FilePath = $first; Arguments = $restText; Kind = 'command' }
}

function Start-HarnessWorkload {
    <#
        Starts the workload, then puts it (and, by job inheritance, everything it
        spawns) into its own job with the CPUs and CPU share it was allocated.
    #>
    param(
        [Parameter(Mandatory)][string] $Command,
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)][int[]] $CpuList,
        [switch] $Hidden
    )

    $program = Resolve-WorkloadProgram -CommandLine $Command
    Write-Kv 'program' "$($program.FilePath) $($program.Arguments)" -Color White
    Write-Kv 'kind' $program.Kind
    Write-Kv 'cpus for the workload' "$($CpuList -join ', ')"

    $startArgs = @{
        FilePath     = $program.FilePath
        ArgumentList = $program.Arguments
        PassThru     = $true
    }
    if ($Hidden) { $startArgs['NoNewWindow'] = $true }

    $proc = Start-Process @startArgs
    if (-not $proc) { throw "could not start '$Command'" }
    Write-Log -Level OK -Message "workload started: $($proc.ProcessName) (pid $($proc.Id))"

    # Give it a moment so the process exists, then constrain it.
    Start-Sleep -Milliseconds 200
    $script:WorkloadPid = $proc.Id

    try {
        $job = New-HarnessJob -Name 'Workload'
        $mask = ConvertFrom-CpuList -Cpu $CpuList
        $ok = [HarnessNative]::SetJobLimits($job.ToInt64(), $false, [uint64]0, [uint64]0,
            $true, [uint64]$mask, $true, [uint32]0x00000020, $false, [uint64]0)
        if (-not $ok) { Write-Log -Level WARN -Message (Get-NativeError 'SetInformationJobObject (workload)') }
        if ($State.WorkloadUnits -gt 0 -and $State.CpuRateUnits -gt 0) {
            [void](Set-HarnessJobCpuRate -Job $job -RateUnits $State.WorkloadUnits)
        }
        $h = Get-ProcessHandle -ProcessId $proc.Id
        if ($h -ne [IntPtr]::Zero) {
            if ([HarnessNative]::AssignToJob($job.ToInt64(), $h.ToInt64())) {
                Write-Log -Level OK -Message "workload bound to $(Format-Mask -Mask $mask)"
                if ($State.CpuRateUnits -gt 0) {
                    Write-Kv 'workload cpu share' "$($State.WorkloadPercent)% of the pinned core (guaranteed)"
                }
            } else {
                Write-Log -Level WARN -Message (Get-NativeError 'AssignProcessToJobObject (workload)')
            }
        }
    } catch {
        Write-Log -Level WARN -Message "could not constrain the workload: $($_.Exception.Message)"
    }

    return $proc
}

function Resolve-WorkloadChoice {
    <#
        The prompt the whole script exists for: "what should run on what's left?"
    #>
    param(
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)][int[]] $CpuList
    )

    Write-Rule 'what should run on the remaining resources?'
    Write-Kv 'free cpus' "$($CpuList -join ', ')" -Color Cyan
    if ($State.CpuRateUnits -gt 0) {
        Write-Kv 'guaranteed share' "$($State.WorkloadPercent)% of the pinned core"
    }

    if ($Workload) {
        return [pscustomobject]@{ Mode = 'command'; Command = $Workload }
    }

    $options = @(
        @{ Label = 'type a command line to run'; Value = 'command'; Hint = 'exe, script or one-liner'; },
        @{ Label = 'run a file'; Value = 'file'; Hint = '.ps1 .bat .cmd .exe .py .lua'; },
        @{ Label = 'open a pinned shell for me to work in'; Value = 'shell'; Hint = 'interactive, already bound'; },
        @{ Label = 'nothing - just hold the game allocation'; Value = 'none'; Hint = 'watch only'; }
    )
    $pick = Read-HarnessChoice -Question 'What do you want to run?' -Options $options -DefaultIndex 0

    switch ($pick) {
        'command' {
            $cmd = Read-HarnessText -Question 'command line' -Default ''
            if (-not $cmd) { return [pscustomobject]@{ Mode = 'none' } }
            return [pscustomobject]@{ Mode = 'command'; Command = $cmd }
        }
        'file' {
            $path = Read-HarnessText -Question 'path to the file' -Default ''
            if (-not $path) { return [pscustomobject]@{ Mode = 'none' } }
            $args2 = Read-HarnessText -Question 'arguments (optional)' -Default ''
            $line = "`"$path`" $args2"
            return [pscustomobject]@{ Mode = 'command'; Command = $line }
        }
        'shell' {
            return [pscustomobject]@{ Mode = 'shell' }
        }
        default { return [pscustomobject]@{ Mode = 'none' } }
    }
}

function Start-PinnedShell {
    <#
        Opens an interactive PowerShell whose process tree is already bound to the
        allocated CPUs, so anything typed inside inherits the allocation.
    #>
    param([Parameter(Mandatory)] $State, [Parameter(Mandatory)][int[]] $CpuList)

    $shell = $PSHOME
    $exe = Join-Path $shell 'pwsh.exe'
    if (-not (Test-Path -LiteralPath $exe)) { $exe = Join-Path $shell 'powershell.exe' }
    if (-not (Test-Path -LiteralPath $exe)) { $exe = 'powershell.exe' }

    $banner = "Write-Host 'Harness shell: bound to CPU $($CpuList -join ', ')' -ForegroundColor Cyan"
    if ($State.CpuRateUnits -gt 0) {
        $banner += "; Write-Host 'CPU share: $($State.WorkloadPercent)% of the pinned core' -ForegroundColor DarkGray"
    }
    $banner += "; Write-Host 'Close this window when you are done.' -ForegroundColor DarkGray"

    $proc = Start-Process -FilePath $exe -ArgumentList "-NoExit -NoProfile -Command `"$banner`"" -PassThru
    Start-Sleep -Milliseconds 150

    try {
        $job = New-HarnessJob -Name 'Workload'
        $mask = ConvertFrom-CpuList -Cpu $CpuList
        [void][HarnessNative]::SetJobLimits($job.ToInt64(), $false, [uint64]0, [uint64]0,
            $true, [uint64]$mask, $false, [uint32]0, $false, [uint64]0)
        if ($State.CpuRateUnits -gt 0) { [void](Set-HarnessJobCpuRate -Job $job -RateUnits $State.WorkloadUnits) }
        $h = Get-ProcessHandle -ProcessId $proc.Id
        if ($h -ne [IntPtr]::Zero -and [HarnessNative]::AssignToJob($job.ToInt64(), $h.ToInt64())) {
            Write-Log -Level OK -Message "shell bound to $(Format-Mask -Mask $mask)"
        } else {
            Write-Log -Level WARN -Message 'shell started but could not be bound to the allocation'
        }
    } catch {
        Write-Log -Level WARN -Message "shell binding failed: $($_.Exception.Message)"
    }
    return $proc
}

# =============================================================================
# Region: watch loop
# =============================================================================

function Invoke-HarnessWatchLoop {
    <#
        Holds the allocation: re-asserts it when anything resets it, re-discovers
        the client if it restarts, and prints a periodic status line.
    #>
    param(
        [Parameter(Mandatory)][object[]] $Targets,
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)] $Topology,
        [int] $IntervalSec = 3,
        [switch] $UntilKeypress
    )

    if ($IntervalSec -lt 1) { $IntervalSec = 1 }
    Write-Rule 'holding the allocation'
    Write-Log -Level INFO -Message "watch loop every ${IntervalSec}s"
    if ($UntilKeypress) {
        Write-Log -Level INFO -Message 'press Q to stop holding and restore, or close the window'
    } else {
        Write-Log -Level INFO -Message 'press Ctrl+C to stop holding and restore'
    }

    $useKeys = $false
    if ($UntilKeypress) {
        try {
            [Console]::TreatControlCAsInput = $true
            $useKeys = $true
        } catch {
            Write-Log -Level DEBUG -Message 'console key handling unavailable; Ctrl+C only'
        }
    }

    $cycles = 0
    $rediscoveries = 0
    $liveTargets = $Targets
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $lastReport = $stopwatch.Elapsed

    try {
        while ($true) {
            Start-Sleep -Seconds $IntervalSec
            $cycles++

            if ($useKeys) {
                while ([Console]::KeyAvailable) {
                    $key = [Console]::ReadKey($true)
                    if ($key.Key -eq [ConsoleKey]::Q) {
                        Write-Log -Level INFO -Message 'stopped by operator'
                        return
                    }
                }
            }

            $alive = @()
            foreach ($t in $liveTargets) {
                if (Get-Process -Id $t.Id -ErrorAction SilentlyContinue) { $alive += $t }
            }

            if ($alive.Count -eq 0) {
                # The client restarted (rejoin, update, crash). Re-discover it if
                # we were auto-detecting in the first place.
                if ($rediscoveries -lt 20 -and -not $TargetName) {
                    $found = @(Select-TargetProcess -Name @())
                    if ($found.Count -gt 0) {
                        $rediscoveries++
                        Write-Log -Level OK -Message "client came back as $($found[0].Name) (pid $($found[0].Id)); re-applying the allocation"
                        $liveTargets = $found
                        [void](Invoke-HarnessAllocation -Targets $liveTargets -State $State)
                        continue
                    }
                }
                Write-Log -Level WARN -Message 'all targets have exited; leaving the watch loop'
                return
            }
            $liveTargets = $alive

            $drift = @(Test-HarnessDrift -Targets $liveTargets -State $State)
            if ($drift.Count -gt 0) {
                Write-Log -Level WARN -Message "drift detected: $($drift -join '; ')"
                [void](Sync-HarnessAllocation -Targets $liveTargets -State $State)
            }

            if (($stopwatch.Elapsed - $lastReport).TotalSeconds -ge 30) {
                $lastReport = $stopwatch.Elapsed
                foreach ($t in $liveTargets) {
                    $info = Get-TargetRuntimeInfo -Target $t
                    if (-not $info.Alive) { continue }
                    $pct = 'n/a'
                    if ($null -ne $info.CpuPercent) { $pct = "$([int]$info.CpuPercent)%" }
                    $held = 0.0
                    if ($State.ReserveBytes -gt 0) { $held = 100.0 * $info.WorkingSet / $State.ReserveBytes }
                    Write-Log -Level INFO -Message ("hold #{0}: {1} (pid {2}) ws {3} ({4:N0}% of floor) cpu {5} affinity {6}" -f `
                        $cycles, $t.Name, $t.Id, (Format-Bytes -Bytes $info.WorkingSet), $held, $pct, (Format-Mask -Mask $info.AffinityMask))
                }
            }
        }
    } finally {
        if ($useKeys) { try { [Console]::TreatControlCAsInput = $false } catch { } }
    }
}

# =============================================================================
# Region: self test
# =============================================================================

function New-SelfTestRow {
    param([string] $Name, [string] $Status, [string] $Detail = '')
    $color = 'Gray'
    switch ($Status) {
        'PASS' { $color = 'Green' }
        'FAIL' { $color = 'Red' }
        'SKIP' { $color = 'Yellow' }
    }
    Write-Host ("  {0,-46} {1,-6} {2}" -f $Name, $Status, $Detail) -ForegroundColor $color
    return [pscustomobject]@{ Name = $Name; Status = $Status; Detail = $Detail }
}

function Invoke-HarnessSelfTest {
    <#
        Exercises every native path against a throwaway child process. This is
        the check to run on a new machine before letting Harness near a game
        client: it proves the interop layer works without touching Roblox.
    #>
    param([Parameter(Mandatory)] $Topology)

    Write-Rule 'self test'
    $rows = New-Object System.Collections.Generic.List[psobject]

    # --- environment ---------------------------------------------------------
    $rows.Add((New-SelfTestRow 'PowerShell version' 'PASS' "$($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"))
    $rows.Add((New-SelfTestRow 'operating system' 'PASS' "$([System.Environment]::OSVersion.VersionString)"))

    $admin = Test-Administrator
    $status = 'SKIP'
    if ($admin) { $status = 'PASS' }
    $rows.Add((New-SelfTestRow 'administrator rights' $status $(if ($admin) { 'elevated: any process can be adjusted' } else { 'not elevated: only your own processes can be adjusted' })))

    # --- native layer --------------------------------------------------------
    try {
        Initialize-HarnessNative
        $rows.Add((New-SelfTestRow 'compile native interop' 'PASS' 'HarnessNative type available'))
    } catch {
        $rows.Add((New-SelfTestRow 'compile native interop' 'FAIL' $_.Exception.Message))
        return $rows.ToArray()
    }

    $map = @([HarnessNative]::GetCoreMap())
    if ($map.Count -ge 5) {
        $cores = [int]($map.Count / 5)
        $detail = "$cores physical cores from GetLogicalProcessorInformationEx"
        if ($Topology.IsHybrid) { $detail += ' (hybrid)' }
        $rows.Add((New-SelfTestRow 'read cpu topology' 'PASS' $detail))
    } else {
        $rows.Add((New-SelfTestRow 'read cpu topology' 'FAIL' 'GetLogicalProcessorInformationEx returned nothing'))
    }

    if ($Topology.TotalLogical -gt 0) {
        $details = "active=$($Topology.TotalLogical) cores=$($Topology.CoreCount) dotnet=$($Topology.DotNetCpuCount)"
        $status = 'PASS'
        if ($Topology.TotalLogical -ne $Topology.DotNetCpuCount) {
            # Not fatal: .NET reports the current processor group, and affinity
            # masks can shrink what it sees.
            $status = 'SKIP'
        }
        $rows.Add((New-SelfTestRow 'topology matches .NET view' $status $details))
    }

    # --- live process round trip --------------------------------------------
    $child = $null
    try {
        $child = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c timeout /t 60 /nobreak' -WindowStyle Hidden -PassThru
        Start-Sleep -Milliseconds 300
        if (-not (Get-Process -Id $child.Id -ErrorAction SilentlyContinue)) {
            $rows.Add((New-SelfTestRow 'start throwaway process' 'FAIL' 'the child exited immediately'))
        } else {
            $rows.Add((New-SelfTestRow 'start throwaway process' 'PASS' "cmd.exe pid $($child.Id)"))

            $h = Get-ProcessHandle -ProcessId $child.Id
            if ($h -eq [IntPtr]::Zero) {
                $rows.Add((New-SelfTestRow 'open process for writing' 'FAIL' (Get-NativeError 'OpenProcess')))
            } else {
                $rows.Add((New-SelfTestRow 'open process for writing' 'PASS' 'handle with SET_QUOTA|SET_INFORMATION'))
            }

            # affinity round trip
            [uint64]$orig = 0
            [uint64]$sys = 0
            $orig = [HarnessNative]::GetAffinity($h.ToInt64(), [ref]$sys)
            $single = $orig -band ([uint64]1 -shl 0)
            if ($single -eq 0) { $single = $orig }
            $applied = [HarnessNative]::SetAffinity($h.ToInt64(), $single)
            [uint64]$after = 0
            [uint64]$sys2 = 0
            $after = [HarnessNative]::GetAffinity($h.ToInt64(), [ref]$sys2)
            if ($applied -and $after -eq $single) {
                $rows.Add((New-SelfTestRow 'set + verify affinity' 'PASS' "mask 0x$($single.ToString('X'))"))
            } else {
                $rows.Add((New-SelfTestRow 'set + verify affinity' 'FAIL' "requested 0x$($single.ToString('X')), read back 0x$($after.ToString('X'))"))
            }
            [void][HarnessNative]::SetAffinity($h.ToInt64(), $orig)

            # priority round trip
            $origPrio = [HarnessNative]::GetPrio($h.ToInt64())
            [void][HarnessNative]::SetPrio($h.ToInt64(), [uint32][HarnessNative]::ABOVE_NORMAL_PRIORITY_CLASS)
            $newPrio = [HarnessNative]::GetPrio($h.ToInt64())
            if ($newPrio -eq [uint32][HarnessNative]::ABOVE_NORMAL_PRIORITY_CLASS) {
                $rows.Add((New-SelfTestRow 'set + verify priority class' 'PASS' "$(Get-PriorityClassName -Value $newPrio)"))
            } else {
                $rows.Add((New-SelfTestRow 'set + verify priority class' 'FAIL' "read back $(Get-PriorityClassName -Value $newPrio)"))
            }
            [void][HarnessNative]::SetPrio($h.ToInt64(), $origPrio)

            # memory priority round trip
            $origMem = [HarnessNative]::GetMemPrio($h.ToInt64())
            if ($origMem -eq 0) {
                $rows.Add((New-SelfTestRow 'set + verify memory priority' 'SKIP' 'ProcessMemoryPriority unsupported (needs Windows 8+)'))
            } else {
                [void][HarnessNative]::SetMemPrio($h.ToInt64(), [uint32]2)
                $newMem = [HarnessNative]::GetMemPrio($h.ToInt64())
                if ($newMem -eq 2) {
                    $rows.Add((New-SelfTestRow 'set + verify memory priority' 'PASS' "was $(Get-MemoryPriorityName -Value $origMem), set to Low"))
                } else {
                    $rows.Add((New-SelfTestRow 'set + verify memory priority' 'FAIL' "read back $(Get-MemoryPriorityName -Value $newMem)"))
                }
                [void][HarnessNative]::SetMemPrio($h.ToInt64(), [uint32]$origMem)
            }

            # working set round trip (small values: this is a real reservation)
            [uint64]$wsMin = 0
            [uint64]$wsMax = 0
            [uint32]$wsFlags = 0
            $wsRead = [HarnessNative]::GetWorkingSet($h.ToInt64(), [ref]$wsMin, [ref]$wsMax, [ref]$wsFlags)
            $targetMin = 64MB
            $wsSet = [HarnessNative]::SetWorkingSet($h.ToInt64(), [uint64]$targetMin, [uint64]0,
                [uint32][HarnessNative]::QUOTA_LIMITS_HARDWS_MIN_ENABLE)
            [uint64]$wsMin2 = 0
            [uint64]$wsMax2 = 0
            [uint32]$wsFlags2 = 0
            [void][HarnessNative]::GetWorkingSet($h.ToInt64(), [ref]$wsMin2, [ref]$wsMax2, [ref]$wsFlags2)
            if ($wsSet -and $wsMin2 -eq $targetMin) {
                $rows.Add((New-SelfTestRow 'set + verify working-set floor' 'PASS' "$(Format-Bytes -Bytes $wsMin2) stored (hard flag: $(($wsFlags2 -band 1) -ne 0))"))
            } elseif ($wsSet) {
                $rows.Add((New-SelfTestRow 'set + verify working-set floor' 'SKIP' "call succeeded, read back $(Format-Bytes -Bytes $wsMin2)"))
            } else {
                $rows.Add((New-SelfTestRow 'set + verify working-set floor' 'FAIL' (Get-NativeError 'SetProcessWorkingSetSizeEx')))
            }
            if ($wsRead) { [void][HarnessNative]::SetWorkingSet($h.ToInt64(), $wsMin, $wsMax, $wsFlags) }

            # job object round trip
            try {
                $job = New-HarnessJob -Name 'SelfTest'
                $mask = ConvertFrom-CpuList -Cpu @($Topology.Cores[0].LogicalCpus)
                $jobOk = [HarnessNative]::SetJobLimits($job.ToInt64(), $true, [uint64](128MB), [uint64]0,
                    $true, [uint64]$mask, $true, [uint32][HarnessNative]::ABOVE_NORMAL_PRIORITY_CLASS, $false, [uint64]0)
                if (-not $jobOk) {
                    $rows.Add((New-SelfTestRow 'job object limits' 'FAIL' (Get-NativeError 'SetInformationJobObject')))
                } else {
                    [uint32]$lf = 0
                    [uint64]$jm = 0
                    [uint64]$jx = 0
                    [uint64]$ja = 0
                    [uint32]$jp = 0
                    [uint32]$jr = 0
                    [uint32]$jf = 0
                    if ([HarnessNative]::GetJobLimits($job.ToInt64(), [ref]$lf, [ref]$jm, [ref]$jx, [ref]$ja, [ref]$jp, [ref]$jr, [ref]$jf)) {
                        $rows.Add((New-SelfTestRow 'job object limits' 'PASS' "flags 0x$($lf.ToString('X8')), floor $(Format-Bytes -Bytes $jm), affinity $(Format-Mask -Mask $ja)"))
                    } else {
                        $rows.Add((New-SelfTestRow 'job object limits' 'SKIP' 'limits set but could not be read back'))
                    }
                }

                if ([HarnessNative]::AssignToJob($job.ToInt64(), $h.ToInt64())) {
                    $ids = @([HarnessNative]::GetJobProcessIds($job.ToInt64()))
                    if ($ids -contains $child.Id) {
                        $rows.Add((New-SelfTestRow 'assign process to job' 'PASS' "job contains pid $($child.Id)"))
                    } else {
                        $rows.Add((New-SelfTestRow 'assign process to job' 'FAIL' "job pid list: $($ids -join ', ')"))
                    }
                } else {
                    $rows.Add((New-SelfTestRow 'assign process to job' 'SKIP' "$(Get-NativeError 'AssignProcessToJobObject') - this is what happens when a process is already in a non-nestable job"))
                }

                $rateOk = [HarnessNative]::SetJobCpuRate($job.ToInt64(), [uint32]5000, $true)
                if ($rateOk) {
                    $rows.Add((New-SelfTestRow 'job cpu rate control' 'PASS' 'hard cap of 50% of one core accepted'))
                } else {
                    $rows.Add((New-SelfTestRow 'job cpu rate control' 'SKIP' (Get-NativeError 'SetInformationJobObject(CpuRate)')))
                }
            } catch {
                $rows.Add((New-SelfTestRow 'job object limits' 'FAIL' $_.Exception.Message))
            }
        }
    } catch {
        $rows.Add((New-SelfTestRow 'live process round trip' 'FAIL' $_.Exception.Message))
    } finally {
        if ($child) {
            try { Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue } catch { }
        }
        if ($script:JobObjects.ContainsKey('SelfTest')) {
            try { [void][HarnessNative]::Close($script:JobObjects['SelfTest'].ToInt64()) } catch { }
            $script:JobObjects.Remove('SelfTest')
        }
    }

    # --- profiles ------------------------------------------------------------
    $profilesDir = Join-Path $script:RepoRoot 'profiles'
    if (Test-Path -LiteralPath $profilesDir) {
        $paramNames = @()
        try {
            $cmd = Get-Command -Name $PSCommandPath -ErrorAction Stop
            $paramNames = @($cmd.Parameters.Keys)
        } catch {
            Write-Log -Level DEBUG -Message "could not introspect parameters: $($_.Exception.Message)"
        }
        foreach ($file in @(Get-ChildItem -LiteralPath $profilesDir -Filter '*.json' -ErrorAction SilentlyContinue)) {
            try {
                $data = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
                $bad = @()
                if ($paramNames.Count -gt 0) {
                    foreach ($prop in $data.PSObject.Properties.Name) {
                        if ($paramNames -notcontains $prop) { $bad += $prop }
                    }
                }
                if ($bad.Count -gt 0) {
                    $rows.Add((New-SelfTestRow "profile $($file.Name)" 'FAIL' "unknown setting(s): $($bad -join ', ')"))
                } else {
                    $rows.Add((New-SelfTestRow "profile $($file.Name)" 'PASS' 'parses and every key maps to a parameter'))
                }
            } catch {
                $rows.Add((New-SelfTestRow "profile $($file.Name)" 'FAIL' $_.Exception.Message))
            }
        }
    } else {
        $rows.Add((New-SelfTestRow 'profiles directory' 'SKIP' 'no profiles/ next to the script'))
    }

    # --- roblox presence (informational) ------------------------------------
    $clients = @(Get-RobloxLikeProcess)
    if ($clients.Count -gt 0) {
        $list = ($clients | ForEach-Object { "$($_.Name)/$($_.Id)" }) -join ', '
        $rows.Add((New-SelfTestRow 'roblox client present' 'PASS' $list))
    } else {
        $rows.Add((New-SelfTestRow 'roblox client present' 'SKIP' 'no Roblox process running right now'))
    }

    $failed = @($rows | Where-Object { $_.Status -eq 'FAIL' }).Count
    $passed = @($rows | Where-Object { $_.Status -eq 'PASS' }).Count
    $skipped = @($rows | Where-Object { $_.Status -eq 'SKIP' }).Count
    Write-Host ''
    $summary = "$passed passed, $skipped skipped, $failed failed"
    if ($failed -gt 0) {
        Write-Log -Level ERROR -Message $summary
    } else {
        Write-Log -Level OK -Message $summary
    }
    return $rows.ToArray()
}

# =============================================================================
# Region: elevation
# =============================================================================

function Invoke-HarnessRelaunchElevated {
    <#
        Offers to restart the script elevated. Only reached when the caller is
        not already an administrator and something actually needed the rights.
    #>
    param([string[]] $Arguments)

    if ($NoElevate) { return $false }

    Write-Log -Level WARN -Message 'administrator rights would help (some limits need PROCESS_SET_QUOTA on another user''s process)'
    if ($Yes) { return $false }
    $answer = Read-HarnessYesNo -Question 'restart this script as administrator?' -Default $false
    if (-not $answer) { return $false }

    $argText = ''
    if ($Arguments) { $argText = ($Arguments | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }) -join ' ' }

    try {
        Start-Process -FilePath (Get-Process -Id $PID).Path -Verb RunAs `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" $argText"
        Write-Log -Level INFO -Message 'elevated window launched; this one is exiting'
        return $true
    } catch {
        Write-Log -Level WARN -Message "elevation failed: $($_.Exception.Message)"
        return $false
    }
}
