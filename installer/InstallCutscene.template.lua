-- Cinematic Cutscene installer (template)
--
-- tools/build.luau inlines each script source into the matching placeholder
-- string in SOURCES and writes installer/InstallCutscene.lua. Edit this file
-- or src/, then rebuild; don't edit the generated file by hand.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local StarterPlayer = game:GetService("StarterPlayer")
local Workspace = game:GetService("Workspace")

-- Where the set is built. Offset from the world origin so it doesn't overlap
-- the default SpawnLocation. The character faces -Z on the pad.
local ORIGIN = Vector3.new(0, 0, -30)

local SOURCES = {
	CinematicDirector = "{{src/ReplicatedStorage/Modules/CinematicDirector.lua}}",
	CutsceneTriggerServer = "{{src/ServerScriptService/CutsceneTriggerServer.server.lua}}",
	CutsceneClient = "{{src/StarterPlayer/StarterPlayerScripts/CutsceneClient.client.lua}}",
}

local function ensure(parent: Instance, className: string, name: string): (Instance, boolean)
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA(className) then
		return existing, false
	end
	local instance = Instance.new(className)
	instance.Name = name
	instance.Parent = parent
	return instance, true
end

local function replaceScript(parent: Instance, className: string, name: string, source: string)
	local existing = parent:FindFirstChild(name)
	if existing then
		existing:Destroy()
	end
	local newScript = Instance.new(className) :: any
	newScript.Name = name
	newScript.Source = source
	newScript.Parent = parent
end

local function block(parent: Instance, name: string, size: Vector3, offset: Vector3, color: Color3, material: Enum.Material): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.Size = size
	part.CFrame = CFrame.new(ORIGIN + offset)
	part.Color = color
	part.Material = material
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

-- 1. The set (kept if it already exists, so Studio edits survive a re-run)
local set, setCreated = ensure(Workspace, "Model", "CutsceneSet")
if setCreated then
	local concrete = Color3.fromRGB(55, 55, 62)
	local accent = Color3.fromRGB(255, 60, 60)

	block(set, "Floor", Vector3.new(26, 0.2, 34), Vector3.new(0, 0.1, -5), Color3.fromRGB(38, 38, 44), Enum.Material.Slate)

	for _, x in { -9, 9 } do
		for _, z in { 6, -6 } do
			block(set, "Pillar", Vector3.new(2, 18, 2), Vector3.new(x, 9.2, z), concrete, Enum.Material.Concrete)
			local inner = x - math.sign(x) * 1.15
			local strip = block(set, "Strip", Vector3.new(0.3, 16, 0.3), Vector3.new(inner, 9.2, z), accent, Enum.Material.Neon)
			strip.CastShadow = false
			local light = Instance.new("PointLight")
			light.Color = accent
			light.Brightness = 1.2
			light.Range = 10
			light.Parent = strip
		end
	end

	-- The doorway the character walks into at the end.
	block(set, "DoorPost", Vector3.new(1.5, 13, 1.5), Vector3.new(-3.5, 6.7, -20), concrete, Enum.Material.Concrete)
	block(set, "DoorPost", Vector3.new(1.5, 13, 1.5), Vector3.new(3.5, 6.7, -20), concrete, Enum.Material.Concrete)
	block(set, "Lintel", Vector3.new(8.5, 1.5, 1.5), Vector3.new(0, 13.95, -20), concrete, Enum.Material.Concrete)
	local void = block(set, "Shadow", Vector3.new(5.5, 13, 0.4), Vector3.new(0, 6.7, -20.6), Color3.new(0, 0, 0), Enum.Material.SmoothPlastic)
	void.CastShadow = false
	block(set, "BackWall", Vector3.new(40, 24, 1), Vector3.new(0, 12.2, -21.5), Color3.fromRGB(30, 30, 35), Enum.Material.Concrete)
end

-- 2. Trigger pad (the character's mark) with a ProximityPrompt
local trigger, triggerCreated = ensure(Workspace, "Part", "CutsceneTriggerPart")
if triggerCreated then
	local part = trigger :: Part
	part.Size = Vector3.new(5, 0.4, 5)
	part.CFrame = CFrame.new(ORIGIN + Vector3.new(0, 0.4, 0))
	part.Anchored = true
	part.Color = Color3.fromRGB(255, 50, 50)
	part.Material = Enum.Material.Neon
	part.TopSurface = Enum.SurfaceType.Smooth
	part:SetAttribute("TouchTrigger", false)
	part:SetAttribute("Cooldown", 3)
	part:SetAttribute("MaxDuration", 45)
end

local prompt, promptCreated = ensure(trigger, "ProximityPrompt", "ProximityPrompt")
if promptCreated then
	local proximityPrompt = prompt :: ProximityPrompt
	proximityPrompt.ActionText = "Start Cutscene"
	proximityPrompt.ObjectText = "Cinematic Engine"
	proximityPrompt.HoldDuration = 0.5
	proximityPrompt.RequiresLineOfSight = false
end

-- 3. RemoteEvents
local remoteFolder = ensure(ReplicatedStorage, "Folder", "RemoteEvents")
ensure(remoteFolder, "RemoteEvent", "PlayCutscene")
ensure(remoteFolder, "RemoteEvent", "CutsceneFinished")

-- 4. Scripts (always replaced, so a re-run picks up new code)
local modulesFolder = ensure(ReplicatedStorage, "Folder", "Modules")
replaceScript(modulesFolder, "ModuleScript", "CinematicDirector", SOURCES.CinematicDirector)
replaceScript(ServerScriptService, "Script", "CutsceneTriggerServer", SOURCES.CutsceneTriggerServer)
replaceScript(
	ensure(StarterPlayer, "StarterPlayerScripts", "StarterPlayerScripts"),
	"LocalScript",
	"CutsceneClient",
	SOURCES.CutsceneClient
)

if Workspace:FindFirstChild("CutsceneNodes") then
	print("Workspace.CutsceneNodes is no longer used by the cutscene; delete it if you don't need it.")
end
print("✅ Cinematic cutscene installed. Press Play (F5), walk to the red pad and hold E.")
