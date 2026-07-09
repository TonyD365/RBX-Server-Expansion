--!strict
--[[
	Codec.luau
	Converts Roblox datatypes to/from a JSON-safe form so property values can
	be serialized into commits (MemoryStore / MessagingService / DataStore all
	require plain tables/scalars).

	Encoding rules:
	  - nil / boolean / number / string  -> stored as-is (unwrapped)
	  - everything else                  -> a tagged table { t = <type>, ... }
	  - Instance references              -> { t = "Ref", id = <SXID> }

	Any unsupported datatype encodes to nil and is skipped by the tracker.
]]

local Identity = require(script.Parent.Identity)

local Codec = {}

-- Encode a single value into a JSON-safe form. Returns (encoded, ok).
function Codec.encode(value: any): (any, boolean)
	local t = typeof(value)

	if value == nil or t == "boolean" or t == "number" or t == "string" then
		return value, true
	elseif t == "CFrame" then
		return { t = "CFrame", c = { value:GetComponents() } }, true
	elseif t == "Vector3" then
		return { t = "Vector3", x = value.X, y = value.Y, z = value.Z }, true
	elseif t == "Vector2" then
		return { t = "Vector2", x = value.X, y = value.Y }, true
	elseif t == "Color3" then
		return { t = "Color3", r = value.R, g = value.G, b = value.B }, true
	elseif t == "BrickColor" then
		return { t = "BrickColor", n = value.Number }, true
	elseif t == "UDim" then
		return { t = "UDim", s = value.Scale, o = value.Offset }, true
	elseif t == "UDim2" then
		return {
			t = "UDim2",
			xs = value.X.Scale,
			xo = value.X.Offset,
			ys = value.Y.Scale,
			yo = value.Y.Offset,
		}, true
	elseif t == "NumberRange" then
		return { t = "NumberRange", min = value.Min, max = value.Max }, true
	elseif t == "EnumItem" then
		return { t = "Enum", e = tostring(value.EnumType), v = value.Value }, true
	elseif t == "Instance" then
		local id = Identity.getId(value)
		if id then
			return { t = "Ref", id = id }, true
		end
		-- Unregistered instance reference: cannot represent cross-server.
		return nil, false
	end

	-- Unsupported datatype (e.g. PhysicalProperties, Faces, ...).
	return nil, false
end

-- Decode a JSON-safe form back into a Roblox datatype.
function Codec.decode(encoded: any): any
	if typeof(encoded) ~= "table" then
		return encoded -- unwrapped scalar / nil
	end

	local t = encoded.t
	if t == "CFrame" then
		return CFrame.new(table.unpack(encoded.c))
	elseif t == "Vector3" then
		return Vector3.new(encoded.x, encoded.y, encoded.z)
	elseif t == "Vector2" then
		return Vector2.new(encoded.x, encoded.y)
	elseif t == "Color3" then
		return Color3.new(encoded.r, encoded.g, encoded.b)
	elseif t == "BrickColor" then
		return BrickColor.new(encoded.n)
	elseif t == "UDim" then
		return UDim.new(encoded.s, encoded.o)
	elseif t == "UDim2" then
		return UDim2.new(encoded.xs, encoded.xo, encoded.ys, encoded.yo)
	elseif t == "NumberRange" then
		return NumberRange.new(encoded.min, encoded.max)
	elseif t == "Enum" then
		-- encoded.e looks like "Enum.Material"; strip the prefix.
		local enumName = string.gsub(encoded.e, "^Enum%.", "")
		local enumType = (Enum :: any)[enumName]
		if enumType then
			for _, item in ipairs(enumType:GetEnumItems()) do
				if item.Value == encoded.v then
					return item
				end
			end
		end
		return nil
	elseif t == "Ref" then
		return Identity.getInstance(encoded.id)
	end

	-- Unknown tag: return as-is so at least raw data round-trips.
	return encoded
end

-- Numbers are compared with a small tolerance because Roblox re-normalizes
-- some datatypes on assignment (notably CFrame), so a value read back after
-- being set is rarely bit-identical to what we wrote. Without this the
-- loop-suppression check would fail and echo the change back out forever.
local EPSILON = 1e-4

-- Compare two encoded values for equality (used by the loop-suppression /
-- dedup logic). Works on the JSON-safe form so it's cheap and type-stable.
function Codec.equal(a: any, b: any): boolean
	if typeof(a) == "number" and typeof(b) == "number" then
		return math.abs(a - b) <= EPSILON
	end
	if typeof(a) ~= "table" or typeof(b) ~= "table" then
		return a == b
	end
	-- Shallow-then-deep compare of the tagged tables.
	for key, valueA in pairs(a) do
		if not Codec.equal(valueA, b[key]) then
			return false
		end
	end
	for key in pairs(b) do
		if a[key] == nil then
			return false
		end
	end
	return true
end

return Codec
