
# =============================================================================
# Region: reporting
# =============================================================================

function Write-HarnessHonesty {
    Write-Host '  What this can and cannot do:' -ForegroundColor DarkGray
    Write-Host '   * a core cannot own RAM - cores are pinned, RAM is reserved as a' -ForegroundColor DarkGray
    Write-Host '     working set the memory manager holds resident for the process' -ForegroundColor DarkGray
    Write-Host '   * Roblox is a Windows program; this script therefore requires Windows' -ForegroundColor DarkGray
    Write-Host '   * the client is not injected, hooked or patched: only kernel' -ForegroundColor DarkGray
    Write-Host '     scheduling and memory limits are used, and every change is read' -ForegroundColor DarkGray
    Write-Host '     back from the OS and shown in the result table' -ForegroundColor DarkGray
    Write-Host ''
}

function ConvertTo-HarnessArgumentList {
    <#
        Rebuilds a command line from the bound parameters so an elevated
        relaunch (or the log header) reproduces exactly this run.
    #>
    param([Parameter(Mandatory)][hashtable] $Bound)

    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($key in ($Bound.Keys | Sort-Object)) {
        if ($key -eq 'Verbose') { continue }
        $value = $Bound[$key]
        if ($value -is [switch] -or $value -is [bool]) {
            if ($value) { $parts.Add("-$key") }
            continue
        }
        if ($value -is [array]) {
            $items = @($value | ForEach-Object { if ("$_" -match '\s') { "`"$_`"" } else { "$_" } })
            if ($items.Count -gt 0) { $parts.Add("-$key $($items -join ',')") }
            continue
        }
        $text = "$value"
        if ($text -match '\s') { $text = "`"$text`"" }
        $parts.Add("-$key $text")
    }
    return ($parts -join ' ')
}

function Show-HarnessPlan {
    <#
        -DryRun output: everything that would happen, nothing that did.
    #>
    param(
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)][object[]] $Targets,
        [Parameter(Mandatory)] $Topology,
        [Parameter(Mandatory)][int[]] $WorkloadCpus
    )

    Write-Rule 'dry run - nothing will be changed'
    Write-Kv 'would pin' (($Targets | ForEach-Object { "$($_.Name) (pid $($_.Id))" }) -join ', ') -Color White
    Write-Kv 'to cpus' (Format-Mask -Mask $State.Mask) -Color Cyan
    Write-Kv 'priority class' $State.Priority
    Write-Kv 'memory priority' $State.MemoryPriority
    if ($State.ReserveBytes -gt 0) {
        Write-Kv 'working set floor' "$(Format-Bytes -Bytes $State.ReserveBytes) ($(if ($State.HardMin) { 'hard' } else { 'soft' }))"
        Write-Kv 'why that size' $State.ReserveReason
    } else {
        Write-Kv 'working set floor' 'none'
    }
    if ($State.CpuRateUnits -gt 0) { Write-Kv 'game cpu cap' "$($State.CpuLimitPercent)% of the pinned core" }
    Write-Kv 'workload cpus' "$($WorkloadCpus -join ', ')"
    Write-Kv 'free cpus after pinning' "$(@(0..($Topology.Group0Logical - 1) | Where-Object { $State.CpuList -notcontains $_ }) -join ', ')"
    if ($Workload) { Write-Kv 'workload' $Workload }
    Write-Host ''
    Write-Log -Level INFO -Message 're-run without -DryRun to apply this'
}

function Show-FinalReport {
    param(
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)][object[]] $Targets,
        [Parameter(Mandatory)] $Topology,
        [object] $WorkloadProcess
    )

    Write-Rule 'result'
    foreach ($t in $Targets) {
        $info = Get-TargetRuntimeInfo -Target $t
        if (-not $info.Alive) {
            Write-Kv "$($t.Name) (pid $($t.Id))" 'exited during the session' -Color Yellow
            continue
        }
        $pct = 'n/a'
        if ($null -ne $info.CpuPercent) { $pct = "$([int]$info.CpuPercent)%" }
        Write-Kv "$($t.Name) (pid $($t.Id))" '' -Color White
        Write-Kv '  pinned to' (Format-Mask -Mask $info.AffinityMask)
        Write-Kv '  priority / memprio' "$(Get-PriorityClassName -Value $info.PriorityClass) / $(Get-MemoryPriorityName -Value $info.MemoryPriority)"
        Write-Kv '  working set now' "$(Format-Bytes -Bytes $info.WorkingSet)  (cpu $pct)"
        if ($State.ReserveBytes -gt 0) {
            $delta = $info.WorkingSet - $State.ReserveBytes
            $word = 'above'
            if ($delta -lt 0) { $word = 'below' }
            Write-Kv '  vs reserved floor' ("{0} {1} the {2} reservation" -f (Format-Bytes -Bytes ([math]::Abs($delta))), $word, (Format-Bytes -Bytes $State.ReserveBytes))
        }
    }

    if ($WorkloadProcess) {
        $alive = Get-Process -Id $WorkloadProcess.Id -ErrorAction SilentlyContinue
        if ($alive) {
            Write-Kv 'workload' "$($alive.ProcessName) (pid $($alive.Id)) is running on the remaining resources" -Color Green
        } else {
            Write-Kv 'workload' "pid $($WorkloadProcess.Id) has exited"
        }
    }

    Write-Host ''
    Write-Host '  machine totals:' -ForegroundColor White
    $liveCores = @($Topology.Cores | Where-Object { $State.CpuList -notcontains $_.PrimaryCpu })
    Write-Kv 'you kept' "$($liveCores.Count) of $($Topology.CoreCount) physical cores"
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
        if ($os) {
            Write-Kv 'memory available' (Format-Bytes -Bytes ([double]$os.FreePhysicalMemory * 1024.0))
        }
    } catch { }
}

# =============================================================================
# Region: main
# =============================================================================

function Get-SimulatedTopology {
    <#
        A topology shaped like the real one, built from what .NET can see, so a
        non-Windows machine can still show the decision flow. It is clearly
        labelled as simulated and is only used by -DryRun.
    #>
    $logical = [int][Environment]::ProcessorCount
    if ($logical -lt 1) { $logical = 1 }
    $cores = New-Object System.Collections.Generic.List[psobject]
    for ($i = 0; $i -lt $logical; $i++) {
        $cores.Add([pscustomobject]@{
            Index           = $i
            Group           = 0
            EfficiencyClass = 0
            HasSmt          = $false
            LogicalCpus     = @($i)
            PrimaryCpu      = $i
        })
    }
    return [pscustomobject]@{
        Cores             = $cores.ToArray()
        CoreCount         = $logical
        TotalLogical      = $logical
        Group0Logical     = $logical
        GroupCount        = 1
        EfficiencyClasses = @(0)
        IsHybrid          = $false
        TotalRam          = 0.0
        FreeRam           = 0.0
        AvailableRam      = 0.0
        DimmCount         = 0
        DimmSpeed         = 0
        DotNetCpuCount    = $logical
        Simulated         = $true
        CapturedAt        = Get-Date
    }
}

function Initialize-HarnessLogging {
    if (-not $LogPath) { return }
    try {
        $full = [System.IO.Path]::GetFullPath($LogPath)
        $dir = Split-Path -Parent $full
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $script:LogFile = $full
        $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Add-Content -LiteralPath $full -Value "--- Harness $script:HarnessVersion session $stamp ---" -Encoding UTF8
        if ($script:BoundParams.Count -gt 0) {
            Add-Content -LiteralPath $full -Value ("    invoked with: " + (ConvertTo-HarnessArgumentList -Bound $PSBoundParameters)) -Encoding UTF8
        }
    } catch {
        $script:LogFile = $null
        Write-Log -Level WARN -Message "could not open the log file '$LogPath': $($_.Exception.Message)"
    }
}

function Invoke-HarnessMain {
    $exitCode = 0

    Write-Banner
    Initialize-HarnessLogging

    $script:DebugMode = $script:BoundParams.ContainsKey('Verbose')
    Write-Log -Level DEBUG -Message "PowerShell $($PSVersionTable.PSVersion) on $([System.Environment]::OSVersion.VersionString)"

    # ---- profile ------------------------------------------------------------
    if ($ProfilePath) {
        $profileInfo = Import-HarnessProfile -Path $ProfilePath
        $script:ProfileData = $profileInfo.Data
    }

    # ---- state path ---------------------------------------------------------
    $resolvedStatePath = $StatePath
    if (-not $resolvedStatePath) { $resolvedStatePath = Get-DefaultStatePath }
    $script:StatePath = $resolvedStatePath

    # ---- mode: restore only -------------------------------------------------
    if ($script:RestoreRequested) {
        Write-Rule 'restore mode'
        try {
            [void](Invoke-RestoreFromStateFile -Path $resolvedStatePath)
        } catch {
            Write-Log -Level ERROR -Message $_.Exception.Message
            $exitCode = 3
        }
        return $exitCode
    }

    # ---- mode: self test ----------------------------------------------------
    if ($SelfTest) {
        $topology = $null
        if (Test-Windows) {
            try {
                Initialize-HarnessNative
                $topology = Get-SystemTopology -Refresh
            } catch {
                Write-Log -Level ERROR -Message $_.Exception.Message
            }
        }
        if (-not $topology) {
            $topology = [pscustomobject]@{
                Cores = @(); CoreCount = 0; TotalLogical = 0; Group0Logical = 0; GroupCount = 0
                EfficiencyClasses = @(); IsHybrid = $false; TotalRam = 0; FreeRam = 0; AvailableRam = 0
                DimmCount = 0; DimmSpeed = 0; DotNetCpuCount = [Environment]::ProcessorCount; CapturedAt = Get-Date
            }
        }
        $rows = @(Invoke-HarnessSelfTest -Topology $topology)
        if (@($rows | Where-Object { $_.Status -eq 'FAIL' }).Count -gt 0) { $exitCode = 4 }
        return $exitCode
    }

    # ---- platform guard ----------------------------------------------------
    if (-not (Test-Windows)) {
        Write-Log -Level ERROR -Message 'this script needs Windows: Roblox does not run natively on this platform, and CPU affinity / job objects / working sets are Win32 concepts'
        Write-Host ''
        Write-Host '  What you can run here instead:' -ForegroundColor White
        Write-Host '    pwsh -File ./HARNESS.ps1 -SelfTest   # environment report, marks the Windows-only parts' -ForegroundColor DarkGray
        Write-Host '    pwsh -File ./HARNESS.ps1 -DryRun     # simulated plan, nothing is changed' -ForegroundColor DarkGray
        Write-Host ''
        Write-Host "  this machine: $([System.Environment]::OSVersion.VersionString)" -ForegroundColor DarkGray
        Write-Host '  Linux equivalents would be taskset -c 3 <pid> plus a cgroup memory floor,' -ForegroundColor DarkGray
        Write-Host '  but the Roblox client itself is Windows-only, which is why this script is too.' -ForegroundColor DarkGray

        if ($DryRun) {
            Write-Host ''
            Write-Log -Level STEP -Message 'simulated plan (this platform cannot run it for real)'
            $sim = Get-SimulatedTopology
            Show-Topology -Topology $sim
            $pick = Select-TargetCore -Topology $sim -Requested @() -Mode 'Logical'
            Write-Kv 'would pin a client to' (Format-Mask -Mask $pick.Mask) -Color Cyan
            Write-Kv 'why that core' $pick.Reason
            Write-Kv 'priority class' 'Auto (High on an idle machine, AboveNormal otherwise)'
            Write-Kv 'working set floor' 'auto-sized from the client usage and free RAM (unavailable here)'
            Write-Kv 'workload cpus' "$(@(0..($sim.Group0Logical - 1) | Where-Object { $pick.CpuList -notcontains $_ }) -join ', ')"
            Write-Host ''
            Write-Log -Level INFO -Message 'on Windows this plan is then applied, read back from the kernel and printed as a table'
        }
        return 1
    }

    $script:IsWindowsHost = $true
    $script:IsAdmin = Test-Administrator
    if (-not $script:IsAdmin) {
        Write-Log -Level DEBUG -Message 'running without administrator rights'
    }

    try {
        Initialize-HarnessNative
    } catch {
        Write-Log -Level ERROR -Message $_.Exception.Message
        Write-Log -Level INFO -Message 'run with -SelfTest for the full environment report'
        return 5
    }

    # ---- topology -----------------------------------------------------------
    $topology = Get-SystemTopology -Refresh
    Write-Rule 'machine'
    Show-Topology -Topology $topology
    if ($topology.CoreCount -eq 0) {
        Write-Log -Level ERROR -Message 'could not read the CPU topology; refusing to guess about affinity masks'
        return 6
    }

    # ---- targets ------------------------------------------------------------
    Write-Rule 'target discovery'
    if ($TargetName) {
        Write-Kv 'looking for' (($TargetName) -join ', ')
    } else {
        Write-Kv 'looking for' (($script:DefaultTargets) -join ', ') 
    }

    $targets = @(Select-TargetProcess -Name $TargetName -LaunchIfMissing:$Launch)
    if ($targets.Count -eq 0 -and -not $Launch) {
        Write-Log -Level WARN -Message 'no target process found'
        Write-Log -Level INFO -Message 'start the game (or use -Launch to start it through the roblox-player: protocol), then re-run'
        if ($TargetName) { Write-Log -Level INFO -Message "if the game is running under a different image name, try: -TargetName '*' to list candidates" }
        return 2
    }

    if ($targets.Count -eq 0 -and $Launch) {
        Write-Log -Level STEP -Message 'waiting up to 90s for a Roblox client to appear'
        $deadline = (Get-Date).AddSeconds(90)
        while ((Get-Date) -lt $deadline -and $targets.Count -eq 0) {
            Start-Sleep -Seconds 3
            $targets = @(Select-TargetProcess -Name $TargetName)
            if ($targets.Count -gt 0) { break }
            Write-Host '.' -NoNewline -ForegroundColor DarkGray
        }
        Write-Host ''
        if ($targets.Count -eq 0) {
            Write-Log -Level WARN -Message 'the client never appeared; is Roblox installed for this user?'
            return 2
        }
    }

    foreach ($t in $targets) {
        $path = [HarnessNative]::GetProcessPath($t.Id)
        Write-Kv "$($t.Name)" "pid $($t.Id) - $(Format-Bytes -Bytes $t.Process.WorkingSet64)" -Color White
        if ($path) { Write-Kv '  image' $path -Color Gray }
    }

    # ---- access check + elevation offer ------------------------------------
    $openable = 0
    foreach ($t in $targets) {
        if ((Get-ProcessHandle -ProcessId $t.Id -Quiet) -ne [IntPtr]::Zero) { $openable++ }
    }
    if ($openable -eq 0) {
        Write-Log -Level WARN -Message 'no target could be opened with write rights (this is what anti-cheat or a different user account looks like)'
        $relaunched = Invoke-HarnessRelaunchElevated -Arguments @(ConvertTo-HarnessArgumentList -Bound $PSBoundParameters)
        if ($relaunched) { return 0 }
        Write-Log -Level WARN -Message 'continuing: affinity and priority often still work even when the quota rights are refused'
    }

    # ---- settings -----------------------------------------------------------
    $state = Resolve-HarnessSettings -Topology $topology -Targets $targets
    $workloadCpus = @(Get-WorkloadCpuList -Topology $topology -State $state)

    if ($DryRun) {
        Show-HarnessPlan -State $state -Targets $targets -Topology $topology -WorkloadCpus $workloadCpus
        return 0
    }

    # ---- confirm ------------------------------------------------------------
    if (-not ($Yes -or $Workload)) {
        Write-Rule 'confirm'
        Write-HarnessHonesty
        $ok = Read-HarnessYesNo -Question 'apply this allocation now?' -Default $true
        if (-not $ok) {
            Write-Log -Level INFO -Message 'cancelled; nothing was changed'
            return 0
        }
    }

    # ---- allocate -----------------------------------------------------------
    Write-Rule 'allocating'
    $results = @(Invoke-HarnessAllocation -Targets $targets -State $state)
    Save-HarnessState -State $state -Results $results

    $applied = @($results | Where-Object { $_.Ok }).Count
    $denied = @($results | Where-Object { -not $_.Ok }).Count
    if ($denied -eq 0) {
        Write-Log -Level OK -Message "$applied limit(s) applied and verified"
    } else {
        Write-Log -Level WARN -Message "$applied limit(s) applied, $denied refused by the OS (see the table above)"
    }

    # ---- workload -----------------------------------------------------------
    # Interactive (a human is at the console) keeps the workload in its own
    # window so the watch loop can keep printing here; batch runs stream into
    # this console instead.
    $script:NonInteractive = [bool]($Yes -or $Workload)
    $interactiveShell = -not $script:NonInteractive
    $workloadProcess = $null
    $choice = Resolve-WorkloadChoice -State $state -CpuList $workloadCpus

    switch ($choice.Mode) {
        'command' {
            try {
                $workloadProcess = Start-HarnessWorkload -Command $choice.Command -State $state -CpuList $workloadCpus `
                    -Hidden:(-not $interactiveShell)
            } catch {
                Write-Log -Level ERROR -Message "workload failed to start: $($_.Exception.Message)"
            }
        }
        'shell' {
            try { $workloadProcess = Start-PinnedShell -State $state -CpuList $workloadCpus } catch {
                Write-Log -Level ERROR -Message "shell failed to start: $($_.Exception.Message)"
            }
        }
        default {
            Write-Log -Level INFO -Message 'nothing queued for the remaining resources; holding the game allocation instead'
        }
    }

    # ---- hold ---------------------------------------------------------------
    $shouldWatch = $Watch.IsPresent
    if ($workloadProcess -and -not $Watch) {
        Write-Log -Level INFO -Message "waiting for the workload (pid $($workloadProcess.Id)) to finish; Ctrl+C keeps it running and returns here"
        try {
            if (Get-Process -Id $workloadProcess.Id -ErrorAction SilentlyContinue) {
                Wait-Process -Id $workloadProcess.Id -ErrorAction Stop
            }
            $code = $null
            try { $code = $workloadProcess.ExitCode } catch { }
            Write-Log -Level OK -Message "workload finished (pid $($workloadProcess.Id))$(if ($null -ne $code) { ", exit code $code" })"
        } catch {
            Write-Log -Level INFO -Message 'stopped waiting for the workload'
        }
        $shouldWatch = $false
    } elseif ($interactiveShell) {
        $shouldWatch = $true
    }

    # A snapshot of where things stand before holding, so the end-of-run report
    # has something to be compared against (the working set creeps up to the
    # floor over the next few seconds).
    Write-Rule 'state now'
    Show-HarnessStatus -Targets $targets -State $state

    if ($shouldWatch) {
        Invoke-HarnessWatchLoop -Targets $targets -State $state -Topology $topology -IntervalSec $WatchIntervalSec -UntilKeypress:$interactiveShell
    }

    Show-FinalReport -State $state -Targets $targets -Topology $topology -WorkloadProcess $workloadProcess

    Write-Host ''
    if ($RestoreOnExit) {
        Write-Log -Level INFO -Message 'restoring original settings on exit (-RestoreOnExit)'
    } else {
        Write-Log -Level INFO -Message "the allocation stays until the client exits or you run -Restore (state file: $script:StatePath)"
    }

    return $exitCode
}

# =============================================================================
# Entry point
# =============================================================================

try {
    $mainResult = Invoke-HarnessMain
    Stop-Harness -Code ([int]$mainResult)
} catch {
    Write-Host ''
    Write-Log -Level ERROR -Message $_.Exception.Message
    if ($script:DebugMode) {
        Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-Host '  If this looks like a bug, the useful details to include are:' -ForegroundColor DarkGray
    Write-Host '    - the -SelfTest output' -ForegroundColor DarkGray
    Write-Host '    - PowerShell version and Windows build' -ForegroundColor DarkGray
    Write-Host "    - the command line you used: $(ConvertTo-HarnessArgumentList -Bound $PSBoundParameters)" -ForegroundColor DarkGray
    Stop-Harness -Code 1 -Reason 'aborted'
}
