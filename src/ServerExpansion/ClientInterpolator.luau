--!strict
--[[
	ClientInterpolator.luau  (run from a LocalScript on the CLIENT)

	Cross-server replication updates an instance's CFrame only every ~commit
	interval (plus network latency), so a mirrored part/avatar visibly steps
	instead of moving smoothly. This module hides that on the client by
	interpolating the rendered CFrame toward the latest replicated target.

	It only touches ANCHORED synced BaseParts: for those, a client-side CFrame
	write is purely visual and won't fight physics or replicate back. Unanchored
	parts are left to the physics/replication system.

	How the stepping is detected without relying on Changed-signal timing
	(Roblox signals may be Deferred): each frame we compare the part's current
	CFrame against the value WE last wrote. If they differ, replication moved it,
	so that becomes the new interpolation target.

		-- LocalScript in StarterPlayerScripts:
		local ClientInterpolator = require(path.to.ClientInterpolator)
		ClientInterpolator.start({ speed = 12 })
]]

local RunService = game:GetService("RunService")

local ClientInterpolator = {}

type State = {
	target: CFrame, -- latest replicated CFrame we're easing toward
	display: CFrame, -- currently rendered CFrame
	lastWrite: CFrame, -- what we wrote last frame (to detect external changes)
}

local started = false
local root: Instance = workspace
local idAttribute = "SXID"
local speed = 12 -- higher = snappier convergence
local states: { [BasePart]: State } = {}

local function cframeClose(a: CFrame, b: CFrame): boolean
	if (a.Position - b.Position).Magnitude > 1e-3 then
		return false
	end
	-- Cheap orientation check via the look/right vectors.
	if (a.LookVector - b.LookVector).Magnitude > 1e-3 then
		return false
	end
	if (a.RightVector - b.RightVector).Magnitude > 1e-3 then
		return false
	end
	return true
end

local function isSmoothable(instance: Instance): boolean
	return instance:IsA("BasePart")
		and instance:GetAttribute(idAttribute) ~= nil
		and (instance :: BasePart).Anchored
end

local function trackPart(part: BasePart)
	if states[part] then
		return
	end
	states[part] = {
		target = part.CFrame,
		display = part.CFrame,
		lastWrite = part.CFrame,
	}
end

local function untrackPart(part: BasePart)
	states[part] = nil
end

local function onDescendantAdded(instance: Instance)
	if isSmoothable(instance) then
		trackPart(instance :: BasePart)
	end
end

local function step(dt: number)
	local alpha = math.clamp(dt * speed, 0, 1)
	for part, state in pairs(states) do
		if part.Parent == nil or not part.Anchored then
			-- Gone or handed to physics: stop smoothing it.
			states[part] = nil
		else
			local current = part.CFrame
			-- If replication changed the CFrame since our last write, retarget.
			if not cframeClose(current, state.lastWrite) then
				state.target = current
			end
			state.display = state.display:Lerp(state.target, alpha)
			part.CFrame = state.display
			state.lastWrite = state.display
		end
	end
end

-- options: { root: Instance?, idAttribute: string?, speed: number? }
function ClientInterpolator.start(options: { [string]: any }?)
	if not RunService:IsClient() then
		error("ClientInterpolator.start() must be called from a LocalScript (client)", 2)
	end
	if started then
		return
	end
	started = true

	options = options or {}
	root = options.root or workspace
	idAttribute = options.idAttribute or "SXID"
	speed = options.speed or 12

	for _, descendant in ipairs(root:GetDescendants()) do
		onDescendantAdded(descendant)
	end
	root.DescendantAdded:Connect(onDescendantAdded)
	root.DescendantRemoving:Connect(function(instance)
		if instance:IsA("BasePart") then
			untrackPart(instance :: BasePart)
		end
	end)

	RunService.RenderStepped:Connect(step)
end

return ClientInterpolator
