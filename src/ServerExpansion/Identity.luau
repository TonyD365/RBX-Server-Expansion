--!strict
--[[
	Identity.luau
	Gives every synced instance a stable, cross-server identity (a GUID stored
	as an attribute) and maintains a two-way id <-> instance registry so ops
	can reference instances by id regardless of which server they run on.

	The id is what makes a "door" on server A and the same door on server B the
	same object in the shared repository.
]]

local HttpService = game:GetService("HttpService")

local Identity = {}

local idAttribute = "SXID"
local idToInstance: { [string]: Instance } = {}

-- Called once by init with the resolved config value.
function Identity.setAttributeName(name: string)
	idAttribute = name
end

-- Return the instance's id, or nil if it has none yet.
function Identity.getId(instance: Instance): string?
	local value = instance:GetAttribute(idAttribute)
	if typeof(value) == "string" then
		return value
	end
	return nil
end

-- Register an id->instance mapping (idempotent).
function Identity.register(id: string, instance: Instance)
	idToInstance[id] = instance
end

function Identity.unregister(id: string)
	idToInstance[id] = nil
end

-- Look up a live instance by id.
function Identity.getInstance(id: string): Instance?
	local instance = idToInstance[id]
	if instance and instance.Parent == nil and instance ~= workspace then
		-- Stale entry (destroyed). Drop it.
		idToInstance[id] = nil
		return nil
	end
	return instance
end

-- Ensure the instance has an id, assigning a fresh GUID if needed, and make
-- sure it is registered. Returns the id.
function Identity.ensureId(instance: Instance): string
	local existing = Identity.getId(instance)
	if existing then
		Identity.register(existing, instance)
		return existing
	end
	local id = HttpService:GenerateGUID(false)
	instance:SetAttribute(idAttribute, id)
	Identity.register(id, instance)
	return id
end

-- Adopt an id that arrived from a remote op (used when creating a mirror
-- instance): set the attribute and register, without generating a new one.
function Identity.adopt(instance: Instance, id: string)
	instance:SetAttribute(idAttribute, id)
	Identity.register(id, instance)
end

-- Debug / snapshot helper.
function Identity.all(): { [string]: Instance }
	return idToInstance
end

return Identity
