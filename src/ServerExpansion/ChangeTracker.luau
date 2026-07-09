--!strict
--[[
	ChangeTracker.luau
	Watches every trackable instance under the sync root and turns LOCAL changes
	into ops (create / update / delete). Only things that actually changed
	produce ops -- unchanged instances cost nothing to send (the "only sync what
	changed" requirement).

	Changes made by the Applier (remote ops) are filtered out here via the
	Applier's consume* API so they don't echo back out as new commits.

	Replicator calls collect() once per commit interval to drain the accumulated
	ops; the tracker coalesces multiple changes to the same property into a
	single latest-value read.
]]

local Players = game:GetService("Players")

local Identity = require(script.Parent.Identity)
local Codec = require(script.Parent.Codec)
local Schema = require(script.Parent.Schema)
local Applier = require(script.Parent.Applier)

local ChangeTracker = {}

type Tracked = {
	id: string,
	connections: { RBXScriptConnection },
}

local syncRoot: Instance = workspace
local classBlacklist: { [string]: boolean } = {}
local syncPlayerCharacters = true
local debugLog = false
local started = false

local tracked: { [Instance]: Tracked } = {}

-- Accumulated changes for the next commit.
local createdOrder: { Instance } = {} -- instances added locally this interval (order preserved)
local createdSet: { [Instance]: boolean } = {}
local dirtyProps: { [string]: { [string]: boolean } } = {} -- id -> set of changed prop names
local deletedIds: { [string]: boolean } = {} -- ids removed locally this interval

local function log(...)
	if debugLog then
		print("[ServerExpansion.ChangeTracker]", ...)
	end
end

function ChangeTracker.configure(root: Instance, blacklist: { [string]: boolean }, syncChars: boolean, isDebug: boolean)
	syncRoot = root
	classBlacklist = blacklist
	syncPlayerCharacters = syncChars
	debugLog = isDebug
end

local function isPlayerCharacter(instance: Instance): boolean
	if not instance:IsA("Model") then
		return false
	end
	return Players:GetPlayerFromCharacter(instance) ~= nil
end

local function shouldTrack(instance: Instance): boolean
	if classBlacklist[instance.ClassName] then
		return false
	end
	if not Schema.isTrackable(instance) then
		return false
	end
	if not syncPlayerCharacters and isPlayerCharacter(instance) then
		return false
	end
	return true
end

local function markDirty(id: string, prop: string)
	local bucket = dirtyProps[id]
	if not bucket then
		bucket = {}
		dirtyProps[id] = bucket
	end
	bucket[prop] = true
end

-- Connect property-changed signals and register the instance. `emitCreate`
-- controls whether a genuine local add is recorded as a create op (false for
-- the initial startup scan and for remote-applied instances).
local function track(instance: Instance, emitCreate: boolean)
	if tracked[instance] then
		return
	end

	local id = Identity.ensureId(instance)
	local connections: { RBXScriptConnection } = {}

	for _, prop in ipairs(Schema.getProps(instance)) do
		local ok, conn = pcall(function()
			return instance:GetPropertyChangedSignal(prop):Connect(function()
				local encoded, encodable = Codec.encode((instance :: any)[prop])
				if not encodable then
					return
				end
				-- Drop changes we ourselves applied from a remote op.
				if Applier.consumeExpected(id, prop, encoded) then
					return
				end
				markDirty(id, prop)
			end)
		end)
		if ok and conn then
			table.insert(connections, conn)
		end
	end

	tracked[instance] = { id = id, connections = connections }

	if emitCreate and not createdSet[instance] then
		createdSet[instance] = true
		table.insert(createdOrder, instance)
	end
end

local function untrack(instance: Instance)
	local entry = tracked[instance]
	if not entry then
		return
	end
	for _, conn in ipairs(entry.connections) do
		conn:Disconnect()
	end
	tracked[instance] = nil
end

local function onDescendantAdded(instance: Instance)
	if not shouldTrack(instance) then
		return
	end
	local existingId = Identity.getId(instance)
	-- Was this add produced by the Applier creating a remote mirror?
	if existingId and Applier.consumeExpectedCreate(existingId) then
		track(instance, false) -- track it, but don't re-emit a create
	else
		track(instance, true)
	end
end

local function onDescendantRemoving(instance: Instance)
	local entry = tracked[instance]
	local id = entry and entry.id or Identity.getId(instance)
	untrack(instance)
	if not id then
		return
	end
	-- If a create for this instance is still pending in this same interval,
	-- cancel it out (created and destroyed before ever committing).
	if createdSet[instance] then
		createdSet[instance] = nil
		local index = table.find(createdOrder, instance)
		if index then
			table.remove(createdOrder, index)
		end
		return
	end
	-- Was this removal produced by the Applier applying a remote delete?
	if Applier.consumeExpectedDelete(id) then
		return
	end
	deletedIds[id] = true
end

function ChangeTracker.start()
	if started then
		return
	end
	started = true

	-- Initial scan: track everything already present WITHOUT emitting creates
	-- (the existing world is captured by the snapshot, not by a flood of ops).
	for _, descendant in ipairs(syncRoot:GetDescendants()) do
		if shouldTrack(descendant) then
			track(descendant, false)
		end
	end

	syncRoot.DescendantAdded:Connect(onDescendantAdded)
	syncRoot.DescendantRemoving:Connect(onDescendantRemoving)
	log("started; tracking", #syncRoot:GetDescendants(), "descendants")
end

-- Build the parentId reference for a create op.
local function parentIdOf(instance: Instance): string
	local parent = instance.Parent
	if parent == syncRoot or parent == nil then
		return Applier.ROOT_PARENT_ID
	end
	-- Ensure the parent has an id so the child can reference it.
	return Identity.ensureId(parent)
end

-- Read a full property snapshot for a create op.
local function encodeAllProps(instance: Instance): { [string]: any }
	local props: { [string]: any } = {}
	for _, prop in ipairs(Schema.getProps(instance)) do
		local encoded, encodable = Codec.encode((instance :: any)[prop])
		if encodable then
			props[prop] = encoded
		end
	end
	return props
end

-- Drain accumulated changes into an ordered list of ops, then reset. Returns
-- an empty table when nothing changed.
function ChangeTracker.collect(): { any }
	local ops: { any } = {}

	-- 1) Creates first (parents precede children by DescendantAdded order).
	for _, instance in ipairs(createdOrder) do
		if instance.Parent ~= nil then
			local id = Identity.getId(instance)
			if id then
				table.insert(ops, {
					op = "create",
					id = id,
					class = instance.ClassName,
					parentId = parentIdOf(instance),
					props = encodeAllProps(instance),
				})
				-- Its initial props are already in the create; clear any dirt.
				dirtyProps[id] = nil
			end
		end
	end

	-- 2) Updates for existing (non-created) instances.
	for id, propSet in pairs(dirtyProps) do
		local instance = Identity.getInstance(id)
		if instance then
			local props: { [string]: any } = {}
			local any = false
			for prop in pairs(propSet) do
				local encoded, encodable = Codec.encode((instance :: any)[prop])
				if encodable then
					props[prop] = encoded
					any = true
				end
			end
			if any then
				table.insert(ops, { op = "update", id = id, props = props })
			end
		end
	end

	-- 3) Deletes.
	for id in pairs(deletedIds) do
		table.insert(ops, { op = "delete", id = id })
	end

	-- Reset accumulators.
	table.clear(createdOrder)
	table.clear(createdSet)
	table.clear(dirtyProps)
	table.clear(deletedIds)

	return ops
end

-- Produce create-ops describing the ENTIRE current world under the sync root.
-- Used to write a snapshot; a fresh server rebuilds the world by applying
-- these, then replays newer commits on top.
function ChangeTracker.serializeWorld(): { any }
	local records: { any } = {}
	for _, instance in ipairs(syncRoot:GetDescendants()) do
		if shouldTrack(instance) then
			local id = Identity.ensureId(instance)
			table.insert(records, {
				op = "create",
				id = id,
				class = instance.ClassName,
				parentId = parentIdOf(instance),
				props = encodeAllProps(instance),
			})
		end
	end
	return records
end

return ChangeTracker
