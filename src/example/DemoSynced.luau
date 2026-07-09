--!strict
--[[
	DemoSynced.luau  (place as a Server Script)

	Demonstrates cross-server world sync. Run the experience across two or more
	servers and watch the demo part stay in sync everywhere:

	  - The first server to start creates a "SyncedDemoPart" and animates it
	    (orbits + cycles colour). Every other server receives the changes and
	    mirrors the part without running any animation of its own.
	  - Creating / moving / recolouring / deleting the part on ANY server
	    propagates to all the others.

	This is just an example of the framework in action -- your real game code
	simply changes instances under the sync root and they replicate.
]]

local ServerScriptService = game:GetService("ServerScriptService")
local RunService = game:GetService("RunService")

local ServerExpansion = require(ServerScriptService:WaitForChild("ServerExpansion"))

-- Start syncing the whole workspace.
ServerExpansion.start({ debug = true })

local PART_NAME = "SyncedDemoPart"

-- Give bootstrap a moment to restore any already-synced world state.
task.wait(3)

-- Is the demo part already here (synced from another server / snapshot)?
local existing = workspace:FindFirstChild(PART_NAME)

local iAmDriver = false
local part: BasePart

if existing and existing:IsA("BasePart") then
	part = existing
else
	-- Nobody has it yet: create it. This server becomes the driver.
	local newPart = Instance.new("Part")
	newPart.Name = PART_NAME
	newPart.Anchored = true
	newPart.Size = Vector3.new(4, 4, 4)
	newPart.Position = Vector3.new(0, 10, 0)
	newPart.Color = Color3.fromRGB(255, 80, 80)
	newPart.Material = Enum.Material.Neon
	newPart.Parent = workspace
	part = newPart
	iAmDriver = true
	print("[Demo] created", PART_NAME, "-- this server is the driver")
end

if not iAmDriver then
	print("[Demo] mirroring", PART_NAME, "from another server")
	return
end

-- Driver: animate the part. The framework turns these property changes into
-- commits that every other server applies.
local t = 0
local hue = 0
RunService.Heartbeat:Connect(function(dt)
	t += dt
	hue = (hue + dt * 0.1) % 1

	-- Orbit around the origin.
	local radius = 20
	part.CFrame = CFrame.new(math.cos(t) * radius, 10, math.sin(t) * radius)
		* CFrame.Angles(0, t, 0)
	part.Color = Color3.fromHSV(hue, 1, 1)
end)
