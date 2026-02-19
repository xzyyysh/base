--[[
    XyzHub Evade Features
    by xzyyysh
    
    Credits to Moun Sok Dara for making these methods possible
    and for open sourcing the code. respectfully, only using
    the features that matter to me.
    
    Why Rayfield UI library?
    - kinda lightweight and better for easy-to-use
    - clean + modern interface without bloat
    - makes more sense than a heavy framework
    - faster load times and better FPS ingame
]]

local Rayfield = loadstring(game:HttpGet('https://sirius.menu/rayfield'))()

local Window = Rayfield:CreateWindow({
   Name = "Evade Features",
   Icon = 0,
   LoadingTitle = "Loading Features",
   LoadingSubtitle = "by xzyyysh",
   Theme = "Default",
   DisableRayfieldPrompts = false,
   DisableBuildWarnings = false,
   ConfigurationSaving = {
      Enabled = true,
      FolderName = nil,
      FileName = "XyzHubEvade"
   },
   Discord = {
      Enabled = false,
      Invite = "noinvitelink",
      RememberJoins = true
   },
   KeySystem = false,
   KeySettings = {
      Title = "Untitled",
      Subtitle = "Key System",
      Note = "No method of obtaining the key is provided",
      FileName = "Key",
      SaveKey = true,
      GrabKeyFromSite = false,
      Key = {"Hello"}
   }
})

local AutoTab = Window:CreateTab("Auto Features", "zap")
local MovementTab = Window:CreateTab("Movement", "wind")
local VisualsTab = Window:CreateTab("Visuals", "eye")

local ButtonLib = loadstring(game:HttpGet("https://raw.githubusercontent.com/xzyyysh/base/refs/heads/main/Button-lib.lua"))()

Players = game:GetService("Players")
RunService = game:GetService("RunService")
UserInputService = game:GetService("UserInputService")
Debris = game:GetService("Debris")
ReplicatedStorage = game:GetService("ReplicatedStorage")
player = Players.LocalPlayer
PlayerGui = player:WaitForChild("PlayerGui")
camera = workspace.CurrentCamera

featureStates = {
   AutoCarry = false,
   Bhop = false,
   BhopHold = false,
   FastRevive = false,
   FastReviveMethod = "Interact"
}

--[[ ========================================
     AUTO CARRY FEATURE
     ======================================== ]]

function startAutoCarry()
AutoCarryConnection = RunService.Heartbeat:Connect(function()
if not featureStates.AutoCarry then return end
local char = player.Character
local hrp = char and char:FindFirstChild("HumanoidRootPart")
if hrp then
for _, other in ipairs(Players:GetPlayers()) do
if other ~= player and other.Character and other.Character:FindFirstChild("HumanoidRootPart") then
local dist = (hrp.Position - other.Character.HumanoidRootPart.Position).Magnitude
if dist <= 20 then
local args = { "Carry", [3] = other.Name }
pcall(function()
game:GetService("ReplicatedStorage"):WaitForChild("Events"):WaitForChild("Character"):WaitForChild("Interact"):FireServer(unpack(args))
end)
task.wait(0.01)
end
end
end
end
end)
end

function stopAutoCarry()
if AutoCarryConnection then
AutoCarryConnection:Disconnect()
AutoCarryConnection = nil
end
end

if ButtonLib and ButtonLib.Create then
   _G.DarahubLibBtn = _G.DarahubLibBtn or {}
   _G.DarahubLibBtn.AutoCarry = ButtonLib.Create:Toggle({
      Text = "Auto Carry",
      Flag = "AutoCarry",
      Visible = false,
      Callback = function(state)
         if AutoCarryToggle then
            AutoCarryToggle:Set(state)
         end
      end
   })
   _G.DarahubLibBtn.AutoCarry.Position = UDim2.new(0.5, -125, 0.3, 0)
end

local AutoCarryToggle = AutoTab:CreateToggle({
   Name = "Auto Carry",
   CurrentValue = false,
   Flag = "AutoCarryToggle",
   Callback = function(state)
      featureStates.AutoCarry = state
      if state then
         startAutoCarry()
      else
         stopAutoCarry()
      end
   end
})

local ShowAutoCarryButton = AutoTab:CreateToggle({
   Name = "Show Auto Carry Button",
   CurrentValue = false,
   Flag = "ShowAutoCarryButton",
   Callback = function(state)
      if _G.DarahubLibBtn and _G.DarahubLibBtn.AutoCarry then
         _G.DarahubLibBtn.AutoCarry.Visible = state
      end
   end
})

--[[ ========================================
     FAST REVIVE FEATURE
     ======================================== ]]

local reviveRange = 10
local loopDelay = 0.15
local reviveLoopHandle = nil
local interactEvent = ReplicatedStorage:WaitForChild("Events"):WaitForChild("Character"):WaitForChild("Interact")

function isPlayerDowned(pl)
   if not pl or not pl.Character then return false end
   local char = pl.Character
   local humanoid = char:FindFirstChild("Humanoid")
   if humanoid and humanoid.Health <= 0 then
      return true
   end
   if char.GetAttribute and char:GetAttribute("Downed") == true then
      return true
   end
   return false
end

function startAutoRevive()
   if featureStates.FastReviveMethod == "Auto" then
      if reviveLoopHandle then return end
      reviveLoopHandle = task.spawn(function()
         while featureStates.FastRevive do
            local LocalPlayer = Players.LocalPlayer
            if LocalPlayer and LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart") then
               local myHRP = LocalPlayer.Character.HumanoidRootPart
               for _, pl in ipairs(Players:GetPlayers()) do
                  if pl ~= LocalPlayer then
                     local char = pl.Character
                     if char and char:FindFirstChild("HumanoidRootPart") then
                        if isPlayerDowned(pl) then
                           local hrp = char.HumanoidRootPart
                           local success, dist = pcall(function()
                              return (myHRP.Position - hrp.Position).Magnitude
                           end)
                           if success and dist and dist <= reviveRange then
                              pcall(function()
                                 interactEvent:FireServer("Revive", true, pl.Name)
                              end)
                           end
                        end
                     end
                  end
               end
            end
            task.wait(loopDelay)
         end
         reviveLoopHandle = nil
      end)
   elseif featureStates.FastReviveMethod == "Interact" then
      if not featureStates.interactHookActive then
         local localPlayer = Players.LocalPlayer
         local eventsFolder = localPlayer.PlayerScripts:WaitForChild("Events")
         local tempEventsFolder = eventsFolder:WaitForChild("temporary_events")
         local useKeybind = tempEventsFolder:WaitForChild("UseKeybind")
         local connection = useKeybind.Event:Connect(function(...)
            local args = {...}
            if args[1] and type(args[1]) == "table" then
               local keyData = args[1]
               if keyData.Key == "Interact" and keyData.Down == true and featureStates.FastRevive then
                  function reviveAllPlayers()
                     local ohString1 = "Revive"
                     local ohBoolean2 = true
                     for _, player in pairs(Players:GetPlayers()) do
                        if player ~= localPlayer then
                           local ohString3 = player.Name
                           pcall(function()
                              interactEvent:FireServer(ohString1, ohBoolean2, ohString3)
                           end)
                        end
                     end
                  end
                  task.spawn(reviveAllPlayers)
               end
            end
         end)
         featureStates.interactConnection = connection
         featureStates.interactHookActive = true
      end
   end
end

function stopAutoRevive()
   if reviveLoopHandle then
      task.cancel(reviveLoopHandle)
      reviveLoopHandle = nil
   end
   if featureStates.interactHookActive then
      if featureStates.interactConnection then
         featureStates.interactConnection:Disconnect()
         featureStates.interactConnection = nil
      end
      featureStates.interactHookActive = false
   end
end

local FastReviveToggle = AutoTab:CreateToggle({
   Name = "Fast Revive",
   CurrentValue = false,
   Flag = "FastReviveToggle",
   Callback = function(state)
      featureStates.FastRevive = state
      if state then
         startAutoRevive()
      else
         stopAutoRevive()
      end
   end
})

local FastReviveMethodDropdown = AutoTab:CreateDropdown({
   Name = "Fast Revive Method",
   Options = {"Auto", "Interact"},
   CurrentOption = {"Interact"},
   MultipleOptions = false,
   Flag = "FastReviveMethodDropdown",
   Callback = function(options)
      featureStates.FastReviveMethod = options[1]
      stopAutoRevive()
      if featureStates.FastReviveMethod == "Interact" then
         featureStates.interactHookActive = false
      end
      if featureStates.FastRevive then
         startAutoRevive()
      end
   end
})


--[[ ========================================
     EASY TRIMP FEATURE
     ======================================== ]]

getgenv().EasyTrimp = {
   Enabled = false,
   BaseSpeed = 50,
   ExtraSpeed = 100,
   FloorDrop = 0
}

extra = getgenv().EasyTrimp.ExtraSpeed
floorDrop = getgenv().EasyTrimp.FloorDrop
last = tick()
airTick = 0
airSum = 0
airborne = false
push = nil
speed = getgenv().EasyTrimp.BaseSpeed
allow = false

function cut(n)
return math.floor(n*10)/10
end

function meter()
   ok, v = pcall(function()
      return player.PlayerGui.Shared.HUD.Overlay.Default.CharacterInfo.Item.Speedometer.Players
   end)
   if ok then return v end
end

RunService.RenderStepped:Connect(function()
   dt = tick() - last
   last = tick()

   ch = player.Character
if not ch then return end

hrp = ch:FindFirstChild("HumanoidRootPart")
hum = ch:FindFirstChild("Humanoid")
if not hrp or not hum then return end

spd = meter()
inAir = hum.FloorMaterial == Enum.Material.Air

if airborne and not inAir then
speed = math.max(getgenv().EasyTrimp.BaseSpeed - floorDrop, speed - 10)
if spd then spd.Text = cut(speed) end
airSum = 0
end
airborne = inAir

if getgenv().EasyTrimp.Enabled then
if inAir then
airSum += dt
airTick += dt
while airTick >= 0.04 do
airTick -= 0.04
add = math.max(0.1, 2.5 * (0.04 / 1))
speed = math.min(getgenv().EasyTrimp.BaseSpeed + extra, speed + add)
end
else
airTick = 0
airSum = 0
speed = math.max(getgenv().EasyTrimp.BaseSpeed - floorDrop, speed - (2.5 * dt))
end

if push then push:Destroy() end

look = camera.CFrame.LookVector
moveDir = Vector3.new(look.X, 0, look.Z)
if moveDir.Magnitude > 0 then moveDir = moveDir.Unit end

bv = Instance.new("BodyVelocity")
bv.Velocity = moveDir * speed
bv.MaxForce = Vector3.new(4e5, 0, 4e5)
bv.P = 1250
bv.Parent = hrp
Debris:AddItem(bv, 0.1)
push = bv

allow = true
if spd then spd.Text = cut(speed) end
else
if push then push:Destroy() push = nil end
speed = getgenv().EasyTrimp.BaseSpeed
allow = false
airTick = 0
airSum = 0
airborne = false
end
end)

MovementTab:CreateSection("Easy Trimp")

if ButtonLib and ButtonLib.Create then
   _G.DarahubLibBtn = _G.DarahubLibBtn or {}
   _G.DarahubLibBtn.EasyTrimp = ButtonLib.Create:Toggle({
      Text = "Easy Trimp",
      Flag = "EasyTrimp",
      Visible = false,
      Callback = function(state)
         if EasyTrimpToggle then
            EasyTrimpToggle:Set(state)
         end
      end
   })
   _G.DarahubLibBtn.EasyTrimp.Position = UDim2.new(0.5, -125, 0.4, 0)
end

local EasyTrimpToggle = MovementTab:CreateToggle({
   Name = "Easy Trimp",
   CurrentValue = false,
   Flag = "EasyTrimpToggle",
   Callback = function(state)
      getgenv().EasyTrimp.Enabled = state
   end
})

local ShowEasyTrimpButton = MovementTab:CreateToggle({
   Name = "Show Easy Trimp Button",
   CurrentValue = false,
   Flag = "ShowEasyTrimpButton",
   Callback = function(state)
      if _G.DarahubLibBtn and _G.DarahubLibBtn.EasyTrimp then
         _G.DarahubLibBtn.EasyTrimp.Visible = state
      end
   end
})

local BaseSpeedInput = MovementTab:CreateInput({
   Name = "Base Speed",
   CurrentValue = "50",
   PlaceholderText = "50",
   RemoveTextAfterFocusLost = false,
   Flag = "EasyTrimpBaseSpeed",
   Callback = function(value)
      local num = tonumber(value)
      if num then
         getgenv().EasyTrimp.BaseSpeed = num
         speed = num
      end
   end
})

local ExtraSpeedInput = MovementTab:CreateInput({
   Name = "Extra Speed",
   CurrentValue = "100",
   PlaceholderText = "100",
   RemoveTextAfterFocusLost = false,
   Flag = "EasyTrimpExtraSpeed",
   Callback = function(value)
      local num = tonumber(value)
      if num then
         getgenv().EasyTrimp.ExtraSpeed = num
         extra = num
      end
   end
})

local FloorDropInput = MovementTab:CreateInput({
   Name = "Floor Drop",
   CurrentValue = "0",
   PlaceholderText = "0",
   RemoveTextAfterFocusLost = false,
   Flag = "EasyTrimpFloorDrop",
   Callback = function(value)
      local num = tonumber(value)
      if num then
         getgenv().EasyTrimp.FloorDrop = num
         floorDrop = num
      end
   end
})


--[[ ========================================
     BHOP/SPEED SYSTEM FEATURE
     ======================================== ]]

getgenv().bhopMode = "Acceleration"
getgenv().bhopAccelValue = -0.5
getgenv().bhopHoldActive = false
getgenv().autoJumpEnabled = false
getgenv().autoJumpType = "Bounce"
getgenv().jumpCooldown = 0.7

isMobile = UserInputService.TouchEnabled

bhopConnection = nil
bhopLoaded = false
characterConnection = nil
frictionTables = {}

Character = nil
Humanoid = nil
HumanoidRootPart = nil
LastJump = 0

GROUND_CHECK_DISTANCE = 3.5
MAX_SLOPE_ANGLE = 45
AIR_RANGE = 0.1

findFrictionTables = function()
frictionTables = {}
for _, t in pairs(getgc(true)) do
if type(t) == "table" and rawget(t, "Friction") then
table.insert(frictionTables, {obj = t, original = t.Friction})
end
end
end

setFriction = function(value)
for _, e in ipairs(frictionTables) do
if e.obj and type(e.obj) == "table" and rawget(e.obj, "Friction") then
e.obj.Friction = value
end
end
end

resetBhopFriction = function()
for _, e in ipairs(frictionTables) do
if e.obj and type(e.obj) == "table" and rawget(e.obj, "Friction") then
e.obj.Friction = e.original
end
end
frictionTables = {}
end

applyBhopFriction = function()
if getgenv().bhopMode == "Acceleration" then
findFrictionTables()
if #frictionTables > 0 then
setFriction(getgenv().bhopAccelValue or -0.5)
end
else
resetBhopFriction()
end
end

IsOnGround = function()
if not Character or not HumanoidRootPart or not Humanoid then return false end

state = Humanoid:GetState()
if state == Enum.HumanoidStateType.Jumping or 
state == Enum.HumanoidStateType.Freefall or
state == Enum.HumanoidStateType.Swimming then
return false
end

raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Blacklist
raycastParams.FilterDescendantsInstances = {Character}
raycastParams.IgnoreWater = true

rayOrigin = HumanoidRootPart.Position
rayDirection = Vector3.new(0, -GROUND_CHECK_DISTANCE, 0)
raycastResult = workspace:Raycast(rayOrigin, rayDirection, raycastParams)

if not raycastResult then return false end

surfaceNormal = raycastResult.Normal
angle = math.deg(math.acos(surfaceNormal:Dot(Vector3.new(0, 1, 0))))

return angle <= MAX_SLOPE_ANGLE
end

updateBhop = function()
if not bhopLoaded then return end

character = player.Character
humanoid = character and character:FindFirstChild("Humanoid")
if not character or not humanoid then
return
end

isBhopActive = getgenv().autoJumpEnabled or getgenv().bhopHoldActive

if isBhopActive then
now = tick()
if IsOnGround() and (now - LastJump) > getgenv().jumpCooldown then
if getgenv().autoJumpType == "Realistic" then
game:GetService("Players").LocalPlayer.PlayerScripts.Events.temporary_events.JumpReact:Fire()
task.wait(0.1)
game:GetService("Players").LocalPlayer.PlayerScripts.Events.temporary_events.EndJump:Fire()
else
humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
end
LastJump = now
end
end
end

loadBhop = function()
if bhopLoaded then return end

bhopLoaded = true

if bhopConnection then
bhopConnection:Disconnect()
end
bhopConnection = RunService.Heartbeat:Connect(updateBhop)
applyBhopFriction()
end

unloadBhop = function()
if not bhopLoaded then return end

bhopLoaded = false

if bhopConnection then
bhopConnection:Disconnect()
bhopConnection = nil
end

getgenv().bhopHoldActive = false
resetBhopFriction()
end

checkBhopState = function()
shouldLoad = getgenv().autoJumpEnabled or getgenv().bhopHoldActive

if shouldLoad then
loadBhop()
else
unloadBhop()
end
end

reapplyBhopOnRespawn = function()
if getgenv().autoJumpEnabled or getgenv().bhopHoldActive then
wait(0.5)
applyBhopFriction()
checkBhopState()
end
end

setupJumpButton = function()
success, err = pcall(function()
touchGui = player:WaitForChild("PlayerGui", 5):WaitForChild("TouchGui", 5)
if not touchGui then return end
touchControlFrame = touchGui:WaitForChild("TouchControlFrame", 5)
if not touchControlFrame then return end
jumpButton = touchControlFrame:WaitForChild("JumpButton", 5)
if not jumpButton then return end

jumpButton.MouseButton1Down:Connect(function()
if featureStates.BhopHold then
getgenv().bhopHoldActive = true
checkBhopState()
end
end)

jumpButton.MouseButton1Up:Connect(function()
getgenv().bhopHoldActive = false
checkBhopState()
end)
end)
end

setupJumpButton()

RunService.Heartbeat:Connect(function()
   if not Character or not Character:IsDescendantOf(workspace) then
      Character = player.Character or player.CharacterAdded:Wait()
      if Character then
         Humanoid = Character:FindFirstChildOfClass("Humanoid")
         HumanoidRootPart = Character:FindFirstChild("HumanoidRootPart")
      else
         Humanoid = nil
         HumanoidRootPart = nil
      end
   end
end)

if characterConnection then
   characterConnection:Disconnect()
end
characterConnection = player.CharacterAdded:Connect(function(character)
   Character = character
   Humanoid = character:WaitForChild("Humanoid")
   HumanoidRootPart = character:WaitForChild("HumanoidRootPart")
   setupJumpButton()
   reapplyBhopOnRespawn()
end)

MovementTab:CreateSection("Bhop / Bunny Hop")

if ButtonLib and ButtonLib.Create then
   _G.DarahubLibBtn = _G.DarahubLibBtn or {}
   _G.DarahubLibBtn.Bhop = ButtonLib.Create:Toggle({
      Text = "Bhop",
      Flag = "Bhop",
      Visible = false,
      Callback = function(state)
         if BhopToggle then
            BhopToggle:Set(state)
         end
      end
   })
   _G.DarahubLibBtn.Bhop.Position = UDim2.new(0.5, -125, 0.5, 0)
end

local AutoJumpTypeDropdown = MovementTab:CreateDropdown({
   Name = "Auto Jump Type",
   Options = {"Bounce", "Realistic"},
   CurrentOption = {"Bounce"},
   MultipleOptions = false,
   Flag = "AutoJumpTypeDropdown",
   Callback = function(options)
      getgenv().autoJumpType = options[1]
   end
})

local BhopToggle = MovementTab:CreateToggle({
   Name = "Bhop",
   CurrentValue = false,
   Flag = "BhopToggle",
   Callback = function(state)
      featureStates.Bhop = state
      getgenv().autoJumpEnabled = state
      checkBhopState()
   end
})

local ShowBhopButton = MovementTab:CreateToggle({
   Name = "Show Bhop Button",
   CurrentValue = false,
   Flag = "ShowBhopButton",
   Callback = function(state)
      if _G.DarahubLibBtn and _G.DarahubLibBtn.Bhop then
         _G.DarahubLibBtn.Bhop.Visible = state
      end
   end
})

local BhopHoldToggle = MovementTab:CreateToggle({
   Name = "Bhop (Hold Space/Jump)",
   CurrentValue = false,
   Flag = "BhopHoldToggle",
   Callback = function(state)
      featureStates.BhopHold = state
      if not state then
         getgenv().bhopHoldActive = false
         checkBhopState()
      end
   end
})

local BhopModeDropdown = MovementTab:CreateDropdown({
   Name = "Bhop Mode",
   Options = {"Acceleration", "No Acceleration"},
   CurrentOption = {"Acceleration"},
   MultipleOptions = false,
   Flag = "BhopModeDropdown",
   Callback = function(options)
      getgenv().bhopMode = options[1]
      checkBhopState()
   end
})

local BhopAccelInput = MovementTab:CreateInput({
   Name = "Bhop Acceleration (Negative Only)",
   CurrentValue = "-0.5",
   PlaceholderText = "-0.5",
   RemoveTextAfterFocusLost = false,
   Flag = "BhopAccelInput",
   Callback = function(value)
      if tostring(value):sub(1, 1) == "-" then
         local n = tonumber(value)
         if n then
            getgenv().bhopAccelValue = n
            if getgenv().autoJumpEnabled or getgenv().bhopHoldActive then
               applyBhopFriction()
            end
         end
      end
   end
})

local JumpCooldownInput = MovementTab:CreateInput({
   Name = "Jump Cooldown (Seconds)",
   CurrentValue = "0.7",
   PlaceholderText = "0.7",
   RemoveTextAfterFocusLost = false,
   Flag = "JumpCooldownInput",
   Callback = function(value)
      local n = tonumber(value)
      if n and n > 0 then
         getgenv().jumpCooldown = n
      end
   end
})


--[[ ========================================
     TIMER DISPLAY FEATURE
     ======================================== ]]

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "TimerGUI"
ScreenGui.ResetOnSpawn = false
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
ScreenGui.Parent = PlayerGui

local Timer = Instance.new("Frame")
Timer.Name = "Timer"
Timer.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
Timer.BackgroundTransparency = 1
Timer.BorderColor3 = Color3.fromRGB(27, 42, 53)
Timer.Size = UDim2.new(1, 0, 1, 0)
Timer.Parent = ScreenGui

local Top = Instance.new("Frame")
Top.Name = "Top"
Top.AnchorPoint = Vector2.new(0.5, 0)
Top.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
Top.BackgroundTransparency = 1
Top.BorderColor3 = Color3.fromRGB(27, 42, 53)
Top.Position = UDim2.new(0.5, 0, 0, 0)
Top.Size = UDim2.new(1, 0, 1, 0)
Top.Parent = Timer

local AspectRatioConstraint = Instance.new("UIAspectRatioConstraint")
AspectRatioConstraint.Parent = Top

local SizeConstraint = Instance.new("UISizeConstraint")
SizeConstraint.MaxSize = Vector2.new(900, 900)
SizeConstraint.Parent = Top

local MainTimer = Instance.new("Frame")
MainTimer.Name = "MainTimer"
MainTimer.AnchorPoint = Vector2.new(0.5, 0)
MainTimer.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
MainTimer.BackgroundTransparency = 0.6
MainTimer.BorderColor3 = Color3.fromRGB(27, 42, 53)
MainTimer.BorderSizePixel = 0
MainTimer.Position = UDim2.new(0.5, 0, 0.04, 0)
MainTimer.Size = UDim2.new(0.25, 0, 0.1, 0)
MainTimer.Parent = Top
MainTimer.Visible = false

local MainTimerCorner = Instance.new("UICorner")
MainTimerCorner.CornerRadius = UDim.new(0, 4)
MainTimerCorner.Parent = MainTimer

local MainTimerStroke = Instance.new("UIStroke")
MainTimerStroke.Transparency = 0.8
MainTimerStroke.Parent = MainTimer

local TimerBackground = Instance.new("ImageLabel")
TimerBackground.Name = "Background"
TimerBackground.Image = "rbxassetid://196969716"
TimerBackground.ImageColor3 = Color3.fromRGB(21, 21, 21)
TimerBackground.ImageTransparency = 0.7
TimerBackground.AnchorPoint = Vector2.new(0.5, 0.5)
TimerBackground.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
TimerBackground.BackgroundTransparency = 1
TimerBackground.BorderColor3 = Color3.fromRGB(27, 42, 53)
TimerBackground.Position = UDim2.new(0.5, 0, 0.5, 0)
TimerBackground.Size = UDim2.new(1, 0, 1, 0)
TimerBackground.ZIndex = 0
TimerBackground.Parent = MainTimer

local TimerBackgroundCorner = Instance.new("UICorner")
TimerBackgroundCorner.CornerRadius = UDim.new(0, 4)
TimerBackgroundCorner.Parent = TimerBackground

local TimerImage = Instance.new("ImageLabel")
TimerImage.Image = "rbxassetid://6761866149"
TimerImage.ImageColor3 = Color3.fromRGB(165, 194, 255)
TimerImage.ImageTransparency = 0.9
TimerImage.ScaleType = Enum.ScaleType.Crop
TimerImage.AnchorPoint = Vector2.new(0.5, 0.5)
TimerImage.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
TimerImage.BackgroundTransparency = 1
TimerImage.BorderColor3 = Color3.fromRGB(27, 42, 53)
TimerImage.Position = UDim2.new(0.5, 0, 0.5, 0)
TimerImage.Size = UDim2.new(0.8, 0, 1, 0)
TimerImage.ZIndex = 2
TimerImage.Parent = MainTimer

local StatusLabel = Instance.new("TextLabel")
StatusLabel.Name = "Status"
StatusLabel.FontFace = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Bold, Enum.FontStyle.Normal)
StatusLabel.Text = "ROUND ACTIVE"
StatusLabel.TextColor3 = Color3.fromRGB(165, 194, 255)
StatusLabel.TextScaled = true
StatusLabel.TextSize = 14
StatusLabel.TextStrokeTransparency = 0.95
StatusLabel.TextWrapped = true
StatusLabel.AnchorPoint = Vector2.new(0.5, 0.5)
StatusLabel.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
StatusLabel.BackgroundTransparency = 1
StatusLabel.BorderColor3 = Color3.fromRGB(27, 42, 53)
StatusLabel.Position = UDim2.new(0.5, 0, 0.25, 0)
StatusLabel.Size = UDim2.new(0.8, 0, 0.25, 0)
StatusLabel.ZIndex = 3
StatusLabel.Parent = MainTimer

local StatusStroke = Instance.new("UIStroke")
StatusStroke.Thickness = 2
StatusStroke.Transparency = 0.7
StatusStroke.Parent = StatusLabel

local StatusGradient = Instance.new("UIGradient")
StatusGradient.Color = ColorSequence.new({
   ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)),
   ColorSequenceKeypoint.new(1, Color3.fromRGB(194, 194, 194))
})
StatusGradient.Rotation = 90
StatusGradient.Parent = StatusLabel

local TimeDisplay = Instance.new("TextLabel")
TimeDisplay.Name = "TimeDisplay"
TimeDisplay.FontFace = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Bold, Enum.FontStyle.Normal)
TimeDisplay.Text = "0:00"
TimeDisplay.TextColor3 = Color3.fromRGB(165, 194, 255)
TimeDisplay.TextScaled = true
TimeDisplay.TextSize = 14
TimeDisplay.TextStrokeTransparency = 0.95
TimeDisplay.TextWrapped = true
TimeDisplay.AnchorPoint = Vector2.new(0.5, 0.5)
TimeDisplay.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
TimeDisplay.BackgroundTransparency = 1
TimeDisplay.BorderColor3 = Color3.fromRGB(27, 42, 53)
TimeDisplay.Position = UDim2.new(0.5, 0, 0.65, 0)
TimeDisplay.Size = UDim2.new(0.5, 0, 0.5, 0)
TimeDisplay.ZIndex = 3
TimeDisplay.Parent = MainTimer

local TimeStroke = Instance.new("UIStroke")
TimeStroke.Thickness = 3
TimeStroke.Transparency = 0.7
TimeStroke.Parent = TimeDisplay

local TimeGradient = Instance.new("UIGradient")
TimeGradient.Color = ColorSequence.new({
   ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)),
   ColorSequenceKeypoint.new(1, Color3.fromRGB(194, 194, 194))
})
TimeGradient.Rotation = 90
TimeGradient.Parent = TimeDisplay

local SpecialRound = Instance.new("Frame")
SpecialRound.Name = "SpecialRound"
SpecialRound.AnchorPoint = Vector2.new(0.5, 0)
SpecialRound.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
SpecialRound.BackgroundTransparency = 0.6
SpecialRound.BorderColor3 = Color3.fromRGB(27, 42, 53)
SpecialRound.BorderSizePixel = 0
SpecialRound.Position = UDim2.new(0.5, 0, 0.15, 0)
SpecialRound.Size = UDim2.new(0.23, 0, 0.05, 0)
SpecialRound.Parent = Top
SpecialRound.Visible = false

local SpecialRoundLabel = Instance.new("TextLabel")
SpecialRoundLabel.Name = "Label"
SpecialRoundLabel.FontFace = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Bold, Enum.FontStyle.Normal)
SpecialRoundLabel.Text = "No Jumping"
SpecialRoundLabel.TextColor3 = Color3.fromRGB(255, 208, 115)
SpecialRoundLabel.TextScaled = true
SpecialRoundLabel.TextSize = 14
SpecialRoundLabel.TextStrokeTransparency = 0.95
SpecialRoundLabel.TextWrapped = true
SpecialRoundLabel.AnchorPoint = Vector2.new(0.5, 0.5)
SpecialRoundLabel.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
SpecialRoundLabel.BackgroundTransparency = 1
SpecialRoundLabel.BorderColor3 = Color3.fromRGB(27, 42, 53)
SpecialRoundLabel.Position = UDim2.new(0.5, 0, 0.5, 0)
SpecialRoundLabel.Size = UDim2.new(0.9, 0, 0.6, 0)
SpecialRoundLabel.ZIndex = 3
SpecialRoundLabel.Parent = SpecialRound

local SpecialRoundStroke = Instance.new("UIStroke")
SpecialRoundStroke.Thickness = 2
SpecialRoundStroke.Transparency = 0.7
SpecialRoundStroke.Parent = SpecialRoundLabel

local SpecialRoundCorner = Instance.new("UICorner")
SpecialRoundCorner.CornerRadius = UDim.new(0, 4)
SpecialRoundCorner.Parent = SpecialRound

local SpecialRoundBackground = Instance.new("ImageLabel")
SpecialRoundBackground.Name = "Background"
SpecialRoundBackground.Image = "rbxassetid://196969716"
SpecialRoundBackground.ImageColor3 = Color3.fromRGB(21, 21, 21)
SpecialRoundBackground.ImageTransparency = 0.7
SpecialRoundBackground.AnchorPoint = Vector2.new(0.5, 0.5)
SpecialRoundBackground.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
SpecialRoundBackground.BackgroundTransparency = 1
SpecialRoundBackground.BorderColor3 = Color3.fromRGB(27, 42, 53)
SpecialRoundBackground.Position = UDim2.new(0.5, 0, 0.5, 0)
SpecialRoundBackground.Size = UDim2.new(1, 0, 1, 0)
SpecialRoundBackground.ZIndex = 0
SpecialRoundBackground.Parent = SpecialRound

local SpecialRoundBackgroundCorner = Instance.new("UICorner")
SpecialRoundBackgroundCorner.CornerRadius = UDim.new(0, 4)
SpecialRoundBackgroundCorner.Parent = SpecialRoundBackground

local SpecialRoundUIStroke = Instance.new("UIStroke")
SpecialRoundUIStroke.Transparency = 0.8
SpecialRoundUIStroke.Parent = SpecialRound

local TimerGUI = {
   ScreenGui = ScreenGui,
   TimeDisplay = TimeDisplay,
   SpecialRoundLabel = SpecialRoundLabel,
   StatusLabel = StatusLabel,
   MainTimer = MainTimer,
   SpecialRound = SpecialRound,
   TimerEnabled = false,
   SpecialRoundEnabled = false,
   CurrentSpecialRoundName = "",
   OriginalTimerVisible = false
}

function TimerGUI:GetRoundTitle(roundName)
   if not roundName or roundName == "" then
      return ""
   end
   local specialRoundsFolder = ReplicatedStorage:FindFirstChild("Info")
   if not specialRoundsFolder then return roundName end
   specialRoundsFolder = specialRoundsFolder:FindFirstChild("SpecialRounds")
   if not specialRoundsFolder then return roundName end
   local roundModule = specialRoundsFolder:FindFirstChild(roundName)
   if not roundModule then return roundName end
   local success, moduleData = pcall(function()
      return require(roundModule)
   end)
   if success and moduleData and moduleData.Title then
      return moduleData.Title
   end
   return roundName
end

function TimerGUI:SetTime(seconds)
   if type(seconds) == "number" then
      local minutes = math.floor(seconds / 60)
      local remainingSeconds = math.floor(seconds % 60)
      self.TimeDisplay.Text = string.format("%d:%02d", minutes, remainingSeconds)
      if seconds <= 5 then
         self.TimeDisplay.TextColor3 = Color3.fromRGB(215, 100, 100)
         self.StatusLabel.TextColor3 = Color3.fromRGB(215, 100, 100)
      else
         self.TimeDisplay.TextColor3 = Color3.fromRGB(165, 194, 255)
         self.StatusLabel.TextColor3 = Color3.fromRGB(165, 194, 255)
      end
   else
      self.TimeDisplay.Text = tostring(seconds)
   end
end

function TimerGUI:SetSpecialRound(roundName)
   if roundName and roundName ~= "" then
      self.CurrentSpecialRoundName = roundName
      local roundTitle = self:GetRoundTitle(roundName)
      self.SpecialRoundLabel.Text = roundTitle
      self.SpecialRound.Visible = self.SpecialRoundEnabled
   else
      self.CurrentSpecialRoundName = ""
      self.SpecialRound.Visible = false
   end
end

function TimerGUI:SetStatus(text)
   self.StatusLabel.Text = text:upper()
end

function TimerGUI:SetTimerVisible(visible)
   self.TimerEnabled = visible
   self.OriginalTimerVisible = visible
   if self.CheckingGameTimer then
      self:CheckGameTimerVisibility()
   else
      self.MainTimer.Visible = visible
   end
end

function TimerGUI:SetSpecialRoundVisible(visible)
   self.SpecialRoundEnabled = visible
   if visible and self.CurrentSpecialRoundName ~= "" then
      self.SpecialRound.Visible = true
   else
      self.SpecialRound.Visible = false
   end
end

function TimerGUI:CheckGameTimerVisibility()
   if not self.TimerEnabled then
      self.MainTimer.Visible = false
      return
   end
   local hud = player.PlayerGui:FindFirstChild("Shared")
   if not hud then
      self.MainTimer.Visible = self.OriginalTimerVisible
      return
   end
   hud = hud:FindFirstChild("HUD")
   if not hud then
      self.MainTimer.Visible = self.OriginalTimerVisible
      return
   end
   hud = hud:FindFirstChild("Overlay")
   if not hud then
      self.MainTimer.Visible = self.OriginalTimerVisible
      return
   end
   hud = hud:FindFirstChild("Default")
   if not hud then
      self.MainTimer.Visible = self.OriginalTimerVisible
      return
   end
   hud = hud:FindFirstChild("RoundOverlay")
   if not hud then
      self.MainTimer.Visible = self.OriginalTimerVisible
      return
   end
   hud = hud:FindFirstChild("Round")
   if not hud then
      self.MainTimer.Visible = self.OriginalTimerVisible
      return
   end
   local roundTimer = hud:FindFirstChild("RoundTimer")
   if not roundTimer then
      self.MainTimer.Visible = self.OriginalTimerVisible
      return
   end
   if roundTimer.Visible then
      self.MainTimer.Visible = false
   else
      self.MainTimer.Visible = self.OriginalTimerVisible
   end
end

function TimerGUI:StartGameTimerCheck()
   if self.CheckingGameTimer then return end
   self.CheckingGameTimer = true
   spawn(function()
      while self.CheckingGameTimer do
         self:CheckGameTimerVisibility()
         wait(0.1)
      end
   end)
end

function TimerGUI:StopGameTimerCheck()
   self.CheckingGameTimer = false
   self.MainTimer.Visible = self.OriginalTimerVisible
end

function TimerGUI:UpdateFromAttributes()
   local statsFolder = workspace:FindFirstChild("Game")
   if not statsFolder then return end
   statsFolder = statsFolder:FindFirstChild("Stats")
   if not statsFolder then return end
   local timerValue = statsFolder:GetAttribute("Timer")
   local specialRoundValue = statsFolder:GetAttribute("SpecialRound")
   local roundStarted = statsFolder:GetAttribute("RoundStarted")
   if timerValue then
      self:SetTime(timerValue)
   end
   if roundStarted ~= nil then
      if roundStarted == true then
         self:SetStatus("Round Active")
      else
         self:SetStatus("Intermission")
      end
   end
   if specialRoundValue then
      self:SetSpecialRound(tostring(specialRoundValue))
   else
      self:SetSpecialRound("")
   end
end

function TimerGUI:StartAttributeMonitor()
   if self._attributeConnection then
      self._attributeConnection:Disconnect()
   end
   local statsFolder = workspace:FindFirstChild("Game")
   if not statsFolder then return end
   statsFolder = statsFolder:FindFirstChild("Stats")
   if not statsFolder then return end
   self._attributeConnection = statsFolder:GetAttributeChangedSignal("Timer"):Connect(function()
      self:UpdateFromAttributes()
   end)
   self._attributeConnection2 = statsFolder:GetAttributeChangedSignal("RoundStarted"):Connect(function()
      self:UpdateFromAttributes()
   end)
   self._attributeConnection3 = statsFolder:GetAttributeChangedSignal("SpecialRound"):Connect(function()
      self:UpdateFromAttributes()
   end)
   self:UpdateFromAttributes()
end

function TimerGUI:StopAttributeMonitor()
   if self._attributeConnection then
      self._attributeConnection:Disconnect()
      self._attributeConnection = nil
   end
   if self._attributeConnection2 then
      self._attributeConnection2:Disconnect()
      self._attributeConnection2 = nil
   end
   if self._attributeConnection3 then
      self._attributeConnection3:Disconnect()
      self._attributeConnection3 = nil
   end
end

TimerGUI:SetTimerVisible(false)
TimerGUI:SetSpecialRoundVisible(false)
TimerGUI:StartAttributeMonitor()

local TimerDisplayToggle = VisualsTab:CreateToggle({
   Name = "Timer Display",
   CurrentValue = false,
   Flag = "TimerDisplayToggle",
   Callback = function(state)
      if state then
         TimerGUI.ScreenGui.Enabled = true
         TimerGUI:SetTimerVisible(true)
         TimerGUI:StartAttributeMonitor()
         TimerGUI:StartGameTimerCheck()
      else
         TimerGUI:SetTimerVisible(false)
         TimerGUI:StopGameTimerCheck()
      end
   end
})

local SpecialRoundToggle = VisualsTab:CreateToggle({
   Name = "Special Round Display",
   CurrentValue = false,
   Flag = "SpecialRoundToggle",
   Callback = function(state)
      TimerGUI:SetSpecialRoundVisible(state)
   end
})