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
local isArrested      = false
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
local policeCar           = nil          -- независимый GameObject PolicayCar
local stayPoint           = nil          -- Transform точки StayPoint
local playerSitPoint      = nil          -- Transform точки PlayerSitPoint
local arrestTimer         = 0.0          -- таймер задержки после ареста
local ARREST_DELAY        = 1.5          -- задержка перед началом движения (сек)
local isEscorting         = false        -- флаг режима сопровождения
local FOLLOW_DISTANCE     = 1.5          -- дистанция игрока за спиной NPC (метры)
local FOLLOW_SMOOTH       = 10.0         -- плавность следования игрока
local hasReachedStay      = false        -- флаг прибытия на точку
local reachedStayTimer    = 0.0          -- таймер после прибытия на StayPoint
local isSittingTimerActive = false       -- флаг запуска таймера посадки
local isPlayerSeated      = false        -- флаг: игрок уже в машине
local isPlayerLocked      = false        -- флаг: игрок заблокирован

-- === ПЕРЕМЕННЫЕ ДЛЯ СИРЕНЫ ===
local sirenaTransform     = nil          -- Transform SirenRoot/Sirena
local sirenaAudio         = nil          -- AudioSource сирены
local SIRENA_ROT_SPEED    = 180.0        -- скорость вращения (градусов в секунду)

local function RandRange(a, b) return unity.Random.Range(a, b) end
local function PlayAnim(name) if animation then animation:Play(name) end end

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

    -- === ОТЦЕПЛЕНИЕ И СПАВН ПОЛИЦЕЙСКОЙ МАШИНЫ ===
    local polCarChild = transform:Find("PolicayCar")
    if polCarChild ~= nil then
        -- 1. Отцепляем от NPC
        polCarChild.parent = nil
        policeCar = polCarChild.gameObject
        
        -- 2. Рассчитываем позицию: 5 метров влево от NPC (по локальной оси Right)
        local sideOffset = transform.right * 5.0
        local newPos = unity.Vector3(spawnPos.x + sideOffset.x, spawnPos.y, spawnPos.z + sideOffset.z)
        
        -- 3. Применяем позицию и поворот (машина будет стоять параллельно NPC)
        policeCar.transform.position = newPos
        policeCar.transform.rotation = transform.rotation
        
        -- 4. Отключаем со старта
        policeCar:SetActive(false)
        unity.Debug.Log("[NPC] PolicayCar detached, spawned 5m to the side, and disabled")
        
        -- Ищем точки назначения
        local stayObj = policeCar.transform:Find("StayPoint")
        if stayObj ~= nil then stayPoint = stayObj end
        
        local sitObj = policeCar.transform:Find("PlayerSitPoint")
        if sitObj ~= nil then 
            playerSitPoint = sitObj 
            unity.Debug.Log("[NPC] PlayerSitPoint found")
        end

        -- === ИНИЦИАЛИЗАЦИЯ СИРЕНЫ ===
        local sirenaObj = policeCar.transform:Find("SirenRoot/Sirena")
        if sirenaObj ~= nil then
            sirenaTransform = sirenaObj
            sirenaAudio = sirenaObj.gameObject:GetComponent(typeof(unity.AudioSource))
            if sirenaAudio then
                sirenaAudio.loop = true -- гарантируем зацикливание
                unity.Debug.Log("[NPC] Siren AudioSource configured")
            end
            unity.Debug.Log("[NPC] Siren object found")
        end
    else
        unity.Debug.LogWarning("[NPC] PolicayCar not found as child of NPC!")
    end

    -- Запуск загрузки картинки
    if ARREST_IMAGE_URL and ARREST_IMAGE_URL ~= "" then
        textureRequest = CS.UnityEngine.Networking.UnityWebRequestTexture.GetTexture(ARREST_IMAGE_URL)
        textureRequest:SendWebRequest()
    end
end

function OnDestroy()
    if policeCar ~= nil then
        unity.Object.Destroy(policeCar)
        unity.Debug.Log("[NPC] PolicayCar destroyed (NPC destroyed)")
    end
end

function OnInteract()
    if Player.IsAdmin then
        adminProvoked = true
        unity.Debug.Log("[NPC] Админ спровоцировал атаку (нажал F)!")
    end
end

function Update()
    if spawnPos == nil then return end
    local dt = unity.Time.deltaTime

    -- Обработка загрузки текстуры
    if textureRequest ~= nil and textureRequest.isDone then
        local success = true
        if textureRequest.isNetworkError or textureRequest.isHttpError then
            success = false
        elseif textureRequest.error ~= nil and textureRequest.error ~= "" then
            success = false
        end
        if success then
            arrestTexture = CS.UnityEngine.Networking.DownloadHandlerTexture.GetContent(textureRequest)
        end
        textureRequest:Dispose()
        textureRequest = nil
    end

    -- === РЕЖИМ АРЕСТА И СОПРОВОЖДЕНИЯ ===
    if isArrested then
        -- Фаза 1: задержка 1.5 сек, игрок "заморожен"
        if arrestTimer > 0 then
            arrestTimer = arrestTimer - dt
            Player.Position = arrestPos
            PlayAnim(ANIM_IDLE)
            return
        end
        
        -- Фаза 2: активация машины и начало сопровождения
        if not isEscorting then
            if policeCar ~= nil then
                policeCar:SetActive(true)
            end
            isEscorting = true
            state = "Escorting"
            hasReachedStay = false
            isPlayerSeated = false
            isPlayerLocked = false
            isSittingTimerActive = false
            PlayAnim(ANIM_RUN)
            unity.Debug.Log("[NPC] Escort started")
        end
        
        -- Движение NPC к StayPoint
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
        
        -- Таймер после прибытия на StayPoint
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
                        isPlayerLocked = true -- Фиксируем игрока
                        Chat:AddMessage(Player.Name .. " помещён в полицейскую машину.", "[00FF00]")
                        unity.Debug.Log("[NPC] Player locked in vehicle")
                    end
                    PlayAnim(ANIM_IDLE)
                end
            end
        end
        
        -- Логика движения/блокировки игрока
        if isPlayerLocked and playerSitPoint ~= nil then
            -- Жёсткая привязка позиции, игрок не сможет двигаться
            Player.Position = playerSitPoint.position
        elseif not isPlayerSeated then
            -- Следование за спиной NPC
            local npcPos = transform.position
            local npcForward = transform.forward
            npcForward.y = 0
            npcForward = npcForward.normalized
            
            local desiredPlayerPos = npcPos - npcForward * FOLLOW_DISTANCE
            local currentPlayerPos = Player.Position
            Player.Position = unity.Vector3.Lerp(currentPlayerPos, desiredPlayerPos, dt * FOLLOW_SMOOTH)
        end
        
        -- === СИРЕНА: Вращение и Звук ===
        if sirenaTransform ~= nil then
            -- Бесконечное вращение вокруг локальной оси Y
            sirenaTransform:Rotate(0, SIRENA_ROT_SPEED * dt, 0)
            
            -- Воспроизведение звука
            if sirenaAudio and not sirenaAudio.isPlaying then
                sirenaAudio:Play()
            end
        end
        
        return
    end

    -- === ОСНОВНАЯ ЛОГИКА (до ареста) ===
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
                elseif delayedAudio then
                    chosenAudio = delayedAudio
                elseif delayedAudio2 then
                    chosenAudio = delayedAudio2
                end
                if chosenAudio then chosenAudio:Play() end
                delayedSoundPlayed = true
            end
        end
    else
        if alertPlayed then
            alertPlayed = false
            delayedSoundPlayed = false
            detectionTimer = 0.0
            attackCount = 0
            adminProvoked = false
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
    else
        if state == "Chase" or state == "Attacking" then
            state = "Idle"
            PlayAnim(ANIM_IDLE)
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
                return
            end
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
end
