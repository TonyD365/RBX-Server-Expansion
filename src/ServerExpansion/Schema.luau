--!strict
--[[
	Schema.luau
	Luau cannot reflect the full property list of an arbitrary Instance at
	runtime, so we maintain an explicit, extensible whitelist of which
	properties to sync per class group.

	Groups are keyed by a class name that is tested with Instance:IsA(), so
	inheritance is handled automatically: a Part matches "BasePart", "Part",
	and "Instance", and the union of their property lists is synced.

	Extend at runtime with Schema.extend(className, { "PropA", "PropB" }).
]]

local Schema = {}

-- className -> array of property names. Order does not matter. Being generous
-- here is safe: getProps() drops any name the instance can't actually read, and
-- the Codec drops any value it can't serialize, so an over-broad list simply
-- syncs whatever is possible and ignores the rest.
local GROUPS: { [string]: { string } } = {
	Instance = { "Name" },

	--== Geometry ==--
	BasePart = {
		"CFrame", "Size", "Color", "Material", "MaterialVariant", "Transparency",
		"Reflectance", "Anchored", "CanCollide", "CanTouch", "CanQuery",
		"CastShadow", "Massless", "CollisionGroup", "RootPriority",
		"AssemblyLinearVelocity", "AssemblyAngularVelocity",
		"TopSurface", "BottomSurface", "FrontSurface", "BackSurface",
		"LeftSurface", "RightSurface",
	},
	Part = { "Shape" },
	MeshPart = { "MeshId", "TextureID", "DoubleSided", "RenderFidelity", "CollisionFidelity" },
	UnionOperation = { "UsePartColor" },
	SpawnLocation = { "Enabled", "Neutral", "TeamColor", "Duration", "AllowTeamChangeOnTouch" },
	Seat = { "Disabled" },
	VehicleSeat = { "Disabled", "Throttle", "Steer", "MaxSpeed", "Torque", "TurnSpeed", "HeadsUpDisplay" },

	DataModelMesh = { "Scale", "Offset", "VertexColor" },
	SpecialMesh = { "MeshId", "TextureId", "MeshType" },

	--== Models / characters ==--
	Model = { "PrimaryPart" },
	Humanoid = {
		"Health", "MaxHealth", "WalkSpeed", "JumpPower", "JumpHeight", "UseJumpPower",
		"DisplayName", "HipHeight", "AutoRotate", "Sit", "PlatformStand",
		"NameDisplayDistance", "HealthDisplayDistance",
	},
	Clothing = { "Color3" }, -- Shirt/Pants add their template below
	Shirt = { "ShirtTemplate" },
	Pants = { "PantsTemplate" },
	ShirtGraphic = { "Graphic", "Color3" },
	BodyColors = {
		"HeadColor3", "LeftArmColor3", "RightArmColor3",
		"LeftLegColor3", "RightLegColor3", "TorsoColor3",
	},
	CharacterMesh = { "MeshId", "BaseTextureId", "OverlayTextureId", "BodyPart" },

	--== Surface appearance ==--
	Decal = { "Texture", "Color3", "Transparency", "Face", "ZIndex" },
	Texture = { "Texture", "Color3", "Transparency", "Face", "StudsPerTileU", "StudsPerTileV", "OffsetStudsU", "OffsetStudsV" },

	--== Lights ==--
	Light = { "Brightness", "Color", "Enabled", "Shadows" },
	PointLight = { "Range" },
	SpotLight = { "Range", "Angle", "Face" },
	SurfaceLight = { "Range", "Angle", "Face" },

	--== Sound ==--
	Sound = {
		"SoundId", "Volume", "Playing", "Looped", "PlaybackSpeed", "TimePosition",
		"RollOffMode", "RollOffMinDistance", "RollOffMaxDistance",
	},

	--== Effects ==--
	Fire = { "Enabled", "Heat", "Size", "Color", "SecondaryColor" },
	Smoke = { "Enabled", "Color", "Opacity", "RiseVelocity", "Size" },
	Sparkles = { "Enabled", "SparkleColor" },
	ParticleEmitter = {
		"Enabled", "Rate", "Lifetime", "Speed", "Color", "Texture", "Transparency",
		"Size", "Rotation", "RotSpeed", "Acceleration", "Drag", "LightEmission",
		"LightInfluence", "LockedToPart", "EmissionDirection", "Brightness",
		"ZOffset", "Squash", "TimeScale", "SpreadAngle",
	},
	Beam = {
		"Attachment0", "Attachment1", "Color", "Enabled", "Width0", "Width1",
		"Transparency", "Texture", "TextureSpeed", "TextureLength", "FaceCamera",
		"Segments", "Brightness", "LightEmission", "LightInfluence",
		"CurveSize0", "CurveSize1", "ZOffset",
	},
	Trail = {
		"Attachment0", "Attachment1", "Color", "Enabled", "Lifetime", "Transparency",
		"Texture", "TextureLength", "TextureMode", "WidthScale", "FaceCamera",
		"LightEmission", "LightInfluence", "MinLength", "MaxLength", "Brightness",
	},
	Highlight = {
		"Adornee", "FillColor", "OutlineColor", "FillTransparency",
		"OutlineTransparency", "Enabled", "DepthMode",
	},

	--== Attachments / constraints / joints ==--
	Attachment = { "CFrame", "Visible" },
	Constraint = { "Enabled", "Visible", "Color", "Attachment0", "Attachment1" },
	WeldConstraint = { "Enabled", "Part0", "Part1" },
	NoCollisionConstraint = { "Enabled", "Part0", "Part1" },
	JointInstance = { "Part0", "Part1", "C0", "C1", "Enabled" },
	Motor6D = { "Transform" },
	RopeConstraint = { "Length", "Thickness", "Restitution", "WinchEnabled", "WinchSpeed", "WinchTarget" },
	SpringConstraint = { "FreeLength", "Stiffness", "Damping", "MaxForce", "Radius", "Coils" },
	HingeConstraint = { "TargetAngle", "AngularSpeed", "ActuatorType", "LimitsEnabled", "UpperAngle", "LowerAngle" },
	PrismaticConstraint = { "TargetPosition", "Speed", "ActuatorType", "LimitsEnabled", "UpperLimit", "LowerLimit" },
	AlignPosition = { "Position", "MaxForce", "Responsiveness", "ApplyAtCenterOfMass", "Mode", "RigidityEnabled" },
	AlignOrientation = { "CFrame", "MaxTorque", "Responsiveness", "Mode", "RigidityEnabled", "PrimaryAxisOnly" },

	--== Interaction ==--
	ClickDetector = { "MaxActivationDistance", "CursorIcon" },
	ProximityPrompt = {
		"ActionText", "ObjectText", "Enabled", "HoldDuration", "MaxActivationDistance",
		"RequiresLineOfSight", "KeyboardKeyCode", "GamepadKeyCode", "ClickablePrompt",
		"Exclusivity", "UIOffset",
	},

	--== Value objects (IntValue/StringValue/ObjectValue/...) ==--
	ValueBase = { "Value" },

	--== GUI ==--
	GuiObject = {
		"Position", "Size", "Visible", "BackgroundColor3", "BackgroundTransparency",
		"BorderColor3", "BorderSizePixel", "BorderMode", "AnchorPoint", "Rotation",
		"ZIndex", "LayoutOrder", "ClipsDescendants", "Active", "AutomaticSize",
	},
	TextLabel = { "Text", "TextColor3", "TextSize", "Font", "FontFace", "TextScaled", "TextWrapped", "TextTransparency", "TextStrokeColor3", "TextStrokeTransparency", "RichText", "TextXAlignment", "TextYAlignment", "LineHeight" },
	TextButton = { "Text", "TextColor3", "TextSize", "Font", "FontFace", "TextScaled", "TextWrapped", "TextTransparency", "RichText", "TextXAlignment", "TextYAlignment", "AutoButtonColor" },
	TextBox = { "Text", "PlaceholderText", "PlaceholderColor3", "TextColor3", "TextSize", "Font", "FontFace", "ClearTextOnFocus", "MultiLine", "TextEditable" },
	ImageLabel = { "Image", "ImageColor3", "ImageTransparency", "ScaleType", "SliceCenter", "TileSize", "ResampleMode" },
	ImageButton = { "Image", "ImageColor3", "ImageTransparency", "ScaleType", "SliceCenter", "TileSize", "AutoButtonColor" },
	ScrollingFrame = { "CanvasSize", "CanvasPosition", "ScrollBarThickness", "ScrollBarImageColor3", "ScrollingDirection", "AutomaticCanvasSize" },
	SurfaceGui = { "Enabled", "Face", "Adornee", "SizingMode", "CanvasSize", "PixelsPerStud", "LightInfluence", "Brightness", "AlwaysOnTop" },
	BillboardGui = { "Enabled", "Size", "StudsOffset", "StudsOffsetWorldSpace", "Adornee", "MaxDistance", "LightInfluence", "AlwaysOnTop", "ExtentsOffset" },

	--== UI helpers (UICorner/UIStroke/UIGradient/layouts/...) ==--
	UICorner = { "CornerRadius" },
	UIStroke = { "Color", "Thickness", "Transparency", "Enabled", "LineJoinMode", "ApplyStrokeMode" },
	UIGradient = { "Color", "Transparency", "Rotation", "Offset", "Enabled" },
	UIGridStyleLayout = { "FillDirection", "HorizontalAlignment", "VerticalAlignment", "SortOrder" },
	UIListLayout = { "Padding", "ItemLineAlignment", "Wraps" },
	UIGridLayout = { "CellSize", "CellPadding", "FillDirectionMaxCells", "StartCorner" },
	UIPadding = { "PaddingTop", "PaddingBottom", "PaddingLeft", "PaddingRight" },
	UIScale = { "Scale" },
	UIAspectRatioConstraint = { "AspectRatio", "AspectType", "DominantAxis" },
	UISizeConstraint = { "MinSize", "MaxSize" },
	UITextSizeConstraint = { "MinTextSize", "MaxTextSize" },
}

-- Base classes we consider "part of the world" and therefore track. Anything
-- not matching one of these (Scripts, RemoteEvents, cameras, etc.) is ignored
-- so we don't try to replicate things that make no sense cross-server.
local TRACKABLE_BASECLASSES = {
	"BasePart",
	"Model",
	"Folder",
	"Light",
	"Decal",
	"Texture",
	"DataModelMesh",
	"Humanoid",
	"Clothing",
	"ShirtGraphic",
	"BodyColors",
	"CharacterMesh",
	"Accessory",
	"Accoutrement",
	"Tool",
	"Sound",
	"Fire",
	"Smoke",
	"Sparkles",
	"ParticleEmitter",
	"Beam",
	"Trail",
	"Highlight",
	"Attachment",
	"Constraint",
	"WeldConstraint",
	"NoCollisionConstraint",
	"JointInstance",
	"ClickDetector",
	"ProximityPrompt",
	"ValueBase",
	"GuiObject",
	"LayerCollector",
	"UIComponent",
}

-- Global custom property names, checked against EVERY tracked instance
-- regardless of class. If the instance actually exposes the property it is
-- synced; if not, it is silently ignored for that instance. Use this to sync a
-- property the built-in schema doesn't list, without caring about class.
local CUSTOM_PROPS: { string } = {}

-- Register one or more property names to try on every instance.
function Schema.addCustom(props: { string })
	for _, prop in ipairs(props) do
		if not table.find(CUSTOM_PROPS, prop) then
			table.insert(CUSTOM_PROPS, prop)
		end
	end
end

-- Should this instance be tracked/synced at all?
function Schema.isTrackable(instance: Instance): boolean
	for _, className in ipairs(TRACKABLE_BASECLASSES) do
		local ok, isA = pcall(function()
			return instance:IsA(className)
		end)
		if ok and isA then
			return true
		end
	end
	return false
end

-- Return the union of property names to sync for the given instance, filtered
-- to those the instance actually exposes.
function Schema.getProps(instance: Instance): { string }
	local seen: { [string]: boolean } = {}
	local result: { string } = {}
	for className, props in pairs(GROUPS) do
		local ok, isA = pcall(function()
			return instance:IsA(className)
		end)
		if ok and isA then
			for _, prop in ipairs(props) do
				if not seen[prop] then
					-- Confirm the property is really readable on this instance.
					local readable = pcall(function()
						return (instance :: any)[prop]
					end)
					if readable then
						seen[prop] = true
						table.insert(result, prop)
					end
				end
			end
		end
	end

	-- Global custom props: include any this specific instance actually exposes.
	for _, prop in ipairs(CUSTOM_PROPS) do
		if not seen[prop] then
			local readable = pcall(function()
				return (instance :: any)[prop]
			end)
			if readable then
				seen[prop] = true
				table.insert(result, prop)
			end
		end
	end

	return result
end

-- Add or replace the property list for a class group.
function Schema.extend(className: string, props: { string })
	GROUPS[className] = props
end

-- Merge extra props into an existing group (creating it if absent).
function Schema.add(className: string, props: { string })
	local existing = GROUPS[className]
	if not existing then
		GROUPS[className] = table.clone(props)
		return
	end
	for _, prop in ipairs(props) do
		if not table.find(existing, prop) then
			table.insert(existing, prop)
		end
	end
end

return Schema
