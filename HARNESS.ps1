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

# =============================================================================
# Region: native layer (kernel32 / job objects)
# =============================================================================

$script:NativeSource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

/// <summary>
/// Thin, PowerShell-friendly wrapper over the Win32 calls Harness needs.
/// Everything returns bool/int/long so PowerShell never has to marshal structs
/// itself; ref/out parameters are exposed as C# "ref" so PS can pass [ref]$var.
/// </summary>
public static class HarnessNative
{
    // ---- Process access rights -------------------------------------------------
    public const uint PROCESS_TERMINATE = 0x0001;
    public const uint PROCESS_SET_QUOTA = 0x0100;
    public const uint PROCESS_SET_INFORMATION = 0x0200;
    public const uint PROCESS_QUERY_INFORMATION = 0x0400;
    public const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
    public const uint HARNESS_ACCESS =
        PROCESS_TERMINATE | PROCESS_SET_QUOTA | PROCESS_SET_INFORMATION |
        PROCESS_QUERY_INFORMATION | PROCESS_QUERY_LIMITED_INFORMATION;

    // ---- Priority classes (winnt.h) -------------------------------------------
    public const uint IDLE_PRIORITY_CLASS = 0x00000040;
    public const uint BELOW_NORMAL_PRIORITY_CLASS = 0x00004000;
    public const uint NORMAL_PRIORITY_CLASS = 0x00000020;
    public const uint ABOVE_NORMAL_PRIORITY_CLASS = 0x00008000;
    public const uint HIGH_PRIORITY_CLASS = 0x00000080;
    public const uint REALTIME_PRIORITY_CLASS = 0x00000100;

    // ---- Working set enforcement flags (SetProcessWorkingSetSizeEx) ----------
    public const uint QUOTA_LIMITS_HARDWS_MIN_ENABLE = 0x00000001;
    public const uint QUOTA_LIMITS_HARDWS_MIN_DISABLE = 0x00000002;
    public const uint QUOTA_LIMITS_HARDWS_MAX_ENABLE = 0x00000004;
    public const uint QUOTA_LIMITS_HARDWS_MAX_DISABLE = 0x00000008;

    // ---- Job object information classes --------------------------------------
    public const int JobObjectBasicLimitInformation = 2;
    public const int JobObjectBasicProcessIdList = 3;
    public const int JobObjectExtendedLimitInformation = 9;
    public const int JobObjectCpuRateControlInformation = 15;

    // ---- Job object limit flags ----------------------------------------------
    public const uint JOB_OBJECT_LIMIT_WORKINGSET = 0x00000001;
    public const uint JOB_OBJECT_LIMIT_AFFINITY = 0x00000010;
    public const uint JOB_OBJECT_LIMIT_PRIORITY_CLASS = 0x00000020;
    public const uint JOB_OBJECT_LIMIT_PROCESS_MEMORY = 0x00000100;

    // ---- CPU rate control flags ----------------------------------------------
    public const uint JOB_OBJECT_CPU_RATE_CONTROL_ENABLE = 0x00000001;
    public const uint JOB_OBJECT_CPU_RATE_CONTROL_WEIGHT_BASED = 0x00000002;
    public const uint JOB_OBJECT_CPU_RATE_CONTROL_HARD_CAP = 0x00000004;

    // ---- PROCESS_INFORMATION_CLASS -------------------------------------------
    public const int ProcessMemoryPriority = 0;

    private const int RelationProcessorCore = 0;
    private const int ERROR_INSUFFICIENT_BUFFER = 122;

    // =========================================================================
    // Structs
    // =========================================================================

    [StructLayout(LayoutKind.Sequential)]
    private struct MEMORY_PRIORITY_INFORMATION
    {
        public uint MemoryPriority;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IO_COUNTERS
    {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_CPU_RATE_CONTROL_INFORMATION
    {
        public uint ControlFlags;
        public uint CpuRate;
    }

    // =========================================================================
    // P/Invoke
    // =========================================================================

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, int dwProcessId);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr hObject);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetProcessAffinityMask(IntPtr hProcess, UIntPtr dwProcessAffinityMask);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetProcessAffinityMask(IntPtr hProcess, out UIntPtr lpProcessAffinityMask, out UIntPtr lpSystemAffinityMask);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetPriorityClass(IntPtr hProcess, uint dwPriorityClass);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint GetPriorityClass(IntPtr hProcess);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetProcessWorkingSetSize(IntPtr hProcess, UIntPtr dwMinimumWorkingSetSize, UIntPtr dwMaximumWorkingSetSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetProcessWorkingSetSizeEx(IntPtr hProcess, UIntPtr dwMinimumWorkingSetSize, UIntPtr dwMaximumWorkingSetSize, uint Flags);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetProcessWorkingSetSizeEx(IntPtr hProcess, out UIntPtr lpMinimumWorkingSetSize, out UIntPtr lpMaximumWorkingSetSize, out uint Flags);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetProcessWorkingSetSize(IntPtr hProcess, out UIntPtr lpMinimumWorkingSetSize, out UIntPtr lpMaximumWorkingSetSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetProcessInformation(IntPtr hProcess, int ProcessInformationClass, ref MEMORY_PRIORITY_INFORMATION ProcessInformation, uint ProcessInformationSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetProcessInformation(IntPtr hProcess, int ProcessInformationClass, ref MEMORY_PRIORITY_INFORMATION ProcessInformation, uint ProcessInformationSize);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool QueryFullProcessImageName(IntPtr hProcess, uint dwFlags, StringBuilder lpExeName, ref uint lpdwSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr CreateJobObject(IntPtr lpJobAttributes, string lpName);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(IntPtr hJob, int JobObjectInformationClass, IntPtr lpJobObjectInformation, uint cbJobObjectInformationLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool QueryInformationJobObject(IntPtr hJob, int JobObjectInformationClass, IntPtr lpJobObjectInformation, uint cbJobObjectInformationLength, out uint lpReturnLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(IntPtr hJob, IntPtr hProcess);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetLogicalProcessorInformationEx(int RelationshipType, IntPtr Buffer, ref int ReturnedLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern int GetActiveProcessorCount(ushort GroupNumber);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern ushort GetActiveProcessorGroupCount();

    // =========================================================================
    // Friendly helpers
    // =========================================================================

    public static int LastError()
    {
        return Marshal.GetLastWin32Error();
    }

    public static string DescribeError(int code)
    {
        try { return new System.ComponentModel.Win32Exception(code).Message; }
        catch { return "error " + code; }
    }

    public static IntPtr Open(long pid, uint access)
    {
        return OpenProcess(access, false, (int)pid);
    }

    public static bool Close(long handle)
    {
        if (handle == 0) { return false; }
        return CloseHandle(new IntPtr(handle));
    }

    // ---- affinity -----------------------------------------------------------

    public static bool SetAffinity(long handle, ulong mask)
    {
        return SetProcessAffinityMask(new IntPtr(handle), new UIntPtr(mask));
    }

    // Returns the process mask (0 on failure) and fills in the system mask.
    public static ulong GetAffinity(long handle, ref ulong systemMask)
    {
        UIntPtr processMask;
        UIntPtr sysMask;
        if (!GetProcessAffinityMask(new IntPtr(handle), out processMask, out sysMask)) { return 0; }
        systemMask = sysMask.ToUInt64();
        return processMask.ToUInt64();
    }

    // ---- priority class -----------------------------------------------------

    public static bool SetPrio(long handle, uint priorityClass)
    {
        return SetPriorityClass(new IntPtr(handle), priorityClass);
    }

    public static uint GetPrio(long handle)
    {
        return GetPriorityClass(new IntPtr(handle));
    }

    // ---- working set --------------------------------------------------------

    public static bool SetWorkingSet(long handle, ulong minBytes, ulong maxBytes, uint flags)
    {
        return SetProcessWorkingSetSizeEx(new IntPtr(handle), new UIntPtr(minBytes),
                                          new UIntPtr(maxBytes), flags);
    }

    public static bool SetWorkingSetLegacy(long handle, ulong minBytes, ulong maxBytes)
    {
        return SetProcessWorkingSetSize(new IntPtr(handle), new UIntPtr(minBytes),
                                        new UIntPtr(maxBytes));
    }

    public static bool GetWorkingSet(long handle, ref ulong minBytes, ref ulong maxBytes, ref uint flags)
    {
        UIntPtr min;
        UIntPtr max;
        uint f;
        if (!GetProcessWorkingSetSizeEx(new IntPtr(handle), out min, out max, out f)) { return false; }
        minBytes = min.ToUInt64();
        maxBytes = max.ToUInt64();
        flags = f;
        return true;
    }

    /// <summary>Pre-Windows-7 read path, used when the Ex variant is unavailable.</summary>
    public static bool GetWorkingSetLegacy(long handle, ref ulong minBytes, ref ulong maxBytes)
    {
        UIntPtr min;
        UIntPtr max;
        if (!GetProcessWorkingSetSize(new IntPtr(handle), out min, out max)) { return false; }
        minBytes = min.ToUInt64();
        maxBytes = max.ToUInt64();
        return true;
    }

    // ---- memory priority ----------------------------------------------------

    public static bool SetMemPrio(long handle, uint priority)
    {
        MEMORY_PRIORITY_INFORMATION info = new MEMORY_PRIORITY_INFORMATION();
        info.MemoryPriority = priority;
        return SetProcessInformation(new IntPtr(handle), ProcessMemoryPriority, ref info,
                                     (uint)Marshal.SizeOf(typeof(MEMORY_PRIORITY_INFORMATION)));
    }

    public static uint GetMemPrio(long handle)
    {
        MEMORY_PRIORITY_INFORMATION info = new MEMORY_PRIORITY_INFORMATION();
        if (!GetProcessInformation(new IntPtr(handle), ProcessMemoryPriority, ref info,
                                   (uint)Marshal.SizeOf(typeof(MEMORY_PRIORITY_INFORMATION))))
        {
            return 0;
        }
        return info.MemoryPriority;
    }

    // ---- process path -------------------------------------------------------

    public static string GetProcessPath(long pid)
    {
        IntPtr h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, (int)pid);
        if (h == IntPtr.Zero) { return null; }
        try
        {
            uint size = 1024;
            StringBuilder sb = new StringBuilder((int)size);
            if (QueryFullProcessImageName(h, 0, sb, ref size)) { return sb.ToString(); }
            return null;
        }
        finally { CloseHandle(h); }
    }

    // ---- job objects --------------------------------------------------------

    public static long CreateJob()
    {
        IntPtr h = CreateJobObject(IntPtr.Zero, null);
        return (long)h;
    }

    /// <summary>
    /// Applies the requested job limits in one call. Any "has*" flag left false
    /// means that field is not constrained at all.
    /// </summary>
    public static bool SetJobLimits(long job, bool hasWorkingSet, ulong wsMin, ulong wsMax,
                                   bool hasAffinity, ulong affinity,
                                   bool hasPriority, uint priorityClass,
                                   bool hasProcessMemory, ulong processMemoryBytes)
    {
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION ext = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
        uint flags = 0;

        if (hasWorkingSet)
        {
            flags |= JOB_OBJECT_LIMIT_WORKINGSET;
            ext.BasicLimitInformation.MinimumWorkingSetSize = new UIntPtr(wsMin);
            ext.BasicLimitInformation.MaximumWorkingSetSize = new UIntPtr(wsMax);
        }
        if (hasAffinity)
        {
            flags |= JOB_OBJECT_LIMIT_AFFINITY;
            ext.BasicLimitInformation.Affinity = new UIntPtr(affinity);
        }
        if (hasPriority)
        {
            flags |= JOB_OBJECT_LIMIT_PRIORITY_CLASS;
            ext.BasicLimitInformation.PriorityClass = priorityClass;
        }
        if (hasProcessMemory)
        {
            flags |= JOB_OBJECT_LIMIT_PROCESS_MEMORY;
            ext.ProcessMemoryLimit = new UIntPtr(processMemoryBytes);
        }

        ext.BasicLimitInformation.LimitFlags = flags;

        int size = Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
        IntPtr buffer = Marshal.AllocHGlobal(size);
        try
        {
            Marshal.StructureToPtr(ext, buffer, false);
            return SetInformationJobObject(new IntPtr(job), JobObjectExtendedLimitInformation, buffer, (uint)size);
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }

    /// <summary>
    /// CPU rate control. rateUnits is in hundredths of a percent of one core
    /// (1..10000), so 4000 == 40% of a core. hardCap stops the job exceeding it
    /// instead of merely hinting.
    /// </summary>
    public static bool SetJobCpuRate(long job, uint rateUnits, bool hardCap)
    {
        JOBOBJECT_CPU_RATE_CONTROL_INFORMATION info = new JOBOBJECT_CPU_RATE_CONTROL_INFORMATION();
        uint control = JOB_OBJECT_CPU_RATE_CONTROL_ENABLE;
        if (hardCap) { control |= JOB_OBJECT_CPU_RATE_CONTROL_HARD_CAP; }
        info.ControlFlags = control;
        info.CpuRate = rateUnits;

        int size = Marshal.SizeOf(typeof(JOBOBJECT_CPU_RATE_CONTROL_INFORMATION));
        IntPtr buffer = Marshal.AllocHGlobal(size);
        try
        {
            Marshal.StructureToPtr(info, buffer, false);
            return SetInformationJobObject(new IntPtr(job), JobObjectCpuRateControlInformation, buffer, (uint)size);
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }

    public static bool AssignToJob(long job, long processHandle)
    {
        return AssignProcessToJobObject(new IntPtr(job), new IntPtr(processHandle));
    }

    /// <summary>PIDs currently inside the job (empty array on failure).</summary>
    public static int[] GetJobProcessIds(long job)
    {
        const int capacity = 1024;
        int bufferSize = 8 + capacity * 8;
        IntPtr buffer = Marshal.AllocHGlobal(bufferSize);
        try
        {
            Marshal.WriteInt32(buffer, 0, capacity);
            uint returned;
            if (!QueryInformationJobObject(new IntPtr(job), JobObjectBasicProcessIdList, buffer,
                                           (uint)bufferSize, out returned))
            {
                return new int[0];
            }
            int count = Marshal.ReadInt32(buffer, 4);
            if (count < 0) { count = 0; }
            if (count > capacity) { count = capacity; }
            int[] ids = new int[count];
            for (int i = 0; i < count; i++)
            {
                ids[i] = (int)Marshal.ReadInt64(buffer, 8 + i * 8);
            }
            return ids;
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }

    /// <summary>
    /// Reads the job's extended limits and CPU rate back out of the kernel so
    /// the report can show what was really stored, not what was requested.
    /// </summary>
    public static bool GetJobLimits(long job, ref uint limitFlags, ref ulong wsMin, ref ulong wsMax,
                                   ref ulong affinity, ref uint priorityClass,
                                   ref uint cpuRate, ref uint cpuControlFlags)
    {
        bool any = false;

        JOBOBJECT_EXTENDED_LIMIT_INFORMATION ext = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
        int extSize = Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
        IntPtr extBuffer = Marshal.AllocHGlobal(extSize);
        try
        {
            Marshal.StructureToPtr(ext, extBuffer, false);
            uint returned;
            if (QueryInformationJobObject(new IntPtr(job), JobObjectExtendedLimitInformation, extBuffer,
                                          (uint)extSize, out returned))
            {
                ext = (JOBOBJECT_EXTENDED_LIMIT_INFORMATION)Marshal.PtrToStructure(
                    extBuffer, typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
                limitFlags = ext.BasicLimitInformation.LimitFlags;
                wsMin = ext.BasicLimitInformation.MinimumWorkingSetSize.ToUInt64();
                wsMax = ext.BasicLimitInformation.MaximumWorkingSetSize.ToUInt64();
                affinity = ext.BasicLimitInformation.Affinity.ToUInt64();
                priorityClass = ext.BasicLimitInformation.PriorityClass;
                any = true;
            }
        }
        finally { Marshal.FreeHGlobal(extBuffer); }

        JOBOBJECT_CPU_RATE_CONTROL_INFORMATION cpu = new JOBOBJECT_CPU_RATE_CONTROL_INFORMATION();
        int cpuSize = Marshal.SizeOf(typeof(JOBOBJECT_CPU_RATE_CONTROL_INFORMATION));
        IntPtr cpuBuffer = Marshal.AllocHGlobal(cpuSize);
        try
        {
            Marshal.StructureToPtr(cpu, cpuBuffer, false);
            uint returned;
            if (QueryInformationJobObject(new IntPtr(job), JobObjectCpuRateControlInformation, cpuBuffer,
                                          (uint)cpuSize, out returned))
            {
                cpu = (JOBOBJECT_CPU_RATE_CONTROL_INFORMATION)Marshal.PtrToStructure(
                    cpuBuffer, typeof(JOBOBJECT_CPU_RATE_CONTROL_INFORMATION));
                cpuRate = cpu.CpuRate;
                cpuControlFlags = cpu.ControlFlags;
                any = true;
            }
        }
        finally { Marshal.FreeHGlobal(cpuBuffer); }

        return any;
    }

    // ---- CPU topology -------------------------------------------------------

    /// <summary>
    /// Flat map of physical cores, stride 5 per core:
    ///   [+0] processor group number
    ///   [+1] efficiency class (0 = efficiency core, higher = more performant)
    ///   [+2] flags (bit0 = SMT/hyperthreaded)
    ///   [+3] first logical CPU index inside that group (-1 if unknown)
    ///   [+4] second logical CPU index inside that group (-1 if not SMT)
    /// Core ordinal is the entry order. Empty array means "unsupported, fall back".
    /// </summary>
    public static int[] GetCoreMap()
    {
        int length = 0;
        GetLogicalProcessorInformationEx(RelationProcessorCore, IntPtr.Zero, ref length);
        if (length <= 0) { return new int[0]; }

        IntPtr buffer = Marshal.AllocHGlobal(length);
        try
        {
            if (!GetLogicalProcessorInformationEx(RelationProcessorCore, buffer, ref length))
            {
                return new int[0];
            }

            List<int> flat = new List<int>();
            int offset = 0;
            while (offset < length)
            {
                int relationship = Marshal.ReadInt32(buffer, offset);
                int entrySize = Marshal.ReadInt32(buffer, offset + 4);
                if (entrySize <= 0 || offset + entrySize > length) { break; }

                if (relationship == RelationProcessorCore)
                {
                    byte flags = Marshal.ReadByte(buffer, offset + 8);
                    byte efficiency = Marshal.ReadByte(buffer, offset + 9);
                    ushort groupCount = (ushort)Marshal.ReadInt16(buffer, offset + 30);
                    int maskBase = offset + 32;

                    for (int g = 0; g < groupCount; g++)
                    {
                        long mask = Marshal.ReadInt64(buffer, maskBase + g * 16);
                        short group = Marshal.ReadInt16(buffer, maskBase + g * 16 + 8);

                        List<int> cpus = new List<int>();
                        for (int bit = 0; bit < 64; bit++)
                        {
                            if ((mask & (1L << bit)) != 0) { cpus.Add(bit); }
                        }

                        flat.Add((int)group);
                        flat.Add((int)efficiency);
                        flat.Add((flags & 1) != 0 ? 1 : 0);
                        flat.Add(cpus.Count > 0 ? cpus[0] : -1);
                        flat.Add(cpus.Count > 1 ? cpus[1] : -1);
                    }
                }
                offset += entrySize;
            }
            return flat.ToArray();
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }

    /// <summary>Active logical processors in a group; pass 0xFFFF for the whole machine.</summary>
    public static int ActiveProcessorCount(int group)
    {
        return GetActiveProcessorCount((ushort)group);
    }

    public static int ProcessorGroupCount()
    {
        return (int)GetActiveProcessorGroupCount();
    }
}
'@

function Initialize-HarnessNative {
    <#
        Compiles the interop helper once per session.
    #>
    if ('HarnessNative' -as [type]) { return }
    Write-Log -Level DEBUG -Message 'compiling native interop helper (Add-Type)'

    if (-not (Test-Windows)) {
        throw 'The native interop layer is Windows-only. Run ".\HARNESS.ps1 -SelfTest" for the portability report.'
    }

    try {
        Add-Type -TypeDefinition $script:NativeSource -Language CSharp -ErrorAction Stop
    } catch {
        $msg = $_.Exception.Message
        if ($_.Exception.InnerException) { $msg = "$msg :: $($_.Exception.InnerException.Message)" }
        throw "Could not compile the interop helper. C# compiler output: $msg"
    }
    if (-not ('HarnessNative' -as [type])) { throw 'interop helper compiled but the type is missing' }
}

function Get-NativeError {
    param([string] $Call)
    $code = [HarnessNative]::LastError()
    $text = [HarnessNative]::DescribeError($code)
    return "$Call failed: $text (Win32 $code)"
}

# =============================================================================
# Region: handle bookkeeping
# =============================================================================

function Get-ProcessHandle {
    <#
        Opens (and caches) a handle with every access right Harness needs.
        Cached handles keep the PID from being recycled while we hold them.
    #>
    param([int] $ProcessId, [switch] $Quiet)

    if ($script:Handles.ContainsKey($ProcessId)) { return $script:Handles[$ProcessId] }

    $h = [HarnessNative]::Open($ProcessId, [HarnessNative]::HARNESS_ACCESS)
    if ($h -eq [IntPtr]::Zero) {
        if (-not $Quiet) {
            Write-Log -Level DEBUG -Message (Get-NativeError "OpenProcess($ProcessId)")
        }
        return [IntPtr]::Zero
    }
    $script:Handles[$ProcessId] = $h
    return $h
}

function Close-HarnessHandles {
    foreach ($pid in @($script:Handles.Keys)) {
        try { [void][HarnessNative]::Close($script:Handles[$pid].ToInt64()) } catch { }
        $script:Handles.Remove($pid)
    }
    foreach ($name in @($script:JobObjects.Keys)) {
        try { [void][HarnessNative]::Close($script:JobObjects[$name].ToInt64()) } catch { }
        $script:JobObjects.Remove($name)
    }
}

# =============================================================================
# Region: topology + memory discovery
# =============================================================================

function Get-SystemTopology {
    <#
        Physical cores, SMT siblings, efficiency classes, total/free RAM.
    #>
    param([switch] $Refresh)

    if ($script:Topology -and -not $Refresh) { return $script:Topology }

    $flat = @([HarnessNative]::GetCoreMap())
    $cores = New-Object System.Collections.Generic.List[psobject]
    $stride = 5
    $coreCount = [int][math]::Floor($flat.Count / $stride)

    for ($i = 0; $i -lt $coreCount; $i++) {
        $b = $i * $stride
        $group = [int]$flat[$b]
        $eff = [int]$flat[$b + 1]
        $flags = [int]$flat[$b + 2]
        $cpu0 = [int]$flat[$b + 3]
        $cpu1 = [int]$flat[$b + 4]

        $cpus = New-Object System.Collections.Generic.List[int]
        if ($cpu0 -ge 0) { $cpus.Add($cpu0) }
        if ($cpu1 -ge 0) { $cpus.Add($cpu1) }
        $primary = -1
        if ($cpus.Count -gt 0) { $primary = $cpus[0] }

        $cores.Add([pscustomobject]@{
            Index           = $i
            Group           = $group
            EfficiencyClass = $eff
            HasSmt          = (($flags -band 1) -ne 0)
            LogicalCpus     = $cpus.ToArray()
            PrimaryCpu      = $primary
        })
    }

    # RAM
    $totalRam = 0.0
    $freeRam = 0.0
    $availableRam = 0.0
    $dimmCount = 0
    $dimmSpeed = 0
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $totalRam = [double]$cs.TotalPhysicalMemory
    } catch {
        Write-Log -Level DEBUG -Message "Win32_ComputerSystem unavailable: $($_.Exception.Message)"
    }
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $freeRam = [double]$os.FreePhysicalMemory * 1024.0
        if ($totalRam -le 0) { $totalRam = [double]$os.TotalVisibleMemorySize * 1024.0 }
    } catch {
        Write-Log -Level DEBUG -Message "Win32_OperatingSystem unavailable: $($_.Exception.Message)"
    }
    try {
        $mem = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Memory -ErrorAction Stop
        $availableRam = [double]$mem.AvailableBytes
    } catch {
        Write-Log -Level DEBUG -Message "PerfOS memory counters unavailable, using FreePhysicalMemory"
    }
    if ($availableRam -le 0) { $availableRam = $freeRam }
    try {
        $dimms = @(Get-CimInstance -ClassName Win32_PhysicalMemory -ErrorAction Stop)
        $dimmCount = $dimms.Count
        if ($dimmCount -gt 0) { $dimmSpeed = [int]($dimms | Measure-Object -Property Speed -Maximum).Maximum }
    } catch {
        Write-Log -Level DEBUG -Message "Win32_PhysicalMemory unavailable"
    }

    $groupCount = [int]([HarnessNative]::ProcessorGroupCount())
    $totalLogical = [int]([HarnessNative]::ActiveProcessorCount(0xFFFF))
    $group0Logical = [int]([HarnessNative]::ActiveProcessorCount(0))
    $effClasses = @($cores | Select-Object -ExpandProperty EfficiencyClass -Unique | Sort-Object)
    $isHybrid = ($effClasses.Count -gt 1)

    $script:Topology = [pscustomobject]@{
        Cores          = $cores.ToArray()
        CoreCount      = $cores.Count
        TotalLogical   = $totalLogical
        Group0Logical  = $group0Logical
        GroupCount     = $groupCount
        EfficiencyClasses = $effClasses
        IsHybrid       = $isHybrid
        TotalRam       = $totalRam
        FreeRam        = $freeRam
        AvailableRam   = $availableRam
        DimmCount      = $dimmCount
        DimmSpeed      = $dimmSpeed
        DotNetCpuCount = [Environment]::ProcessorCount
        CapturedAt     = Get-Date
    }
    return $script:Topology
}

function Show-Topology {
    param([object] $Topology)

    if ($Topology.PSObject.Properties['Simulated']) {
        Write-Kv 'source' 'simulated (.NET processor count; Win32 topology unavailable on this platform)' -Color Yellow
    }
    Write-Kv 'physical cores'     "$($Topology.CoreCount)"
    Write-Kv 'logical processors' "$($Topology.TotalLogical) (group0: $($Topology.Group0Logical), groups: $($Topology.GroupCount))"
    if ($Topology.IsHybrid) {
        $p = @($Topology.Cores | Where-Object { $_.EfficiencyClass -gt 0 }).Count
        $e = @($Topology.Cores | Where-Object { $_.EfficiencyClass -eq 0 }).Count
        Write-Kv 'hybrid cpu' "yes ($p performance, $e efficiency cores)"
    } else {
        Write-Kv 'hybrid cpu' 'no (uniform cores)'
    }
    Write-Kv 'SMT' "$(@($Topology.Cores | Where-Object { $_.HasSmt }).Count) of $($Topology.CoreCount) cores hyperthreaded"
    if ($Topology.TotalRam -gt 0) {
        Write-Kv 'physical memory' (Format-Bytes -Bytes $Topology.TotalRam) -Color White
    }
    if ($Topology.DimmCount -gt 0) {
        Write-Kv 'memory modules' "$($Topology.DimmCount) DIMM(s) @ $($Topology.DimmSpeed) MT/s"
    }
    Write-Kv 'available now' (Format-Bytes -Bytes $Topology.AvailableRam) -Color White
    if ($Topology.GroupCount -gt 1) {
        Write-Kv 'note' 'multi-group CPU: affinity is applied inside group 0 only' -Color Yellow
    }
}

function Get-CoreLoad {
    <#
        Per-logical-CPU busy percentage from the OS performance counters.
        Returns $null when the counters are unavailable so callers can degrade
        to round-robin instead of failing.
    #>
    try {
        $rows = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Processor -ErrorAction Stop
    } catch {
        Write-Log -Level DEBUG -Message "PerfOS_Processor unavailable: $($_.Exception.Message)"
        return $null
    }

    $map = @{}
    $total = $null
    foreach ($row in $rows) {
        if ($row.Name -eq '_Total') { $total = [double]$row.PercentProcessorTime; continue }
        $n = 0
        if ([int]::TryParse($row.Name, [ref]$n)) {
            $map[$n] = [double]$row.PercentProcessorTime
        }
    }
    if ($map.Count -eq 0) { return $null }
    return [pscustomobject]@{ PerCpu = $map; Total = $total }
}

# =============================================================================
# Region: target discovery
# =============================================================================

function Get-RobloxLikeProcess {
    <#
        Every process whose name or image path smells like Roblox. Used both for
        the default target list and to explain "nothing to pin" when the client
        runs under an unexpected image name (UWP builds do).
    #>
    $found = New-Object System.Collections.Generic.List[psobject]
    $procs = @(Get-Process -ErrorAction SilentlyContinue)

    # UWP Roblox and odd launchers hide behind generic image names, so a handful
    # of generic hosts get their image path checked. Querying the path of every
    # process on the machine would be needlessly slow.
    $suspectNames = @('Windows10Universal', 'ApplicationFrameHost', 'RobloxCrashHandler', 'RobloxPlayerLauncher')
    $pathBudget = 40

    foreach ($p in $procs) {
        $name = $p.ProcessName
        $path = $null
        $isHit = $false

        if ($name -match 'roblox') { $isHit = $true }
        if (-not $isHit -and ($script:DefaultTargets -contains $name)) { $isHit = $true }

        if (-not $isHit -and ($suspectNames -contains $name) -and $pathBudget -gt 0) {
            $pathBudget--
            $path = [HarnessNative]::GetProcessPath($p.Id)
            if ($path -and ($path -match 'roblox')) { $isHit = $true }
        }

        if ($isHit) {
            if (-not $path) { $path = [HarnessNative]::GetProcessPath($p.Id) }
            $found.Add([pscustomobject]@{
                Process   = $p
                Id        = $p.Id
                Name      = $name
                Path      = $path
                WorkingSet = [double]$p.WorkingSet64
                IsUwp     = ($suspectNames -contains $name)
            })
        }
    }
    return $found.ToArray()
}

function Test-TargetAllowed {
    <#
        Guard-rail: refuse to constrain critical system processes, and say why.
    #>
    param([string] $Name)

    $blocked = @(
        'system', 'idle', 'registry', 'smss', 'csrss', 'wininit', 'winlogon', 'services',
        'lsass', 'lsaiso', 'svchost', 'fontdrvhost', 'dwm', 'audiodg', 'memory compression',
        'msmpeng', 'securityhealthservice', 'wininit', 'spoolsv', 'explorer'
    )
    $clean = $Name -replace '\.exe$', ''
    if ($blocked -contains $clean.ToLowerInvariant()) { return $false }
    return $true
}

function Select-TargetProcess {
    <#
        Resolves the --TargetName list (or the default Roblox list) to live
        processes, with a picker when the match is ambiguous or empty.
    #>
    param(
        [string[]] $Name,
        [switch] $LaunchIfMissing
    )

    $wanted = $Name
    if (-not $wanted) { $wanted = $script:DefaultTargets }

    $selected = New-Object System.Collections.Generic.List[psobject]
    $candidates = @(Get-Process -ErrorAction SilentlyContinue)

    if ($wanted -contains '*') {
        $options = New-Object System.Collections.Generic.List[object]
        foreach ($c in Get-RobloxLikeProcess) {
            $options.Add(@{
                Label = "$($c.Name) (pid $($c.Id), $(Format-Bytes -Bytes $c.WorkingSet))"
                Value = $c.Id
                Hint  = $c.Path
            })
        }
        if ($options.Count -eq 0) { return @() }
        $chosen = Read-HarnessChoice -Question 'Which process?' -Options $options.ToArray() -DefaultIndex 0
        $selected.Add(([pscustomobject]@{ Process = (Get-Process -Id $chosen); Id = $chosen; Name = (Get-Process -Id $chosen).ProcessName }))
        return $selected.ToArray()
    }

    foreach ($w in $wanted) {
        $clean = $w -replace '\.exe$', ''
        $hits = @($candidates | Where-Object { $_.ProcessName -ieq $clean -or $_.ProcessName -ieq $w })
        foreach ($m in $hits) {
            if (-not (Test-TargetAllowed -Name $m.ProcessName)) {
                Write-Log -Level WARN -Message "skipping system process $($m.ProcessName) (pid $($m.Id))"
                continue
            }
            $selected.Add([pscustomobject]@{
                Process = $m
                Id      = $m.Id
                Name    = $m.ProcessName
            })
        }
    }

    if ($selected.Count -eq 0) {
        # Nothing matched by name: report what Roblox-shaped things exist, if any.
        $like = @(Get-RobloxLikeProcess)
        if ($like.Count -gt 0) {
            Write-Log -Level WARN -Message 'no process matched by name, but these look like Roblox clients:'
            foreach ($l in $like) {
                Write-Host ("    pid {0,-7} {1,-28} {2}" -f $l.Id, $l.Name, $l.Path) -ForegroundColor Yellow
            }
        }
        if ($LaunchIfMissing) {
            Write-Log -Level STEP -Message 'launching Roblox via protocol handler'
            try {
                Start-Process $script:RobloxProtocol -ErrorAction Stop
            } catch {
                Write-Log -Level WARN -Message "could not launch $script:RobloxProtocol: $($_.Exception.Message)"
            }
        }
    }

    return $selected.ToArray()
}

function Get-AutoRamReserve {
    <#
        Sizes the working-set floor. Returns bytes plus the reasoning so the
        report can show why the number is what it is.

        Rules:
          * never reserve less than what the target already uses (a lower floor
            would tell the memory manager to *shrink* the client)
          * respect at least 60% of current free RAM staying free, so raising
            the floor cannot start pushing the machine into the pagefile
          * cap at $MaxSystemFraction of installed RAM
    #>
    param(
        [double] $TotalRam,
        [double] $AvailableRam,
        [double] $CurrentWorkingSet,
        [double] $RequestedPercent = -1,
        [double] $MaxSystemFraction = 0.5
    )

    $reasons = New-Object System.Collections.Generic.List[string]
    if ($TotalRam -le 0) {
        return [pscustomobject]@{ Bytes = 0; Percent = 0; Reasons = @('total RAM unknown') }
    }

    $minFloor = [math]::Max($CurrentWorkingSet, 512MB)
    $reasons.Add("floor at least the client's current working set ($(Format-Bytes -Bytes $CurrentWorkingSet))")

    $percent = $RequestedPercent
    if ($percent -le 0) {
        $percent = 20.0
        if ($CurrentWorkingSet -gt 2GB) { $percent = 25.0 }
        if ($CurrentWorkingSet -gt 4GB) { $percent = 30.0 }
        $reasons.Add("auto percentage ${percent}% of installed RAM (scaled by current usage)")
    } else {
        $reasons.Add("requested percentage ${percent}%")
    }

    $byPercent = $TotalRam * ($percent / 100.0)
    $byFree = $AvailableRam * 0.4
    $byCap = $TotalRam * $MaxSystemFraction

    $reserve = [math]::Min($byPercent, $byFree)
    $reserve = [math]::Min($reserve, $byCap)
    if ($reserve -lt $minFloor) { $reserve = $minFloor }
    if ($reserve -gt $byCap) {
        $reserve = $byCap
        $reasons.Add('clamped to the system cap')
    }
    $reasons.Add("limited by 40% of currently available RAM ($(Format-Bytes -Bytes $byFree)) and cap $(Format-Bytes -Bytes $byCap)")

    # A floor above physical RAM is nonsense; keep 512 MiB for Windows itself.
    $hardMax = [math]::Max(0, $TotalRam - 512MB)
    if ($reserve -gt $hardMax) { $reserve = $hardMax; $reasons.Add('clamped so the OS keeps 512 MiB') }

    return [pscustomobject]@{
        Bytes   = [double][math]::Round($reserve)
        Percent = [double]($percent)
        Reasons = $reasons.ToArray()
    }
}

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
