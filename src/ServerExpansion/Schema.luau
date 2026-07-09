--!strict
--[[
	Schema.luau
	Luau cannot reflect the full property list of an arbitrary Instance at
	runtime, so we maintain an explicit, extensible whitelist of which
	properties to sync per class group.

	Groups are keyed by a class name that is tested with Instance:IsA(), so
	inheritance is handled automatically: a Part matches "BasePart", "Part",
	and "Instance", and the union of their property lists is synced.

	Extend at runtime with Schema.extend(className, { "PropA", "PropB" }).
]]

local Schema = {}

-- className -> array of property names. Order does not matter.
local GROUPS: { [string]: { string } } = {
	Instance = { "Name" },

	BasePart = {
		"CFrame",
		"Size",
		"Color",
		"Material",
		"Transparency",
		"Reflectance",
		"Anchored",
		"CanCollide",
		"CanTouch",
		"CanQuery",
		"CastShadow",
		"Massless",
		"CollisionGroup",
		"AssemblyLinearVelocity",
		"AssemblyAngularVelocity",
	},
	Part = { "Shape" },
	MeshPart = { "MeshId", "TextureID", "DoubleSided" },
	WedgePart = {},
	TrussPart = {},

	-- Models have no synced scalar props of their own; their state lives in
	-- their descendant parts' CFrames. Listed so IsA("Model") is recognised
	-- as a syncable class rather than skipped.
	Model = {},

	Humanoid = {
		"Health",
		"MaxHealth",
		"WalkSpeed",
		"JumpPower",
		"DisplayName",
		"HipHeight",
	},

	Decal = { "Texture", "Color3", "Transparency", "Face" },
	Texture = { "Texture", "Color3", "Transparency", "Face", "StudsPerTileU", "StudsPerTileV" },

	PointLight = { "Brightness", "Color", "Enabled", "Range", "Shadows" },
	SpotLight = { "Brightness", "Color", "Enabled", "Range", "Angle", "Face", "Shadows" },
	SurfaceLight = { "Brightness", "Color", "Enabled", "Range", "Angle", "Face", "Shadows" },

	Sound = { "SoundId", "Volume", "Playing", "Looped", "PlaybackSpeed", "TimePosition" },

	Fire = { "Enabled", "Heat", "Size", "Color", "SecondaryColor" },
	Smoke = { "Enabled", "Color", "Opacity", "RiseVelocity", "Size" },
	Sparkles = { "Enabled", "SparkleColor" },

	ParticleEmitter = { "Enabled", "Rate", "Lifetime", "Speed", "Color", "Texture", "Transparency" },

	Attachment = { "CFrame" },

	SurfaceGui = { "Enabled", "Face" },
	BillboardGui = { "Enabled", "Size", "StudsOffset" },
	TextLabel = { "Text", "TextColor3", "BackgroundColor3", "TextTransparency", "Visible" },
	ImageLabel = { "Image", "ImageColor3", "BackgroundColor3", "ImageTransparency", "Visible" },

	Seat = { "Disabled" },
	VehicleSeat = { "Disabled", "Throttle", "Steer" },
}

-- Base classes we consider "part of the world" and therefore track. Anything
-- not matching one of these (Scripts, values, client GUIs, etc.) is ignored so
-- we don't try to replicate things that make no sense cross-server.
local TRACKABLE_BASECLASSES = {
	"BasePart",
	"Model",
	"Folder",
	"Light",
	"Decal",
	"Texture",
	"Humanoid",
	"Accessory",
	"Accoutrement",
	"Tool",
	"Sound",
	"Fire",
	"Smoke",
	"Sparkles",
	"ParticleEmitter",
	"Attachment",
	"SurfaceGui",
	"BillboardGui",
	"Seat",
	"VehicleSeat",
}

-- Should this instance be tracked/synced at all?
function Schema.isTrackable(instance: Instance): boolean
	for _, className in ipairs(TRACKABLE_BASECLASSES) do
		local ok, isA = pcall(function()
			return instance:IsA(className)
		end)
		if ok and isA then
			return true
		end
	end
	return false
end

-- Return the union of property names to sync for the given instance, filtered
-- to those the instance actually exposes.
function Schema.getProps(instance: Instance): { string }
	local seen: { [string]: boolean } = {}
	local result: { string } = {}
	for className, props in pairs(GROUPS) do
		local ok, isA = pcall(function()
			return instance:IsA(className)
		end)
		if ok and isA then
			for _, prop in ipairs(props) do
				if not seen[prop] then
					-- Confirm the property is really readable on this instance.
					local readable = pcall(function()
						return (instance :: any)[prop]
					end)
					if readable then
						seen[prop] = true
						table.insert(result, prop)
					end
				end
			end
		end
	end
	return result
end

-- Add or replace the property list for a class group.
function Schema.extend(className: string, props: { string })
	GROUPS[className] = props
end

-- Merge extra props into an existing group (creating it if absent).
function Schema.add(className: string, props: { string })
	local existing = GROUPS[className]
	if not existing then
		GROUPS[className] = table.clone(props)
		return
	end
	for _, prop in ipairs(props) do
		if not table.find(existing, prop) then
			table.insert(existing, prop)
		end
	end
end

return Schema
