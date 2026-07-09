--!strict
--[[
	DemoClient.luau  (place as a LocalScript in StarterPlayerScripts)

	Smooths the ~1s stepped CFrame updates of cross-server-synced anchored parts
	so remote objects/avatars glide instead of teleporting each replication tick.

	Pair it with the server-side ServerExpansion.start(); this is purely visual
	and runs entirely on the local client.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Adjust this path to wherever you place the module on the client. A common
-- setup is to copy ClientInterpolator into ReplicatedStorage so clients can
-- require it.
local ClientInterpolator = require(ReplicatedStorage:WaitForChild("ClientInterpolator"))

ClientInterpolator.start({
	speed = 12, -- higher = snappier, lower = smoother/laggier
})
