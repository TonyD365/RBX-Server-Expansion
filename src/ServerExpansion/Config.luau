--!strict
--[[
	Config.luau
	Central, overridable configuration for the ServerExpansion cross-server
	world-sync framework.

	Override any field by passing a partial table to ServerExpansion.start(config).
]]

export type Config = {
	-- Which instance is the sync root. Everything under it is tracked.
	-- Default resolver returns workspace (sync the whole world).
	getSyncRoot: () -> Instance,

	-- Attribute used to give each synced instance a stable cross-server id.
	idAttribute: string,

	-- MemoryStore / MessagingService / DataStore resource names.
	headMapName: string, -- MemoryStore HashMap holding the HEAD version counter
	commitMapName: string, -- MemoryStore SortedMap holding the commit log
	lockMapName: string, -- MemoryStore HashMap holding the snapshot-writer lock
	snapshotStoreName: string, -- DataStore holding world snapshots
	topic: string, -- MessagingService topic for "new commit" notifications

	-- Timing (seconds).
	commitInterval: number, -- how often local changes are flushed into a commit
	maxCommitInterval: number, -- upper bound the commit interval backs off to under failures
	reconcileInterval: number, -- how often to pull missed commits as a fallback
	snapshotInterval: number, -- how often the elected server writes a snapshot

	-- Time-to-live (seconds).
	commitTtl: number, -- how long a commit lives in the log
	headTtl: number, -- how long the HEAD counter lives (kept alive by writes)
	lockTtl: number, -- snapshot-writer lock lease

	-- Limits.
	maxOpsPerCommit: number, -- cap ops in one commit (rate-limit safety)
	maxCommitBytes: number, -- soft cap on a serialized commit
	inlineMessageBytes: number, -- if a commit serializes under this, inline it in the message
	snapshotChunkSize: number, -- records per snapshot chunk (keeps each DataStore value under the 4MB limit)

	-- Class names never synced (local-only / client-only instances).
	classBlacklist: { [string]: boolean },

	-- Whether to also sync player Characters (remote avatars appear as clones).
	syncPlayerCharacters: boolean,

	-- Verbose logging.
	debug: boolean,
}

local defaults: Config = {
	getSyncRoot = function(): Instance
		return workspace
	end,

	idAttribute = "SXID",

	headMapName = "SX_Head_v1",
	commitMapName = "SX_Commits_v1",
	lockMapName = "SX_Locks_v1",
	snapshotStoreName = "SX_Snapshot_v1",
	topic = "SX_Commit_v1",

	commitInterval = 0.5,
	maxCommitInterval = 30, -- back off up to this under repeated push failures
	reconcileInterval = 10,
	snapshotInterval = 60,

	commitTtl = 3600,
	headTtl = 3888000, -- MemoryStore max (~45 days)
	lockTtl = 90,

	maxOpsPerCommit = 200,
	maxCommitBytes = 28000, -- under the 32KB MemoryStore value ceiling
	inlineMessageBytes = 700, -- under the 1KB MessagingService ceiling
	snapshotChunkSize = 500, -- ~hundreds of records per chunk keeps values well under 4MB

	classBlacklist = {
		Camera = true,
		Terrain = true, -- Terrain voxels can't be property-synced this way
	},

	syncPlayerCharacters = true,

	debug = false,
}

local Config = {}

Config.defaults = defaults

-- Merge a partial override table into a fresh copy of the defaults.
function Config.resolve(overrides: { [string]: any }?): Config
	local merged = table.clone(defaults) :: any
	if overrides then
		for key, value in pairs(overrides) do
			merged[key] = value
		end
	end
	return merged
end

return Config
