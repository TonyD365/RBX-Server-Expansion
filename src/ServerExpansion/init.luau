--!strict
--[[
	ServerExpansion
	Cross-server world synchronization for Roblox, with a git-like update model.

	Multiple servers in one experience share a single world: any changed
	instance under the sync root (default: workspace) -- and only changed ones --
	is captured as a versioned commit, pushed to a shared log, and applied by
	every other server in version order. Conflicts resolve to the latest version.

	Usage (a single Server Script is enough):

		local ServerExpansion = require(game.ServerScriptService.ServerExpansion)
		ServerExpansion.start()          -- sync the whole workspace

		-- or with overrides:
		ServerExpansion.start({
			getSyncRoot = function() return workspace.SharedWorld end,
			debug = true,
		})

	Everything runs on the server only. See README.md for the full model,
	limits, and how to test across servers.
]]

local RunService = game:GetService("RunService")

local Config = require(script.Config)
local Identity = require(script.Identity)
local Schema = require(script.Schema)
local Applier = require(script.Applier)
local ChangeTracker = require(script.ChangeTracker)
local Repository = require(script.Repository)
local Replicator = require(script.Replicator)

local ServerExpansion = {}

-- Sub-modules exposed for advanced use (e.g. Schema.extend to sync more props).
ServerExpansion.Schema = Schema
ServerExpansion.Identity = Identity
ServerExpansion.Repository = Repository

local activeConfig: any = nil

-- Start syncing. Safe to call once; subsequent calls are ignored.
-- `overrides` is an optional partial Config table.
function ServerExpansion.start(overrides: { [string]: any }?)
	if not RunService:IsServer() then
		error("ServerExpansion.start() must be called from the server", 2)
	end
	if activeConfig then
		warn("[ServerExpansion] already started; ignoring extra start()")
		return activeConfig
	end

	local config = Config.resolve(overrides)
	local root = config.getSyncRoot()
	assert(typeof(root) == "Instance", "getSyncRoot must return an Instance")

	Identity.setAttributeName(config.idAttribute)
	Applier.configure(root, config.debug)
	ChangeTracker.configure(root, config.classBlacklist, config.syncPlayerCharacters, config.debug)
	Replicator.start(config)

	activeConfig = config
	return config
end

-- Current synchronized version this server has caught up to.
function ServerExpansion.getVersion(): number
	return Replicator.getLocalHead()
end

return ServerExpansion
