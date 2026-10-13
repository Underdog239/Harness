#Requires -Version 5.1
<#
.SYNOPSIS
    Roblox Resource Harness - pins a Roblox client (or any process you name) to one
    chosen CPU core, reserves a working set of RAM for it, and then lets you run
    whatever you want on the resources that are left.

.DESCRIPTION
    Harness does four things, in order:

      1. DISCOVER  finds the running Roblox client (Player / Studio / UWP) and reads
                   the real CPU topology (physical cores, SMT siblings, P/E cores).
      2. ALLOCATE  picks a core, pins the target process to it (process affinity +
                   a job object with a hard affinity limit), lifts its priority so
                   Windows is less likely to preempt it, raises its memory priority
                   and reserves a working set floor so the memory manager keeps that
                   much RAM resident instead of trimming it away.
      3. ASK       prompts you for the thing you want to run on the resources that
                   are left: a command line, a .ps1/.bat/.exe/.py/.lua file, or a
                   pinned interactive shell to type into.
      4. HOLD      watches the allocation, re-asserts it if anything resets it, and
                   restores the original affinity/priority/working-set limits when
                   you exit (with -RestoreOnExit).

    Everything it changes is read back from the OS afterwards and printed, so the
    report tells you what actually happened rather than what was requested.

    HONEST LIMITS - read these before filing a bug:
      * A CPU core cannot be given RAM. Cores and memory are separate resources.
        What Harness can do to memory is reserve a *working set* (physical RAM the
        memory manager tries to keep resident for that process) and set job-object
        memory limits. It cannot hand 8 GB of RAM to core #3.
      * Roblox is a Windows program. This script therefore requires Windows.
        Roblox does not run natively on Linux/macOS, and no script can run it there.
      * Roblox's anti-cheat (Hyperion) protects RobloxPlayerBeta.exe. Harness does
        not inject, hook, patch or read the process; it only asks the kernel for
        scheduling/memory limits, which are the same knobs Process Lasso or Task
        Manager expose. If the kernel denies a handle, Harness reports the denial
        instead of pretending it worked. Nothing here violates the Roblox Terms of
        Use, but that also means it cannot do impossible things to the client.
      * Luau (Roblox's script language) cannot do any of this: task scheduler and
        memory limits are OS level. The Lua file in roblox/ is a read-only reporter
        you can paste into Studio if you want in-game numbers.

.PARAMETER TargetName
    Process names to target. Default: the Roblox client, which handles
    RobloxPlayerBeta.exe and RobloxStudioBeta.exe as well as the UWP/Store build
    (which reports an ApplicationFrameHost-hosted name). Case-insensitive; ".exe"
    is optional. Use -TargetName "*" to list candidates.

.PARAMETER Core
    Which core(s) to pin to. With -CoreMode Logical (the default) these are logical
    CPU numbers as shown in Task Manager's CPU view. With -CoreMode Physical they are
    physical core numbers and every SMT sibling of each core is included.
    Omit to let Harness pick. Examples: -Core 3, -Core 3,4, -Core 0 -CoreMode Physical.

.PARAMETER CoreMode
    Logical (default) or Physical. See -Core.

.PARAMETER Priority
    Windows priority class for the target: Auto, Idle, BelowNormal, Normal,
    AboveNormal, High (default) or RealTime. "Auto" means the first interactive
    process on the machine (the shell) gets High and every later one gets
    AboveNormal. RealTime is accepted but warned about: on a pinned core it can
    starve the rest of the system if a driver shares that core.

.PARAMETER MemoryPriority
    Page priority hint (Windows 8+): Auto, Off, VeryLow, Low, Medium, BelowNormal
    or Normal. Auto raises the target above the default only when a working set
    floor is requested, because that is when it helps.

.PARAMETER RamReservePercent
    Percentage of total physical RAM to try to keep resident for the target.
    Default -1 = Auto, which sizes from the target's *current* usage and free
    memory (see Get-AutoRamReserve). Absolute override: -RamReserveMB.

.PARAMETER RamReserveMB
    Explicit working-set floor in MiB. Wins over -RamReservePercent.

.PARAMETER RamCeilingMB
    Optional working-set ceiling in MiB. Ignored unless -NoHardMin is also given,
    since Windows refuses a hard ceiling below a hard floor.

.PARAMETER NoHardMin
    Do not use QUOTA_LIMITS_HARDWS_MIN_ENABLE. The floor becomes a hint: the
    memory manager may still trim the target under pressure. Softer on the system,
    but it will not hold the reservation when RAM gets tight.

.PARAMETER CpuLimitPercent
    Optionally cap the target inside its pinned core (job object CPU rate control,
    hard cap). 100 = the whole core, 25 = a quarter of it. The remainder is what
    your workload is allocated, which is the only honest sense in which a single
    core can be "split" between two programs.

.PARAMETER WorkloadPercent
    CPU share for the workload launched in step 3, as a percentage of the pinned
    core. Default -1 = Auto: 100 minus -CpuLimitPercent when that is set, else 100.

.PARAMETER Workload
    Non-interactive mode: the command or file to run on the allocated resources.
    Everything after -Workload is treated as that command's arguments
    (-WorkloadArgument). Supported: full command lines, .ps1, .bat/.cmd, .exe,
    .py, .lua (via a Luau/Lua binary on PATH).

.PARAMETER ProfilePath
    JSON profile from profiles/ (or your own file) that pre-fills any of the
    knobs above. Explicit command-line parameters always win over the profile.

.PARAMETER Watch
    Keep monitoring the allocation and re-assert it. Also the default behaviour
    after step 3 in interactive mode; -Watch alone (with -TargetName) attaches
    without prompting.

.PARAMETER WatchIntervalSec
    Seconds between re-assert passes in the watch loop. Default 3.

.PARAMETER RestoreOnExit
    Restore the original affinity, priority class, memory priority and working-set
    limits for every process Harness touched when it exits.

.PARAMETER Restore
    Restore only: read the state file, undo the last allocation, exit.

.PARAMETER DryRun
    Probe and report; change nothing.

.PARAMETER SelfTest
    Run the built-in checks: parse the profile files, probe every native call,
    verify the CPU topology matches .NET's processor count, and apply/verify/undo
    an affinity change on a throwaway process. Prints a PASS/FAIL table and exits
    non-zero on failure.

.PARAMETER StatePath
    Where the restore journal lives. Default: %LOCALAPPDATA%\Harness\state.json.

.PARAMETER LogPath
    Optional log file. Default: none (console only).

.PARAMETER Yes
    Answer yes to every prompt using the defaults, so the script can run
    non-interactively.

.PARAMETER NoElevate
    Never offer to relaunch with administrator rights.

.PARAMETER NoPause
    Do not wait for a keypress at the end when double-clicked.

.PARAMETER Launch
    Launch Roblox if no client is running (uses the roblox-player: URI protocol;
    falls back to a plain message if that is not registered).

.INPUTS
    None.

.OUTPUTS
    Console report; optionally a JSON state file used by -Restore.

.EXAMPLE
    .\HARNESS.ps1
    Full interactive run: find Roblox, auto-pick a core and RAM reservation, then
    ask what to run on what is left.

.EXAMPLE
    .\HARNESS.ps1 -Core 3 -Priority High -RamReservePercent 25 -CpuLimitPercent 40
    Roblox onto logical CPU 3, High priority, reserve 25% of system RAM, cap it at
    40% of that core.

.EXAMPLE
    .\HARNESS.ps1 -Core 0 -CoreMode Physical -Watch
    Pin every sibling thread of physical core 0 and just hold the allocation.

.EXAMPLE
    .\HARNESS.ps1 -Workload "python train.py --epochs 200" -Yes
    Roblox (auto-detected) constrained, then train on the remaining share.

.EXAMPLE
    .\HARNESS.ps1 -Restore
    Undo the last allocation recorded in the state file.

.NOTES
    Author : built for the Harness repository
    License: MIT
    Version: 1.0.0
    Requires: Windows 10 1607+ / Windows 11, Windows PowerShell 5.1 or PowerShell 7+.
              Administrator rights are only needed for processes you do not own.
#>
[CmdletBinding()]
param(
    [string]   $ProfilePath,

    [string[]] $TargetName,
    [int[]]    $Core,
    [ValidateSet('Logical', 'Physical')]
    [string]   $CoreMode = 'Logical',

    [ValidateSet('Auto', 'Idle', 'BelowNormal', 'Normal', 'AboveNormal', 'High', 'RealTime')]
    [string]   $Priority = 'Auto',

    [ValidateSet('Auto', 'Off', 'VeryLow', 'Low', 'Medium', 'BelowNormal', 'Normal')]
    [string]   $MemoryPriority = 'Auto',

    [double]   $RamReservePercent = -1,
    [int]      $RamReserveMB = -1,
    [int]      $RamCeilingMB = -1,
    [switch]   $NoHardMin,

    [int]      $CpuLimitPercent = -1,
    [int]      $WorkloadPercent = -1,

    [switch]   $Watch,
    [int]      $WatchIntervalSec = 3,
    [switch]   $RestoreOnExit,
    [switch]   $DryRun,
    [switch]   $Yes,
    [switch]   $Restore,
    [switch]   $SelfTest,

    [string]   $Workload,
    [string[]] $WorkloadArgument,

    [string]   $StatePath,
    [string]   $LogPath,
    [switch]   $NoElevate,
    [switch]   $NoPause,
    [switch]   $Launch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Which knobs the caller set explicitly. This is what makes command-line
# parameters win over profile values and prompt defaults: anything absent here
# is still free to be filled in from a profile or by asking.
$script:BoundParams = @{}
foreach ($boundName in $PSBoundParameters.Keys) { $script:BoundParams[$boundName] = $true }

# =============================================================================
# Region: constants
# =============================================================================

$script:RepoRoot = if ($PSCommandPath) { Split-Path -Parent $PSCommandPath } else { (Get-Location).Path }
$script:HarnessVersion = '1.0.0'
$script:IsWindowsHost  = $false
$script:IsAdmin        = $false
$script:DefaultTargets = @(
    'RobloxPlayerBeta',      # desktop client
    'RobloxStudioBeta',      # Studio
    'RobloxStudio',          # older Studio build
    'Windows10Universal'     # UWP/Store "Roblox" package host (also see -TargetName *)
)
$script:RobloxProtocol = 'roblox-player:'

# Priority class values (winnt.h) and their friendly names.
$script:PriorityClasses = [ordered]@{
    'Idle'        = 0x00000040
    'BelowNormal' = 0x00004000
    'Normal'      = 0x00000020
    'AboveNormal' = 0x00008000
    'High'        = 0x00000080
    'RealTime'    = 0x00000100
}

# Memory priority values (MEMORY_PRIORITY_*), default for new processes is Normal=5.
$script:MemoryPriorities = [ordered]@{
    'VeryLow'     = 1
    'Low'         = 2
    'Medium'      = 3
    'BelowNormal' = 4
    'Normal'      = 5
}

$script:State = $null      # working settings, built by Resolve-HarnessSettings
$script:ProfileData = $null  # parsed -ProfilePath JSON, merged under the CLI
$script:Topology = $null   # cached Get-SystemTopology result
$script:Handles = @{}      # pid -> process handle (kept open for the run)
$script:JobObjects = @{}   # name -> job handle
$script:Journal = @()      # original values captured for -RestoreOnExit
$script:LogFile = $null
$script:DebugMode = $false
$script:NonInteractive = $false   # set when running with -Workload/-Yes
$script:RestoreRequested = $Restore

# =============================================================================
# Region: preflight / logging
# =============================================================================

function Test-Windows {
    # $IsWindows exists only in PowerShell 6+; 5.1 is always Windows.
    if (Test-Path variable:IsWindows) { return [bool]$IsWindows }
    return [bool]($env:OS -eq 'Windows_NT')
}

function Test-Administrator {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $p  = New-Object Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][string] $Message = '',
        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR', 'STEP', 'DEBUG', 'RAW')]
        [string] $Level = 'INFO',
        [switch] $NoConsole
    )

    $plain = $Message
    if ($Level -ne 'RAW') { $plain = "[$Level] $Message" }

    if ($script:LogFile) {
        try {
            $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            Add-Content -LiteralPath $script:LogFile -Value "$stamp $plain" -Encoding UTF8
        } catch {
            # Logging must never take the tool down.
            Write-Verbose "log write failed: $($_.Exception.Message)"
        }
    }

    if ($NoConsole) { return }

    switch ($Level) {
        'STEP'  { Write-Host "==> $Message" -ForegroundColor Cyan }
        'OK'    { Write-Host "[ ok ] $Message" -ForegroundColor Green }
        'WARN'  { Write-Host "[warn] $Message" -ForegroundColor Yellow }
        'ERROR' { Write-Host "[fail] $Message" -ForegroundColor Red }
        'DEBUG' { if ($script:DebugMode) { Write-Host "[dbg ] $Message" -ForegroundColor DarkGray } }
        'RAW'   { Write-Host $Message }
        default { Write-Host "[info] $Message" -ForegroundColor Gray }
    }
}

function Write-Rule {
    param([string] $Title = '')
    $line = '- ' * 39
    if ($Title) {
        Write-Host ''
        Write-Host $line -ForegroundColor DarkCyan
        Write-Host "  $Title" -ForegroundColor White
        Write-Host $line -ForegroundColor DarkCyan
    } else {
        Write-Host $line -ForegroundColor DarkCyan
    }
}

function Write-Kv {
    param(
        [string] $Key,
        [string] $Value,
        [string] $Color = 'Gray'
    )
    Write-Host ("  {0,-26} {1}" -f $Key, $Value) -ForegroundColor $Color
}

function Write-Banner {
    Write-Host ''
    Write-Host '  ============================================================' -ForegroundColor DarkCyan
    Write-Host '    R O B L O X   R E S O U R C E   H A R N E S S' -ForegroundColor White
    Write-Host "    one core, a held working set, and your workload on the rest" -ForegroundColor DarkGray
    Write-Host "    v$script:HarnessVersion" -ForegroundColor DarkGray
    Write-Host '  ============================================================' -ForegroundColor DarkCyan
    Write-Host ''
}

function Stop-Harness {
    <#
        Central exit path: closes handles, optionally restores, prints the footer.
    #>
    param(
        [int] $Code = 0,
        [string] $Reason
    )
    if ($Reason) { Write-Log -Level INFO -Message $Reason }

    Close-HarnessHandles

    if ($RestoreOnExit -and $script:Journal.Count -gt 0) {
        Write-Log -Level STEP -Message 'Restoring original process settings (-RestoreOnExit)'
        Restore-Journal
    }

    if (-not $NoPause -and -not $Yes -and $Host.Name -eq 'ConsoleHost' -and -not $script:NonInteractive) {
        Write-Host ''
        Write-Host 'Press any key to close...' -ForegroundColor DarkGray
        try { $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } catch { }
    }

    exit $Code
}

function Get-DefaultStatePath {
    $base = $env:LOCALAPPDATA
    if (-not $base) { $base = $env:TEMP }
    if (-not $base) { $base = '.' }
    return (Join-Path (Join-Path $base 'Harness') 'state.json')
}

# =============================================================================
# Region: small utilities
# =============================================================================

function Format-Bytes {
    param([double] $Bytes, [int] $Decimals = 2)
    $units = @('B', 'KiB', 'MiB', 'GiB', 'TiB')
    $i = 0
    $v = [double]$Bytes
    while ([math]::Abs($v) -ge 1024 -and $i -lt ($units.Count - 1)) { $v = $v / 1024; $i++ }
    return ('{0:N' + $Decimals + '} {1}') -f $v, $units[$i]
}

function Format-LongBytes {
    param([double] $Bytes)
    return ('{0:N0} bytes ({1})' -f $Bytes, (Format-Bytes -Bytes $Bytes))
}

function ConvertFrom-CpuList {
    <#
        Turns a logical CPU list into a 64-bit affinity mask.
        Group 0 only: Windows puts the first 64 logical CPUs in processor group 0,
        and process affinity masks via SetProcessAffinityMask are group-relative.
    #>
    param([int[]] $Cpu)

    [uint64]$mask = 0
    foreach ($c in $Cpu) {
        if ($c -lt 0 -or $c -gt 63) {
            throw "CPU index $c is out of range for a single processor group (0-63). See the README for the >64 CPU caveat."
        }
        $mask = $mask -bor ([uint64]1 -shl $c)
    }
    return $mask
}

function ConvertTo-CpuList {
    param([uint64] $Mask, [int] $Limit = 64)
    $list = New-Object System.Collections.Generic.List[int]
    for ($i = 0; $i -lt $Limit; $i++) {
        if (($Mask -band ([uint64]1 -shl $i)) -ne 0) { $list.Add($i) }
    }
    return $list.ToArray()
}

function Format-Mask {
    param([uint64] $Mask)
    $cpus = ConvertTo-CpuList -Mask $Mask
    if (-not $cpus -or $cpus.Count -eq 0) { return '(none)' }
    return (($cpus | ForEach-Object { "CPU$_" }) -join ', ')
}

function Resolve-PriorityClass {
    param([string] $Name)
    if (-not $script:PriorityClasses.Contains($Name)) {
        throw "Unknown priority class '$Name'"
    }
    return [uint32]$script:PriorityClasses[$Name]
}

function Resolve-MemoryPriority {
    param([string] $Name)
    if (-not $script:MemoryPriorities.Contains($Name)) {
        throw "Unknown memory priority '$Name'"
    }
    return [uint32]$script:MemoryPriorities[$Name]
}

function Get-MemoryPriorityName {
    param([uint32] $Value)
    foreach ($k in $script:MemoryPriorities.Keys) {
        if ([uint32]$script:MemoryPriorities[$k] -eq $Value) { return $k }
    }
    return "Unknown($Value)"
}

function Get-PriorityClassName {
    param([uint32] $Value)
    foreach ($k in $script:PriorityClasses.Keys) {
        if ([uint32]$script:PriorityClasses[$k] -eq $Value) { return $k }
    }
    return "Unknown($Value)"
}

function Read-HarnessChoice {
    <#
        Numbered prompt with a default. Returns the chosen option's value.
        $Options is an array of hashtables: @{ Label = 'text'; Value = $x; Hint = 'text' }
    #>
    param(
        [string] $Question,
        [object[]] $Options,
        [int] $DefaultIndex = 0
    )

    if ($Yes) {
        $chosen = $Options[$DefaultIndex]
        Write-Log -Level INFO -Message "$Question -> $($chosen.Label) (auto: -Yes)"
        return $chosen.Value
    }

    Write-Host ''
    Write-Host "  $Question" -ForegroundColor White
    for ($i = 0; $i -lt $Options.Count; $i++) {
        $o = $Options[$i]
        $mark = ' '
        if ($i -eq $DefaultIndex) { $mark = '*' }
        $hint = ''
        if ($o.ContainsKey('Hint') -and $o.Hint) { $hint = "  - $($o.Hint)" }
        Write-Host ("   {0} {1}) {2}{3}" -f $mark, ($i + 1), $o.Label, $hint) -ForegroundColor DarkGray
    }

    while ($true) {
        $raw = Read-Host "  choice [$($DefaultIndex + 1)]"
        if ([string]::IsNullOrWhiteSpace($raw)) { return $Options[$DefaultIndex].Value }
        $n = 0
        if ([int]::TryParse($raw.Trim(), [ref]$n) -and $n -ge 1 -and $n -le $Options.Count) {
            return $Options[$n - 1].Value
        }
        Write-Host '  enter one of the numbers above' -ForegroundColor Yellow
    }
}

function Read-HarnessText {
    param([string] $Question, [string] $Default = '')
    if ($Yes) {
        Write-Log -Level INFO -Message "$Question -> '$Default' (auto: -Yes)"
        return $Default
    }
    Write-Host ''
    Write-Host "  $Question" -ForegroundColor White
    if ($Default) { $raw = Read-Host "  value [$Default]" } else { $raw = Read-Host '  value' }
    if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
    return $raw.Trim()
}

function Read-HarnessYesNo {
    param([string] $Question, [bool] $Default = $true)
    $suffix = 'y/n'
    if ($Default) { $suffix = 'Y/n' } else { $suffix = 'y/N' }
    if ($Yes) {
        Write-Log -Level INFO -Message "$Question -> $Default (auto: -Yes)"
        return $Default
    }
    Write-Host ''
    while ($true) {
        $raw = Read-Host "  $Question [$suffix]"
        if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
        switch ($raw.Trim().ToLowerInvariant()) {
            'y'     { return $true }
            'yes'   { return $true }
            'n'     { return $false }
            'no'    { return $false }
            default { Write-Host '  please answer y or n' -ForegroundColor Yellow }
        }
    }
}
