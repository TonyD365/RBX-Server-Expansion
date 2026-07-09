--!strict
--[[
	Replicator.luau
	The orchestrator that ties change detection, the shared repository, and
	messaging together into the git-like sync loop:

	  local changes  --collect-->  commit  --push-->  reserve version + write log
	                                                    + PublishAsync{v}
	  PublishAsync / reconcile timer  --pull-->  read commits after localHEAD
	                                             --apply--> Applier

	Own commits are applied to the local world at the source, so they are
	skipped on pull (author == this jobId).
]]

local MessagingService = game:GetService("MessagingService")
local HttpService = game:GetService("HttpService")

local Config = require(script.Parent.Config)
local Repository = require(script.Parent.Repository)
local ChangeTracker = require(script.Parent.ChangeTracker)
local Applier = require(script.Parent.Applier)

local Replicator = {}

local config: any
local jobId: string
local topic: string
local started = false

local localHead = 0
local pulling = false

-- Reliability/perf state.
local pendingOps: { any } = {} -- ops that failed to push; retried next interval
local consecutiveFailures = 0
local currentInterval = 0.5 -- adaptive commit interval (backs off under failure)

local function log(...)
	if config and config.debug then
		print("[ServerExpansion.Replicator]", ...)
	end
end

-- Fetch and apply everything newer than our local HEAD. Guarded so overlapping
-- triggers (a message arriving during a reconcile) don't double-apply.
local function pullNow()
	if pulling then
		return
	end
	pulling = true
	local ok, err = pcall(function()
		local latest = Repository.getLatestVersion()
		if latest <= localHead then
			return
		end
		local commits = Repository.getCommitsAfter(localHead, latest)
		for _, commit in ipairs(commits) do
			if commit.author ~= jobId then
				Applier.applyCommit(commit)
			end
		end
		localHead = math.max(localHead, latest)
		log("pulled up to", localHead)
	end)
	pulling = false
	if not ok then
		log("pull failed:", err)
	end
end

-- Split ops into commits no larger than maxOpsPerCommit and push each. Returns
-- the ops that could NOT be pushed (from the first failing chunk onward) so the
-- caller can re-queue them -- changes are never silently dropped.
local function pushOps(ops: { any }): { any }
	local i = 1
	while i <= #ops do
		local chunk = {}
		local last = math.min(i + config.maxOpsPerCommit - 1, #ops)
		for j = i, last do
			table.insert(chunk, ops[j])
		end

		local commit = { author = jobId, t = os.time(), ops = chunk }
		local version = Repository.pushCommit(commit)
		if not version then
			-- Return everything not yet pushed (this chunk included).
			log("push failed; re-queuing", #ops - i + 1, "ops")
			return table.move(ops, i, #ops, 1, {})
		end

		localHead = math.max(localHead, version)
		-- Notify peers; payload is just the version number (tiny, well under the
		-- 1KB MessagingService limit). Peers pull the commit.
		pcall(function()
			MessagingService:PublishAsync(topic, { v = version, from = jobId })
		end)
		log("pushed commit", version, "with", #chunk, "ops")
		i = last + 1
	end
	return {}
end

-- One commit-loop tick: drain local changes (plus anything re-queued), push,
-- and adapt the interval. Returns nothing; updates module state.
local function flushTick()
	local ops = ChangeTracker.collect()

	-- Prepend previously-failed ops so ordering is preserved (older first).
	if #pendingOps > 0 then
		local combined = table.clone(pendingOps)
		for _, op in ipairs(ops) do
			table.insert(combined, op)
		end
		ops = combined
		table.clear(pendingOps)
	end

	if #ops == 0 then
		return
	end

	local leftover = pushOps(ops)
	if #leftover > 0 then
		pendingOps = leftover
		consecutiveFailures += 1
		-- Exponential backoff, capped, to avoid hammering a throttled store.
		currentInterval = math.min(config.maxCommitInterval, config.commitInterval * 2 ^ consecutiveFailures)
	else
		consecutiveFailures = 0
		currentInterval = config.commitInterval
	end
end

-- Rebuild the world from the newest snapshot, then replay commits on top.
local function bootstrap()
	local snapshot = Repository.loadSnapshot()
	if snapshot and typeof(snapshot.records) == "table" then
		for _, record in ipairs(snapshot.records) do
			Applier.applyOp(record)
		end
		localHead = tonumber(snapshot.v) or 0
		log("bootstrapped from snapshot @", localHead, "with", #snapshot.records, "records")
	else
		log("no snapshot; starting from live commit log")
	end

	-- Replay any commits newer than the snapshot.
	local latest = Repository.getLatestVersion()
	if latest > localHead then
		local commits = Repository.getCommitsAfter(localHead, latest)
		for _, commit in ipairs(commits) do
			Applier.applyCommit(commit)
		end
		localHead = latest
	end
	log("bootstrap complete @", localHead)
end

local function startLoops()
	-- Commit loop: flush local changes on the (adaptive) commit interval.
	task.spawn(function()
		while started do
			task.wait(currentInterval)
			flushTick()
		end
	end)

	-- Reconcile loop: catch commits whose PublishAsync we missed.
	task.spawn(function()
		while started do
			task.wait(config.reconcileInterval)
			pullNow()
		end
	end)

	-- Snapshot loop: the elected writer periodically dumps the world.
	task.spawn(function()
		while started do
			task.wait(config.snapshotInterval)
			if Repository.acquireSnapshotLock(jobId) then
				local records = ChangeTracker.serializeWorld()
				if Repository.saveSnapshot(records, localHead) then
					log("wrote snapshot @", localHead, "with", #records, "records")
				end
			end
		end
	end)
end

function Replicator.start(resolvedConfig: any)
	if started then
		return
	end
	config = resolvedConfig
	topic = config.topic
	currentInterval = config.commitInterval

	jobId = game.JobId
	if jobId == "" then
		-- Studio / unpublished: fabricate a stable-per-session id.
		jobId = "studio-" .. HttpService:GenerateGUID(false)
	end

	Repository.configure(config)

	-- Build the world before we begin tracking, so restoring the snapshot
	-- doesn't get mistaken for local creates.
	bootstrap()

	ChangeTracker.start()

	-- Subscribe for real-time notifications.
	task.spawn(function()
		local ok, err = pcall(function()
			MessagingService:SubscribeAsync(topic, function(message)
				local data = (message :: any).Data
				if typeof(data) == "table" and data.from ~= jobId then
					if typeof(data.v) == "number" and data.v > localHead then
						pullNow()
					end
				end
			end)
		end)
		if not ok then
			log("SubscribeAsync failed; relying on reconcile loop:", err)
		end
	end)

	started = true
	startLoops()

	-- On shutdown: flush any last-moment local changes so they are not lost,
	-- then (if elected) write a final snapshot. BindToClose runs synchronously
	-- and may yield, so these blocking calls are safe here.
	game:BindToClose(function()
		flushTick() -- push remaining + previously-queued ops
		if #pendingOps > 0 then
			-- One more attempt for anything still queued after a transient fail.
			pushOps(pendingOps)
			table.clear(pendingOps)
		end
		if Repository.acquireSnapshotLock(jobId) then
			local records = ChangeTracker.serializeWorld()
			Repository.saveSnapshot(records, localHead)
		end
	end)

	log("started as", jobId, "@ HEAD", localHead)
end

function Replicator.getLocalHead(): number
	return localHead
end

return Replicator
