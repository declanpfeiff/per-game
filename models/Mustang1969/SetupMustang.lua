--!strict
-- 1969 Mustang SportsRoof: paint and assemble the imported model
--
-- Run this once after importing Mustang1969.fbx (or .glb) with Studio's 3D
-- Importer: select the imported model, then paste this whole file into the
-- Command Bar (View > Command Bar) and press Enter. If nothing is selected it
-- looks for a model named Mustang1969 in Workspace.
--
-- The importer brings every mesh in grey, so this script:
--   1. colors each part by its name (Body, Stripes, Trim_Chrome, Glass, ...),
--   2. stands the car upright with its front along the model's LookVector,
--   3. scales it to TARGET_LENGTH studs and sets it on whatever is below it,
--   4. welds every part to the body and anchors the car.
-- Running it again is safe.

local Selection = game:GetService("Selection")
local Workspace = game:GetService("Workspace")

local MODEL_NAME = "Mustang1969"
-- Bumper to bumper. The real car is 17.4 studs at Roblox's 1 stud = 0.28 m.
local TARGET_LENGTH = 17.4
-- Set to false if you'll drive it with your own chassis (welds stay in place).
local ANCHORED = true

type Style = {
	color: Color3,
	material: Enum.Material,
	reflectance: number?,
	transparency: number?,
	collide: boolean?,
	shadow: boolean?,
}

local PAINT = Color3.fromRGB(33, 76, 156) -- metallic blue, matched to the photo
local CHROME: Style = { color = Color3.fromRGB(214, 216, 220), material = Enum.Material.SmoothPlastic, reflectance = 0.55 }
local BLACK: Style = { color = Color3.fromRGB(22, 22, 24), material = Enum.Material.SmoothPlastic }

-- Matched against the start of each part's name, longest name first, so
-- "TireLetters_LF" gets TireLetters rather than Tire and "Body_2" gets Body.
local STYLES: { [string]: Style } = {
	Body = { color = PAINT, material = Enum.Material.SmoothPlastic, reflectance = 0.12, collide = true },
	Mirrors = { color = PAINT, material = Enum.Material.SmoothPlastic, reflectance = 0.12 },
	Stripes = { color = Color3.fromRGB(240, 240, 234), material = Enum.Material.SmoothPlastic, reflectance = 0.1 },
	PanelGaps = { color = Color3.fromRGB(12, 14, 22), material = Enum.Material.SmoothPlastic },
	Glass = { color = Color3.fromRGB(60, 72, 78), material = Enum.Material.Glass, transparency = 0.45, shadow = false },
	Trim_Chrome = CHROME,
	Bumpers = CHROME,
	RimChrome = CHROME,
	Trim_Black = BLACK,
	Grille = BLACK,
	Rim = { color = Color3.fromRGB(176, 178, 183), material = Enum.Material.SmoothPlastic, reflectance = 0.3 },
	Tire = { color = Color3.fromRGB(28, 28, 28), material = Enum.Material.Rubber, collide = true },
	TireLetters = { color = Color3.fromRGB(232, 232, 226), material = Enum.Material.SmoothPlastic },
	Headlights = { color = Color3.fromRGB(226, 230, 234), material = Enum.Material.Glass, reflectance = 0.35, transparency = 0.05 },
	Lamps_Red = { color = Color3.fromRGB(170, 16, 16), material = Enum.Material.SmoothPlastic, reflectance = 0.1 },
	Lamps_Amber = { color = Color3.fromRGB(235, 125, 20), material = Enum.Material.SmoothPlastic },
	Plates = { color = Color3.fromRGB(238, 238, 236), material = Enum.Material.SmoothPlastic },
	PlateBorders = { color = Color3.fromRGB(196, 24, 30), material = Enum.Material.SmoothPlastic },
	Interior = { color = Color3.fromRGB(26, 26, 28), material = Enum.Material.Leather },
	Underbody = { color = Color3.fromRGB(20, 20, 21), material = Enum.Material.SmoothPlastic, shadow = false },
}

local prefixes: { string } = {}
for prefix in STYLES do
	table.insert(prefixes, prefix)
end
table.sort(prefixes, function(a, b)
	return #a > #b
end)

local function styleFor(name: string): Style?
	for _, prefix in prefixes do
		if name:sub(1, #prefix) == prefix then
			return STYLES[prefix]
		end
	end
	return nil
end

-- The selected model, or the outermost model around a selected part.
local function findModel(): Model?
	for _, selected in Selection:Get() do
		local model: Model? = nil
		local node: Instance? = selected
		while node and node ~= Workspace and node ~= game do
			if node:IsA("Model") then
				model = node
			end
			node = node.Parent
		end
		if model then
			return model
		end
	end
	local found = Workspace:FindFirstChild(MODEL_NAME, true)
	return if found and found:IsA("Model") then found else nil
end

local model = findModel()
assert(model, "Select the imported Mustang model first (or name it " .. MODEL_NAME .. ").")

local parts: { BasePart } = {}
for _, descendant in model:GetDescendants() do
	if descendant:IsA("BasePart") then
		table.insert(parts, descendant)
	end
end

-- 1. Paint ------------------------------------------------------------------

local painted = 0
local unknown: { string } = {}
for _, part in parts do
	local style = styleFor(part.Name)
	if style then
		part.Color = style.color
		part.Material = style.material
		part.Reflectance = style.reflectance or 0
		part.Transparency = style.transparency or 0
		part.CastShadow = style.shadow ~= false
		part.CanCollide = style.collide == true
		part.CanTouch = style.collide == true
		painted += 1
	else
		table.insert(unknown, part.Name)
	end
	-- Imported materials would cover the colors.
	for _, child in part:GetChildren() do
		if child:IsA("SurfaceAppearance") then
			child:Destroy()
		end
	end
	if part:IsA("MeshPart") then
		part.TextureID = ""
	end
end
assert(painted > 0, "None of the parts have the Mustang's names. Re-import with 'Merge Meshes' turned off.")

-- 2. Stand it up, front along the LookVector ----------------------------------

local function centroid(prefix: string): Vector3
	local sum, count = Vector3.zero, 0
	for _, part in parts do
		if part.Name:sub(1, #prefix) == prefix then
			sum += part.Position
			count += 1
		end
	end
	assert(count > 0, "missing part: " .. prefix)
	return sum / count
end

-- Lowest and highest reach of all the parts along an axis.
local function extent(axis: Vector3): (number, number)
	local low, high = math.huge, -math.huge
	for _, part in parts do
		local cf, half = part.CFrame, part.Size / 2
		local reach = math.abs(cf.RightVector:Dot(axis)) * half.X
			+ math.abs(cf.UpVector:Dot(axis)) * half.Y
			+ math.abs(cf.LookVector:Dot(axis)) * half.Z
		local center = cf.Position:Dot(axis)
		low = math.min(low, center - reach)
		high = math.max(high, center + reach)
	end
	return low, high
end

local front = (centroid("Headlights") - centroid("Lamps_Red")).Unit
local up = centroid("Glass") - centroid("Tire")
up = (up - front * up:Dot(front)).Unit
local right = front:Cross(up)

local frontLow, frontHigh = extent(front)
local upLow = extent(up)
local rightLow, rightHigh = extent(right)
-- Pivot at the ground under the middle of the car.
local base = front * ((frontLow + frontHigh) / 2) + up * upLow + right * ((rightLow + rightHigh) / 2)

local primary: BasePart = parts[1]
for _, part in parts do
	local size, best = part.Size, primary.Size
	if styleFor(part.Name) == STYLES.Body and size.X * size.Y * size.Z > best.X * best.Y * best.Z then
		primary = part
	end
end
model.PrimaryPart = primary
model.WorldPivot = CFrame.fromMatrix(base, right, up, -front)

local heading = Vector3.new(front.X, 0, front.Z)
heading = if heading.Magnitude > 0.1 then heading.Unit else Vector3.new(0, 0, -1)
model:PivotTo(CFrame.lookAt(base, base + heading))

-- 3. Scale and set down -------------------------------------------------------

local length = frontHigh - frontLow
if math.abs(TARGET_LENGTH / length - 1) > 1e-3 then
	model:ScaleTo(model:GetScale() * TARGET_LENGTH / length)
end

local pivot = model:GetPivot()
local params = RaycastParams.new()
params.FilterType = Enum.RaycastFilterType.Exclude
params.FilterDescendantsInstances = { model }
local hit = Workspace:Raycast(pivot.Position + Vector3.new(0, 10, 0), Vector3.new(0, -200, 0), params)
if hit then
	model:PivotTo(pivot + Vector3.new(0, hit.Position.Y - pivot.Position.Y, 0))
end

-- 4. Weld and anchor ------------------------------------------------------------

for _, part in parts do
	for _, child in part:GetChildren() do
		if child:IsA("WeldConstraint") and child.Name == "MustangWeld" then
			child:Destroy()
		end
	end
	part.Anchored = ANCHORED
	part.Massless = part ~= primary
	if part ~= primary then
		local weld = Instance.new("WeldConstraint")
		weld.Name = "MustangWeld"
		weld.Part0 = primary
		weld.Part1 = part
		weld.Parent = part
	end
end

print(("%s: painted %d parts, %.1f studs long, welded to %s."):format(
	model.Name,
	painted,
	TARGET_LENGTH,
	primary.Name
))
if #unknown > 0 then
	warn("Left unpainted (names not recognised): " .. table.concat(unknown, ", "))
end
