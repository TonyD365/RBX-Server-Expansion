--!strict
--[[
	Repository.luau
	The shared, git-like repository that lives outside any single server.

	  - HEAD        : an atomically-incremented version counter (MemoryStore
	                  HashMap). Reserving a version is the "commit hash" step --
	                  it gives every commit a globally unique, totally-ordered
	                  number, which is what makes conflict resolution simply
	                  "latest version wins".
	  - commit log  : a MemoryStore SortedMap keyed by zero-padded version, each
	                  value a serialized commit. Peers read the range after their
	                  local HEAD to catch up.
	  - snapshot    : a periodic full-world dump in a DataStore, so a brand-new
	                  server can rebuild the whole world, then replay recent
	                  commits on top.

	Every remote call is wrapped in pcall + light retry because MemoryStore /
	DataStore throw on throttling or transient network faults.
]]

local MemoryStoreService = game:GetService("MemoryStoreService")
local DataStoreService = game:GetService("DataStoreService")

local Repository = {}

local HEAD_KEY = "HEAD"
local LOCK_KEY = "snapshot_writer"
local SNAPSHOT_KEY = "latest"

local headMap: any
local commitMap: any
local lockMap: any
local snapshotStore: any

local headTtl = 3888000
local commitTtl = 3600
local lockTtl = 90
local debugLog = false

local function log(...)
	if debugLog then
		print("[ServerExpansion.Repository]", ...)
	end
end

local function pad(version: number): string
	return string.format("%012d", version)
end

-- Run fn with a few retries on transient failures. Returns (ok, result).
local function retry(fn: () -> any, tries: number?): (boolean, any)
	local attempts = tries or 3
	local lastErr: any
	for i = 1, attempts do
		local ok, result = pcall(fn)
		if ok then
			return true, result
		end
		lastErr = result
		if i < attempts then
			task.wait(0.25 * i)
		end
	end
	log("call failed after retries:", lastErr)
	return false, lastErr
end

function Repository.configure(config: any)
	headMap = MemoryStoreService:GetHashMap(config.headMapName)
	commitMap = MemoryStoreService:GetSortedMap(config.commitMapName)
	lockMap = MemoryStoreService:GetHashMap(config.lockMapName)
	snapshotStore = DataStoreService:GetDataStore(config.snapshotStoreName)
	headTtl = config.headTtl
	commitTtl = config.commitTtl
	lockTtl = config.lockTtl
	debugLog = config.debug
end

--== HEAD version counter ==--

-- Atomically bump HEAD and return the freshly reserved version number.
function Repository.reserveVersion(): number?
	local ok, newValue = retry(function()
		return headMap:UpdateAsync(HEAD_KEY, function(old)
			return (old or 0) + 1
		end, headTtl)
	end)
	if ok and typeof(newValue) == "number" then
		return newValue
	end
	return nil
end

function Repository.getLatestVersion(): number
	local ok, value = retry(function()
		return headMap:GetAsync(HEAD_KEY)
	end)
	if ok and typeof(value) == "number" then
		return value
	end
	return 0
end

--== Commit log ==--

-- Reserve a version, stamp it on the commit, and write it to the log.
-- Returns the version, or nil on failure.
function Repository.pushCommit(commit: any): number?
	local version = Repository.reserveVersion()
	if not version then
		return nil
	end
	commit.v = version
	local ok = retry(function()
		commitMap:SetAsync(pad(version), commit, commitTtl)
		return true
	end)
	if not ok then
		log("failed to write commit", version, "to log")
		return nil
	end
	return version
end

-- Read all commits with version in (fromExclusive, toInclusive], in order.
function Repository.getCommitsAfter(fromExclusive: number, toInclusive: number): { any }
	local commits: { any } = {}
	if toInclusive <= fromExclusive then
		return commits
	end

	local cursor = fromExclusive
	local upperBound = pad(toInclusive + 1) -- exclusive upper => includes toInclusive
	while cursor < toInclusive do
		local ok, items = retry(function()
			return commitMap:GetRangeAsync(Enum.SortDirection.Ascending, 100, pad(cursor), upperBound)
		end)
		if not ok or typeof(items) ~= "table" or #items == 0 then
			break
		end
		for _, item in ipairs(items) do
			table.insert(commits, item.value)
			local keyNumber = tonumber(item.key)
			if keyNumber then
				cursor = keyNumber
			end
		end
		if #items < 100 then
			break
		end
	end

	return commits
end

--== Snapshot (DataStore) ==--

function Repository.saveSnapshot(records: { any }, version: number): boolean
	local ok = retry(function()
		snapshotStore:SetAsync(SNAPSHOT_KEY, {
			v = version,
			records = records,
			savedAt = os.time(),
		})
		return true
	end)
	return ok
end

-- Returns { v = number, records = {...} } or nil.
function Repository.loadSnapshot(): any?
	local ok, value = retry(function()
		return snapshotStore:GetAsync(SNAPSHOT_KEY)
	end)
	if ok and typeof(value) == "table" then
		return value
	end
	return nil
end

--== Snapshot-writer election ==--

-- Try to become (or stay) the single server responsible for writing snapshots.
-- The lease expires after lockTtl, so if the holder dies another server takes
-- over. Returns true if this jobId currently holds the lock.
function Repository.acquireSnapshotLock(jobId: string): boolean
	local ok, holder = retry(function()
		return lockMap:UpdateAsync(LOCK_KEY, function(old)
			if old == nil or old == jobId then
				return jobId
			end
			return old
		end, lockTtl)
	end)
	return ok and holder == jobId
end

return Repository
