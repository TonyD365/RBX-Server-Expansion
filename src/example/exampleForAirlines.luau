--!strict
local ServerExpansion = require(script.Parent.ServerExpansion)

ServerExpansion.start({
    commitInterval = 0.2,      -- 飞机建议用 0.15~0.25
    debug = true,              -- 先开着调试，看日志
    -- getSyncRoot = function() return workspace:WaitForChild("FlightWorld") end,  -- 可选：只同步某个文件夹
})

print("✅ RBX Server Expansion 已启动，用于飞机同步")
