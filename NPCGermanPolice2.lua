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

-- === НАСТРОЙКИ РОЗЫСКА ===
local PURSUIT_TIME_FOR_SECOND_STAR = 20.0
local MIN_PLAYERS_FOR_THIRD_STAR = 3

-- === КЭШ СОСТОЯНИЯ (для синхронизации ареста между NPC) ===
local PROPERTIES_FILE_PATH = "C:\\\\DANZIG\\\\properties.json"
local FILE_READ_INTERVAL = 0.5
local fileReadTimer = 0

-- === ПЕРЕМЕННЫЕ ДЛЯ ТЕКСТУР ===
local arrestTexture = nil
local starTexture = nil
local textureRequest = nil
local starTextureRequest = nil
local _starTextureWarned = false

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

-- === ПЕР-ПЛЕЕР РОЗЫСК (в памяти + кэш ареста) ===
local wantedData = {}
local arrestedByCache = {}  -- playerName -> npcId (кто арестовал)

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

-- === ЛОКАЛЬНЫЕ ФУНКЦИИ ===
local function GetLocalPlayerName()
    return Player.Name or "Unknown"
end

local function GetNPCId()
    return "DNPC_German_Police_" .. tostring(transform:GetInstanceID())
end

-- === МИНИМАЛЬНЫЙ JSON для кэша ареста ===
local function SerializeArrestCache(data)
    local result = "{"
    local first = true
    for pname, npcId in pairs(data) do
        if not first then result = result .. "," end
        result = result .. "\"" .. pname .. "\":\"" .. npcId .. "\""
        first = false
    end
    return result .. "}"
end

local function ParseArrestCache(jsonStr)
    local result = {}
    if not jsonStr or jsonStr == "" then return result end
    for pname, npcId in jsonStr:gmatch('"([^"]+)"%s*:%s*"([^"]*)"') do
        result[pname] = npcId
    end
    return result
end

-- === РАБОТА С ФАЙЛОМ (только для кэша ареста) ===
local function EnsureDirectoryExists(path)
    local dir = CS.System.IO.Path.GetDirectoryName(path)
    if dir and not CS.System.IO.Directory.Exists(dir) then
        CS.System.IO.Directory.CreateDirectory(dir)
    end
end

local function ReadArrestCache()
    arrestedByCache = {}
    if not CS.System.IO.File.Exists(PROPERTIES_FILE_PATH) then return end
    
    local content = CS.System.IO.File.ReadAllText(PROPERTIES_FILE_PATH)
    if not content or content == "" then return end
    
    local parsed = ParseArrestCache(content)
    for pname, npcId in pairs(parsed) do
        if npcId and npcId ~= "" then
            arrestedByCache[pname] = npcId
        end
    end
    
    for pname, npcId in pairs(arrestedByCache) do
        wantedData[pname] = wantedData[pname] or {}
        wantedData[pname].arrestedBy = npcId
    end
end

local function WriteArrestCache()
    EnsureDirectoryExists(PROPERTIES_FILE_PATH)
    local arrestData = {}
    for pname, pdata in pairs(wantedData) do
        if pdata and pdata.arrestedBy then
            arrestData[pname] = pdata.arrestedBy
        end
    end
    for pname, npcId in pairs(arrestedByCache) do
        arrestData[pname] = npcId
    end
    
    local jsonStr = SerializeArrestCache(arrestData)
    CS.System.IO.File.WriteAllText(PROPERTIES_FILE_PATH, jsonStr)
end

local function UpdateArrestCache(playerName, npcId)
    if npcId then
        arrestedByCache[playerName] = npcId
        wantedData[playerName] = wantedData[playerName] or {}
        wantedData[playerName].arrestedBy = npcId
    else
        arrestedByCache[playerName] = nil
        if wantedData[playerName] then
            wantedData[playerName].arrestedBy = nil
        end
    end
    WriteArrestCache()
end

-- === ЛОГИКА РОЗЫСКА (без кэша звёзд, только память) ===
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
        wantedData[playerName] = wd
    end
end

local function UpdatePlayerWanted(playerName, field, value)
    wantedData[playerName] = wantedData[playerName] or {}
    wantedData[playerName][field] = value
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

    if ARREST_IMAGE_URL and ARREST_IMAGE_URL ~= "" then
        CS.UnityEngine.Debug.Log("[NPCGermanPolice2] Загрузка картинки ареста: " .. ARREST_IMAGE_URL)
        textureRequest = CS.UnityEngine.Networking.UnityWebRequestTexture.GetTexture(ARREST_IMAGE_URL)
        textureRequest:SendWebRequest()
    end

    if STAR_ICON_URL and STAR_ICON_URL ~= "" then
        CS.UnityEngine.Debug.Log("[NPCGermanPolice2] Загрузка иконки звезды: " .. STAR_ICON_URL)
        starTextureRequest = CS.UnityEngine.Networking.UnityWebRequestTexture.GetTexture(STAR_ICON_URL)
        starTextureRequest:SendWebRequest()
    end

    ReadArrestCache()
    local myName = GetLocalPlayerName()
    ValidateWantedLevel(myName)
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
    if arrestedPlayerName then
        UpdateArrestCache(arrestedPlayerName, nil)
    end
end

function OnInteract()
    if Player.IsAdmin then
        adminProvoked = true
        CS.UnityEngine.Debug.Log("[NPCGermanPolice2] 👮 Admin " .. Player.Name .. " provoked NPC")
    end
end

function Update()
    if spawnPos == nil then return end
    local dt = unity.Time.deltaTime
    local myName = GetLocalPlayerName()
    local playerPos = Player.Position
    local distToPlayer = unity.Vector3.Distance(transform.position, playerPos)

    if textureRequest and textureRequest.isDone then
        if not textureRequest.isNetworkError and not textureRequest.isHttpError then
            arrestTexture = CS.UnityEngine.Networking.DownloadHandlerTexture.GetContent(textureRequest)
            if arrestTexture and arrestTexture.width > 0 then
                CS.UnityEngine.Debug.Log("[NPCGermanPolice2] ✅ Arrest texture loaded: " .. arrestTexture.width .. "x" .. arrestTexture.height)
            end
        end
        textureRequest:Dispose()
        textureRequest = nil
    end
    if starTextureRequest and starTextureRequest.isDone then
        if not starTextureRequest.isNetworkError and not starTextureRequest.isHttpError then
            starTexture = CS.UnityEngine.Networking.DownloadHandlerTexture.GetContent(starTextureRequest)
            if starTexture and starTexture.width > 0 then
                CS.UnityEngine.Debug.Log("[NPCGermanPolice2] ✅ Star icon loaded: " .. starTexture.width .. "x" .. starTexture.height)
            end
        end
        starTextureRequest:Dispose()
        starTextureRequest = nil
    end

    fileReadTimer = fileReadTimer + dt
    if fileReadTimer >= FILE_READ_INTERVAL then
        fileReadTimer = 0
        ReadArrestCache()
    end

    ValidateWantedLevel(myName)

    if Player.IsAdmin then
        if unity.Input.GetKeyDown(unity.KeyCode.Alpha0) then
            wantedData[myName] = wantedData[myName] or {}
            wantedData[myName].star1 = not (wantedData[myName].star1 or false)
        end
        if unity.Input.GetKeyDown(unity.KeyCode.Minus) then
            wantedData[myName] = wantedData[myName] or {}
            wantedData[myName].star2 = not (wantedData[myName].star2 or false)
        end
        if unity.Input.GetKeyDown(unity.KeyCode.Equals) then
            wantedData[myName] = wantedData[myName] or {}
            wantedData[myName].star3 = not (wantedData[myName].star3 or false)
        end
    end

    local wd = wantedData[myName] or {}
    local arrestedByOther = wd.arrestedBy and wd.arrestedBy ~= GetNPCId() and not isArrestedLocal

    if arrestedByOther then
        if state ~= "Idle" and state ~= "Wander" then
            state = "Idle"
            PlayAnim(ANIM_IDLE)
            alertPlayed = false
            delayedSoundPlayed = false
            detectionTimer = 0
            attackCount = 0
            adminProvoked = false
            if wd then wd.pursuitTimer = 0 end
            targetPos = nil
            waitTimer = RandRange(WAIT_MIN, WAIT_MAX)
            CS.UnityEngine.Debug.Log("[NPCGermanPolice2] 🛑 Player " .. myName .. " arrested by " .. wd.arrestedBy .. " — returning to patrol")
        end
    end

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
            if policeCar ~= nil then policeCar:SetActive(true) end
            isEscorting = true
            state = "Escorting"
            hasReachedStay = false
            isPlayerSeated = false
            isPlayerLocked = false
            isSittingTimerActive = false
            PlayAnim(ANIM_RUN)
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

    -- === 🔧 ЛОГИКА АГГРО И АТАКИ ===
    if not arrestedByOther then
        local isInRadius = distToPlayer <= CHASE_RADIUS
        local isNormalPlayer = not Player.IsAdmin
        local isProvokedAdmin = Player.IsAdmin and adminProvoked
        
        if isInRadius and (isNormalPlayer or isProvokedAdmin) and not wd.star1 then
            UpdatePlayerWanted(myName, "star1", true)
        end
        
        local shouldAggro = isInRadius and (isNormalPlayer or isProvokedAdmin)

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
                end
            end

            RecalculateThirdStar(myName)

            if distToPlayer <= ATTACK_DIST then
                local canAttack = false
                if isNormalPlayer then
                    canAttack = true
                elseif isProvokedAdmin then
                    canAttack = true
                end
                
                if canAttack then
                    if state ~= "Attacking" then
                        state = "Attacking"
                        attackTimer = ATTACK_COOLDOWN
                        PlayAnim(ANIM_ATTACK)
                        CS.UnityEngine.Debug.Log("[NPCGermanPolice2] ⚔️ Attack started: " .. Player.Name)
                    end
                end
            else
                if state == "Attacking" then
                    state = "Chase"
                    PlayAnim(ANIM_RUN)
                end
                if state ~= "Chase" then
                    state = "Chase"
                    PlayAnim(ANIM_RUN)
                end
                MoveTo(playerPos, CHASE_SPEED, dt)
            end
            
            if state == "Attacking" then
                attackTimer = attackTimer - dt
                if attackTimer <= 0 then
                    if ATTACK_DAMAGE > 0 then
                        Player:TakeDamage(ATTACK_DAMAGE)
                    end
                    if attackAudio then attackAudio:Play() end
                    
                    attackCount = attackCount + 1
                    CS.UnityEngine.Debug.Log("[NPCGermanPolice2] ⚔️ Hit #" .. attackCount .. " on " .. Player.Name)
                    
                    if attackCount >= MAX_ATTACKS then
                        isArrestedLocal = true
                        arrestTimer = ARREST_DELAY
                        arrestPos = playerPos
                        arrestedPlayerName = myName
                        Chat:AddMessage(Player.Name .. " был арестован!", "[FF0000]")
                        UpdateArrestCache(myName, GetNPCId())
                        return
                    end
                    
                    state = "Chase"
                    PlayAnim(ANIM_RUN)
                end
                return
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
    if isArrestedLocal then
        if arrestTexture == nil then
            CS.UnityEngine.Debug.LogWarning("[NPCGermanPolice2] OnGUI: arrestTexture is nil")
        elseif arrestTexture.width > 0 then
            local sw, sh = unity.Screen.width, unity.Screen.height
            unity.GUI.DrawTexture(unity.Rect(sw - 220, sh - 220, 200, 200), arrestTexture)
        end
    end

    if starTexture and starTexture.width > 0 then
        local myName = GetLocalPlayerName()
        local wd = wantedData[myName] or {star1=false, star2=false, star3=false}
        local sw = unity.Screen.width
        local iconSize, margin, spacing = 40, 10, 5
        local rightMostX = sw - margin - iconSize
        local startY = margin

        for i = 3, 1, -1 do
            local isActive = (i == 1 and wd.star1) or (i == 2 and wd.star2) or (i == 3 and wd.star3)
            local offset = (3 - i) * (iconSize + spacing)
            local x = rightMostX - offset
            unity.GUI.color = isActive and unity.Color(1,1,1,1) or unity.Color(0.5,0.5,0.5,0.7)
            unity.GUI.DrawTexture(unity.Rect(x, startY, iconSize, iconSize), starTexture)
        end
        unity.GUI.color = unity.Color(1,1,1,1)
    end
end
