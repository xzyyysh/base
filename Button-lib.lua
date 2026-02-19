--[[
    Button Library
    Original by Moun Sok Dara (DaraHub)
    
    Used in XyzHub with gratitude for making this lib available.
    Thanks for the clean and functional button system :3
]]

local ButtonLib = {}
local CoreGui = game:GetService("CoreGui")
local camera = workspace.CurrentCamera
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
_G.DarahubLibBtn = {}
local function getDPIScale()
    return camera.ViewportSize.Y / 1080
end
if not UserInputService.KeyboardEnabled then
    local darahubGui = CoreGui:FindFirstChild("Darahub") or Instance.new("ScreenGui", CoreGui)
    darahubGui.Name = "Darahub"
    darahubGui.DisplayOrder = 78
    darahubGui.IgnoreGuiInset = true
    darahubGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    local floatingButton = Instance.new("ImageButton")
    floatingButton.Name = "FloatingButton_Darahub"
    floatingButton.Parent = darahubGui
    floatingButton.Active = true
    floatingButton.BorderSizePixel = 0
    floatingButton.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    floatingButton.Size = UDim2.new(0, 80, 0, 80)
    floatingButton.Position = UDim2.new(0.85, 0, 0.05, 0)
    floatingButton.BackgroundTransparency = 1
    floatingButton.Image = "rbxassetid://137330250139083"
    floatingButton.Visible = false
    local aspectRatio = Instance.new("UIAspectRatioConstraint", floatingButton)
    aspectRatio.DominantAxis = Enum.DominantAxis.Height
    local sizeConstraint = Instance.new("UISizeConstraint", floatingButton)
    sizeConstraint.MinSize = Vector2.new(68, 68)
    sizeConstraint.MaxSize = Vector2.new(100, 100)
    local corner = Instance.new("UICorner", floatingButton)
    corner.CornerRadius = UDim.new(1, 0)
    local uiScale = Instance.new("UIScale", floatingButton)
    uiScale.Scale = getDPIScale()
    local dragDetector = Instance.new("UIDragDetector", floatingButton)
    local dragStartPosition = nil
    local CLICK_THRESHOLD = 10
    local HOLD_TIME = 1.5
    local holdStartTime = nil
    local isHolding = false
    local holdCheckConnection = nil
    local holdStartPosition = nil
    local resettingDragDetector = false
    
    local function reinsertDragDetector()
        resettingDragDetector = true
        if dragDetector then
            dragDetector.Enabled = false
            task.wait(0.01)
            dragDetector.Enabled = true
        end
        task.wait(0.2)
        resettingDragDetector = false
        dragStartPosition = nil
    end
    
    local function startHoldCheck()
        holdStartTime = tick()
        holdStartPosition = floatingButton.Position
        isHolding = true
        holdCheckConnection = RunService.Heartbeat:Connect(function()
            if not isHolding then
                holdCheckConnection:Disconnect()
                return
            end
            local currentPosition = floatingButton.Position
            local positionChanged = currentPosition.X.Offset ~= holdStartPosition.X.Offset or 
                                   currentPosition.Y.Offset ~= holdStartPosition.Y.Offset
            if positionChanged then
                isHolding = false
                holdCheckConnection:Disconnect()
                return
            end
            local holdDuration = tick() - holdStartTime
            if holdDuration >= HOLD_TIME then
                isHolding = false
                holdCheckConnection:Disconnect()
                reinsertDragDetector()
            end
        end)
    end
    
    floatingButton.InputBegan:Connect(function(input)
        if resettingDragDetector then return end
        
        if input.UserInputType == Enum.UserInputType.Touch or 
           input.UserInputType == Enum.UserInputType.MouseButton1 then
            startHoldCheck()
        end
    end)
    
    floatingButton.InputEnded:Connect(function(input)
        if resettingDragDetector then return end
        
        if input.UserInputType == Enum.UserInputType.Touch or 
           input.UserInputType == Enum.UserInputType.MouseButton1 then
            isHolding = false
            if holdCheckConnection then
                holdCheckConnection:Disconnect()
            end
        end
    end)
    
    dragDetector.DragStart:Connect(function()
        if resettingDragDetector then return end
        dragStartPosition = floatingButton.Position
        isHolding = false
        if holdCheckConnection then
            holdCheckConnection:Disconnect()
        end
    end)
    
    dragDetector.DragEnd:Connect(function()
        if resettingDragDetector then return end
        
        if dragStartPosition then
            local currentPosition = floatingButton.Position
            local distance = math.sqrt(
                (currentPosition.X.Offset - dragStartPosition.X.Offset)^2 +
                (currentPosition.Y.Offset - dragStartPosition.Y.Offset)^2
            )
            if distance < CLICK_THRESHOLD then
                if Window and Window.Open then
                    Window:Open()
                end
            end
            dragStartPosition = nil
        end
    end)
end

ButtonLib.Create = {}

local function buildBaseFrame(config)
    local darahubGui = CoreGui:FindFirstChild("Darahub") or Instance.new("ScreenGui", CoreGui)
    darahubGui.Name = "Darahub"
    darahubGui.IgnoreGuiInset = true
    darahubGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    local frame = Instance.new("Frame")
    local flag = config.Flag or config.Text or "Element"
    if _G.DarahubLibBtn[flag] then
        pcall(function() _G.DarahubLibBtn[flag]:Destroy() end)
    end
    frame.Name = flag
    frame.Parent = darahubGui
    frame.Visible = config.Visible ~= false
    frame.Draggable = true
    frame.Active = true
    frame.Size = UDim2.new(0, 250, 0, 90)
    frame.Position = config.Position or UDim2.new(0.5, -125, 0.5, -45)
    frame.BackgroundColor3 = Color3.new(1, 1, 1)
    frame.BackgroundTransparency = 0.2
    local uiScale = Instance.new("UIScale", frame)
    uiScale.Scale = getDPIScale()
    local corner = Instance.new("UICorner", frame)
    corner.CornerRadius = UDim.new(0, 10)
    local strokeB = Instance.new("UIStroke", frame)
    strokeB.Thickness = 2
    strokeB.Color = Color3.new(0, 0, 0)
    strokeB.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    local strokeW = Instance.new("UIStroke", frame)
    strokeW.Thickness = 1
    strokeW.Color = Color3.new(1, 1, 1)
    strokeW.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    local grad = Instance.new("UIGradient", frame)
    grad.Rotation = 90
    grad.Color = ColorSequence.new(Color3.fromRGB(47, 47, 47), Color3.new(0, 0, 0))
    local label = Instance.new("TextLabel", frame)
    label.Name = "Label"
    label.Size = UDim2.new(1, -20, 1, 0)
    label.Position = UDim2.new(0, 10, 0, 0)
    label.BackgroundTransparency = 1
    label.TextColor3 = Color3.new(1, 1, 1)
    label.TextScaled = true
    label.Font = Enum.Font.FredokaOne
    label.ZIndex = 5
    local drag = Instance.new("UIDragDetector", frame)
    drag.Parent.Draggable = true
    
    local HOLD_TIME_FRAME = 1.5
    local isHoldingFrame = false
    local holdStartTimeFrame = nil
    local holdCheckConnectionFrame = nil
    local holdStartPositionFrame = nil
    local resettingDragDetectorFrame = false
    
    local function reinsertDragDetectorFrame()
        resettingDragDetectorFrame = true
        if drag then
            drag.Parent.Draggable = false
            drag.Enabled = false
            task.wait(0.01)
            drag.Enabled = true
            drag.Parent.Draggable = true
        end
        -- Add a small delay before allowing click detection again
        task.wait(0.2)
        resettingDragDetectorFrame = false
    end
    
    local function startHoldCheckFrame()
        holdStartTimeFrame = tick()
        holdStartPositionFrame = frame.Position
        isHoldingFrame = true
        holdCheckConnectionFrame = RunService.Heartbeat:Connect(function()
            if not isHoldingFrame then
                holdCheckConnectionFrame:Disconnect()
                return
            end
            local currentPosition = frame.Position
            local positionChanged = currentPosition.X.Offset ~= holdStartPositionFrame.X.Offset or 
                                   currentPosition.Y.Offset ~= holdStartPositionFrame.Y.Offset
            if positionChanged then
                isHoldingFrame = false
                holdCheckConnectionFrame:Disconnect()
                return
            end
            local holdDuration = tick() - holdStartTimeFrame
            if holdDuration >= HOLD_TIME_FRAME then
                isHoldingFrame = false
                holdCheckConnectionFrame:Disconnect()
                reinsertDragDetectorFrame()
            end
        end)
    end
    
    frame.InputBegan:Connect(function(input)
        if resettingDragDetectorFrame then return end
        
        if input.UserInputType == Enum.UserInputType.Touch or 
           input.UserInputType == Enum.UserInputType.MouseButton1 then
            startHoldCheckFrame()
        end
    end)
    
    frame.InputEnded:Connect(function(input)
        if resettingDragDetectorFrame then return end
        
        if input.UserInputType == Enum.UserInputType.Touch or 
           input.UserInputType == Enum.UserInputType.MouseButton1 then
            isHoldingFrame = false
            if holdCheckConnectionFrame then
                holdCheckConnectionFrame:Disconnect()
            end
        end
    end)
    
    drag.DragStart:Connect(function()
        if resettingDragDetectorFrame then return end
        isHoldingFrame = false
        if holdCheckConnectionFrame then
            holdCheckConnectionFrame:Disconnect()
        end
    end)
    
    local api = {}
    function api:Destroy()
        if _G.DarahubLibBtn[flag] then
            _G.DarahubLibBtn[flag] = nil
        end
        frame:Destroy()
    end
    function api:SetVisible(visible)
        frame.Visible = visible
    end
    function api:ReinsertDragDetector()
        reinsertDragDetectorFrame()
    end
    function api:SetDraggable(enabled)
        if drag.Parent then
            drag.Parent.Draggable = enabled
            drag.Enabled = enabled
        end
    end
    return api, frame, label, drag, flag
end

function ButtonLib.Create:Button(config)
    local api, frame, label, drag, flag = buildBaseFrame(config)
    local callback = config.Callback or config[1] or function() end
    label.Text = config.Text or "Button"
    
    local startPos
    local resettingDragDetector = false
    
    drag.DragStart:Connect(function() 
        if resettingDragDetector then return end
        startPos = frame.Position 
    end)
    
    drag.DragEnd:Connect(function()
        if resettingDragDetector then return end
        
        if not startPos then return end
        local currentPos = frame.Position
        local dist = math.sqrt(
            (currentPos.X.Offset - startPos.X.Offset)^2 +
            (currentPos.Y.Offset - startPos.Y.Offset)^2
        )
        if dist < 5 then
            frame:TweenSize(UDim2.new(0, 240, 0, 85), "Out", "Quad", 0.05, true)
            task.wait(0.05)
            frame:TweenSize(UDim2.new(0, 250, 0, 90), "Out", "Quad", 0.05, true)
            pcall(callback)
        end
        startPos = nil
    end)
    
    _G.DarahubLibBtn[flag] = setmetatable(api, {
        __index = function(self, key)
            return frame[key]
        end,
        __newindex = function(self, key, value)
            frame[key] = value
        end
    })
    return _G.DarahubLibBtn[flag]
end

function ButtonLib.Create:Toggle(config)
    local api, frame, label, drag, flag = buildBaseFrame(config)
    local callback = config.Callback or config[1] or function() end
    local baseText = config.Text or "Toggle"
    local state = config.Default or config.Deafult or false
    local resettingDragDetector = false
    
    local function updateUI()
        label.Text = baseText .. (state and " : ON" or " : OFF")
    end
    updateUI()
    
    function api:Set(val)
        if state ~= val then
            state = val
            updateUI()
            pcall(callback, state)
        end
    end
    
    function api:Get()
        return state
    end
    
    local startPos
    
    drag.DragStart:Connect(function() 
        if resettingDragDetector then return end
        startPos = frame.Position 
    end)
    
    drag.DragEnd:Connect(function()
        if resettingDragDetector then return end
        
        if not startPos then return end
        local currentPos = frame.Position
        local dist = math.sqrt(
            (currentPos.X.Offset - startPos.X.Offset)^2 +
            (currentPos.Y.Offset - startPos.Y.Offset)^2
        )
        if dist < 5 then
            frame:TweenSize(UDim2.new(0, 240, 0, 85), "Out", "Quad", 0.05, true)
            task.wait(0.05)
            frame:TweenSize(UDim2.new(0, 250, 0, 90), "Out", "Quad", 0.05, true)
            api:Set(not state)
        end
        startPos = nil
    end)
    
    _G.DarahubLibBtn[flag] = setmetatable(api, {
        __index = function(self, key)
            return frame[key]
        end,
        __newindex = function(self, key, value)
            frame[key] = value
        end
    })
    return _G.DarahubLibBtn[flag]
end

return ButtonLib