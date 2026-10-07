--!strict
-- CinematicDirector
-- ModuleScript at ReplicatedStorage > Modules > CinematicDirector
--
-- Plays a client-side cutscene from a list of shots. Shots are framed
-- relative to an anchor (the character's mark), so they look the same
-- wherever the set is built. Each shot can cut or blend in, move the camera
-- (dolly, crane, orbit, zoom), add handheld shake, grade the image, focus on
-- the subject, show subtitles or a title card, play sounds, pose the face and
-- walk the character. Everything the cutscene changes is put back afterwards.

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

export type Grade = {
	Brightness: number?,
	Contrast: number?,
	Saturation: number?,
	TintColor: Color3?,
}

export type FacialState = {
	HunterEyes: number?, -- 0..1 brow drop + squint
	HollowCheeks: number?, -- 0..1 flat pucker + lip suck (approximation)
	MewingPosture: number?, -- 0..1 chin raise + lips pressed + head tilt
	Duration: number?, -- seconds to ease into the pose
}

export type TrackKeyframe = {
	Duration: number,
	Transition: ("Cut" | "Blend")?, -- default "Cut"
	BlendTime: number?, -- Blend only; default min(1, Duration)

	-- Camera position: Offset is in anchor space (+X right, +Y up from the
	-- floor, -Z the way the character faces). PositionPart is a fixed world
	-- position and wins over Offset.
	Offset: Vector3?,
	EndOffset: Vector3?, -- camera travels from Offset to EndOffset
	Orbit: number?, -- degrees the camera swings around the character
	PositionPart: BasePart?,

	LookAtPart: BasePart?, -- default: the character's Head
	LookAtOffset: Vector3?, -- world-space nudge for the look target

	FOV: number?, -- nil keeps the previous shot's FOV
	EndFOV: number?, -- zoom to this over the shot
	Roll: number?, -- degrees
	Shake: number?, -- handheld shake, 0..1
	Ease: Enum.EasingStyle?, -- easing of the camera move; default Sine

	Subtitle: string?,
	Title: string?, -- large centered title card
	VignetteIntensity: number?, -- 0..1; nil keeps the previous value
	Focus: (number | "Subject")?, -- depth of field; "Subject" keeps the look target sharp
	FocusRadius: number?, -- studs kept sharp; default scales with distance
	Grade: Grade?, -- color grade; nil keeps the previous grade

	FacialState: FacialState?,
	SoundId: string?,
	SoundVolume: number?,
	WalkTo: Vector3?, -- anchor space; the character walks here during the shot
	WalkSpeed: number?,
}

export type DirectorOptions = {
	TargetCharacter: Model?,
	Mark: CFrame?, -- the character is moved here behind the opening fade
	AllowSkip: boolean?,
	HoldSkipDuration: number?,
	FadeIn: number?,
	FadeOut: number?,
	MusicId: string?,
	MusicVolume: number?,
	HideCoreGui: boolean?, -- default true
}

local RENDER_STEP_NAME = "CinematicDirectorCamera"
local DEFAULT_FADE = 0.6
local SKIP_FADE = 0.3
local SUBTITLE_TYPE_SPEED = 45 -- graphemes per second
local SUBTITLE_FADE = 0.25
local TITLE_FADE = 1.2
local LETTERBOX_ASPECT = 2.39
local VIGNETTE_LAYERS = 7
local VIGNETTE_LAYER_ALPHA = 0.22
local SHAKE_DEGREES = 2
local LOOK_DISTANCE = 10 -- default look target distance when there is no subject

-- FacialState control -> { FaceControls property = scale }. FaceControls has
-- no lid-tightener or cheek-suck pose, so the squint is a partial eye close
-- and HollowCheeks is approximated with a flat pucker and a lower-lip suck.
local FACIAL_MAP: { [string]: { [string]: number } } = {
	HunterEyes = { LeftBrowLowerer = 1, RightBrowLowerer = 1, LeftEyeClosed = 0.35, RightEyeClosed = 0.35 },
	HollowCheeks = { FlatPucker = 1, LowerLipSuck = 1 },
	MewingPosture = { ChinRaiser = 1, LipsTogether = 1 },
}
-- Chin lift applied to the R15 neck so MewingPosture also reads on classic heads.
local MEWING_NECK_TILT = math.rad(9)

type GradeValues = {
	Brightness: number,
	Contrast: number,
	Saturation: number,
	TintColor: Color3,
}

local NEUTRAL_GRADE: GradeValues = {
	Brightness = 0,
	Contrast = 0,
	Saturation = 0,
	TintColor = Color3.new(1, 1, 1),
}

type ShotState = {
	keyframe: TrackKeyframe,
	start: number,
	duration: number,
	blendTime: number?,
	fromCFrame: CFrame,
	fromFOV: number,
	fov: number,
	endFOV: number,
	fromVignette: number,
	toVignette: number,
	fromGrade: GradeValues,
	toGrade: GradeValues,
	graphemes: number,
	typeSubtitle: boolean,
}

type Ui = {
	Gui: ScreenGui,
	Fade: Frame,
	TopBar: Frame,
	BottomBar: Frame,
	Subtitle: TextLabel,
	Title: TextLabel,
	TitleScale: UIScale,
	VignetteStrokes: { UIStroke },
	SkipButton: TextButton?,
	SkipFill: Frame?,
}

type Saved = {
	CameraType: Enum.CameraType,
	CameraSubject: Instance?,
	FieldOfView: number,
	CoreGui: { [Enum.CoreGuiType]: boolean },
	PromptsEnabled: boolean,
	WalkSpeed: number?,
	NeckC0: CFrame?,
	Face: { [string]: number },
}

local CinematicDirector = {}
CinematicDirector.__index = CinematicDirector

type DirectorFields = {
	_shots: { TrackKeyframe },
	_options: DirectorOptions,
	_character: Model?,
	_humanoid: Humanoid?,
	_head: BasePart?,
	_neck: Motor6D?,
	_anchor: CFrame,
	_state: "Idle" | "Playing" | "Done",
	_stopped: boolean,
	_started: number,
	_connections: { RBXScriptConnection },
	_instances: { Instance },
	_tweens: { Tween },
	_walked: boolean,
	_visibleParts: { BasePart },
	_visibleDecals: { Decal },
	_controls: any,
	_saved: Saved?,
	_ui: Ui?,
	_depthOfField: DepthOfFieldEffect?,
	_colorCorrection: ColorCorrectionEffect?,
	_music: Sound?,
	_shot: ShotState?,
	_vignette: number,
	_grade: GradeValues,
	_subtitleText: string,
}

export type CinematicDirector = typeof(setmetatable({} :: DirectorFields, CinematicDirector))

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

local function ease(alpha: number, style: Enum.EasingStyle?): number
	return TweenService:GetValue(math.clamp(alpha, 0, 1), style or Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
end

local function lerpGrade(from: GradeValues, to: GradeValues, t: number): GradeValues
	return {
		Brightness = lerp(from.Brightness, to.Brightness, t),
		Contrast = lerp(from.Contrast, to.Contrast, t),
		Saturation = lerp(from.Saturation, to.Saturation, t),
		TintColor = from.TintColor:Lerp(to.TintColor, t),
	}
end

local function resolveGrade(grade: Grade): GradeValues
	return {
		Brightness = grade.Brightness or 0,
		Contrast = grade.Contrast or 0,
		Saturation = grade.Saturation or 0,
		TintColor = grade.TintColor or Color3.new(1, 1, 1),
	}
end

local function getControls(): any
	local playerScripts = Players.LocalPlayer:FindFirstChild("PlayerScripts")
	local playerModule = playerScripts and playerScripts:FindFirstChild("PlayerModule")
	if not playerModule or not playerModule:IsA("ModuleScript") then
		return nil
	end
	local ok, module = pcall(require, playerModule)
	if ok and type(module) == "table" and module.GetControls then
		return module:GetControls()
	end
	return nil
end

-- Height of the root part's center above the floor when standing.
local function rootHeight(humanoid: Humanoid, root: BasePart): number
	if humanoid.RigType == Enum.HumanoidRigType.R15 then
		return humanoid.HipHeight + root.Size.Y / 2
	end
	return 3 -- R6: 2-stud legs plus half the torso
end

local function handheld(time: number, amount: number): CFrame
	local a = math.rad(SHAKE_DEGREES) * amount
	return CFrame.Angles(
		math.noise(time * 0.9, 11.3) * a,
		math.noise(time * 0.7, 47.1) * a,
		math.noise(time * 0.5, 83.9) * a * 0.5
	)
end

local function tween(instance: Instance, seconds: number, goals: { [string]: any }, style: Enum.EasingStyle?): Tween
	local info = TweenInfo.new(seconds, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local created = TweenService:Create(instance, info, goals)
	created:Play()
	return created
end

local function waitFor(seconds: number)
	local finish = os.clock() + seconds
	while os.clock() < finish do
		task.wait()
	end
end

function CinematicDirector.new(shots: { TrackKeyframe }, options: DirectorOptions?): CinematicDirector
	local self: DirectorFields = {
		_shots = shots,
		_options = options or {},
		_character = nil,
		_humanoid = nil,
		_head = nil,
		_neck = nil,
		_anchor = CFrame.identity,
		_state = "Idle",
		_stopped = false,
		_started = 0,
		_connections = {},
		_instances = {},
		_tweens = {},
		_walked = false,
		_visibleParts = {},
		_visibleDecals = {},
		_controls = nil,
		_saved = nil,
		_ui = nil,
		_depthOfField = nil,
		_colorCorrection = nil,
		_music = nil,
		_shot = nil,
		_vignette = 0,
		_grade = NEUTRAL_GRADE,
		_subtitleText = "",
	}
	return setmetatable(self, CinematicDirector)
end

-- Ends the cutscene early; Play() returns once everything is restored.
function CinematicDirector.Stop(self: CinematicDirector)
	self._stopped = true
end

-- Yields until the cutscene finishes, is skipped, or the character dies.
function CinematicDirector.Play(self: CinematicDirector)
	if self._state ~= "Idle" then
		return
	end
	self._state = "Playing"

	local ok, err = pcall(function()
		self:_setup()
		for _, keyframe in self._shots do
			if self._stopped then
				break
			end
			self:_runShot(keyframe)
		end
	end)

	self:_finish()
	self._state = "Done"
	if not ok then
		error(err, 0)
	end
end

function CinematicDirector._buildUi(self: CinematicDirector): Ui
	local camera = Workspace.CurrentCamera
	local viewport = camera.ViewportSize
	local aspect = if viewport.Y > 0 then viewport.X / viewport.Y else 16 / 9
	local barHeight = math.clamp((1 - aspect / LETTERBOX_ASPECT) / 2, 0.06, 0.14)

	local gui = Instance.new("ScreenGui")
	gui.Name = "CinematicDirectorGui"
	gui.IgnoreGuiInset = true
	gui.ScreenInsets = Enum.ScreenInsets.None
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 100
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	-- Stacked rounded strokes, each drawn outside a shrinking frame, add up to
	-- a soft radial vignette without needing an image asset.
	local vignette = Instance.new("Frame")
	vignette.Name = "Vignette"
	vignette.BackgroundTransparency = 1
	vignette.Size = UDim2.fromScale(1, 1)
	vignette.Parent = gui
	local strokes: { UIStroke } = {}
	for i = 1, VIGNETTE_LAYERS do
		local t = (i - 1) / (VIGNETTE_LAYERS - 1)
		local layer = Instance.new("Frame")
		layer.Name = "Layer" .. i
		layer.AnchorPoint = Vector2.new(0.5, 0.5)
		layer.Position = UDim2.fromScale(0.5, 0.5)
		layer.Size = UDim2.fromScale(lerp(1.3, 0.8, t), lerp(1.45, 0.9, t))
		layer.BackgroundTransparency = 1
		layer.Parent = vignette

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0.5, 0)
		corner.Parent = layer

		local stroke = Instance.new("UIStroke")
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		stroke.BorderStrokePosition = Enum.BorderStrokePosition.Outer
		stroke.Color = Color3.new(0, 0, 0)
		stroke.Thickness = 4000
		stroke.Transparency = 1
		stroke.Parent = layer
		table.insert(strokes, stroke)
	end

	local function bar(name: string, top: boolean): Frame
		local frame = Instance.new("Frame")
		frame.Name = name
		frame.BackgroundColor3 = Color3.new(0, 0, 0)
		frame.BorderSizePixel = 0
		frame.AnchorPoint = if top then Vector2.new(0, 0) else Vector2.new(0, 1)
		frame.Position = if top then UDim2.fromScale(0, 0) else UDim2.fromScale(0, 1)
		frame.Size = UDim2.fromScale(1, barHeight)
		frame.Visible = false -- shown once the opening fade is black
		frame.ZIndex = 2
		frame.Parent = gui
		return frame
	end
	local topBar = bar("TopBar", true)
	local bottomBar = bar("BottomBar", false)

	local subtitle = Instance.new("TextLabel")
	subtitle.Name = "Subtitle"
	subtitle.BackgroundTransparency = 1
	subtitle.AnchorPoint = Vector2.new(0.5, 0.5)
	subtitle.Position = UDim2.fromScale(0.5, 1 - barHeight / 2)
	subtitle.Size = UDim2.fromScale(0.8, barHeight * 0.55)
	subtitle.Font = Enum.Font.GothamMedium
	subtitle.TextColor3 = Color3.fromRGB(240, 240, 240)
	subtitle.TextScaled = true
	subtitle.Text = ""
	subtitle.ZIndex = 3
	subtitle.Parent = gui
	local subtitleSize = Instance.new("UITextSizeConstraint")
	subtitleSize.MaxTextSize = 28
	subtitleSize.Parent = subtitle

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.AnchorPoint = Vector2.new(0.5, 0.5)
	title.Position = UDim2.fromScale(0.5, 0.5)
	title.Size = UDim2.fromScale(0.85, 0.12)
	title.Font = Enum.Font.GothamBlack
	title.TextColor3 = Color3.new(1, 1, 1)
	title.TextScaled = true
	title.TextTransparency = 1
	title.TextStrokeColor3 = Color3.new(0, 0, 0)
	title.TextStrokeTransparency = 1
	title.Text = ""
	title.ZIndex = 3
	title.Parent = gui
	local titleSize = Instance.new("UITextSizeConstraint")
	titleSize.MaxTextSize = 72
	titleSize.Parent = title
	local titleScale = Instance.new("UIScale")
	titleScale.Parent = title

	local skipButton: TextButton? = nil
	local skipFill: Frame? = nil
	if self._options.AllowSkip then
		local button = Instance.new("TextButton")
		button.Name = "SkipButton"
		button.AutoButtonColor = false
		button.AnchorPoint = Vector2.new(1, 0.5)
		button.Position = UDim2.new(1, -16, barHeight / 2, 0)
		button.Size = UDim2.fromOffset(170, 30)
		button.BackgroundColor3 = Color3.fromRGB(25, 25, 25)
		button.BackgroundTransparency = 0.35
		button.Font = Enum.Font.GothamMedium
		button.TextColor3 = Color3.new(1, 1, 1)
		button.TextSize = 14
		button.Text = if UserInputService.KeyboardEnabled then "Hold [Space] to skip" else "Hold to skip"
		button.Visible = false
		button.ZIndex = 3
		button.Parent = gui

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 6)
		corner.Parent = button

		local fill = Instance.new("Frame")
		fill.Name = "Fill"
		fill.BackgroundColor3 = Color3.new(1, 1, 1)
		fill.BackgroundTransparency = 0.75
		fill.BorderSizePixel = 0
		fill.Size = UDim2.fromScale(0, 1)
		fill.Parent = button
		corner:Clone().Parent = fill

		skipButton = button
		skipFill = fill
	end

	-- The fade sits above everything else.
	local fade = Instance.new("Frame")
	fade.Name = "Fade"
	fade.BackgroundColor3 = Color3.new(0, 0, 0)
	fade.BackgroundTransparency = 1
	fade.BorderSizePixel = 0
	fade.Size = UDim2.fromScale(1, 1)
	fade.ZIndex = 10
	fade.Parent = gui

	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	return {
		Gui = gui,
		Fade = fade,
		TopBar = topBar,
		BottomBar = bottomBar,
		Subtitle = subtitle,
		Title = title,
		TitleScale = titleScale,
		VignetteStrokes = strokes,
		SkipButton = skipButton,
		SkipFill = skipFill,
	}
end

function CinematicDirector._bindSkipInput(self: CinematicDirector, ui: Ui)
	local skipButton = ui.SkipButton
	local fill = ui.SkipFill
	if not skipButton or not fill then
		return
	end

	local holdDuration = self._options.HoldSkipDuration or 1
	local keyHeld = false
	local pointerHeld = false
	local heldFor = 0

	local function isSkipKey(input: InputObject): boolean
		return input.KeyCode == Enum.KeyCode.Space or input.KeyCode == Enum.KeyCode.ButtonA
	end
	local function isPointer(input: InputObject): boolean
		return input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
	end

	table.insert(
		self._connections,
		UserInputService.InputBegan:Connect(function(input, gameProcessed)
			if not gameProcessed and isSkipKey(input) then
				keyHeld = true
			end
		end)
	)
	table.insert(
		self._connections,
		UserInputService.InputEnded:Connect(function(input)
			if isSkipKey(input) then
				keyHeld = false
			elseif isPointer(input) then
				pointerHeld = false
			end
		end)
	)
	table.insert(
		self._connections,
		skipButton.InputBegan:Connect(function(input)
			if isPointer(input) then
				pointerHeld = true
			end
		end)
	)
	table.insert(
		self._connections,
		RunService.Heartbeat:Connect(function(dt)
			if keyHeld or pointerHeld then
				heldFor += dt
			else
				heldFor = 0
			end
			fill.Size = UDim2.fromScale(math.clamp(heldFor / holdDuration, 0, 1), 1)
			if heldFor >= holdDuration then
				self:Stop()
			end
		end)
	)
end

function CinematicDirector._setup(self: CinematicDirector)
	local options = self._options
	local camera = Workspace.CurrentCamera

	local character = options.TargetCharacter
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = humanoid and humanoid.RootPart
	local head = character and character:FindFirstChild("Head")
	self._character = character
	self._humanoid = humanoid
	self._head = if head and head:IsA("BasePart") then head else nil
	if humanoid and humanoid.RigType == Enum.HumanoidRigType.R15 and head then
		local neck = head:FindFirstChild("Neck")
		self._neck = if neck and neck:IsA("Motor6D") then neck else nil
	end

	local saved: Saved = {
		CameraType = camera.CameraType,
		CameraSubject = camera.CameraSubject,
		FieldOfView = camera.FieldOfView,
		CoreGui = {},
		PromptsEnabled = ProximityPromptService.Enabled,
		WalkSpeed = humanoid and humanoid.WalkSpeed,
		NeckC0 = self._neck and self._neck.C0,
		Face = {},
	}
	self._saved = saved

	-- Freeze the camera where it is and take the player's input away.
	camera.CameraType = Enum.CameraType.Scriptable
	self._controls = getControls()
	if self._controls then
		self._controls:Disable()
	end
	ProximityPromptService.Enabled = false
	if options.HideCoreGui ~= false then
		for _, coreGuiType in Enum.CoreGuiType:GetEnumItems() do
			if coreGuiType ~= Enum.CoreGuiType.All then
				local ok, enabled = pcall(function()
					return StarterGui:GetCoreGuiEnabled(coreGuiType)
				end)
				if ok then
					saved.CoreGui[coreGuiType] = enabled
				end
			end
		end
		pcall(function()
			StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.All, false)
		end)
	end

	if humanoid then
		table.insert(
			self._connections,
			humanoid.Died:Connect(function()
				self:Stop()
			end)
		)
	end
	if character then
		for _, descendant in character:GetDescendants() do
			if descendant:IsA("BasePart") then
				table.insert(self._visibleParts, descendant)
			elseif descendant:IsA("Decal") then
				table.insert(self._visibleDecals, descendant)
			end
		end
	end

	local depthOfField = Instance.new("DepthOfFieldEffect")
	depthOfField.Name = "CinematicDepthOfField"
	depthOfField.Enabled = false
	depthOfField.FarIntensity = 0.45
	depthOfField.NearIntensity = 0.4
	depthOfField.Parent = camera
	self._depthOfField = depthOfField
	table.insert(self._instances, depthOfField)

	local colorCorrection = Instance.new("ColorCorrectionEffect")
	colorCorrection.Name = "CinematicGrade"
	colorCorrection.Parent = camera
	self._colorCorrection = colorCorrection
	table.insert(self._instances, colorCorrection)

	local ui = self:_buildUi()
	self._ui = ui
	table.insert(self._instances, ui.Gui)
	self:_bindSkipInput(ui)

	-- Fade out of gameplay, then put the character on its mark unseen.
	tween(ui.Fade, 0.35, { BackgroundTransparency = 0 })
	waitFor(0.35)
	ui.TopBar.Visible = true
	ui.BottomBar.Visible = true
	if ui.SkipButton then
		ui.SkipButton.Visible = true
	end

	if root and humanoid then
		local height = rootHeight(humanoid, root)
		if options.Mark then
			self._anchor = options.Mark
			if character then
				character:PivotTo(options.Mark * CFrame.new(0, height, 0))
			end
			root.AssemblyLinearVelocity = Vector3.zero
		else
			local look = root.CFrame.LookVector
			local flat = Vector3.new(look.X, 0, look.Z)
			if flat.Magnitude < 1e-3 then
				flat = Vector3.new(0, 0, -1)
			end
			local floor = root.Position - Vector3.new(0, height, 0)
			self._anchor = CFrame.lookAt(floor, floor + flat)
		end
	elseif options.Mark then
		self._anchor = options.Mark
	end

	if options.MusicId and options.MusicId ~= "" then
		local music = Instance.new("Sound")
		music.Name = "CinematicMusic"
		music.SoundId = options.MusicId
		music.Looped = true
		music.Volume = 0
		music.Parent = SoundService
		music:Play()
		self:_tween(music, 1.5, { Volume = options.MusicVolume or 0.5 }, Enum.EasingStyle.Linear)
		self._music = music
		table.insert(self._instances, music)
	end

	self._started = os.clock()
	RunService:BindToRenderStep(RENDER_STEP_NAME, Enum.RenderPriority.Camera.Value + 1, function()
		self:_update()
	end)

	tween(ui.Fade, options.FadeIn or DEFAULT_FADE, { BackgroundTransparency = 1 }, Enum.EasingStyle.Sine)
end

-- Tweens started during the shots; _finish cancels them so none can
-- overwrite what it restores.
function CinematicDirector._tween(
	self: CinematicDirector,
	instance: Instance,
	seconds: number,
	goals: { [string]: any },
	style: Enum.EasingStyle?
)
	table.insert(self._tweens, tween(instance, seconds, goals, style))
end

function CinematicDirector._applyFacialState(self: CinematicDirector, state: FacialState)
	local saved = self._saved :: Saved
	local seconds = state.Duration or 0.5
	local character = self._character
	local faceControls = character and character:FindFirstChildWhichIsA("FaceControls", true)
	if faceControls then
		local goals: { [string]: number } = {}
		for control, properties in FACIAL_MAP do
			local weight = (state :: any)[control]
			if type(weight) == "number" then
				for property, scale in properties do
					local ok, current = pcall(function()
						return (faceControls :: any)[property]
					end)
					if ok and type(current) == "number" then
						if saved.Face[property] == nil then
							saved.Face[property] = current
						end
						goals[property] = math.clamp(weight * scale, 0, 1)
					end
				end
			end
		end
		if next(goals) then
			self:_tween(faceControls, seconds, goals, Enum.EasingStyle.Sine)
		end
	end

	local neck = self._neck
	if neck and saved.NeckC0 and state.MewingPosture then
		local tilt = MEWING_NECK_TILT * math.clamp(state.MewingPosture, 0, 1)
		self:_tween(neck, seconds, { C0 = saved.NeckC0 * CFrame.Angles(tilt, 0, 0) }, Enum.EasingStyle.Sine)
	end
end

function CinematicDirector._playSound(self: CinematicDirector, soundId: string, volume: number?)
	local sound = Instance.new("Sound")
	sound.SoundId = soundId
	sound.Volume = volume or 0.8
	sound.Parent = SoundService
	table.insert(self._instances, sound)
	sound:Play()
end

function CinematicDirector._runShot(self: CinematicDirector, keyframe: TrackKeyframe)
	local camera = Workspace.CurrentCamera
	local ui = self._ui :: Ui
	local previous = self._shot
	local duration = math.max(keyframe.Duration, 0.05)
	local blend = previous ~= nil and keyframe.Transition == "Blend"

	local fov = keyframe.FOV or camera.FieldOfView
	local subtitle = keyframe.Subtitle or ""
	local shot: ShotState = {
		keyframe = keyframe,
		start = os.clock(),
		duration = duration,
		blendTime = if blend then math.min(keyframe.BlendTime or 1, duration) else nil,
		fromCFrame = camera.CFrame,
		fromFOV = camera.FieldOfView,
		fov = fov,
		endFOV = keyframe.EndFOV or fov,
		fromVignette = self._vignette,
		toVignette = keyframe.VignetteIntensity or self._vignette,
		fromGrade = self._grade,
		toGrade = if keyframe.Grade then resolveGrade(keyframe.Grade) else self._grade,
		graphemes = utf8.len(subtitle) or #subtitle,
		typeSubtitle = subtitle ~= self._subtitleText,
	}

	-- Subtitles: type out new lines, fade out when a shot has none.
	if subtitle == "" then
		if self._subtitleText ~= "" then
			self:_tween(ui.Subtitle, SUBTITLE_FADE, { TextTransparency = 1 })
		end
	elseif shot.typeSubtitle then
		ui.Subtitle.Text = subtitle
		ui.Subtitle.TextTransparency = 0
		ui.Subtitle.MaxVisibleGraphemes = 0
	end
	self._subtitleText = subtitle

	if keyframe.Title then
		ui.Title.Text = keyframe.Title
		ui.TitleScale.Scale = 1.08
		self:_tween(ui.Title, TITLE_FADE, { TextTransparency = 0, TextStrokeTransparency = 0.6 }, Enum.EasingStyle.Sine)
		self:_tween(ui.TitleScale, duration, { Scale = 1 }, Enum.EasingStyle.Sine)
	end

	local depthOfField = self._depthOfField
	if depthOfField then
		depthOfField.Enabled = keyframe.Focus ~= nil
	end

	if keyframe.FacialState then
		self:_applyFacialState(keyframe.FacialState)
	end
	if keyframe.SoundId and keyframe.SoundId ~= "" then
		self:_playSound(keyframe.SoundId, keyframe.SoundVolume)
	end
	local humanoid = self._humanoid
	if keyframe.WalkTo and humanoid then
		if keyframe.WalkSpeed then
			humanoid.WalkSpeed = keyframe.WalkSpeed
		end
		humanoid:MoveTo((self._anchor:PointToWorldSpace(keyframe.WalkTo)))
		self._walked = true
	end

	self._shot = shot
	self:_update()

	while not self._stopped and os.clock() - shot.start < duration do
		task.wait()
	end
end

function CinematicDirector._update(self: CinematicDirector)
	local shot = self._shot
	if not shot then
		return
	end
	local keyframe = shot.keyframe
	local camera = Workspace.CurrentCamera
	local now = os.clock()
	local elapsed = now - shot.start
	local progress = ease(elapsed / shot.duration, keyframe.Ease)

	-- Where the camera is.
	local position: Vector3
	if keyframe.PositionPart then
		position = keyframe.PositionPart.Position
	else
		local startOffset = keyframe.Offset or Vector3.new(0, 5, 12)
		local offset = startOffset:Lerp(keyframe.EndOffset or startOffset, progress)
		if keyframe.Orbit then
			offset = CFrame.Angles(0, math.rad(keyframe.Orbit * progress), 0) * offset
		end
		position = self._anchor:PointToWorldSpace(offset)
	end

	-- What it looks at.
	local lookPart = keyframe.LookAtPart or self._head
	local target = if lookPart
		then lookPart.Position + (keyframe.LookAtOffset or Vector3.zero)
		else position + self._anchor.LookVector * LOOK_DISTANCE
	local fov = lerp(shot.fov, shot.endFOV, progress)

	-- Cuts land instantly. Blends carry the camera across while it stays
	-- aimed at the subject, so the subject never drifts out of frame.
	local look = 1
	if shot.blendTime then
		look = ease(elapsed / shot.blendTime)
		position = shot.fromCFrame.Position:Lerp(position, look)
		fov = lerp(shot.fromFOV, fov, look)
	end

	local cframe = if (target - position).Magnitude > 1e-3 then CFrame.lookAt(position, target) else CFrame.new(position)
	if keyframe.Shake and keyframe.Shake > 0 then
		cframe *= handheld(now - self._started, keyframe.Shake)
	end
	cframe *= CFrame.Angles(0, 0, math.rad(keyframe.Roll or 0))
	camera.CFrame = cframe
	camera.FieldOfView = fov
	camera.Focus = CFrame.new(target)

	self:_setVignette(lerp(shot.fromVignette, shot.toVignette, look))
	self._grade = lerpGrade(shot.fromGrade, shot.toGrade, look)
	local colorCorrection = self._colorCorrection
	if colorCorrection then
		colorCorrection.Brightness = self._grade.Brightness
		colorCorrection.Contrast = self._grade.Contrast
		colorCorrection.Saturation = self._grade.Saturation
		colorCorrection.TintColor = self._grade.TintColor
	end

	local depthOfField = self._depthOfField
	local focus = keyframe.Focus
	if depthOfField and focus then
		local distance = if type(focus) == "number" then focus else (target - cframe.Position).Magnitude
		depthOfField.FocusDistance = distance
		depthOfField.InFocusRadius = keyframe.FocusRadius or math.max(1.5, distance * 0.3)
	end

	local ui = self._ui
	if ui and shot.typeSubtitle then
		ui.Subtitle.MaxVisibleGraphemes = math.min(math.floor(elapsed * SUBTITLE_TYPE_SPEED), shot.graphemes)
	end

	-- Camera scripts fade the character out when the camera gets close
	-- (or the player was in first person); keep it visible for the shot.
	for _, part in self._visibleParts do
		part.LocalTransparencyModifier = 0
	end
	for _, decal in self._visibleDecals do
		decal.LocalTransparencyModifier = 0
	end
end

function CinematicDirector._setVignette(self: CinematicDirector, intensity: number)
	self._vignette = intensity
	local ui = self._ui
	if not ui then
		return
	end
	local transparency = 1 - math.clamp(intensity, 0, 1) * VIGNETTE_LAYER_ALPHA
	for _, stroke in ui.VignetteStrokes do
		stroke.Transparency = transparency
	end
end

function CinematicDirector._finish(self: CinematicDirector)
	local ui = self._ui
	local fadeOut = if self._stopped then SKIP_FADE else self._options.FadeOut or DEFAULT_FADE
	for _, running in self._tweens do
		running:Cancel()
	end
	table.clear(self._tweens)

	-- Fade to black while the last shot keeps running underneath.
	if ui then
		tween(ui.Fade, fadeOut, { BackgroundTransparency = 0 }, Enum.EasingStyle.Sine)
	end
	local music = self._music
	if music then
		tween(music, fadeOut, { Volume = 0 }, Enum.EasingStyle.Linear)
	end
	if ui then
		waitFor(fadeOut)
	end

	pcall(function()
		RunService:UnbindFromRenderStep(RENDER_STEP_NAME)
	end)
	self._shot = nil
	for _, connection in self._connections do
		connection:Disconnect()
	end
	table.clear(self._connections)

	local camera = Workspace.CurrentCamera
	local humanoid = self._humanoid
	local saved = self._saved
	if saved then
		camera.CameraType = if saved.CameraType == Enum.CameraType.Scriptable
			then Enum.CameraType.Custom
			else saved.CameraType
		camera.CameraSubject = humanoid or saved.CameraSubject
		camera.FieldOfView = saved.FieldOfView
		ProximityPromptService.Enabled = saved.PromptsEnabled
		for coreGuiType, enabled in saved.CoreGui do
			pcall(function()
				StarterGui:SetCoreGuiEnabled(coreGuiType, enabled)
			end)
		end
		if humanoid then
			if saved.WalkSpeed then
				humanoid.WalkSpeed = saved.WalkSpeed
			end
			local root = humanoid.RootPart
			if self._walked and root and humanoid.Health > 0 then
				humanoid:MoveTo(root.Position) -- cancel a walk cut short by a skip
			end
		end
		local character = self._character
		local faceControls = character and character:FindFirstChildWhichIsA("FaceControls", true)
		if faceControls and next(saved.Face) then
			tween(faceControls, 0.4, saved.Face)
		end
		if self._neck and saved.NeckC0 then
			self._neck.C0 = saved.NeckC0
		end
	end
	if self._controls then
		self._controls:Enable()
	end

	-- Back to gameplay from black.
	if ui then
		ui.TopBar.Visible = false
		ui.BottomBar.Visible = false
		ui.Subtitle.Visible = false
		ui.Title.Visible = false
		if ui.SkipButton then
			ui.SkipButton.Visible = false
		end
		self:_setVignette(0)
		tween(ui.Fade, 0.5, { BackgroundTransparency = 1 }, Enum.EasingStyle.Sine)
	end
	if self._depthOfField then
		self._depthOfField.Enabled = false
	end
	if self._colorCorrection then
		self._colorCorrection.Enabled = false
	end

	local instances = self._instances
	self._instances = {}
	task.delay(0.5, function()
		for _, instance in instances do
			instance:Destroy()
		end
	end)
end

return CinematicDirector
