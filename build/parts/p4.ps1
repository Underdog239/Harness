
# =============================================================================
# Region: allocation engine (apply + read back + verify)
# =============================================================================

function Add-JournalEntry {
    <#
        Records what a process looked like before Harness touched it. Only the
        fields Harness actually intends to change are marked, so -Restore never
        "restores" something it never modified.
    #>
    param(
        [Parameter(Mandatory)] $Target,
        [Parameter(Mandatory)] $State,
        [string[]] $Touched = @(),
        [string]   $JobName
    )

    $exePath = $null
    try { $exePath = $Target.Process.MainModule.FileName } catch { $exePath = [HarnessNative]::GetProcessPath($Target.Id) }

    $startTime = $null
    try { $startTime = $Target.Process.StartTime.ToString('o') } catch { }

    $entry = [pscustomobject]@{
        Pid             = $Target.Id
        Name            = $Target.Name
        Path            = $exePath
        StartTime       = $startTime
        Touched         = $Touched
        JobName         = $JobName
        AffinityMask    = [uint64]0
        PriorityClass   = [uint32]0
        MemoryPriority  = [uint32]0
        WorkingSetMin   = [uint64]0
        WorkingSetMax   = [uint64]0
        WorkingSetFlags = [uint32]0
    }
    $script:Journal += $entry
    return $entry
}

function Save-HarnessState {
    <#
        Writes the journal + allocation to disk so -Restore can undo it in a
        later session. Best effort: a failure here never breaks the run.
    #>
    param(
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)][object[]] $Results
    )

    if (-not $script:StatePath) { return }
    try {
        $dir = Split-Path -Parent $script:StatePath
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $payload = [pscustomobject]@{
            Version    = $script:HarnessVersion
            WrittenAt  = (Get-Date).ToString('o')
            Machine    = $env:COMPUTERNAME
            ProcessId  = $PID
            Allocation = [pscustomobject]@{
                CpuList         = $State.CpuList
                Mask            = $State.Mask.ToString()
                CoreMode        = $State.CoreMode
                Priority        = $State.Priority
                MemoryPriority  = $State.MemoryPriority
                ReserveBytes    = $State.ReserveBytes
                HardMin         = $State.HardMin
                CpuLimitPercent = $State.CpuLimitPercent
            }
            Journal    = $script:Journal
            Results    = $Results
        }
        $payload | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:StatePath -Encoding UTF8
        Write-Log -Level DEBUG -Message "state written to $script:StatePath"
    } catch {
        Write-Log -Level WARN -Message "could not write the state file ($script:StatePath): $($_.Exception.Message)"
    }
}

function Invoke-AffinityApply {
    param([Parameter(Mandatory)] $Target, [uint64] $Mask, [switch] $RecordOnly)

    $h = Get-ProcessHandle -ProcessId $Target.Id
    if ($h -eq [IntPtr]::Zero) {
        return New-Result -Action 'affinity' -Requested (Format-Mask -Mask $Mask) -ReadBack '' `
            -Ok $false -Notes (Get-NativeError "OpenProcess(pid $($Target.Id))")
    }

    [uint64]$original = 0
    [uint64]$systemMask = 0
    $original = [HarnessNative]::GetAffinity($h.ToInt64(), [ref]$systemMask)
    if ($RecordOnly) { return [pscustomobject]@{ OriginalMask = $original } }

    if ($original -eq 0) {
        return New-Result -Action 'affinity' -Requested (Format-Mask -Mask $Mask) -ReadBack '' `
            -Ok $false -Notes (Get-NativeError 'GetProcessAffinityMask')
    }

    # The requested mask must be inside what the OS allows for this process,
    # otherwise SetProcessAffinityMask fails with ERROR_INVALID_PARAMETER.
    if (($Mask -band $systemMask) -ne $Mask) {
        Write-Log -Level WARN -Message "requested CPUs are outside the system mask 0x$($systemMask.ToString('X')); intersecting"
        $Mask = $Mask -band $systemMask
        if ($Mask -eq 0) {
            return New-Result -Action 'affinity' -Requested '(empty after intersect)' -ReadBack '' -Ok $false `
                -Notes 'no usable CPU after intersecting with the system affinity mask'
        }
    }

    if (-not [HarnessNative]::SetAffinity($h.ToInt64(), $Mask)) {
        return New-Result -Action 'affinity' -Requested (Format-Mask -Mask $Mask) -ReadBack (Format-Mask -Mask $original) `
            -Ok $false -Notes (Get-NativeError 'SetProcessAffinityMask')
    }

    [uint64]$after = 0
    [uint64]$sysAfter = 0
    $after = [HarnessNative]::GetAffinity($h.ToInt64(), [ref]$sysAfter)
    $ok = ($after -eq $Mask)
    $note = ''
    if (-not $ok) { $note = 'kernel reports a different mask than requested' }
    return New-Result -Action 'affinity' -Requested (Format-Mask -Mask $Mask) `
        -ReadBack ("0x{0:X} -> {1}" -f $after, (Format-Mask -Mask $after)) -Ok $ok -Notes $note
}

function Invoke-PriorityApply {
    param([Parameter(Mandatory)] $Target, [uint32] $PriorityValue)

    $h = Get-ProcessHandle -ProcessId $Target.Id
    if ($h -eq [IntPtr]::Zero) {
        return New-Result -Action 'priority class' -Requested (Get-PriorityClassName -Value $PriorityValue) -ReadBack '' `
            -Ok $false -Notes (Get-NativeError "OpenProcess(pid $($Target.Id))")
    }

    if (-not [HarnessNative]::SetPrio($h.ToInt64(), $PriorityValue)) {
        return New-Result -Action 'priority class' -Requested (Get-PriorityClassName -Value $PriorityValue) `
            -ReadBack (Get-PriorityClassName -Value ([HarnessNative]::GetPrio($h.ToInt64()))) `
            -Ok $false -Notes (Get-NativeError 'SetPriorityClass')
    }

    $after = [HarnessNative]::GetPrio($h.ToInt64())
    $ok = ($after -eq $PriorityValue)
    $note = ''
    if (-not $ok) { $note = 'a job object is likely pinning the class; the job value is what applies' }
    return New-Result -Action 'priority class' -Requested (Get-PriorityClassName -Value $PriorityValue) `
        -ReadBack (Get-PriorityClassName -Value $after) -Ok $ok -Notes $note
}

function Invoke-MemoryPriorityApply {
    param([Parameter(Mandatory)] $Target, [uint32] $Value)

    $h = Get-ProcessHandle -ProcessId $Target.Id
    if ($h -eq [IntPtr]::Zero) {
        return New-Result -Action 'memory priority' -Requested (Get-MemoryPriorityName -Value $Value) -ReadBack '' `
            -Ok $false -Notes (Get-NativeError "OpenProcess(pid $($Target.Id))")
    }

    $before = [HarnessNative]::GetMemPrio($h.ToInt64())
    if (-not [HarnessNative]::SetMemPrio($h.ToInt64(), $Value)) {
        return New-Result -Action 'memory priority' -Requested (Get-MemoryPriorityName -Value $Value) `
            -ReadBack (Get-MemoryPriorityName -Value $before) -Ok $false `
            -Notes "$(Get-NativeError 'SetProcessInformation(ProcessMemoryPriority)') - needs Windows 8 or newer"
    }

    $after = [HarnessNative]::GetMemPrio($h.ToInt64())
    return New-Result -Action 'memory priority' -Requested (Get-MemoryPriorityName -Value $Value) `
        -ReadBack (Get-MemoryPriorityName -Value $after) -Ok ($after -eq $Value)
}

function Invoke-WorkingSetApply {
    <#
        Reserves a working-set floor for the target.

        Two layers, because they do different jobs:
          * process level (SetProcessWorkingSetSizeEx + QUOTA_LIMITS_HARDWS_MIN_ENABLE)
            stores the quota Windows uses for bookkeeping and trimming targets.
          * job object (JOB_OBJECT_LIMIT_WORKINGSET) is the layer Windows actually
            enforces for a process it does not own, so Harness sets both and reads
            both back.
    #>
    param(
        [Parameter(Mandatory)] $Target,
        [Parameter(Mandatory)] $State,
        [switch] $ProcessLevelOnly
    )

    $results = New-Object System.Collections.Generic.List[psobject]

    $h = Get-ProcessHandle -ProcessId $Target.Id
    if ($h -eq [IntPtr]::Zero) {
        $results.Add((New-Result -Action 'working set' -Requested 'floor' -ReadBack '' -Ok $false `
            -Notes (Get-NativeError "OpenProcess(pid $($Target.Id))")))
        return $results.ToArray()
    }

    if ($State.ReserveBytes -le 0) {
        $results.Add((New-Result -Action 'working set' -Requested 'no reservation' -ReadBack 'unchanged' -Ok $true))
        return $results.ToArray()
    }

    [uint64]$min = [uint64]$State.ReserveBytes
    [uint64]$max = [uint64]0
    if ($State.CeilingBytes -gt 0) { $max = [uint64]$State.CeilingBytes }

    [uint32]$flags = [uint32][HarnessNative]::QUOTA_LIMITS_HARDWS_MIN_ENABLE
    if ($State.HardMin -eq $false) { $flags = [uint32][HarnessNative]::QUOTA_LIMITS_HARDWS_MIN_DISABLE }
    if ($max -gt 0) { $flags = $flags -bor [uint32][HarnessNative]::QUOTA_LIMITS_HARDWS_MAX_ENABLE }

    $okCall = [HarnessNative]::SetWorkingSet($h.ToInt64(), $min, $max, $flags)
    $note = ''
    if (-not $okCall) {
        $note = Get-NativeError 'SetProcessWorkingSetSizeEx'
        Write-Log -Level DEBUG -Message "$note - trying the legacy entry point"
        $okCall = [HarnessNative]::SetWorkingSetLegacy($h.ToInt64(), $min, $max)
        if ($okCall) { $note = 'set through SetProcessWorkingSetSize (legacy)' }
    }

    [uint64]$readMin = 0
    [uint64]$readMax = 0
    [uint32]$readFlags = 0
    $read = [HarnessNative]::GetWorkingSet($h.ToInt64(), [ref]$readMin, [ref]$readMax, [ref]$readFlags)
    if (-not $read) { $read = [HarnessNative]::GetWorkingSetLegacy($h.ToInt64(), [ref]$readMin, [ref]$readMax) }

    $flagText = 'soft'
    if (($readFlags -band [uint32][HarnessNative]::QUOTA_LIMITS_HARDWS_MIN_ENABLE) -ne 0) { $flagText = 'hard' }
    $readBack = "$(Format-Bytes -Bytes $readMin) ($flagText)"
    $verified = $read -and ($readMin -eq $min)

    $results.Add((New-Result -Action 'working set floor' -Requested "$(Format-Bytes -Bytes $min) ($(if ($State.HardMin) { 'hard' } else { 'soft' }))" `
        -ReadBack $readBack -Ok $verified -Notes $note))

    return $results.ToArray()
}

function New-HarnessJob {
    <#
        Creates or reuses the job object used to enforce the allocation. Limits
        are applied by the caller so that a job can also be created for the
        workload alone.
    #>
    param([Parameter(Mandatory)][string] $Name)

    if ($script:JobObjects.ContainsKey($Name)) { return $script:JobObjects[$Name] }

    $handle = [HarnessNative]::CreateJob()
    if ($handle -eq 0) {
        throw (Get-NativeError 'CreateJobObject')
    }
    $wrapped = [IntPtr]::new($handle)
    $script:JobObjects[$Name] = $wrapped
    Write-Log -Level DEBUG -Message "job object '$Name' created"
    return $wrapped
}

function Set-HarnessJobLimits {
    param(
        [Parameter(Mandatory)][IntPtr] $Job,
        [Parameter(Mandatory)] $State,
        [switch] $IncludeWorkingSet,
        [switch] $IncludeAffinity,
        [switch] $IncludePriority
    )

    $hasWs = $IncludeWorkingSet -and ($State.ReserveBytes -gt 0)
    [uint64]$wsMin = 0
    [uint64]$wsMax = 0
    if ($hasWs) {
        $wsMin = [uint64]$State.ReserveBytes
        if ($State.CeilingBytes -gt 0) { $wsMax = [uint64]$State.CeilingBytes }
    }

    $ok = [HarnessNative]::SetJobLimits(
        $Job.ToInt64(),
        $hasWs, $wsMin, $wsMax,
        [bool]$IncludeAffinity, [uint64]$State.Mask,
        [bool]$IncludePriority, [uint32]$State.PriorityValue,
        $false, [uint64]0)

    if (-not $ok) {
        throw (Get-NativeError 'SetInformationJobObject(ExtendedLimitInformation)')
    }
}

function Set-HarnessJobCpuRate {
    param([Parameter(Mandatory)][IntPtr] $Job, [Parameter(Mandatory)][int] $RateUnits)

    if ($RateUnits -le 0) { return $true }
    if (-not [HarnessNative]::SetJobCpuRate($Job.ToInt64(), [uint32]$RateUnits, $true)) {
        Write-Log -Level WARN -Message (Get-NativeError 'SetInformationJobObject(CpuRateControl)')
        return $false
    }
    return $true
}

function Add-ProcessToHarnessJob {
    <#
        Assigns the target to a job. Windows 8+ nests jobs, but a process that is
        already inside a job which forbids nesting (some anti-cheat and store
        packages do this) cannot be moved. That is reported, not hidden.
    #>
    param([Parameter(Mandatory)][IntPtr] $Job, [Parameter(Mandatory)] $Target)

    $h = Get-ProcessHandle -ProcessId $Target.Id
    if ($h -eq [IntPtr]::Zero) {
        return New-Result -Action 'job object' -Requested 'assign' -ReadBack '' -Ok $false `
            -Notes (Get-NativeError "OpenProcess(pid $($Target.Id))")
    }

    if (-not [HarnessNative]::AssignToJob($Job.ToInt64(), $h.ToInt64())) {
        return New-Result -Action 'job object' -Requested 'enforce limits via job' -ReadBack 'not in job' -Ok $false `
            -Notes "$(Get-NativeError 'AssignProcessToJobObject') - the process is probably already in a job that forbids nesting; process-level limits still apply"
    }

    $ids = @([HarnessNative]::GetJobProcessIds($Job.ToInt64()))
    $ok = $ids -contains $Target.Id
    if ($ok) {
        return New-Result -Action 'job object' -Requested 'enforce limits via job' -ReadBack "pid $($Target.Id) is in the job" -Ok $true
    }
    return New-Result -Action 'job object' -Requested 'enforce limits via job' -ReadBack "job holds pids: $($ids -join ', ')" -Ok $false `
        -Notes 'assignment returned success but the pid list does not contain the target'
}

function Show-JobLimits {
    <#
        Reads the job limits back out of the kernel and prints them, so the
        table never claims enforcement it cannot show.
    #>
    param([Parameter(Mandatory)][IntPtr] $Job, [Parameter(Mandatory)][string] $Label)

    [uint32]$limitFlags = 0
    [uint64]$wsMin = 0
    [uint64]$wsMax = 0
    [uint64]$affinity = 0
    [uint32]$prioClass = 0
    [uint32]$cpuRate = 0
    [uint32]$cpuFlags = 0

    $ok = [HarnessNative]::GetJobLimits($Job.ToInt64(), [ref]$limitFlags, [ref]$wsMin, [ref]$wsMax,
        [ref]$affinity, [ref]$prioClass, [ref]$cpuRate, [ref]$cpuFlags)
    if (-not $ok) {
        Write-Kv "$Label job" 'limits could not be read back' -Color Yellow
        return
    }

    Write-Host ''
    Write-Host "  job object limits ($Label):" -ForegroundColor White
    Write-Kv 'limit flags' ("0x{0:X8}" -f $limitFlags)
    if ($limitFlags -band [HarnessNative]::JOB_OBJECT_LIMIT_WORKINGSET) {
        Write-Kv 'working set floor' "$(Format-Bytes -Bytes $wsMin)  (job-enforced)" -Color Green
        if ($wsMax -gt 0) { Write-Kv 'working set ceiling' (Format-Bytes -Bytes $wsMax) }
    }
    if ($limitFlags -band [HarnessNative]::JOB_OBJECT_LIMIT_AFFINITY) {
        Write-Kv 'affinity' "0x$($affinity.ToString('X')) -> $(Format-Mask -Mask $affinity)" -Color Green
    }
    if ($limitFlags -band [HarnessNative]::JOB_OBJECT_LIMIT_PRIORITY_CLASS) {
        Write-Kv 'priority class' (Get-PriorityClassName -Value $prioClass)
    }
    if (($cpuFlags -band [HarnessNative]::JOB_OBJECT_CPU_RATE_CONTROL_ENABLE) -ne 0) {
        $pct = [double]$cpuRate / 100.0
        Write-Kv 'cpu rate cap' "$($pct)% of one core (hard cap)" -Color Green
    }
}

function Invoke-HarnessAllocation {
    <#
        Applies the whole allocation to every target and returns every result.
    #>
    param(
        [Parameter(Mandatory)][object[]] $Targets,
        [Parameter(Mandatory)] $State
    )

    if ($DryRun) {
        Write-Log -Level WARN -Message 'dry run: no process setting will be changed'
        return @()
    }

    $all = New-Object System.Collections.Generic.List[psobject]
    $jobName = 'Harness'
    $job = $null

    if (-not $DryRun) {
        try {
            $job = New-HarnessJob -Name $jobName
            Set-HarnessJobLimits -Job $job -State $State -IncludeWorkingSet -IncludeAffinity -IncludePriority
            if ($State.CpuRateUnits -gt 0) { [void](Set-HarnessJobCpuRate -Job $job -RateUnits $State.CpuRateUnits) }
        } catch {
            Write-Log -Level WARN -Message "job object setup failed: $($_.Exception.Message)"
            Write-Log -Level WARN -Message 'continuing with process-level limits only'
            $job = $null
        }
    }

    foreach ($target in $Targets) {
        Write-Rule "target: $($target.Name) (pid $($target.Id))"

        $targetResults = New-Object System.Collections.Generic.List[psobject]
        $touched = New-Object System.Collections.Generic.List[string]
        $jobLabel = ''
        if ($null -ne $job) { $jobLabel = $jobName }
        $entry = Add-JournalEntry -Target $target -State $State -Touched @() -JobName $jobLabel

        # capture originals first, then change things
        $h = Get-ProcessHandle -ProcessId $target.Id
        if ($h -ne [IntPtr]::Zero) {
            [uint64]$nullSys = 0
            $entry.AffinityMask = [HarnessNative]::GetAffinity($h.ToInt64(), [ref]$nullSys)
            $entry.PriorityClass = [HarnessNative]::GetPrio($h.ToInt64())
            $entry.MemoryPriority = [HarnessNative]::GetMemPrio($h.ToInt64())
            [uint64]$jMin = 0
            [uint64]$jMax = 0
            [uint32]$jFlags = 0
            [void][HarnessNative]::GetWorkingSet($h.ToInt64(), [ref]$jMin, [ref]$jMax, [ref]$jFlags)
            $entry.WorkingSetMin = $jMin
            $entry.WorkingSetMax = $jMax
            $entry.WorkingSetFlags = $jFlags
        } else {
            Write-Log -Level WARN -Message (Get-NativeError "OpenProcess(pid $($target.Id))")
            Write-Log -Level WARN -Message 'trying anyway with reduced rights (affinity/priority may still work)'
        }

        Write-Kv 'before' "affinity $(Format-Mask -Mask $entry.AffinityMask) | prio $(Get-PriorityClassName -Value $entry.PriorityClass) | memprio $(Get-MemoryPriorityName -Value $entry.MemoryPriority)"
        Write-Kv 'working set before' "$(Format-Bytes -Bytes $target.Process.WorkingSet64)"

        $r = Invoke-AffinityApply -Target $target -Mask $State.Mask
        $targetResults.Add($r); $all.Add($r)
        if ($r.Ok) { $touched.Add('Affinity') }

        $r = Invoke-PriorityApply -Target $target -PriorityValue $State.PriorityValue
        $targetResults.Add($r); $all.Add($r)
        if ($r.Ok) { $touched.Add('Priority') }

        if ($State.MemoryPriorityValue -ne 5) {
            $r = Invoke-MemoryPriorityApply -Target $target -Value $State.MemoryPriorityValue
            $targetResults.Add($r); $all.Add($r)
            if ($r.Ok) { $touched.Add('MemoryPriority') }
        }

        foreach ($r in Invoke-WorkingSetApply -Target $target -State $State) {
            $targetResults.Add($r); $all.Add($r)
            if ($r.Ok) { $touched.Add('WorkingSet') }
        }

        if ($null -ne $job) {
            $r = Add-ProcessToHarnessJob -Job $job -Target $target
            $targetResults.Add($r); $all.Add($r)
            if ($r.Ok) { $touched.Add('Job') }
        }

        $entry.Touched = $touched.ToArray()
        Write-Host ''
        Show-ApplyTable -Results $targetResults.ToArray()
    }

    if ($null -ne $job) { Show-JobLimits -Job $job -Label 'Harness' }

    return $all.ToArray()
}

# =============================================================================
# Region: status, drift detection, re-assert
# =============================================================================

function Get-ProcessCpuSample {
    <#
        Per-process CPU percentage from the formatted perf counters. Because the
        target is pinned to one core, this doubles as "% of its core".
    #>
    param([Parameter(Mandatory)][int] $ProcessId)

    try {
        $row = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfProc_Process `
            -Filter "IDProcess=$ProcessId" -ErrorAction Stop | Select-Object -First 1
        if ($row) { return [double]$row.PercentProcessorTime }
    } catch {
        Write-Log -Level DEBUG -Message "perf counters for pid $ProcessId unavailable: $($_.Exception.Message)"
    }
    return $null
}

function Get-TargetRuntimeInfo {
    param([Parameter(Mandatory)] $Target)

    $p = Get-Process -Id $Target.Id -ErrorAction SilentlyContinue
    if (-not $p) {
        return [pscustomobject]@{
            Alive = $false; Pid = $Target.Id; Name = $Target.Name
            WorkingSet = 0.0; PrivateMemory = 0.0; CpuPercent = $null
            AffinityMask = [uint64]0; PriorityClass = [uint32]0; MemoryPriority = [uint32]0
            Threads = 0; Handles = 0
        }
    }

    $h = Get-ProcessHandle -ProcessId $Target.Id -Quiet
    [uint64]$mask = 0
    [uint64]$sys = 0
    [uint32]$prio = 0
    [uint32]$memPrio = 0
    if ($h -ne [IntPtr]::Zero) {
        $mask = [HarnessNative]::GetAffinity($h.ToInt64(), [ref]$sys)
        $prio = [HarnessNative]::GetPrio($h.ToInt64())
        $memPrio = [HarnessNative]::GetMemPrio($h.ToInt64())
    }

    $threads = 0
    $handles = 0
    try {
        $threads = $p.Threads.Count
        $handles = $p.Handles
    } catch {
        Write-Log -Level DEBUG -Message "thread/handle counts unavailable for pid $($Target.Id)"
    }

    return [pscustomobject]@{
        Alive          = $true
        Pid            = $Target.Id
        Name           = $Target.Name
        WorkingSet     = [double]$p.WorkingSet64
        PrivateMemory  = [double]$p.PrivateMemorySize64
        CpuPercent     = Get-ProcessCpuSample -ProcessId $Target.Id
        AffinityMask   = $mask
        PriorityClass  = $prio
        MemoryPriority = $memPrio
        Threads        = $threads
        Handles        = $handles
    }
}

function Show-HarnessStatus {
    param(
        [Parameter(Mandatory)][object[]] $Targets,
        $State
    )

    foreach ($t in $Targets) {
        $info = Get-TargetRuntimeInfo -Target $t
        Write-Host ''
        if (-not $info.Alive) {
            Write-Log -Level WARN -Message "$($info.Name) (pid $($info.Pid)) has exited"
            continue
        }
        Write-Host "  $($info.Name) (pid $($info.Pid))" -ForegroundColor White
        Write-Kv 'working set' (Format-Bytes -Bytes $info.WorkingSet)
        Write-Kv 'private commit' (Format-Bytes -Bytes $info.PrivateMemory)
        if ($null -ne $info.CpuPercent) {
            $ofCore = ''
            if ($State -and @($State.CpuList).Count -gt 0) { $ofCore = " of its pinned core (CPU$(($State.CpuList) -join '/CPU'))" }
            Write-Kv 'cpu (1s sample)' "$([int]$info.CpuPercent)%$ofCore"
        }
        Write-Kv 'affinity' (Format-Mask -Mask $info.AffinityMask)
        Write-Kv 'priority class' (Get-PriorityClassName -Value $info.PriorityClass)
        Write-Kv 'memory priority' (Get-MemoryPriorityName -Value $info.MemoryPriority)
        Write-Kv 'threads / handles' "$($info.Threads) / $($info.Handles)"
        if ($State -and $State.ReserveBytes -gt 0) {
            $pct = 0.0
            if ($State.ReserveBytes -gt 0) { $pct = 100.0 * $info.WorkingSet / $State.ReserveBytes }
            Write-Kv 'vs reserved floor' ("{0:N0}% of {1}" -f $pct, (Format-Bytes -Bytes $State.ReserveBytes))
        }
    }
}

function Test-HarnessDrift {
    <#
        Compares reality against the allocation. Returns one string per drift so
        the caller can decide whether to re-assert.
    #>
    param(
        [Parameter(Mandatory)][object[]] $Targets,
        [Parameter(Mandatory)] $State
    )

    $drift = New-Object System.Collections.Generic.List[string]
    foreach ($t in $Targets) {
        $info = Get-TargetRuntimeInfo -Target $t
        if (-not $info.Alive) {
            $drift.Add("$($t.Name) (pid $($t.Id)) exited")
            continue
        }
        if ($info.AffinityMask -ne $State.Mask) {
            $drift.Add("$($t.Name): affinity is $(Format-Mask -Mask $info.AffinityMask), expected $(Format-Mask -Mask $State.Mask)")
        }
        if ($State.PriorityValue -ne 0 -and $info.PriorityClass -ne $State.PriorityValue) {
            $drift.Add("$($t.Name): priority class is $(Get-PriorityClassName -Value $info.PriorityClass), expected $($State.Priority)")
        }
        if ($State.MemoryPriorityValue -ne 5 -and $info.MemoryPriority -ne $State.MemoryPriorityValue) {
            $drift.Add("$($t.Name): memory priority is $(Get-MemoryPriorityName -Value $info.MemoryPriority), expected $($State.MemoryPriority)")
        }
    }
    return $drift.ToArray()
}

function Sync-HarnessAllocation {
    <#
        Re-asserts affinity/priority/memory priority for live targets. Called from
        the watch loop whenever drift is seen (some launchers and overlays reset
        these values behind your back).
    #>
    param(
        [Parameter(Mandatory)][object[]] $Targets,
        [Parameter(Mandatory)] $State,
        [switch] $Quiet
    )

    $fixed = 0
    foreach ($t in $Targets) {
        $info = Get-TargetRuntimeInfo -Target $t
        if (-not $info.Alive) { continue }

        if ($info.AffinityMask -ne $State.Mask) {
            if (-not $Quiet) { Write-Log -Level WARN -Message "re-pinning $($t.Name) to $(Format-Mask -Mask $State.Mask)" }
            [void](Invoke-AffinityApply -Target $t -Mask $State.Mask)
            $fixed++
        }
        if ($State.PriorityValue -ne 0 -and $info.PriorityClass -ne $State.PriorityValue) {
            if (-not $Quiet) { Write-Log -Level WARN -Message "restoring priority class for $($t.Name)" }
            [void](Invoke-PriorityApply -Target $t -PriorityValue $State.PriorityValue)
            $fixed++
        }
        if ($State.MemoryPriorityValue -ne 5 -and $info.MemoryPriority -ne $State.MemoryPriorityValue) {
            if (-not $Quiet) { Write-Log -Level WARN -Message "restoring memory priority for $($t.Name)" }
            [void](Invoke-MemoryPriorityApply -Target $t -Value $State.MemoryPriorityValue)
            $fixed++
        }
    }
    return $fixed
}

# =============================================================================
# Region: restore
# =============================================================================

function Restore-Journal {
    <#
        Puts the affected processes back the way they were. Identity is checked
        (pid + start time) before touching anything, because a pid can be reused
        between the allocation and the restore.
    #>
    param([switch] $Quiet)

    $restored = 0
    foreach ($entry in @($script:Journal)) {
        if (-not $entry.Touched -or @($entry.Touched).Count -eq 0) { continue }

        $p = Get-Process -Id $entry.Pid -ErrorAction SilentlyContinue
        if (-not $p) {
            if (-not $Quiet) { Write-Log -Level INFO -Message "pid $($entry.Pid) no longer exists, nothing to restore" }
            continue
        }
        if ($entry.StartTime) {
            $nowStart = $null
            try { $nowStart = $p.StartTime.ToString('o') } catch { }
            if ($nowStart -and $nowStart -ne $entry.StartTime) {
                if (-not $Quiet) { Write-Log -Level WARN -Message "pid $($entry.Pid) now belongs to a different process ($($p.ProcessName)); skipping" }
                continue
            }
        }

        $h = Get-ProcessHandle -ProcessId $entry.Pid -Quiet
        if ($h -eq [IntPtr]::Zero) {
            if (-not $Quiet) { Write-Log -Level WARN -Message "cannot reopen pid $($entry.Pid) to restore it" }
            continue
        }

        if ($entry.Touched -contains 'Affinity' -and $entry.AffinityMask -ne 0) {
            if ([HarnessNative]::SetAffinity($h.ToInt64(), [uint64]$entry.AffinityMask)) {
                $restored++
                if (-not $Quiet) { Write-Log -Level OK -Message "affinity of pid $($entry.Pid) restored to $(Format-Mask -Mask $entry.AffinityMask)" }
            }
        }
        if ($entry.Touched -contains 'Priority' -and $entry.PriorityClass -ne 0) {
            if ([HarnessNative]::SetPrio($h.ToInt64(), [uint32]$entry.PriorityClass)) {
                $restored++
                if (-not $Quiet) { Write-Log -Level OK -Message "priority of pid $($entry.Pid) restored to $(Get-PriorityClassName -Value $entry.PriorityClass)" }
            }
        }
        if ($entry.Touched -contains 'MemoryPriority' -and $entry.MemoryPriority -gt 0) {
            if ([HarnessNative]::SetMemPrio($h.ToInt64(), [uint32]$entry.MemoryPriority)) {
                $restored++
                if (-not $Quiet) { Write-Log -Level OK -Message "memory priority of pid $($entry.Pid) restored to $(Get-MemoryPriorityName -Value $entry.MemoryPriority)" }
            }
        }
        if ($entry.Touched -contains 'WorkingSet' -and ($entry.WorkingSetMin -gt 0 -or $entry.WorkingSetMax -gt 0)) {
            $flags = [uint32]$entry.WorkingSetFlags
            if ([HarnessNative]::SetWorkingSet($h.ToInt64(), [uint64]$entry.WorkingSetMin, [uint64]$entry.WorkingSetMax, $flags)) {
                $restored++
                if (-not $Quiet) { Write-Log -Level OK -Message "working-set limits of pid $($entry.Pid) restored" }
            } else {
                if (-not $Quiet) { Write-Log -Level DEBUG -Message (Get-NativeError 'SetProcessWorkingSetSizeEx (restore)') }
            }
        }
        if ($entry.Touched -contains 'Job' -and $entry.JobName) {
            # A job cannot be "left"; closing the handle releases the job and the
            # process returns to whatever it was in before (Windows 8+).
            if (-not $Quiet) { Write-Log -Level INFO -Message "pid $($entry.Pid) leaves the Harness job when this session closes its job handle" }
        }
    }

    if ($restored -gt 0) {
        Write-Log -Level OK -Message "$restored setting(s) restored"
    } elseif (-not $Quiet) {
        Write-Log -Level INFO -Message 'nothing needed restoring'
    }
    return $restored
}

function Invoke-RestoreFromStateFile {
    param([Parameter(Mandatory)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "no state file at $Path - nothing has been allocated from this machine (or -StatePath points elsewhere)"
    }
    $data = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if (-not $data.Journal) {
        Write-Log -Level WARN -Message "state file $Path has no journal entries"
        return 0
    }

    Write-Log -Level STEP -Message "restoring from $Path (written $($data.WrittenAt) by pid $($data.ProcessId))"
    $script:Journal = @($data.Journal)
    $n = Restore-Journal
    try {
        Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
        Write-Log -Level INFO -Message 'state file removed'
    } catch {
        Write-Log -Level DEBUG -Message "could not remove the state file: $($_.Exception.Message)"
    }
    return $n
}
