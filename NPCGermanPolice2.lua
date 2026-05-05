local unity = CS.UnityEngine

-- === НАСТРОЙКИ ===
local CHASE_RADIUS    = 70.0
local ATTACK_DIST     = 1.5
local CHASE_SPEED     = 3.5
local ATTACK_COOLDOWN = 0.5
local ATTACK_DAMAGE   = 0
local MAX_ATTACKS     = 5
local ANIM_RUN        = "run_3"
local ANIM_ATTACK     = "dig"
local ANIM_IDLE       = "idle"

-- === НАСТРОЙКИ СОБАКИ ===
local DOG_CHASE_SPEED = 5.5
local DOG_ANIM_RUN    = "run_0"
local DOG_ANIM_IDLE   = "idle_3"
local DOG_SOUND_INTERVAL = 5.0
local DOG_ATTACK_DIST = 2.0
local DOG_ATTACK_COOLDOWN = 0.5
local DOG_ATTACK_DAMAGE = 0 

-- URL картинки, которая появится при аресте
local ARREST_IMAGE_URL = "https://raw.githubusercontent.com/0x2171/DiggerMod/refs/heads/main/narucniki.png"
local STAR_ICON_URL = "https://raw.githubusercontent.com/0x2171/DiggerMod/refs/heads/main/CopIcon.png"

-- === ПУТЬ К ФАЙЛУ (ЛОКАЛЬНЫЙ КЭШ) ===
local PROPERTIES_FILE_PATH = "C:\\\\DANZIG\\\\properties.json"
local PURSUIT_TIME_FOR_SECOND_STAR = 20.0
local MIN_PLAYERS_FOR_THIRD_STAR = 3

-- === СЕТЕВЫЕ СОБЫТИЯ ===
local EVT_SYNC_STATE    = "NPC:SyncState"
local EVT_SYNC_POS      = "NPC:SyncPos"
local EVT_SYNC_WANTED   = "NPC:SyncWanted"
local EVT_SYNC_ARREST   = "NPC:SyncArrest"
local EVT_SYNC_DOG      = "NPC:SyncDog"
local EVT_SYNC_CAR      = "NPC:SyncCar"
local EVT_SYNC_ANIM     = "NPC:SyncAnim"

-- === ТАЙМЕРЫ СИНХРОНИЗАЦИИ ===
local POS_SYNC_INTERVAL   = 0.15
local STATE_SYNC_INTERVAL = 0.3
local WANTED_SYNC_INTERVAL = 0.5
local posSyncTimer = 0
local stateSyncTimer = 0
local wantedSyncTimer = 0
local lastSentState = nil
local lastSentPos = nil

-- === ПЕРЕМЕННЫЕ ДЛЯ ТЕКСТУР ===
local arrestTexture = nil
local starTexture = nil
local textureRequest = nil
local starTextureRequest = nil

-- === СОСТОЯНИЕ NPC ===
local animation = nil
local alertAudio = nil
local attackAudio = nil
local delayedAudio = nil
local delayedAudio2 = nil
local alertPlayed = false
local delayedSoundPlayed = false
local detectionTimer = 0
local state = "Idle"
local attackCount = 0
local isArrestedLocal = false
local arrestPos = nil
local attackTimer = 0
local spawnPos = nil
local targetPos = nil
local waitTimer = 0
local WANDER_RADIUS = 10
local WAIT_MIN = 1
local WAIT_MAX = 3
local WALK_SPEED = 1.6
local adminProvoked = false

-- === ПЕР-ПЛЕЕР РОЗЫСК ===
local wantedData = {}
local fileReadTimer = 0
local FILE_READ_INTERVAL = 0.5

-- === СОБАКА ===
local dogObject = nil
local dogAnimation = nil
local dogAudioSource = nil
local dogChaseTimer = 0
local dogLastSoundTime = 0
local dogIsActive = false
local dogLastAttackTime = 0

-- === АРЕСТ И МАШИНА ===
local policeCar = nil
local stayPoint = nil
local playerSitPoint = nil
local carSpawned = false
local arrestTimer = 0
local ARREST_DELAY = 1.5
local isEscorting = false
local FOLLOW_DISTANCE = 1.5
local FOLLOW_SMOOTH = 10
local hasReachedStay = false
local reachedStayTimer = 0
local isSittingTimerActive = false
local isPlayerSeated = false
local isPlayerLocked = false
local arrestedPlayerName = nil

-- === СИРЕНА ===
local sirenaTransform = nil
local sirenaAudio = nil
local SIRENA_ROT_SPEED = 180

-- === ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ ===
local function RandRange(a, b) return unity.Random.Range(a, b) end
local function PlayAnim(name) if animation then animation:Play(name) end end

-- === JSON: Сериализация ===
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

-- === JSON: Парсинг (улучшенный) ===
local function ParseSimpleJson(jsonStr)
    local result = {}
    if not jsonStr or jsonStr == "" then return result end
    local clean = jsonStr:gsub("^%s*{", ""):gsub("}%s*$", ""):gsub("\n", " ")
    
    for key, val in clean:gmatch('"([^"]+)"%s*:%s*([^,}]+)') do
        val = val:gsub("^%s*", ""):gsub("%s*$", "")
        if val == "true" then
            result[key] = true
        elseif val == "false" then
            result[key] = false
        else
            -- Гарантированная конвертация в число, если возможно
            local num = tonumber(val)
            if num then
                result[key] = num
            else
                result[key] = val:gsub('"', "")
            end
        end
    end
    return result
end

-- === РАБОТА С ФАЙЛОМ ===
local function EnsureDirectoryExists(path)
    local dir = CS.System.IO.Path.GetDirectoryName(path)
    if dir and not CS.System.IO.Directory.Exists(dir) then
        CS.System.IO.Directory.CreateDirectory(dir)
    end
end

local function ReadWantedCache()
    wantedData = {}
    if not CS.System.IO.File.Exists(PROPERTIES_FILE_PATH) then return end
    
    local content = CS.System.IO.File.ReadAllText(PROPERTIES_FILE_PATH)
    if not content or content == "" then return end
    
    local parsed = ParseSimpleJson(content)
    if type(parsed) ~= "table" then return end
    
    for key, val in pairs(parsed) do
        local pname, field = key:match("^([^_]+)_(.+)$")
        if pname and field then
            wantedData[pname] = wantedData[pname] or {}
            if field == "star1" or field == "star2" or field == "star3" then
                wantedData[pname][field] = (val == true)
            elseif field == "pursuitTimer" then
                wantedData[pname][field] = type(val) == "number" and val or 0
            else
                wantedData[pname][field] = val
            end
        end
    end
end

local function WriteWantedCache()
    EnsureDirectoryExists(PROPERTIES_FILE_PATH)
    local flat = {}
    
    if type(wantedData) == "table" then
        for pname, pdata in pairs(wantedData) do
            if type(pdata) == "table" then
                for field, val in pairs(pdata) do
                    flat[pname .. "_" .. field] = val
                end
            end
        end
    end
    
    local jsonStr = SerializeTable(flat)
    CS.System.IO.File.WriteAllText(PROPERTIES_FILE_PATH, jsonStr)
end

local function GetNPCId()
    return "DNPC_German_Police_" .. tostring(transform:GetInstanceID())
end

-- === СЕТЕВЫЕ ФУНКЦИИ: ОТПРАВКА ===
local function GetLocalPlayerName()
    return Player.Name or "Unknown"
end

local function BroadcastState()
    local payload = {
        npcId = GetNPCId(),
        state = state,
        isArrestedLocal = isArrestedLocal,
        arrestedPlayerName = arrestedPlayerName,
        attackCount = attackCount,
        adminProvoked = adminProvoked,
        isEscorting = isEscorting,
        hasReachedStay = hasReachedStay,
        isPlayerSeated = isPlayerSeated
    }
    self:SendEvent(EVT_SYNC_STATE, false, SerializeTable(payload))
end

local function BroadcastPosition(force)
    local pos = transform.position
    local rot = transform.eulerAngles
    
    if not force and lastSentPos then
        local dx = pos.x - lastSentPos.x
        local dy = pos.y - lastSentPos.y
        local dz = pos.z - lastSentPos.z
        if dx*dx + dy*dy + dz*dz < 0.01 then return end
    end
    
    lastSentPos = {x=pos.x, y=pos.y, z=pos.z}
    local payload = {
        npcId = GetNPCId(),
        x = pos.x, y = pos.y, z = pos.z,
        rotX = rot.x, rotY = rot.y, rotZ = rot.z
    }
    self:SendEvent(EVT_SYNC_POS, false, SerializeTable(payload))
end

local function BroadcastWantedForPlayer(playerName)
    local pdata = wantedData[playerName] or {}
    local payload = {
        npcId = GetNPCId(),
        targetPlayer = playerName,
        star1 = pdata.star1 or false,
        star2 = pdata.star2 or false,
        star3 = pdata.star3 or false,
        pursuitTimer = pdata.pursuitTimer or 0,
        arrestedBy = pdata.arrestedBy
    }
    self:SendEvent(EVT_SYNC_WANTED, true, SerializeTable(payload))
end

local function BroadcastArrest(playerName, arrested, arrestNpcId)
    local payload = {
        npcId = GetNPCId(),
        targetPlayer = playerName,
        isArrested = arrested,
        arrestedByNpc = arrestNpcId,
        pos = arrested and {x=transform.position.x, y=transform.position.y, z=transform.position.z} or nil
    }
    self:SendEvent(EVT_SYNC_ARREST, true, SerializeTable(payload))
end

local function BroadcastDog(active, pos)
    local payload = {
        npcId = GetNPCId(),
        dogActive = active,
        dogPos = pos and {x=pos.x, y=pos.y, z=pos.z} or nil
    }
    self:SendEvent(EVT_SYNC_DOG, false, SerializeTable(payload))
end

local function BroadcastCar(active, pos, rot)
    if policeCar == nil then return end
    local payload = {
        npcId = GetNPCId(),
        carActive = active,
        carPos = pos and {x=pos.x, y=pos.y, z=pos.z} or nil,
        carRot = rot and {x=rot.x, y=rot.y, z=rot.z} or nil
    }
    self:SendEvent(EVT_SYNC_CAR, false, SerializeTable(payload))
end

local function BroadcastAnim(animName)
    local payload = { npcId = GetNPCId(), anim = animName }
    self:SendEvent(EVT_SYNC_ANIM, false, SerializeTable(payload))
end

-- === СЕТЕВЫЕ ФУНКЦИИ: ПРИЁМ (ИСПРАВЛЕНО) ===
function ReceiveEvent(eventName, arg)
    if not arg then return end
    
    -- 🔧 БЕЗОПАСНОЕ ПОЛУЧЕНИЕ ПЕРВОГО ЭЛЕМЕНТА
    local firstArg = nil
    local success, result = pcall(function() return arg[0] end)
    if success and result ~= nil then
        firstArg = result
    else
        -- Пробуем 1-индексацию как запасной вариант
        success, result = pcall(function() return arg[1] end)
        if success and result ~= nil then
            firstArg = result
        else
            return
        end
    end
    
    local dataStr = tostring(firstArg)
    local data = ParseSimpleJson(dataStr)
    if not data or not data.npcId then return end
    
    if data.npcId == GetNPCId() and self:IsOwner() then return end
    
    local myName = GetLocalPlayerName()
    
    if eventName == EVT_SYNC_STATE then
        if data.state then state = data.state end
        if data.isArrestedLocal ~= nil then isArrestedLocal = data.isArrestedLocal end
        if data.arrestedPlayerName then arrestedPlayerName = data.arrestedPlayerName end
        if data.attackCount then attackCount = data.attackCount end
        if data.adminProvoked ~= nil then adminProvoked = data.adminProvoked end
        if data.isEscorting ~= nil then isEscorting = data.isEscorting end
        if data.hasReachedStay ~= nil then hasReachedStay = data.hasReachedStay end
        if data.isPlayerSeated ~= nil then isPlayerSeated = data.isPlayerSeated end
        
    elseif eventName == EVT_SYNC_POS then
        -- 🔧 ИСПРАВЛЕНО: tonumber() для всех координат
        if data.x and data.y and data.z then
            local x = tonumber(data.x)
            local y = tonumber(data.y)
            local z = tonumber(data.z)
            if x and y and z then
                transform.position = unity.Vector3(x, y, z)
            end
        end
        if data.rotY then
            local rotY = tonumber(data.rotY)
            if rotY then
                local eul = transform.eulerAngles
                transform.eulerAngles = unity.Vector3(eul.x, rotY, eul.z)
            end
        end
        
    elseif eventName == EVT_SYNC_WANTED then
        if data.targetPlayer and data.targetPlayer == myName then
            wantedData[myName] = wantedData[myName] or {}
            local wd = wantedData[myName]
            if data.star1 ~= nil then wd.star1 = data.star1 end
            if data.star2 ~= nil then wd.star2 = data.star2 end
            if data.star3 ~= nil then wd.star3 = data.star3 end
            if data.pursuitTimer then wd.pursuitTimer = tonumber(data.pursuitTimer) or 0 end
            if data.arrestedBy then wd.arrestedBy = data.arrestedBy end
            WriteWantedCache()
        elseif data.targetPlayer then
            wantedData[data.targetPlayer] = wantedData[data.targetPlayer] or {}
            local wd = wantedData[data.targetPlayer]
            if data.star1 ~= nil then wd.star1 = data.star1 end
            if data.star2 ~= nil then wd.star2 = data.star2 end
            if data.pursuitTimer then wd.pursuitTimer = tonumber(data.pursuitTimer) or 0 end
        end
        
    elseif eventName == EVT_SYNC_ARREST then
        if data.targetPlayer == myName and data.isArrested ~= nil then
            if data.isArrested then
                if not isArrestedLocal and state ~= "Escorting" then
                    if alertPlayed then
                        alertPlayed = false
                        delayedSoundPlayed = false
                        detectionTimer = 0
                        attackCount = 0
                    end
                    if wantedData[myName] then
                        wantedData[myName].arrestedBy = data.arrestedByNpc
                    end
                end
            else
                if wantedData[myName] then
                    wantedData[myName].arrestedBy = nil
                end
            end
        end
        
    elseif eventName == EVT_SYNC_DOG then
        if data.dogActive ~= nil and dogObject ~= nil then
            dogIsActive = data.dogActive
            dogObject:SetActive(dogIsActive)
            if data.dogPos and dogIsActive then
                -- 🔧 ИСПРАВЛЕНО: tonumber() для координат собаки
                local x = tonumber(data.dogPos.x)
                local y = tonumber(data.dogPos.y)
                local z = tonumber(data.dogPos.z)
                if x and y and z then
                    dogObject.transform.position = unity.Vector3(x, y, z)
                end
            end
        end
        
    elseif eventName == EVT_SYNC_CAR then
        if policeCar ~= nil and data.carActive ~= nil then
            policeCar:SetActive(data.carActive)
            if data.carPos then
                -- 🔧 ИСПРАВЛЕНО: tonumber() для координат машины
                local x = tonumber(data.carPos.x)
                local y = tonumber(data.carPos.y)
                local z = tonumber(data.carPos.z)
                if x and y and z then
                    policeCar.transform.position = unity.Vector3(x, y, z)
                end
            end
            if data.carRot then
                -- 🔧 ИСПРАВЛЕНО: tonumber() для вращения машины
                local x = tonumber(data.carRot.x)
                local y = tonumber(data.carRot.y)
                local z = tonumber(data.carRot.z)
                if x and y and z then
                    policeCar.transform.eulerAngles = unity.Vector3(x, y, z)
                end
            end
        end
        
    elseif eventName == EVT_SYNC_ANIM then
        if data.anim and animation then
            animation:Play(data.anim)
        end
    end
end

-- === ЛОГИКА РОЗЫСКА ===
local function GetPlayerWanted(playerName)
    return wantedData[playerName] or {star1=false, star2=false, star3=false, pursuitTimer=0}
end

local function ValidateWantedLevel(playerName)
    if not playerName or playerName == "Unknown" then return end
    
    local wd = wantedData[playerName]
    if not wd then return end
    
    local needsUpdate = false
    local playerPos = Player.Position
    local npcPos = transform.position
    
    if playerPos and npcPos then
        local dist = unity.Vector3.Distance(playerPos, npcPos)
        if dist > CHASE_RADIUS * 2 then
            if wd.star1 or wd.star2 or wd.star3 or (wd.pursuitTimer and wd.pursuitTimer > 0) then
                wd.star1 = false
                wd.star2 = false
                wd.star3 = false
                wd.pursuitTimer = 0
                needsUpdate = true
            end
        end
    end
    
    if wd.pursuitTimer and (wd.pursuitTimer < 0 or wd.pursuitTimer > 3600) then
        wd.pursuitTimer = 0
        needsUpdate = true
    end
    
    if wd.star1 == false and (wd.star2 or wd.star3) then
        wd.star2 = false
        wd.star3 = false
        needsUpdate = true
    end
    
    if wd.star2 == false and wd.star3 then
        wd.star3 = false
        needsUpdate = true
    end
    
    if needsUpdate then
        WriteWantedCache()
        BroadcastWantedForPlayer(playerName)
    end
end

local function UpdatePlayerWanted(playerName, field, value)
    wantedData[playerName] = wantedData[playerName] or {}
    wantedData[playerName][field] = value
    WriteWantedCache()
    BroadcastWantedForPlayer(playerName)
end

local function RecalculateThirdStar(playerName)
    local activePursuits = 0
    for _, wd in pairs(wantedData) do
        if wd.star1 and wd.pursuitTimer and wd.pursuitTimer > 0 then
            activePursuits = activePursuits + 1
        end
    end
    local shouldStar3 = activePursuits >= MIN_PLAYERS_FOR_THIRD_STAR
    if wantedData[playerName] and wantedData[playerName].star3 ~= shouldStar3 then
        wantedData[playerName].star3 = shouldStar3
        WriteWantedCache()
        BroadcastWantedForPlayer(playerName)
    end
end

-- === ДВИЖЕНИЕ ===
local function GetRandomPoint()
    local r = RandRange(0, WANDER_RADIUS)
    local a = RandRange(0, 6.283185)
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
        RotateTo(dir, dt * 8)
    end
end

-- === UNITY CALLBACKS ===
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

    -- === Инициализация собаки ===
    local dogSpawnObj = transform:Find("DogSpawn")
    if dogSpawnObj ~= nil then
        local dogTransform = dogSpawnObj:Find("dog")
        if dogTransform ~= nil then
            dogObject = dogTransform.gameObject
            if dogObject ~= nil then
                dogObject:SetActive(false)
                local dogChild = dogObject.transform:Find("Dog")
                if dogChild ~= nil then
                    dogAnimation = dogChild.gameObject:GetComponent(typeof(unity.Animation))
                end
                dogAudioSource = dogObject:GetComponent(typeof(unity.AudioSource))
            end
        end
    end

    -- === Инициализация машины ===
    local polCarChild = transform:Find("PolicayCar")
    if polCarChild ~= nil then
        policeCar = polCarChild.gameObject
        policeCar:SetActive(false)

        local stayObj = policeCar.transform:Find("StayPoint")
        if stayObj ~= nil then stayPoint = stayObj end
        local sitObj = policeCar.transform:Find("PlayerSitPoint")
        if sitObj ~= nil then playerSitPoint = sitObj end

        local sirenaObj = policeCar.transform:Find("SirenRoot/Sirena")
        if sirenaObj ~= nil then
            sirenaTransform = sirenaObj
            sirenaAudio = sirenaObj.gameObject:GetComponent(typeof(unity.AudioSource))
            if sirenaAudio then sirenaAudio.loop = true end
        end
    end

    -- === Загрузка текстур ===
    if ARREST_IMAGE_URL and ARREST_IMAGE_URL ~= "" then
        textureRequest = CS.UnityEngine.Networking.UnityWebRequestTexture.GetTexture(ARREST_IMAGE_URL)
        textureRequest:SendWebRequest()
    end
    if STAR_ICON_URL and STAR_ICON_URL ~= "" then
        starTextureRequest = CS.UnityEngine.Networking.UnityWebRequestTexture.GetTexture(STAR_ICON_URL)
        starTextureRequest:SendWebRequest()
    end

    -- === Инициализация кэша ===
    ReadWantedCache()
    local myName = GetLocalPlayerName()
    ValidateWantedLevel(myName)
    
    BroadcastState()
    BroadcastPosition(true)
    BroadcastCar(policeCar and policeCar.activeSelf, policeCar and policeCar.transform.position, policeCar and policeCar.transform.eulerAngles)
    BroadcastDog(dogIsActive, dogObject and dogObject.transform.position)
end

function OnDestroy()
    if dogObject ~= nil then
        unity.Object.Destroy(dogObject)
        dogObject = nil
        dogIsActive = false
    end
    if policeCar ~= nil then
        unity.Object.Destroy(policeCar)
    end
    if arrestedPlayerName and wantedData[arrestedPlayerName] then
        wantedData[arrestedPlayerName].arrestedBy = nil
        WriteWantedCache()
        BroadcastArrest(arrestedPlayerName, false, nil)
    end
end

function OnInteract()
    if Player.IsAdmin then
        adminProvoked = true
        BroadcastState()
    end
end

function Update()
    if spawnPos == nil then return end
    local dt = unity.Time.deltaTime
    local myName = GetLocalPlayerName()
    local playerPos = Player.Position
    local distToPlayer = unity.Vector3.Distance(transform.position, playerPos)

    -- === Загрузка текстур ===
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

    -- === Таймеры синхронизации ===
    posSyncTimer = posSyncTimer + dt
    if posSyncTimer >= POS_SYNC_INTERVAL then
        posSyncTimer = 0
        BroadcastPosition()
    end
    stateSyncTimer = stateSyncTimer + dt
    if stateSyncTimer >= STATE_SYNC_INTERVAL then
        stateSyncTimer = 0
        local curStateKey = state .. "|".. tostring(isArrestedLocal) .. "|".. tostring(attackCount)
        if curStateKey ~= lastSentState then
            lastSentState = curStateKey
            BroadcastState()
        end
    end
    wantedSyncTimer = wantedSyncTimer + dt
    if wantedSyncTimer >= WANTED_SYNC_INTERVAL and wantedData[myName] then
        wantedSyncTimer = 0
        BroadcastWantedForPlayer(myName)
        RecalculateThirdStar(myName)
    end

    -- === Локальный кэш файла ===
    fileReadTimer = fileReadTimer + dt
    if fileReadTimer >= FILE_READ_INTERVAL then
        fileReadTimer = 0
        ReadWantedCache()
        ValidateWantedLevel(myName)
        WriteWantedCache()
    end
    
    ValidateWantedLevel(myName)

    -- === Админ-управление ===
    if Player.IsAdmin then
        if unity.Input.GetKeyDown(unity.KeyCode.Alpha0) then
            wantedData[myName] = wantedData[myName] or {}
            wantedData[myName].star1 = not (wantedData[myName].star1 or false)
            WriteWantedCache()
            BroadcastWantedForPlayer(myName)
        end
        if unity.Input.GetKeyDown(unity.KeyCode.Minus) then
            wantedData[myName] = wantedData[myName] or {}
            wantedData[myName].star2 = not (wantedData[myName].star2 or false)
            WriteWantedCache()
            BroadcastWantedForPlayer(myName)
        end
        if unity.Input.GetKeyDown(unity.KeyCode.Equals) then
            wantedData[myName] = wantedData[myName] or {}
            wantedData[myName].star3 = not (wantedData[myName].star3 or false)
            WriteWantedCache()
            BroadcastWantedForPlayer(myName)
        end
    end

    -- === Проверка: арестован ли игрок ДРУГИМ NPC ===
    local wd = wantedData[myName] or {}
    local arrestedByOther = wd.arrestedBy and wd.arrestedBy ~= GetNPCId() and not isArrestedLocal

    if arrestedByOther then
        if state ~= "Idle" and state ~= "Wander" then
            state = "Idle"
            PlayAnim(ANIM_IDLE)
            BroadcastAnim(ANIM_IDLE)
            alertPlayed = false
            delayedSoundPlayed = false
            detectionTimer = 0
            attackCount = 0
            adminProvoked = false
            if wd then wd.pursuitTimer = 0 end
            targetPos = nil
            waitTimer = RandRange(WAIT_MIN, WAIT_MAX)
            BroadcastState()
        end
    end

    -- === ЛОГИКА СОБАКИ ===
    if dogIsActive and dogObject ~= nil then
        local dogPos = dogObject.transform.position
        if arrestedByOther or isArrestedLocal then
            if dogAnimation then dogAnimation:Play(DOG_ANIM_IDLE) end
            if dogAudioSource and dogAudioSource.isPlaying then dogAudioSource:Stop() end
        else
            local dir = playerPos - dogPos
            dir.y = 0
            if dir.sqrMagnitude > 0.0001 then
                dir = dir.normalized
                local d = unity.Vector3.Distance(dogPos, playerPos)
                dogObject.transform.position = dogPos + dir * math.min(d, DOG_CHASE_SPEED * dt)
                dogObject.transform.rotation = unity.Quaternion.Slerp(
                    dogObject.transform.rotation,
                    unity.Quaternion.LookRotation(dir),
                    dt * 8
                )
            end
            if unity.Vector3.Distance(dogPos, playerPos) <= DOG_ATTACK_DIST then
                if unity.Time.time - dogLastAttackTime >= DOG_ATTACK_COOLDOWN then
                    dogLastAttackTime = unity.Time.time
                    Player:TakeDamage(DOG_ATTACK_DAMAGE)
                end
            end
            if dogAnimation then dogAnimation:Play(DOG_ANIM_RUN) end
            dogLastSoundTime = dogLastSoundTime + dt
            if dogLastSoundTime >= DOG_SOUND_INTERVAL then
                dogLastSoundTime = 0
                if dogAudioSource then dogAudioSource:Play() end
            end
        end
    end

    -- === ЛОГИКА АРЕСТА ===
    if isArrestedLocal then
        if arrestTimer > 0 then
            arrestTimer = arrestTimer - dt
            Player.Position = arrestPos
            PlayAnim(ANIM_IDLE)
            return
        end
        if not isEscorting then
            if policeCar ~= nil and not carSpawned then
                policeCar.transform:SetParent(nil)
                policeCar.transform.position = transform.position - transform.right * -8
                policeCar.transform.rotation = transform.rotation
                carSpawned = true
            end

            if policeCar ~= nil then
                policeCar:SetActive(true)
                BroadcastCar(true, policeCar.transform.position, policeCar.transform.eulerAngles)
            end
            isEscorting = true
            state = "Escorting"
            hasReachedStay = false
            isPlayerSeated = false
            isPlayerLocked = false
            isSittingTimerActive = false
            PlayAnim(ANIM_RUN)
            BroadcastState()
            BroadcastAnim(ANIM_RUN)
        end
        if stayPoint ~= nil and not hasReachedStay then
            local toStay = stayPoint.position - transform.position
            toStay.y = 0
            if toStay.magnitude > 0.3 then
                MoveTo(stayPoint.position, WALK_SPEED, dt)
            else
                hasReachedStay = true
                PlayAnim(ANIM_IDLE)
                BroadcastAnim(ANIM_IDLE)
            end
        end
        if hasReachedStay then
            if not isSittingTimerActive then
                reachedStayTimer = 0
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
                    BroadcastAnim(ANIM_IDLE)
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

    -- === ЛОГИКА АГГРО ===
    if not arrestedByOther then
        local shouldAggro = distToPlayer <= CHASE_RADIUS and ((not Player.IsAdmin) or adminProvoked)
        local wd = wantedData[myName] or {}

        if shouldAggro then
            if not alertPlayed then
                if alertAudio then alertAudio:Play() end
                alertPlayed = true
                delayedSoundPlayed = false
                detectionTimer = 0
            end
            if not delayedSoundPlayed then
                detectionTimer = detectionTimer + dt
                if detectionTimer >= 2.0 then
                    local chosen = nil
                    if delayedAudio and delayedAudio2 then
                        chosen = unity.Random.value < 0.5 and delayedAudio or delayedAudio2
                    elseif delayedAudio then chosen = delayedAudio
                    elseif delayedAudio2 then chosen = delayedAudio2 end
                    if chosen then chosen:Play() end
                    delayedSoundPlayed = true
                end
            end

            if not wd.star1 then
                UpdatePlayerWanted(myName, "star1", true)
            end
            wd.pursuitTimer = (wd.pursuitTimer or 0) + dt
            UpdatePlayerWanted(myName, "pursuitTimer", wd.pursuitTimer)

            if wd.pursuitTimer >= PURSUIT_TIME_FOR_SECOND_STAR and not wd.star2 then
                UpdatePlayerWanted(myName, "star2", true)
                if dogObject ~= nil and not dogIsActive then
                    dogObject.transform:SetParent(nil)
                    dogObject.transform.position = transform.position - transform.right * 2
                    dogObject:SetActive(true)
                    dogIsActive = true
                    dogChaseTimer = 0
                    dogLastSoundTime = 0
                    if dogAnimation then dogAnimation:Play(DOG_ANIM_RUN) end
                    if dogAudioSource then dogAudioSource:Play() end
                    BroadcastDog(true, dogObject.transform.position)
                end
            end

            RecalculateThirdStar(myName)

            if state == "Attacking" then
                attackTimer = attackTimer - dt
                if attackTimer <= 0 then
                    attackCount = attackCount + 1
                    if attackCount >= MAX_ATTACKS then
                        isArrestedLocal = true
                        arrestTimer = ARREST_DELAY
                        arrestPos = playerPos
                        arrestedPlayerName = myName
                        Chat:AddMessage(Player.Name .. " был арестован!", "[FF0000]")
                        UpdatePlayerWanted(myName, "arrestedBy", GetNPCId())
                        BroadcastArrest(myName, true, GetNPCId())
                        BroadcastState()
                        return
                    end
                    state = "Chase"
                    PlayAnim(ANIM_RUN)
                    BroadcastState()
                    BroadcastAnim(ANIM_RUN)
                end
                return
            end

            if distToPlayer <= ATTACK_DIST then
                if state ~= "Attacking" then
                    state = "Attacking"
                    attackTimer = ATTACK_COOLDOWN
                    PlayAnim(ANIM_ATTACK)
                    BroadcastAnim(ANIM_ATTACK)
                    Player:TakeDamage(ATTACK_DAMAGE)
                    if attackAudio then attackAudio:Play() end
                    BroadcastState()
                end
            else
                if state ~= "Chase" then
                    state = "Chase"
                    PlayAnim(ANIM_RUN)
                    BroadcastAnim(ANIM_RUN)
                end
                MoveTo(playerPos, CHASE_SPEED, dt)
            end
            return
        else
            if alertPlayed then
                alertPlayed = false
                delayedSoundPlayed = false
                detectionTimer = 0
                attackCount = 0
                adminProvoked = false
                if wd.star1 then
                    UpdatePlayerWanted(myName, "star1", false)
                    UpdatePlayerWanted(myName, "pursuitTimer", 0)
                    UpdatePlayerWanted(myName, "star2", false)
                end
            end
        end
    end

    -- === ПАТРУЛЬ ===
    if state == "Chase" or state == "Attacking" then
        state = "Idle"
        PlayAnim(ANIM_IDLE)
        BroadcastState()
        BroadcastAnim(ANIM_IDLE)
        waitTimer = RandRange(WAIT_MIN, WAIT_MAX)
    end

    if state == "Idle" then
        waitTimer = waitTimer - dt
        if waitTimer <= 0 then
            state = "Wander"
            targetPos = GetRandomPoint()
            PlayAnim(ANIM_RUN)
            BroadcastAnim(ANIM_RUN)
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
                BroadcastAnim(ANIM_IDLE)
            else
                MoveTo(targetPos, WALK_SPEED, dt)
            end
        end
    end
end

function OnGUI()
    if isArrestedLocal and arrestTexture ~= nil then
        local sw = unity.Screen.width
        local sh = unity.Screen.height
        local rect = unity.Rect(sw - 220, sh - 220, 200, 200)
        unity.GUI.DrawTexture(rect, arrestTexture)
    end

    if starTexture ~= nil then
        local myName = GetLocalPlayerName()
        local wd = wantedData[myName] or {star1=false, star2=false, star3=false}
        local sw = unity.Screen.width
        local iconSize = 40
        local margin = 10
        local spacing = 5
        local rightMostX = sw - margin - iconSize
        local startY = margin

        for i = 3, 1, -1 do
            local isActive = false
            if i == 1 then isActive = wd.star1
            elseif i == 2 then isActive = wd.star2
            elseif i == 3 then isActive = wd.star3 end

            local offset = (3 - i) * (iconSize + spacing)
            local x = rightMostX - offset
            local rect = unity.Rect(x, startY, iconSize, iconSize)

            unity.GUI.color = isActive and unity.Color(1,1,1,1) or unity.Color(0.5,0.5,0.5,1)
            unity.GUI.DrawTexture(rect, starTexture)
        end
        unity.GUI.color = unity.Color(1,1,1,1)
    end
end
