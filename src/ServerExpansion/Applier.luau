--!strict
--[[
	Applier.luau
	Applies ops that arrived from other servers to the local world.

	Two hard problems it handles:

	1. Feedback loops. Setting a property here fires GetPropertyChangedSignal,
	   which the ChangeTracker would otherwise turn into a fresh local commit,
	   echoing the change back out forever. Before applying, we record the
	   "expected" encoded value; the tracker consults consumeExpected() and
	   drops changes that match, breaking the loop. Same idea for create/delete
	   via consumeExpectedCreate/Delete.

	2. Out-of-order parents. A child's create op can be applied before its
	   parent exists (across authors). Such ops are buffered per parent id and
	   flushed when the parent appears.
]]

local Identity = require(script.Parent.Identity)
local Codec = require(script.Parent.Codec)

local Applier = {}

-- Sentinel parentId meaning "directly under the sync root".
Applier.ROOT_PARENT_ID = "ROOT"

local syncRoot: Instance = workspace
local debugLog = false

local expectedProps: { [string]: { [string]: any } } = {}
local expectedAttrs: { [string]: { [string]: any } } = {}
local expectedCreates: { [string]: boolean } = {}
local expectedDeletes: { [string]: boolean } = {}
local pendingChildren: { [string]: { any } } = {} -- parentId -> list of create ops

local function log(...)
	if debugLog then
		print("[ServerExpansion.Applier]", ...)
	end
end

function Applier.configure(root: Instance, isDebug: boolean)
	syncRoot = root
	debugLog = isDebug
end

--== Loop-suppression consume API (called by ChangeTracker) ==--

-- Returns true if this property change was one we just applied (so skip it).
function Applier.consumeExpected(id: string, prop: string, encoded: any): boolean
	local props = expectedProps[id]
	if props and props[prop] ~= nil and Codec.equal(props[prop], encoded) then
		props[prop] = nil
		return true
	end
	return false
end

-- Returns true if this attribute change was one we just applied (so skip it).
function Applier.consumeExpectedAttr(id: string, name: string, encoded: any): boolean
	local attrs = expectedAttrs[id]
	if attrs and attrs[name] ~= nil and Codec.equal(attrs[name], encoded) then
		attrs[name] = nil
		return true
	end
	return false
end

function Applier.consumeExpectedCreate(id: string): boolean
	if expectedCreates[id] then
		expectedCreates[id] = nil
		return true
	end
	return false
end

function Applier.consumeExpectedDelete(id: string): boolean
	if expectedDeletes[id] then
		expectedDeletes[id] = nil
		return true
	end
	return false
end

--== Applying ops ==--

local function recordExpectedProp(id: string, prop: string, encoded: any)
	local bucket = expectedProps[id]
	if not bucket then
		bucket = {}
		expectedProps[id] = bucket
	end
	bucket[prop] = encoded
end

local function setProps(instance: Instance, id: string, props: { [string]: any })
	for prop, encoded in pairs(props) do
		recordExpectedProp(id, prop, encoded)
		local value = Codec.decode(encoded)
		-- Ref decode may return nil if the target isn't here yet; skip those.
		if value ~= nil or typeof(encoded) ~= "table" or encoded.t ~= "Ref" then
			local ok, err = pcall(function()
				(instance :: any)[prop] = value
			end)
			if not ok then
				log("failed to set", prop, "on", id, err)
			end
		end
	end
end

local function recordExpectedAttr(id: string, name: string, encoded: any)
	local bucket = expectedAttrs[id]
	if not bucket then
		bucket = {}
		expectedAttrs[id] = bucket
	end
	bucket[name] = encoded
end

local function setAttrs(instance: Instance, id: string, attrs: { [string]: any })
	for name, encoded in pairs(attrs) do
		recordExpectedAttr(id, name, encoded)
		-- The REMOVED marker means "unset this attribute".
		local isRemoval = typeof(encoded) == "table" and encoded.t == "Removed"
		local value = if isRemoval then nil else Codec.decode(encoded)
		-- Skip unresolved instance refs (target not here yet).
		local isUnresolvedRef = typeof(encoded) == "table" and encoded.t == "Ref" and value == nil
		if not isUnresolvedRef then
			local ok, err = pcall(function()
				instance:SetAttribute(name, value)
			end)
			if not ok then
				log("failed to set attribute", name, "on", id, err)
			end
		end
	end
end

local function resolveParent(parentId: string): Instance?
	if parentId == Applier.ROOT_PARENT_ID then
		return syncRoot
	end
	return Identity.getInstance(parentId)
end

local applyCreate -- forward declaration

local function flushPending(parentId: string)
	local waiting = pendingChildren[parentId]
	if not waiting then
		return
	end
	pendingChildren[parentId] = nil
	for _, op in ipairs(waiting) do
		applyCreate(op)
	end
end

function applyCreate(op: any)
	local id = op.id

	-- Already present? Treat as an update instead of duplicating.
	local existing = Identity.getInstance(id)
	if existing then
		setProps(existing, id, op.props or {})
		setAttrs(existing, id, op.attrs or {})
		return
	end

	local parent = resolveParent(op.parentId)
	if not parent then
		-- Parent not here yet: buffer until it arrives.
		local bucket = pendingChildren[op.parentId]
		if not bucket then
			bucket = {}
			pendingChildren[op.parentId] = bucket
		end
		table.insert(bucket, op)
		log("buffered create", id, "awaiting parent", op.parentId)
		return
	end

	local ok, instance = pcall(function()
		return Instance.new(op.class)
	end)
	if not ok or not instance then
		log("cannot Instance.new", op.class, "for", id)
		return
	end

	expectedCreates[id] = true
	Identity.adopt(instance, id)
	setProps(instance, id, op.props or {})
	setAttrs(instance, id, op.attrs or {})
	instance.Parent = parent

	-- Any children that were waiting on this instance can now be created.
	flushPending(id)
end

local function applyUpdate(op: any)
	local instance = Identity.getInstance(op.id)
	if not instance then
		-- Update arrived before the create (or after a missed create).
		-- Snapshot / reconcile will heal this; ignore for now.
		log("update for unknown id", op.id)
		return
	end
	setProps(instance, op.id, op.props or {})
	setAttrs(instance, op.id, op.attrs or {})
end

local function applyDelete(op: any)
	local id = op.id
	expectedDeletes[id] = true
	local instance = Identity.getInstance(id)
	if instance and instance ~= syncRoot then
		pcall(function()
			instance:Destroy()
		end)
	end
	Identity.unregister(id)
	pendingChildren[id] = nil
	expectedProps[id] = nil
	expectedAttrs[id] = nil
end

function Applier.applyOp(op: any)
	if op.op == "create" then
		applyCreate(op)
	elseif op.op == "update" then
		applyUpdate(op)
	elseif op.op == "delete" then
		applyDelete(op)
	else
		log("unknown op", op.op)
	end
end

-- Apply every op in a commit, in order.
function Applier.applyCommit(commit: any)
	if not commit or not commit.ops then
		return
	end
	for _, op in ipairs(commit.ops) do
		Applier.applyOp(op)
	end
end

return Applier
