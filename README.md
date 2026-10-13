# Harness

Pins a Roblox client (or any process you name) to **one CPU core**, holds a
**reserved working set of RAM** for it, and then hands the rest of the machine to
whatever you want to run.

```powershell
.\HARNESS.ps1
```

That is the whole interface. It finds the client, picks a core, reserves RAM,
shows you the allocation, and then asks what you want to run on what is left.

---

## Read this first: what is and is not possible

Three limits, stated up front, because they decide whether this tool is useful to
you:

1. **A CPU core cannot own RAM.** Cores and memory are separate resources; there
   is no mechanism, in Windows or anywhere else, that gives 8 GB of RAM to
   "core 3". What Harness actually does with memory is reserve a *working set*:
   it tells the memory manager to keep a chosen amount of that process's memory
   resident and to trim it last. That is a real, measurable effect - it stops the
   client's pages being evicted to disk and back - and it is the closest thing to
   "this core has this RAM" that exists.
2. **Roblox is a Windows program.** So this script is Windows-only (Windows 10
   1607+ / Windows 11, Windows PowerShell 5.1 or PowerShell 7+). Roblox does not
   run natively on Linux or macOS, so there is no Linux version of this to offer.
   On a non-Windows host the script tells you so and exits; `-SelfTest` and
   `-DryRun` still work there for inspection.
3. **Luau cannot do any of this.** A script inside Roblox runs in a sandbox with
   no access to CPU affinity, working sets, job objects or any other process. No
   API - documented, undocumented or executor-provided - lets in-game code
   reserve host RAM. `roblox/harness_reporter.lua` is included, but it is a
   *measurement* tool: it reports FPS, memory, physics rate and Lua heap from
   inside the client. It deliberately does not pretend to allocate anything.

And one thing it deliberately *does not* do: Harness never injects, hooks,
patches or reads the Roblox process. It asks the kernel for scheduling and memory
limits - the same knobs Process Lasso, Process Explorer and Task Manager expose -
and then reads every value back to prove what happened.

---

## What it does, step by step

**1. Discover.** Finds the client by process name *and* image path, so the
Microsoft Store build (which hides behind a generic image name) is found too.
Reads the real topology with `GetLogicalProcessorInformationEx`: physical cores,
SMT siblings, and efficiency classes on hybrid CPUs (Intel P/E cores).

**2. Allocate.** For each target process:

| Layer | Call | Effect |
| --- | --- | --- |
| Affinity | `SetProcessAffinityMask` | the process runs only on the chosen core |
| Job object | `AssignProcessToJobObject` + `JOB_OBJECT_LIMIT_AFFINITY` | the limit is enforced even if the process tries to widen it |
| Priority class | `SetPriorityClass` | High on an idle machine, AboveNormal on a busy one, overridable |
| Memory priority | `SetProcessInformation(ProcessMemoryPriority)` | page-priority hint: whose pages get trimmed first |
| Working set floor | `SetProcessWorkingSetSizeEx` + `QUOTA_LIMITS_HARDWS_MIN_ENABLE` | reserves RAM to stay resident |
| Job working set | `JOB_OBJECT_LIMIT_WORKINGSET` | the enforcement layer Windows applies to a process it does not own |
| CPU share | `JobObjectCpuRateControlInformation` + hard cap | optional: cap the game at e.g. 40% of its core |

Every call is followed by a read-back, and the report shows a table with a
verdict per row: **verified**, **requested-only**, or **NOT APPLIED**. If the
kernel refuses something, you see it instead of a silent no-op.

**3. Ask.** This is the part you asked for: once the game is confined, Harness
asks what should run on the resources that remain. You can type a command line,
pick a file (`.ps1`, `.bat`, `.cmd`, `.exe`, `.py`, `.lua`), or open an
interactive PowerShell whose whole process tree is already bound to those CPUs.
The workload gets its own job object, so anything it spawns inherits the
allocation.

**4. Hold.** Optionally watches the allocation, re-asserts it if a launcher or
overlay resets it, re-discovers the client if it restarts, and prints a status
line every 30 seconds.

---

## Requirements

* Windows 10 1607+ or Windows 11
* Windows PowerShell 5.1 (built in) or PowerShell 7+
* Administrator rights are only needed for processes you do not own

## Running it

```powershell
# if script execution is blocked, allow it for this session only
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

.\HARNESS.ps1
```

If you downloaded the folder rather than cloning it, PowerShell may mark the
file as blocked; `Unblock-File .\HARNESS.ps1` clears that.

### Examples

```powershell
# Roblox onto logical CPU 3, High priority, reserve 25% of system RAM
.\HARNESS.ps1 -Core 3 -Priority High -RamReservePercent 25

# pin every sibling thread of physical core 0 and just hold it
.\HARNESS.ps1 -Core 0 -CoreMode Physical -Watch

# cap the game at 40% of its core and give the workload the guaranteed 60%
.\HARNESS.ps1 -CpuLimitPercent 40 -WorkloadPercent 60 -Workload "python train.py"

# non-interactive: auto-detect the client, run this command on the free cores,
# wait for it, then continue
.\HARNESS.ps1 -Workload "ffmpeg -i input.mp4 -c:v libx264 out.mp4" -Yes

# see exactly what would happen, changing nothing
.\HARNESS.ps1 -DryRun

# check that every native call works on this machine (uses a throwaway process)
.\HARNESS.ps1 -SelfTest

# undo the last allocation recorded in the state file
.\HARNESS.ps1 -Restore

# list Roblox-shaped processes if detection found nothing
.\HARNESS.ps1 -TargetName "*"
```

### Profiles

`profiles/*.json` pre-fill any knob; command-line parameters always win.

```powershell
.\HARNESS.ps1 -ProfilePath background-workload   # profiles/background-workload.json
```

Three are included: `roblox-game`, `roblox-studio` and `background-workload`
(game capped at 35% of its core, workload guaranteed 65%).

### The main parameters

| Parameter | Default | Meaning |
| --- | --- | --- |
| `-TargetName` | Roblox clients | Process names; `"*"` lists candidates |
| `-Core` | auto | Logical CPU numbers, or physical core numbers with `-CoreMode Physical` |
| `-CoreMode` | `Logical` | How to read `-Core` |
| `-Priority` | `Auto` | `Idle`..`RealTime`; Auto is High on an idle machine, else AboveNormal |
| `-MemoryPriority` | `Auto` | Page priority hint; Auto leaves the Windows default |
| `-RamReservePercent` | `-1` (auto) | Percent of installed RAM to hold resident |
| `-RamReserveMB` | `-1` | Absolute working-set floor in MiB (wins over the percent) |
| `-RamCeilingMB` | `-1` | Optional working-set ceiling |
| `-NoHardMin` | off | Use a soft floor instead of `HARDWS_MIN_ENABLE` |
| `-CpuLimitPercent` | `-1` (none) | Hard cap on the game's share of its own core |
| `-WorkloadPercent` | `-1` (auto) | Guaranteed share for the workload |
| `-Workload` / `-WorkloadArgument` | none | Non-interactive command to run on the remaining CPUs |
| `-Watch` / `-WatchIntervalSec` | off / 3 | Hold and re-assert the allocation |
| `-RestoreOnExit` | off | Undo everything when the script exits |
| `-Restore`, `-DryRun`, `-SelfTest`, `-Yes`, `-ProfilePath`, `-StatePath`, `-LogPath`, `-NoElevate`, `-NoPause`, `-Launch` | | See `Get-Help .\HARNESS.ps1 -Full` |

### Automatic sizing

With no RAM parameters, the floor is sized from the client's *current* usage plus
free memory, and the reasoning is printed:

* never below what the client already uses (a lower floor would tell Windows to
  shrink it)
* never more than 40% of currently available RAM, so raising the floor cannot
  start pushing the machine into the pagefile
* capped at 50% of installed RAM, leaving 512 MiB for Windows

The interactive prompt always offers the auto value, 10/25/50%, a custom figure,
or no reservation at all.

### Automatic core choice

On a hybrid CPU an **efficiency core** is preferred - that is the core whose loss
costs the game least and leaves the performance cores free for your work. On a
uniform CPU the least-loaded core is picked. In both cases the *whole physical
core* is taken (all SMT siblings), so the game gets a real processor rather than
half of one; the top five candidates and why they ranked that way are printed.

### Sharing one core honestly

If you set `-CpuLimitPercent`, the game is capped inside its core by the job
object's rate control, and the workload is then allowed to use that core too,
with a guaranteed share of the remainder (`WorkloadPercent`, default
`100 - CpuLimitPercent`). Without a cap, the workload is restricted to the other
CPUs by affinity - real spatial separation, no sharing.

---

## Restoring

The state file (`%LOCALAPPDATA%\Harness\state.json` by default) records what each
process looked like before Harness touched it. `-Restore` reads it and puts the
original affinity, priority class, memory priority and working-set limits back.
Before touching anything it verifies that the PID still refers to the same
process (PID + start time), because PIDs get reused.

Job-object membership is not "restored"; closing the job handle from the session
that created it releases the process, which is how Windows models jobs.

## Troubleshooting

**"no target could be opened with write rights"** - the client is either owned by
another user or protected; Harness offers to relaunch elevated. Affinity and
priority often still work even when quota rights are refused, and the table will
show which rows actually took effect.

**"the process is probably already in a job that forbids nesting"** - some
anti-cheat and store packages put the process in a job that cannot be nested
into. Harness reports this rather than pretending; the process-level affinity,
priority and working-set calls still apply, and the job-enforced floor is what
you lose.

**Machine with more than 64 logical processors** - `SetProcessAffinityMask` is
per processor group, and this script works in group 0. On such a machine it tells
you so and confines itself to the CPUs in that group.

**Nothing changed according to Task Manager** - Task Manager shows the priority
class, not affinity, in its main view. Use the details tab, or `-Watch` which
prints the live affinity, priority and working-set-versus-floor numbers.

---

## Repository layout

```
HARNESS.ps1                    the script (single file, no dependencies)
profiles/*.json                ready-made settings
roblox/harness_reporter.lua    in-client measurement (cannot allocate anything)
tools/check_ps.py              parse/encoding/profile checks for CI
tools/lint_ps_refs.py          undefined-function/variable and ordering checks
build/parts/*.ps1              the same script split into regions (source of truth
                               for editing; concatenated in order into HARNESS.ps1)
```

If you edit `build/parts/*.ps1`, rebuild with:

```bash
for i in 1 2 3 4 5 6; do cat "build/parts/p$i.ps1" >> HARNESS.ps1; done
```

and then run the checks:

```bash
python3 tools/check_ps.py --root .
python3 tools/lint_ps_refs.py HARNESS.ps1
```

## Verification status

Be aware of what has and has not been tested: the script was written and checked
on a machine without Windows, so it is verified by *static* checking (grammar
parse of the whole file, undefined-reference analysis, profile cross-checks) and
by careful review of every Win32 signature against the Microsoft documentation.
It has not been executed against a live Roblox client from here. On your machine,
`.\HARNESS.ps1 -SelfTest` is the first thing to run: it exercises every native
call against a throwaway `cmd.exe` - affinity, priority, memory priority,
working-set floor, job object, CPU rate control - and prints a PASS/FAIL table
without going anywhere near the game.

## License

MIT. See `LICENSE`.
