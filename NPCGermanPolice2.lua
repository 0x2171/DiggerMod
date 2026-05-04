local unity = CS.UnityEngine

-- === НАСТРОЙКИ ===
local CHASE_RADIUS    = 50.0
local ATTACK_DIST     = 1.5
local CHASE_SPEED     = 3.5
local ATTACK_COOLDOWN = 0.5
local ATTACK_DAMAGE   = 0
local MAX_ATTACKS     = 5
local ANIM_RUN        = "run_3"
local ANIM_ATTACK     = "dig"
local ANIM_IDLE       = "idle"

-- URL картинки, которая появится при аресте
local ARREST_IMAGE_URL = "https://raw.githubusercontent.com/0x2171/DiggerMod/refs/heads/main/narucniki.png"

-- === СИСТЕМА РОЗЫСКА ===
local STAR_ICON_URL = "https://raw.githubusercontent.com/0x2171/DiggerMod/refs/heads/main/CopIcon.png"
local PROPERTIES_FILE_PATH = "C:\\DANZIG\\properties.json"
local PURSUIT_TIME_FOR_SECOND_STAR = 120.0 -- 2 минуты
local MIN_PLAYERS_FOR_THIRD_STAR = 3

-- Переменные для иконок звезд
local starTexture = nil
local starTextureRequest = nil
local star1Active = false
local star2Active = false
local star3Active = false
local pursuitTimer = 0.0

-- Глобальные данные из файла
local globalWantedData = {}
local fileReadTimer = 0.0
local FILE_READ_INTERVAL = 0.1 -- Читаем файл каждые 0.1 сек

-- === СОСТОЯНИЕ NPC ===
local animation       = nil
local alertAudio      = nil
local attackAudio     = nil
local delayedAudio    = nil
local delayedAudio2   = nil
local alertPlayed     = false
local delayedSoundPlayed = false
local detectionTimer  = 0.0
local state           = "Idle"
local attackCount     = 0
local isArrested      = false -- Локальный флаг: этот NPC арестовал игрока
local arrestPos       = nil
local attackTimer     = 0.0

-- Параметры блуждания
local spawnPos        = nil
local targetPos       = nil
local waitTimer       = 0.0
local WANDER_RADIUS   = 10.0
local WAIT_MIN        = 1.0
local WAIT_MAX        = 3.0
local WALK_SPEED      = 1.6

local adminProvoked   = false

-- === ПЕРЕМЕННЫЕ ДЛЯ КАРТИНКИ ===
local arrestTexture   = nil
local textureRequest  = nil

-- === ПЕРЕМЕННЫЕ ДЛЯ АРЕСТА И СОПРОВОЖДЕНИЯ ===
local policeCar           = nil
local stayPoint           = nil
local playerSitPoint      = nil
local arrestTimer         = 0.0
local ARREST_DELAY        = 1.5
local isEscorting         = false
local FOLLOW_DISTANCE     = 1.5
local FOLLOW_SMOOTH       = 10.0
local hasReachedStay      = false
local reachedStayTimer    = 0.0
local isSittingTimerActive = false
local isPlayerSeated      = false
local isPlayerLocked      = false

-- === ПЕРЕМЕННЫЕ ДЛЯ СИРЕНЫ ===
local sirenaTransform     = nil
local sirenaAudio         = nil
local SIRENA_ROT_SPEED    = 180.0

local function RandRange(a, b) return unity.Random.Range(a, b) end
local function PlayAnim(name) if animation then animation:Play(name) end end

-- === РАБОТА С JSON (РУЧНАЯ РЕАЛИЗАЦИЯ) ===

local function SerializeTable(val, s, depth)
    s = s or "{}"
    depth = depth or 0
    
    if type(val) == "table" then
        local s2 = "{"
        local count = 0
        for k, v in pairs(val) do
            count = count + 1
            if count > 1 then s2 = s2 .. "," end
            local k_str = tostring(k)
            local v_str
            if type(v) == "table" then
                v_str = SerializeTable(v, nil, depth + 1)
            elseif type(v) == "boolean" then
                v_str = tostring(v)
            elseif type(v) == "number" then
                v_str = tostring(v)
            else
                v_str = "\"" .. tostring(v) .. "\""
            end
            s2 = s2 .. "\n" .. string.rep("  ", depth + 1) .. "\"" .. k_str .. "\": " .. v_str
        end
        s2 = s2 .. "\n" .. string.rep("  ", depth) .. "}"
        return s2
    elseif type(val) == "string" then
        return "\"" .. val .. "\""
    elseif type(val) == "number" or type(val) == "boolean" then
        return tostring(val)
    else
        return "null"
    end
end

local function ParseSimpleJson(jsonStr)
    local result = {}
    if not jsonStr or jsonStr == "" then return result end
    
    local content = jsonStr:gsub("^%s*{", ""):gsub("}%s*$", "")
    local pattern = '"([^"]+)"%s*:%s*(%b{})'
    
    for npcId, dataStr in content:gmatch(pattern) do
        local npcData = {}
        for key, val in dataStr:gmatch('"([^"]+)"%s*:%s*([^,%}]+)') do
            val = val:gsub("^%s*", ""):gsub("%s*$", "")
            if val == "true" then
                npcData[key] = true
            elseif val == "false" then
                npcData[key] = false
            elseif tonumber(val) then
                npcData[key] = tonumber(val)
            else
                npcData[key] = val:gsub('"', "")
            end
        end
        result[npcId] = npcData
    end
    
    return result
end

local function EnsureDirectoryExists(path)
    local dir = CS.System.IO.Path.GetDirectoryName(path)
    if dir and not CS.System.IO.Directory.Exists(dir) then
        CS.System.IO.Directory.CreateDirectory(dir)
    end
end

local function ReadWantedData()
    if CS.System.IO.File.Exists(PROPERTIES_FILE_PATH) then
        local content = CS.System.IO.File.ReadAllText(PROPERTIES_FILE_PATH)
        if content and content ~= "" then
            globalWantedData = ParseSimpleJson(content)
        else
            globalWantedData = {}
        end
    else
        globalWantedData = {}
    end
end

local function WriteWantedData()
    EnsureDirectoryExists(PROPERTIES_FILE_PATH)
    local jsonStr = SerializeTable(globalWantedData)
    CS.System.IO.File.WriteAllText(PROPERTIES_FILE_PATH, jsonStr)
end

local function GetNPCId()
    return "DNPC_German_Police_" .. tostring(transform:GetInstanceID())
end

local function UpdateNPCDataInFile()
    ReadWantedData()
    local npcId = GetNPCId()
    
    globalWantedData[npcId] = {
        star1 = star1Active,
        star2 = star2Active,
        star3 = star3Active,
        isArrested = isArrested,
        pursuitTimer = pursuitTimer,
        posX = transform.position.x,
        posY = transform.position.y,
        posZ = transform.position.z
    }
    
    WriteWantedData()
end

local function IsPlayerAlreadyArrested()
    ReadWantedData()
    local myId = GetNPCId()
    
    for npcId, data in pairs(globalWantedData) do
        if npcId ~= myId then
            if data and data.isArrested == true then
                return true
            end
        end
    end
    return false
end

local function SyncWantedLogic()
    ReadWantedData()
    local totalDetected = 0
    local myId = GetNPCId()
    
    for npcId, data in pairs(globalWantedData) do
        if data and data.star1 == true then
            totalDetected = totalDetected + 1
        end
    end
    
    if totalDetected >= MIN_PLAYERS_FOR_THIRD_STAR then
        star3Active = true
    else
        star3Active = false
    end
end

local function GetRandomPoint()
    local r = RandRange(0.0, WANDER_RADIUS)
    local a = RandRange(0.0, 6.283185)
    return unity.Vector3(spawnPos.x + unity.Mathf.Cos(a) * r, spawnPos.y, spawnPos.z + unity.Mathf.Sin(a) * r)
end

local function RotateTo(dir, speed)
    if dir.sqrMagnitude > 0.0001 then
        local flatDir = unity.Vector3(dir.x, 0, dir.z)
        transform.rotation = unity.Quaternion.Slerp(transform.rotation, unity.Quaternion.LookRotation(flatDir), speed)
    end
end

local function MoveTo(target, speed, dt)
    local pos = transform.position
    local dir = target - pos
    dir.y = 0
    local dist = dir.magnitude
    if dist > 0.1 then
        dir = dir.normalized
        transform.position = pos + dir * math.min(dist, speed * dt)
        RotateTo(dir, dt * 8.0)
    end
end

function Start()
    animation = gameObject:GetComponent(typeof(unity.Animation))
    alertAudio = gameObject:GetComponent(typeof(unity.AudioSource))

    local rootTransform = transform:Find("Root")
    attackAudio = rootTransform and rootTransform.gameObject:GetComponent(typeof(unity.AudioSource))

    local charObj = transform:Find("characters")
    delayedAudio = charObj and charObj.gameObject:GetComponent(typeof(unity.AudioSource))

    local soundObj = transform:Find("Sounddetection2")
    delayedAudio2 = soundObj and soundObj.gameObject:GetComponent(typeof(unity.AudioSource))

    spawnPos = transform.position
    waitTimer = RandRange(WAIT_MIN, WAIT_MAX)
    PlayAnim(ANIM_IDLE)

    local polCarChild = transform:Find("PolicayCar")
    if polCarChild ~= nil then
        polCarChild.parent = nil
        policeCar = polCarChild.gameObject

        local sideOffset = transform.right * 5.0
        local newPos = unity.Vector3(spawnPos.x + sideOffset.x, spawnPos.y, spawnPos.z + sideOffset.z)

        policeCar.transform.position = newPos
        policeCar.transform.rotation = transform.rotation
        policeCar:SetActive(false)
        unity.Debug.Log("[NPC] PolicayCar detached and disabled")

        local stayObj = policeCar.transform:Find("StayPoint")
        if stayObj ~= nil then stayPoint = stayObj end

        local sitObj = policeCar.transform:Find("PlayerSitPoint")
        if sitObj ~= nil then
            playerSitPoint = sitObj
            unity.Debug.Log("[NPC] PlayerSitPoint found")
        end

        local sirenaObj = policeCar.transform:Find("SirenRoot/Sirena")
        if sirenaObj ~= nil then
            sirenaTransform = sirenaObj
            sirenaAudio = sirenaObj.gameObject:GetComponent(typeof(unity.AudioSource))
            if sirenaAudio then sirenaAudio.loop = true end
        end
    end

    if ARREST_IMAGE_URL and ARREST_IMAGE_URL ~= "" then
        textureRequest = CS.UnityEngine.Networking.UnityWebRequestTexture.GetTexture(ARREST_IMAGE_URL)
        textureRequest:SendWebRequest()
    end

    if STAR_ICON_URL and STAR_ICON_URL ~= "" then
        starTextureRequest = CS.UnityEngine.Networking.UnityWebRequestTexture.GetTexture(STAR_ICON_URL)
        starTextureRequest:SendWebRequest()
    end

    UpdateNPCDataInFile()
end

function OnDestroy()
    if policeCar ~= nil then
        unity.Object.Destroy(policeCar)
    end
    
    ReadWantedData()
    globalWantedData[GetNPCId()] = nil
    WriteWantedData()
end

function OnInteract()
    if Player.IsAdmin then
        adminProvoked = true
        unity.Debug.Log("[NPC] Admin provoked attack")
    end
end

function Update()
    if spawnPos == nil then return end
    local dt = unity.Time.deltaTime

    -- Загрузка текстур
    if textureRequest and textureRequest.isDone then
        if not textureRequest.isNetworkError and not textureRequest.isHttpError then
            arrestTexture = CS.UnityEngine.Networking.DownloadHandlerTexture.GetContent(textureRequest)
        end
        textureRequest:Dispose()
        textureRequest = nil
    end

    if starTextureRequest and starTextureRequest.isDone then
        if not starTextureRequest.isNetworkError and not starTextureRequest.isHttpError then
            starTexture = CS.UnityEngine.Networking.DownloadHandlerTexture.GetContent(starTextureRequest)
        end
        starTextureRequest:Dispose()
        starTextureRequest = nil
    end

    -- Синхронизация
    fileReadTimer = fileReadTimer + dt
    if fileReadTimer >= FILE_READ_INTERVAL then
        fileReadTimer = 0
        SyncWantedLogic()
        UpdateNPCDataInFile()
    end

    -- Управление админа (звезды)
    if Player.IsAdmin then
        if unity.Input.GetKeyDown(unity.KeyCode.Alpha0) then
            star1Active = not star1Active
            UpdateNPCDataInFile()
        end
        if unity.Input.GetKeyDown(unity.KeyCode.Minus) then
            star2Active = not star2Active
            UpdateNPCDataInFile()
        end
        if unity.Input.GetKeyDown(unity.KeyCode.Equals) then
            star3Active = not star3Active
            UpdateNPCDataInFile()
        end
    end

    -- Проверка: арестован ли игрок другим NPC?
    local playerArrestedByOther = IsPlayerAlreadyArrested() and not isArrested and state ~= "Escorting"

    if playerArrestedByOther then
        -- СБРОС АГРЕССИИ И ВОЗВРАТ К ПАТРУЛЮ
        if state ~= "Idle" and state ~= "Wander" then
            state = "Idle"
            PlayAnim(ANIM_IDLE)
            alertPlayed = false
            delayedSoundPlayed = false
            detectionTimer = 0.0
            attackCount = 0
            adminProvoked = false
            pursuitTimer = 0.0
            -- Сбрасываем цель преследования, чтобы не стоять на месте
            targetPos = nil 
            waitTimer = RandRange(WAIT_MIN, WAIT_MAX)
        end
        -- Не делаем return, а даем коду идти дальше до блока Idle/Wander
    end

    -- === ЛОГИКА АРЕСТА (ЕСЛИ МЫ АРЕСТОВАЛИ) ===
    if isArrested then
        if arrestTimer > 0 then
            arrestTimer = arrestTimer - dt
            Player.Position = arrestPos
            PlayAnim(ANIM_IDLE)
            return
        end

        if not isEscorting then
            if policeCar ~= nil then policeCar:SetActive(true) end
            isEscorting = true
            state = "Escorting"
            hasReachedStay = false
            isPlayerSeated = false
            isPlayerLocked = false
            isSittingTimerActive = false
            PlayAnim(ANIM_RUN)
            UpdateNPCDataInFile() 
        end

        if stayPoint ~= nil and not hasReachedStay then
            local toStay = stayPoint.position - transform.position
            toStay.y = 0
            if toStay.magnitude > 0.3 then
                MoveTo(stayPoint.position, WALK_SPEED, dt)
            else
                hasReachedStay = true
                PlayAnim(ANIM_IDLE)
            end
        end

        if hasReachedStay then
            if not isSittingTimerActive then
                reachedStayTimer = 0.0
                isSittingTimerActive = true
            else
                reachedStayTimer = reachedStayTimer + dt
                if reachedStayTimer >= 1.5 and not isPlayerSeated then
                    if playerSitPoint ~= nil then
                        Player.Position = playerSitPoint.position
                        isPlayerSeated = true
                        isPlayerLocked = true
                        Chat:AddMessage(Player.Name .. " помещён в полицейскую машину.", "[00FF00]")
                    end
                    PlayAnim(ANIM_IDLE)
                end
            end
        end

        if isPlayerLocked and playerSitPoint ~= nil then
            Player.Position = playerSitPoint.position
        elseif not isPlayerSeated then
            local npcPos = transform.position
            local npcForward = transform.forward
            npcForward.y = 0
            npcForward = npcForward.normalized
            local desiredPlayerPos = npcPos - npcForward * FOLLOW_DISTANCE
            local currentPlayerPos = Player.Position
            Player.Position = unity.Vector3.Lerp(currentPlayerPos, desiredPlayerPos, dt * FOLLOW_SMOOTH)
        end

        if sirenaTransform ~= nil then
            sirenaTransform:Rotate(0, SIRENA_ROT_SPEED * dt, 0)
            if sirenaAudio and not sirenaAudio.isPlaying then
                sirenaAudio:Play()
            end
        end

        return
    end

    -- Если игрок арестован другим, пропускаем логику агрессии и идем сразу к патрулю
    if not playerArrestedByOther then
        local playerPos = Player.Position
        local dist = unity.Vector3.Distance(transform.position, playerPos)

        local shouldAggro = dist <= CHASE_RADIUS and ((not Player.IsAdmin) or adminProvoked)

        if shouldAggro then
            if not alertPlayed then
                if alertAudio then alertAudio:Play() end
                alertPlayed = true
                delayedSoundPlayed = false
                detectionTimer = 0.0
            end

            if not delayedSoundPlayed then
                detectionTimer = detectionTimer + dt
                if detectionTimer >= 2.0 then
                    local chosenAudio = nil
                    if delayedAudio and delayedAudio2 then
                        chosenAudio = unity.Random.value < 0.5 and delayedAudio or delayedAudio2
                    elseif delayedAudio then chosenAudio = delayedAudio
                    elseif delayedAudio2 then chosenAudio = delayedAudio2 end
                    
                    if chosenAudio then chosenAudio:Play() end
                    delayedSoundPlayed = true
                end
            end
            
            if not star1Active then
                star1Active = true
                UpdateNPCDataInFile()
            end
            
            pursuitTimer = pursuitTimer + dt
            if pursuitTimer >= PURSUIT_TIME_FOR_SECOND_STAR and not star2Active then
                star2Active = true
                UpdateNPCDataInFile()
            end
        else
            if alertPlayed then
                alertPlayed = false
                delayedSoundPlayed = false
                detectionTimer = 0.0
                attackCount = 0
                adminProvoked = false
                if star1Active then
                    star1Active = false
                    pursuitTimer = 0.0
                    UpdateNPCDataInFile()
                end
            end
        end

        if state == "Attacking" then
            attackTimer = attackTimer - dt
            if attackTimer <= 0 then
                attackCount = attackCount + 1
                if attackCount >= MAX_ATTACKS then
                    isArrested = true
                    arrestTimer = ARREST_DELAY
                    arrestPos = playerPos
                    Chat:AddMessage(Player.Name .. " был арестован!", "[FF0000]")
                    UpdateNPCDataInFile()
                    return
                end
                state = "Chase"
                PlayAnim(ANIM_RUN)
            end
            return
        end

        if shouldAggro then
            if dist <= ATTACK_DIST then
                if state ~= "Attacking" then
                    state = "Attacking"
                    attackTimer = ATTACK_COOLDOWN
                    PlayAnim(ANIM_ATTACK)
                    Player:TakeDamage(ATTACK_DAMAGE)
                    if attackAudio then attackAudio:Play() end
                end
            else
                if state ~= "Chase" then
                    state = "Chase"
                    PlayAnim(ANIM_RUN)
                end
                MoveTo(playerPos, CHASE_SPEED, dt)
            end
            -- Если мы в аггро, не выполняем логику патруля ниже
            return 
        end
    end

    -- === ЛОГИКА ПАТРУЛЯ (IDLE / WANDER) ===
    -- Сюда попадаем, если нет аггро ИЛИ если игрок арестован другим NPC
    if state == "Chase" or state == "Attacking" then
        state = "Idle"
        PlayAnim(ANIM_IDLE)
        waitTimer = RandRange(WAIT_MIN, WAIT_MAX)
    end

    if state == "Idle" then
        waitTimer = waitTimer - dt
        if waitTimer <= 0 then
            state = "Wander"
            targetPos = GetRandomPoint()
            PlayAnim(ANIM_RUN)
        end
    elseif state == "Wander" then
        if targetPos == nil then
            state = "Idle"
            waitTimer = RandRange(WAIT_MIN, WAIT_MAX)
        else
            local to = targetPos - transform.position
            if to.magnitude < 0.5 then
                state = "Idle"
                waitTimer = RandRange(WAIT_MIN, WAIT_MAX)
                PlayAnim(ANIM_IDLE)
            else
                MoveTo(targetPos, WALK_SPEED, dt)
            end
        end
    end
end

function OnGUI()
    if isArrested and arrestTexture ~= nil then
        local screenW = unity.Screen.width
        local screenH = unity.Screen.height
        local imgW = 200
        local imgH = 200
        local margin = 20
        local rect = unity.Rect(screenW - imgW - margin, screenH - imgH - margin, imgW, imgH)
        unity.GUI.DrawTexture(rect, arrestTexture)
    end

    -- Отрисовка звезд: 1 (слева), 2 (центр), 3 (справа у края)
    if starTexture ~= nil then
        local screenW = unity.Screen.width
        local iconSize = 40
        local margin = 10
        local spacing = 5

        -- Правый край экрана минус отступ минус ширина иконки = позиция 3-й звезды
        local rightMostX = screenW - margin - iconSize
        local startY = margin

        -- Рисуем от 3 к 1, чтобы расположить их справа налево визуально, 
        -- но индекс 1 будет слева в группе.
        -- Порядок отрисовки: 3 (справа), 2 (центр), 1 (слева в группе)
        for i = 3, 1, -1 do
            local isActive = false
            if i == 1 then isActive = star1Active
            elseif i == 2 then isActive = star2Active
            elseif i == 3 then isActive = star3Active
            end

            -- Вычисляем X. 
            -- i=3: offset = 0 -> x = rightMostX
            -- i=2: offset = size+space -> x = rightMostX - (size+space)
            -- i=1: offset = 2*(size+space) -> x = rightMostX - 2*(size+space)
            local offset = (3 - i) * (iconSize + spacing)
            local x = rightMostX - offset
            local y = startY
            local rect = unity.Rect(x, y, iconSize, iconSize)

            if not isActive then
                unity.GUI.color = unity.Color(0.5, 0.5, 0.5, 1.0)
            else
                unity.GUI.color = unity.Color(1.0, 1.0, 1.0, 1.0)
            end

            unity.GUI.DrawTexture(rect, starTexture)
        end
        
        unity.GUI.color = unity.Color(1.0, 1.0, 1.0, 1.0)
    end
end
