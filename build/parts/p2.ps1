
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
