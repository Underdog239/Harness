--!nonstrict
--[[
    harness_reporter.lua -- read-only companion for the Harness PowerShell script.

    WHERE THIS RUNS
        Inside Roblox: paste into a Script in Studio, or run it through your own
        executor. It uses only public, documented APIs (Stats, RunService).

    WHAT IT DOES
        Measures the numbers that describe the client's resources from inside the
        sandbox: frames per second, client memory, physics step rate and the Lua
        heap. Use it before and after applying an allocation from HARNESS.ps1 to
        see whether the client actually behaved differently.

    WHAT IT CANNOT DO - READ THIS BEFORE ASKING IT TO "ALLOCATE RAM"
        Luau runs inside Roblox's sandbox and has no access to the host:
          * CPU affinity / which core the process runs on is SetProcessAffinityMask,
            a Win32 call the PowerShell side makes. No Luau API exposes it.
          * the working set, job objects and page priority are also host-level
            (SetProcessWorkingSetSizeEx / AssignProcessToJobObject / memory
            priority). Luau cannot read or change any of them.
          * there is no API - documented, undocumented or executor-only - that
            lets a script inside the client reserve RAM for the client. A script
            that claims to do that is reading fiction or numbers.
        Anything in this file is measurement only. If you want the allocation to
        happen, run HARNESS.ps1 on the host.

    USAGE
        local reporter = require(script.Parent.harness_reporter)   -- ModuleScript
        -- or simply paste the body of this file into a Script:
        reporter.report()        -- one sample now
        reporter.start(5)        -- sample every 5 seconds, forever
]]

local RunService = game:GetService("RunService")
local Stats = game:GetService("Stats")

local DEFAULT_INTERVAL_SECONDS = 5

local HarnessReporter = {}

-- Every Stats/workspace call is wrapped: a restricted context should degrade to
-- "unavailable" instead of erroring the whole reporter.
local function safely(fn, fallback)
	local ok, value = pcall(fn)
	if ok and value ~= nil then
		return value
	end
	return fallback
end

local function getMemoryMb()
	local total = safely(function()
		return Stats:GetTotalMemoryUsageMb()
	end, nil)
	if total then
		return total
	end
	return safely(function()
		return Stats:GetMemoryUsageMb()
	end, nil)
end

local function getPhysicsFps()
	return safely(function()
		return math.floor(workspace:GetRealPhysicsFPS())
	end, nil)
end

local function getLuaHeapMb()
	local kilobytes = safely(function()
		return gcinfo()
	end, nil)
	if kilobytes then
		return kilobytes / 1024
	end
	return nil
end

local function formatNumber(value, suffix, decimals)
	if value == nil then
		return "unavailable"
	end
	return string.format("%." .. tostring(decimals or 1) .. "f %s", value, suffix or "")
end

--[[
    Samples frames per second by counting Heartbeat signals over a window.
    Heartbeat fires once per frame, so frames / elapsed time is the frame rate.
]]
function HarnessReporter.sample(durationSeconds)
	local duration = durationSeconds or DEFAULT_INTERVAL_SECONDS
	local frames = 0
	local connection = RunService.Heartbeat:Connect(function()
		frames = frames + 1
	end)

	task.wait(duration)
	connection:Disconnect()

	return {
		duration = duration,
		frames = frames,
		fps = frames / math.max(duration, 0.001),
		memoryMb = getMemoryMb(),
		luaHeapMb = getLuaHeapMb(),
		physicsFps = getPhysicsFps(),
	}
end

function HarnessReporter.report(durationSeconds)
	local sample = HarnessReporter.sample(durationSeconds)

	print(string.format("[harness] fps      %s (%d frames in %.0fs)",
		formatNumber(sample.fps, "fps"), sample.frames, sample.duration))
	print(string.format("[harness] memory   %s", formatNumber(sample.memoryMb, "MiB")))
	print(string.format("[harness] lua heap %s", formatNumber(sample.luaHeapMb, "MiB")))
	print(string.format("[harness] physics  %s",
		sample.physicsFps and (tostring(sample.physicsFps) .. " Hz") or "unavailable"))
	print("[harness] note: core pinning and RAM reservation are applied outside the")
	print("          client by HARNESS.ps1 - this reporter only measures the effect.")

	return sample
end

function HarnessReporter.start(intervalSeconds)
	local interval = intervalSeconds or DEFAULT_INTERVAL_SECONDS
	return task.spawn(function()
		while true do
			local sample = HarnessReporter.report(interval)
			if not sample then
				break
			end
			task.wait(interval)
		end
	end)
end

-- Auto-start when this file is pasted directly into a Script (not required as a
-- module, where returning the table is the expectation).
if script and script.ClassName == "Script" then
	HarnessReporter.start(DEFAULT_INTERVAL_SECONDS)
end

return HarnessReporter
