
# =============================================================================
# Region: profiles + settings resolution
# =============================================================================

function Import-HarnessProfile {
    <#
        Loads a JSON profile. Accepts an absolute path, a path relative to the
        repo, or a bare name that resolves under profiles/.
    #>
    param([Parameter(Mandatory)][string] $Path)

    $candidates = New-Object System.Collections.Generic.List[string]
    $candidates.Add($Path)
    if (-not [System.IO.Path]::IsPathRooted($Path)) {
        $candidates.Add((Join-Path $script:RepoRoot $Path))
        $candidates.Add((Join-Path (Join-Path $script:RepoRoot 'profiles') $Path))
        if ($Path -notmatch '\.json$') {
            $candidates.Add((Join-Path (Join-Path $script:RepoRoot 'profiles') "$Path.json"))
        }
    }

    $resolved = $null
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c -PathType Leaf) {
            $resolved = (Resolve-Path -LiteralPath $c).ProviderPath
            break
        }
    }
    if (-not $resolved) {
        throw "profile '$Path' not found (looked in: $($candidates -join '; '))"
    }

    try {
        $raw = Get-Content -LiteralPath $resolved -Raw -ErrorAction Stop
        $data = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "profile '$resolved' is not valid JSON: $($_.Exception.Message)"
    }
    if ($null -eq $data) { throw "profile '$resolved' is empty" }

    Write-Log -Level OK -Message "profile loaded: $resolved"
    return [pscustomobject]@{ Path = $resolved; Data = $data }
}

function Get-EffectiveSetting {
    <#
        Precedence: command line > profile > caller-supplied fallback.
    #>
    param([Parameter(Mandatory)][string] $Name, [object] $Fallback = $null)

    if ($script:BoundParams.ContainsKey($Name)) {
        return (Get-Variable -Name $Name -Scope Script -ValueOnly)
    }
    if ($script:ProfileData) {
        $prop = $script:ProfileData.PSObject.Properties[$Name]
        if ($prop -and $null -ne $prop.Value) { return $prop.Value }
    }
    return $Fallback
}

function Get-SystemLoadSummary {
    <#
        One number for total CPU busyness plus a process count. Used by the
        priority heuristic (busy machine: do not also demand High priority).
    #>
    $total = $null
    $procCount = 0
    try {
        $procCount = @(Get-Process -ErrorAction SilentlyContinue).Count
    } catch { }
    try {
        $row = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop
        $total = [double]$row.PercentProcessorTime
    } catch {
        Write-Log -Level DEBUG -Message "total CPU load unavailable: $($_.Exception.Message)"
    }
    return [pscustomobject]@{ TotalCpuPercent = $total; ProcessCount = $procCount }
}

function Select-TargetCore {
    <#
        Turns -Core/-CoreMode (or an auto-pick) into a concrete set of logical
        CPUs and an affinity mask.

        Auto-pick strategy, in order:
          1. on a hybrid CPU, prefer an efficiency core: confining the game to a
             slow core is what frees the performance cores for your workload
          2. prefer a physical core whose sibling threads are idle
          3. lowest measured load, then lowest index
        The whole physical core is taken (all siblings) so the "one processor"
        the game gets is a real core, not half of one.
    #>
    param(
        [Parameter(Mandatory)] $Topology,
        [int[]] $Requested,
        [ValidateSet('Logical', 'Physical')][string] $Mode = 'Logical'
    )

    $load = Get-CoreLoad
    $candidates = New-Object System.Collections.Generic.List[psobject]

    foreach ($core in $Topology.Cores) {
        $cpuLoad = 0.0
        $known = $false
        if ($load) {
            $sum = 0.0
            foreach ($cpu in $core.LogicalCpus) {
                if ($load.PerCpu.ContainsKey($cpu)) { $sum += [double]$load.PerCpu[$cpu]; $known = $true }
            }
            if ($known) { $cpuLoad = $sum / [double]$core.LogicalCpus.Count }
        }
        $isEfficiency = ($core.EfficiencyClass -eq 0)
        $candidates.Add([pscustomobject]@{
            Core         = $core
            LoadPercent  = [math]::Round($cpuLoad, 1)
            LoadKnown    = $known
            IsEfficiency = $isEfficiency
        })
    }

    if ($Requested -and $Requested.Count -gt 0) {
        $cpus = New-Object System.Collections.Generic.List[int]
        foreach ($r in $Requested) {
            if ($Mode -eq 'Logical') {
                if ($r -lt 0 -or $r -ge $Topology.Group0Logical) {
                    throw "logical CPU $r does not exist (group 0 has $($Topology.Group0Logical) logical processors)"
                }
                if (-not $cpus.Contains($r)) { $cpus.Add($r) }
            } else {
                if ($r -lt 0 -or $r -ge $Topology.CoreCount) {
                    throw "physical core $r does not exist (this machine has $($Topology.CoreCount) physical cores)"
                }
                foreach ($cpu in $Topology.Cores[$r].LogicalCpus) {
                    if (-not $cpus.Contains($cpu)) { $cpus.Add($cpu) }
                }
            }
        }
        $sorted = @($cpus | Sort-Object)
        return [pscustomobject]@{
            CpuList    = $sorted
            Mask       = (ConvertFrom-CpuList -Cpu $sorted)
            Mode       = $Mode
            Reason     = "requested by caller ($Mode)"
            Candidates = @()
            PhysicalCores = @(Get-CoresForCpu -Topology $Topology -Cpu $sorted)
        }
    }

    # ---- auto pick -----------------------------------------------------------
    $ordered = @($candidates | Sort-Object `
        -Property @{ Expression = 'IsEfficiency'; Descending = $true },
                  @{ Expression = 'LoadPercent'; Descending = $false },
                  @{ Expression = { $_.Core.Index }; Ascending = $true })

    # `$Topology.IsHybrid` is the tie-breaker only: Sort-Object already pushed
    # efficiency cores first, but on a uniform CPU every core is "efficiency 0".
    if (-not $Topology.IsHybrid) {
        $ordered = @($candidates | Sort-Object `
            -Property @{ Expression = 'LoadPercent'; Descending = $false },
                      @{ Expression = { $_.Core.Index }; Ascending = $true })
    }

    $best = $ordered[0]
    $cpuList = @($best.Core.LogicalCpus | Sort-Object)
    $reasonParts = New-Object System.Collections.Generic.List[string]
    if ($Topology.IsHybrid -and $best.IsEfficiency) { $reasonParts.Add('efficiency core (leaves performance cores free)') }
    if ($best.LoadKnown) { $reasonParts.Add("measured load $($best.LoadPercent)%") }
    $reasonParts.Add("physical core $($best.Core.Index)")

    return [pscustomobject]@{
        CpuList       = $cpuList
        Mask          = (ConvertFrom-CpuList -Cpu $cpuList)
        Mode          = 'Physical'
        Reason        = ($reasonParts -join ', ')
        Candidates    = @($ordered | Select-Object -First 5)
        PhysicalCores = @($best.Core.Index)
    }
}

function Get-CoresForCpu {
    param([Parameter(Mandatory)] $Topology, [Parameter(Mandatory)][int[]] $Cpu)
    $cores = New-Object System.Collections.Generic.List[int]
    foreach ($c in $Cpu) {
        foreach ($core in $Topology.Cores) {
            if ($core.LogicalCpus -contains $c) {
                if (-not $cores.Contains($core.Index)) { $cores.Add($core.Index) }
                break
            }
        }
    }
    return $cores.ToArray()
}

function Show-CoreCandidates {
    param([Parameter(Mandatory)] $Selection)
    if (-not $Selection.Candidates -or $Selection.Candidates.Count -eq 0) { return }

    Write-Host '  candidate cores (auto-pick ranking):' -ForegroundColor DarkGray
    $rank = 1
    foreach ($c in $Selection.Candidates) {
        $kind = 'performance'
        if ($c.IsEfficiency) { $kind = 'efficiency' }
        $loadText = 'load n/a'
        if ($c.LoadKnown) { $loadText = "load $($c.LoadPercent)%" }
        $mark = '  '
        if ($rank -eq 1) { $mark = '> ' }
        Write-Host ("   {0}{1}. core {2,-3} cpus [{3,-9}] {4,-11} {5}" -f `
            $mark, $rank, $c.Core.Index, (($c.Core.LogicalCpus) -join ','), $kind, $loadText) -ForegroundColor DarkGray
        $rank++
    }
}

function New-Result {
    param(
        [string] $Action,
        [string] $Requested,
        [string] $ReadBack,
        [bool]   $Ok,
        [string] $Notes = ''
    )
    $verdict = 'requested-only'
    if ($Ok -and $ReadBack) { $verdict = 'verified' }
    if (-not $Ok) { $verdict = 'NOT APPLIED' }
    return [pscustomobject]@{
        Action    = $Action
        Requested = $Requested
        ReadBack  = $ReadBack
        Ok        = $Ok
        Verdict   = $verdict
        Notes     = $Notes
    }
}

function Show-ApplyTable {
    param([Parameter(Mandatory)][object[]] $Results)
    Write-Host ''
    Write-Host ("  {0,-18} {1,-26} {2,-30} {3}" -f 'ACTION', 'REQUESTED', 'READ BACK FROM OS', 'RESULT') -ForegroundColor White
    Write-Host ('  ' + ('-' * 92)) -ForegroundColor DarkCyan
    foreach ($r in $Results) {
        $color = 'Gray'
        if (-not $r.Ok) { $color = 'Red' }
        elseif ($r.Verdict -eq 'verified') { $color = 'Green' }
        else { $color = 'Yellow' }
        $req = $r.Requested
        if ($req.Length -gt 25) { $req = $req.Substring(0, 24) + [char]0x2026 }
        $rb = $r.ReadBack
        if ($rb.Length -gt 29) { $rb = $rb.Substring(0, 28) + [char]0x2026 }
        Write-Host ("  {0,-18} {1,-26} {2,-30} {3}" -f $r.Action, $req, $rb, $r.Verdict) -ForegroundColor $color
    }
}

function Resolve-HarnessSettings {
    <#
        Collects every knob (command line > profile > prompt/auto) into one
        settings object, and prints the allocation ledger before anything is
        changed.
    #>
    param(
        [Parameter(Mandatory)] $Topology,
        [Parameter(Mandatory)][object[]] $Targets
    )

    $interactive = -not ($Yes -or $Workload)

    # ---- core ---------------------------------------------------------------
    $requestedCore = @(Get-EffectiveSetting -Name 'Core' -Fallback @())
    $coreMode = [string](Get-EffectiveSetting -Name 'CoreMode' -Fallback 'Logical')
    $selection = Select-TargetCore -Topology $Topology -Requested $requestedCore -Mode $coreMode

    Write-Log -Level STEP -Message 'Core allocation'
    if ($requestedCore.Count -eq 0) {
        Write-Kv 'selected' "$($selection.Reason)" -Color White
        Show-CoreCandidates -Selection $selection
    } else {
        Write-Kv 'selected' "operator choice ($coreMode)" -Color White
    }
    Write-Kv 'pinning to' (Format-Mask -Mask $selection.Mask) -Color Cyan
    Write-Kv 'physical core(s)' (($selection.PhysicalCores) -join ', ') -Color White
    if ($interactive) {
        Write-Host ''
        $alt = @(
            @{ Label = 'use this core'; Value = 'auto'; Hint = 'recommended'; },
            @{ Label = 'pick a different logical CPU number'; Value = 'logical'; Hint = 'e.g. 3 pins one thread'; },
            @{ Label = 'pick a different physical core'; Value = 'physical'; Hint = 'whole core, all siblings'; }
        )
        $pick = Read-HarnessChoice -Question 'Change the pinned core?' -Options $alt -DefaultIndex 0
        if ($pick -eq 'logical') {
            $text = Read-HarnessText -Question 'logical CPU number(s), comma separated' -Default (($selection.CpuList) -join ',')
            $nums = @($text -split '[,\s]+' | Where-Object { $_ -ne '' } | ForEach-Object { [int]$_ })
            $selection = Select-TargetCore -Topology $Topology -Requested $nums -Mode 'Logical'
        } elseif ($pick -eq 'physical') {
            $text = Read-HarnessText -Question 'physical core number(s), comma separated' -Default (($selection.PhysicalCores) -join ',')
            $nums = @($text -split '[,\s]+' | Where-Object { $_ -ne '' } | ForEach-Object { [int]$_ })
            $selection = Select-TargetCore -Topology $Topology -Requested $nums -Mode 'Physical'
        }
        Write-Kv 'final pin' (Format-Mask -Mask $selection.Mask) -Color Cyan
    }

    # ---- priority -----------------------------------------------------------
    $priorityName = [string](Get-EffectiveSetting -Name 'Priority' -Fallback 'Auto')
    $loadSummary = Get-SystemLoadSummary
    $priorityReason = 'requested'
    if ($priorityName -eq 'Auto') {
        $priorityName = 'AboveNormal'
        $priorityReason = 'default for a machine that is already busy'
        if ($null -ne $loadSummary.TotalCpuPercent -and $loadSummary.TotalCpuPercent -lt 20 -and $loadSummary.ProcessCount -lt 250) {
            $priorityName = 'High'
            $priorityReason = "first-busy-process heuristic (system idle at $([int]$loadSummary.TotalCpuPercent)%)"
        }
    } else {
        $priorityReason = 'operator choice'
    }
    if ($priorityName -eq 'RealTime') {
        Write-Log -Level WARN -Message 'RealTime priority on a pinned core can starve drivers that share that core; prefer High.'
    }
    $priorityValue = Resolve-PriorityClass -Name $priorityName

    # ---- memory priority ----------------------------------------------------
    # Decided after the working-set block below, because "Auto" only lifts the
    # page priority above the Windows default when a floor is actually being
    # requested - that is the case where pages are worth protecting.

    # ---- working set --------------------------------------------------------
    $reserveMB = [int](Get-EffectiveSetting -Name 'RamReserveMB' -Fallback -1)
    $reservePercent = [double](Get-EffectiveSetting -Name 'RamReservePercent' -Fallback -1)
    $ceilingMB = [int](Get-EffectiveSetting -Name 'RamCeilingMB' -Fallback -1)
    $hardMin = -not ([bool](Get-EffectiveSetting -Name 'NoHardMin' -Fallback $false))

    $currentWorkingSet = 0.0
    foreach ($t in $Targets) { $currentWorkingSet += [double]$t.Process.WorkingSet64 }

    $auto = Get-AutoRamReserve -TotalRam $Topology.TotalRam -AvailableRam $Topology.AvailableRam `
        -CurrentWorkingSet $currentWorkingSet -RequestedPercent $reservePercent

    $reserveBytes = $auto.Bytes
    $reserveReason = $auto.Reasons -join '; '
    if ($reserveMB -gt 0) {
        $reserveBytes = [double]$reserveMB * 1MB
        $reserveReason = "explicit -RamReserveMB $reserveMB"
    }

    if ($interactive -and $reserveMB -le 0) {
        $options = @(
            @{ Label = "accept $(Format-Bytes -Bytes $reserveBytes)"; Value = 'auto'; Hint = 'auto-sized'; },
            @{ Label = '10% of installed RAM'; Value = '10'; Hint = $(Format-Bytes -Bytes ($Topology.TotalRam * 0.10)); },
            @{ Label = '25% of installed RAM'; Value = '25'; Hint = $(Format-Bytes -Bytes ($Topology.TotalRam * 0.25)); },
            @{ Label = '50% of installed RAM'; Value = '50'; Hint = $(Format-Bytes -Bytes ($Topology.TotalRam * 0.50)); },
            @{ Label = 'type my own MiB figure'; Value = 'custom'; Hint = ''; },
            @{ Label = 'do not reserve RAM'; Value = 'none'; Hint = 'affinity + priority only'; }
        )
        Write-Log -Level STEP -Message 'Memory allocation'
        Write-Kv 'installed / available' "$(Format-Bytes -Bytes $Topology.TotalRam) / $(Format-Bytes -Bytes $Topology.AvailableRam)"
        Write-Kv 'target working set' (Format-Bytes -Bytes $currentWorkingSet)
        $pick = Read-HarnessChoice -Question 'How much RAM should be held resident for the game?' -Options $options -DefaultIndex 0
        switch ($pick) {
            'none'   { $reserveBytes = 0; $reserveReason = 'operator declined a reservation' }
            'custom' {
                $text = Read-HarnessText -Question 'reserve how many MiB?' -Default ([string][int]($reserveBytes / 1MB))
                $n = 0
                if ([int]::TryParse($text, [ref]$n) -and $n -ge 0) {
                    $reserveBytes = [double]$n * 1MB
                    $reserveReason = "operator chose $n MiB"
                } else {
                    Write-Log -Level WARN -Message "could not parse '$text', keeping $(Format-Bytes -Bytes $reserveBytes)"
                }
            }
            '10' { $reserveBytes = $Topology.TotalRam * 0.10; $reserveReason = 'operator chose 10%' }
            '25' { $reserveBytes = $Topology.TotalRam * 0.25; $reserveReason = 'operator chose 25%' }
            '50' { $reserveBytes = $Topology.TotalRam * 0.50; $reserveReason = 'operator chose 50%' }
        }
    } elseif ($reserveBytes -gt 0) {
        Write-Log -Level STEP -Message 'Memory allocation'
        Write-Kv 'installed / available' "$(Format-Bytes -Bytes $Topology.TotalRam) / $(Format-Bytes -Bytes $Topology.AvailableRam)"
        Write-Kv 'target working set' (Format-Bytes -Bytes $currentWorkingSet)
        Write-Kv 'reserving' (Format-Bytes -Bytes $reserveBytes) -Color Cyan
        Write-Log -Level DEBUG -Message "auto-size reasoning: $reserveReason"
    }

    $ceilingBytes = 0.0
    if ($ceilingMB -gt 0) { $ceilingBytes = [double]$ceilingMB * 1MB }
    if ($ceilingBytes -gt 0 -and $hardMin -and $ceilingBytes -lt $reserveBytes) {
        Write-Log -Level WARN -Message 'working-set ceiling is below the hard floor; Windows rejects that pair, so the ceiling is being dropped (use -NoHardMin to keep it).'
        $ceilingBytes = 0
    }

    # ---- memory priority ----------------------------------------------------
    $memPrioName = [string](Get-EffectiveSetting -Name 'MemoryPriority' -Fallback 'Auto')
    if ($memPrioName -eq 'Off') { $memPrioName = 'Normal' }
    if ($memPrioName -eq 'Auto') {
        if ($reserveBytes -gt 0) {
            # One notch above the default of 5 so the memory manager trims the
            # game's pages last while the floor is being held.
            $memPrioName = 'Normal'
            Write-Log -Level DEBUG -Message 'memory priority left at the Windows default (5); raising it is only useful on very tight RAM'
        } else {
            $memPrioName = 'Normal'
        }
    }

    # ---- CPU share inside the pinned core -----------------------------------
    $cpuLimit = [int](Get-EffectiveSetting -Name 'CpuLimitPercent' -Fallback -1)
    if ($interactive -and $cpuLimit -lt 0) {
        $options = @(
            @{ Label = 'no cap - the game may use the whole core'; Value = -1; Hint = 'default'; },
            @{ Label = 'cap the game at 50% of the core'; Value = 50; Hint = 'leaves 50% guaranteed'; },
            @{ Label = 'cap the game at 25% of the core'; Value = 25; Hint = 'leaves 75% guaranteed'; },
            @{ Label = 'cap the game at 75% of the core'; Value = 75; Hint = ''; }
        )
        $pick = Read-HarnessChoice -Question 'Should the game be capped inside its core?' -Options $options -DefaultIndex 0
        $cpuLimit = [int]$pick
    }
    $cpuRateUnits = 0
    if ($cpuLimit -gt 0) {
        if ($cpuLimit -gt 100) { $cpuLimit = 100 }
        # CpuRate is in hundredths of a percent of one processor.
        $cpuRateUnits = [int]($cpuLimit * 100)
    }

    $workloadPercent = [int](Get-EffectiveSetting -Name 'WorkloadPercent' -Fallback -1)
    if ($workloadPercent -lt 0) {
        if ($cpuRateUnits -gt 0) { $workloadPercent = 100 - $cpuLimit } else { $workloadPercent = 100 }
    }
    if ($workloadPercent -gt 100) { $workloadPercent = 100 }
    if ($workloadPercent -lt 1) { $workloadPercent = 1 }

    # ---- ledger -------------------------------------------------------------
    Write-Rule 'allocation ledger'
    Write-Kv 'target(s)' (($Targets | ForEach-Object { "$($_.Name) (pid $($_.Id))" }) -join ', ') -Color White
    Write-Kv 'cpu' "$(Format-Mask -Mask $selection.Mask)  [physical core $(($selection.PhysicalCores) -join ',')]"
    Write-Kv 'affinity source' $selection.Reason
    Write-Kv 'priority class' "$priorityName ($priorityReason)"
    if ($memPrioName -ne 'Normal') { Write-Kv 'memory priority' $memPrioName }
    if ($reserveBytes -gt 0) {
        Write-Kv 'working set floor' "$(Format-Bytes -Bytes $reserveBytes) ($(if ($hardMin) { 'hard' } else { 'soft' })) - $reserveReason"
    } else {
        Write-Kv 'working set floor' 'none (no reservation)'
    }
    if ($ceilingBytes -gt 0) { Write-Kv 'working set ceiling' (Format-Bytes -Bytes $ceilingBytes) }
    if ($cpuRateUnits -gt 0) {
        Write-Kv 'game cpu share' "$cpuLimit% of the pinned core (hard cap)"
        Write-Kv 'workload cpu share' "$workloadPercent% of the pinned core (guaranteed)"
    } else {
        Write-Kv 'game cpu share' 'uncapped (workload shares best-effort)'
    }

    return [pscustomobject]@{
        CpuList        = $selection.CpuList
        Mask           = [uint64]$selection.Mask
        CoreMode       = $selection.Mode
        PhysicalCores  = $selection.PhysicalCores
        CoreReason     = $selection.Reason
        Priority       = $priorityName
        PriorityValue  = [uint32]$priorityValue
        MemoryPriority = $memPrioName
        MemoryPriorityValue = [uint32](Resolve-MemoryPriority -Name $memPrioName)
        ReserveBytes   = [double]$reserveBytes
        ReserveReason  = $reserveReason
        CeilingBytes   = [double]$ceilingBytes
        HardMin        = $hardMin
        CpuLimitPercent = $cpuLimit
        CpuRateUnits   = $cpuRateUnits
        WorkloadPercent = $workloadPercent
        WorkloadUnits  = [int]($workloadPercent * 100)
    }
}
