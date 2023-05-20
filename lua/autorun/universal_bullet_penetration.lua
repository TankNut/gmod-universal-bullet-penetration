local enabled = CreateConVar("ubp_enabled", 1, {FCVAR_ARCHIVE, FCVAR_REPLICATED}, "Is penetration enabled?", 0, 1)

local penMult = CreateConVar("ubp_penetration_multiplier", 2, {FCVAR_ARCHIVE, FCVAR_REPLICATED}, "A multiplier for how hard a bullet penetrates through materials")
local dmgMult = CreateConVar("ubp_damage_multiplier", 1, {FCVAR_ARCHIVE, FCVAR_REPLICATED}, "A multiplier for how much damage is lost after penetration")

local doShotguns = CreateConVar("ubp_shotguns", 1, {FCVAR_ARCHIVE, FCVAR_REPLICATED}, "Whether to apply penetration to shotguns (or other weapons that fire more than one bullet at a time)")
local doAlive = CreateConVar("ubp_alive", 1, {FCVAR_ARCHIVE, FCVAR_REPLICATED}, "Whether bullets can penetrate through living things (players and NPC's)")

local STEP_SIZE = 4

local function runCallback(attacker, tr, dmginfo)
	local ent = tr.Entity

	if not doAlive:GetBool() and (ent:IsPlayer() or ent:IsNPC()) then
		return
	end

	local mat = util.GetSurfaceData(tr.SurfaceProps).density / 1000

	local dist = (dmginfo:GetDamage() / mat) * penMult:GetFloat()

	local start = tr.HitPos
	local dir = tr.Normal

	local trace
	local hit = false

	for i = STEP_SIZE, dist + STEP_SIZE, STEP_SIZE do
		local endPos = start + dir * i

		local contents = util.PointContents(endPos)

		if bit.band(contents, MASK_SHOT) == 0 or bit.band(contents, CONTENTS_HITBOX) == CONTENTS_HITBOX then
			trace = util.TraceLine({
				start = endPos,
				endpos = endPos - dir * STEP_SIZE,
				mask = bit.bor(MASK_SHOT, CONTENTS_HITBOX),
			})

			if trace.StartSolid and bit.band(trace.SurfaceFlags, SURF_HITBOX) == SURF_HITBOX then
				trace = util.TraceLine({
					start = endPos,
					endpos = endPos - dir * STEP_SIZE,
					mask = MASK_SHOT,
					filter = trace.Entity
				})
			end

			if trace.HitPos == endPos - dir * STEP_SIZE then
				trace = util.TraceLine({
					start = endPos + dir * ent:BoundingRadius(),
					endpos = endPos,
					mask = bit.bor(MASK_SHOT, CONTENTS_HITBOX),
					filter = function(hent)
						return hent == ent
					end,
					ignoreworld = true
				})
			end

			hit = true

			break
		end
	end

	if hit then
		local finalDist = start:Distance(trace.HitPos)
		local ratio = 1 - (finalDist / dist)

		local damage = dmginfo:GetDamage() * ratio * dmgMult:GetFloat()

		if damage <= 1 then
			return
		end

		local effect = EffectData()

		effect:SetEntity(trace.Entity)
		effect:SetOrigin(trace.HitPos)
		effect:SetStart(trace.StartPos)
		effect:SetSurfaceProp(trace.SurfaceProps)
		effect:SetDamageType(dmginfo:GetDamageType())
		effect:SetHitBox(trace.HitBox)

		util.Effect("Impact", effect, false)

		attacker:FireBullets({
			Num = 1,
			Src = trace.HitPos + dir,
			Dir = dir,
			Damage = damage,
			Spread = vector_origin,
			Tracer = 0
		})
	end
end

local biasMin, biasMax = GetConVar("ai_shot_bias_min"), GetConVar("ai_shot_bias_max")

local function getSpread(dir, vec)
	local right = dir:Angle():Right()
	local up = dir:Angle():Up()

	local x, y, z
	local bias = 1

	local min, max = biasMin:GetFloat(), biasMax:GetFloat()

	local shotBias = ((max - min) * bias) + min
	local flatness = math.abs(bias) * 0.5

	repeat
		x = math.Rand(-1, 1) * flatness + math.Rand(-1, 1) * (1 - flatness)
		y = math.Rand(-1, 1) * flatness + math.Rand(-1, 1) * (1 - flatness)

		if shotBias < 0 then
			x = x >= 0 and 1 - x or -1 - x
			y = y >= 0 and 1 - y or -1 - y
		end

		z = x * x + y * y
	until z <= 1

	return (dir + x * vec.x * right + y * vec.y * up):GetNormalized()
end

hook.Add("EntityFireBullets", "ubp", function(ent, bullet)
	if not enabled:GetBool() then
		return
	end

	if bullet.Callback then
		local oldCallback = bullet.Callback

		bullet.Callback = function(attacker, tr, dmginfo)
			oldCallback(attacker, tr, dmginfo)
			runCallback(attacker, tr, dmginfo)
		end
	else
		bullet.Callback = runCallback
	end

	-- Callbacks are unreliable with bullets with .Num > 1 so we force them into manual mode
	if bullet.Num > 1 then
		if not doShotguns:GetBool() then
			return
		end

		local count = bullet.Num
		local dir = bullet.Dir

		bullet.Num = 1

		for i = 1, count do
			bullet.Dir = getSpread(dir, bullet.Spread)
			ent:FireBullets(bullet)
		end

		return false
	end

	return true
end)
