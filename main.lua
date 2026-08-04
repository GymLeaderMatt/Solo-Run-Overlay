return function(mod)
  -- Huge shoutout to the Kanto Companion mod for the inspiration. I took
  -- what it did and it turned into a whole new project entirely.
  --
  -- DISCLAIMER: This overlay requires my badge boost glitch mod. There's no
  -- way around it.
  --
  -- This is an overlay designed solely for solo running. It shows game time,
  -- resets, your Pokemon's moves, stats, growth rate, experience, and more.
  -- It also shows enemy moves and stats. Both sets of stats update in real
  -- time to show stat changes, burn debuffs, badge boost glitch effects, etc.
  --
  -- It includes a stylized badge box, a conditional repel counter, and an
  -- indicator when bags are almost full (18, 19, or 20 slots).
  --
  -- I tried to keep this minimal. I made this just for me to use and I'm
  -- happy with it. I likely will not be making many more changes, so what you
  -- see is what you get. If you use this for inspiration, give me a little
  -- credit and do your own thing!

  local OVERLAY_KEYS = { o = true, f8 = true }   -- toggle the passive overlay
  local RESETS_INC_KEY  = "]"    -- manual resets counter: +1
  local RESETS_DEC_KEY  = "["    -- manual resets counter: -1
  local RESETS_ZERO_KEY = "\\"   -- manual resets counter: reset to 0
  local REF_H      = 1440        -- design reference height; everything scales off this
  local INTERVAL   = 0.12        -- seconds between save reads

  local C = _G.__KANTO_INGAME or {}
  _G.__KANTO_INGAME = C
  if C.visible == nil then C.visible = true end    -- shown by default; O/F8 toggles it
  if C.resets == nil then C.resets = mod.save:get("resets", 0) end   -- persists across sessions
  C.fonts   = C.fonts or {}
  C.sprites = C.sprites or {}
  C.dispHP  = C.dispHP or {}      -- animated HP values keyed by "p1".."p6"/"enemy"
  C.dispSp  = C.dispSp or {}      -- species behind each animated value (reset on change)

  -- engine modules (same sources the streaming mod uses)
  local function req(p) local ok, m = pcall(require, p); return ok and m or nil end
  C.game     = C.game or req("src.core.Game")
  C.TypeChart = C.TypeChart or req("src.battle.TypeChart")
  C.Growth   = C.Growth or req("src.pokemon.Growth")
  C.Badges   = C.Badges or req("src.inventory.Badges")
  C.BattleState = C.BattleState or req("src.battle.BattleState")
  C.Bag      = C.Bag or req("src.inventory.Bag")
  C.Stats    = C.Stats or req("src.pokemon.Stats")
  C.PaletteFX = C.PaletteFX or req("src.render.PaletteFX")
  C.Status   = C.Status or req("src.battle.Status")
  mod.events:on("game.ready", function(p) C.game = (p and p.game) or C.game end)

  -- ---------------------------------------------------------------------
  -- Palette (0..1)
  -- ---------------------------------------------------------------------
  local function hex(s)
    return { tonumber(s:sub(1,2),16)/255, tonumber(s:sub(3,4),16)/255, tonumber(s:sub(5,6),16)/255 }
  end
  local COL = {
    panel = hex("10121a"), border = hex("ffffff"),
    text = hex("ffffff"), dim = hex("b9bdc9"),
    hi = hex("7dd87d"), mid = hex("e6d24a"), lo = hex("e05a5a"),
    xp = hex("5ab0ff"), gold = hex("ffd54a"), money = hex("ffe27a"),
    barbg = hex("ffffff"), threat = hex("ffb38a"),
    super = hex("7dd87d"), resist = hex("e0906a"),
  }
  local TYPE = {
    NORMAL=hex("9a9a80"), FIRE=hex("e0632c"), WATER=hex("3a86e8"), ELECTRIC=hex("e0b330"),
    GRASS=hex("5fb04a"), ICE=hex("5fc7c7"), FIGHTING=hex("b23a2e"), POISON=hex("8a3a9a"),
    GROUND=hex("c8a84a"), FLYING=hex("7a8fe0"), PSYCHIC=hex("e0508a"), BUG=hex("8a9a20"),
    ROCK=hex("a89440"), GHOST=hex("5a4a8a"), DRAGON=hex("5a4ae0"),
  }

  -- ---------------------------------------------------------------------
  -- Cheap caches: scaled fonts + species sprites
  -- ---------------------------------------------------------------------
  local function getFont(sizePx)
    sizePx = math.max(8, math.floor(sizePx))
    local f = C.fonts[sizePx]
    if not f then f = love.graphics.newFont(sizePx); C.fonts[sizePx] = f end
    return f
  end
  -- Making sure battle sprites get colored the correct way and not be greyscale.
  local function getSprite(speciesId, dPoke)
    -- Cache key includes the color scheme so it can't get stuck wrong forever.
    local def = dPoke[speciesId]
    local pal = C.PaletteFX and C.gameData and C.PaletteFX.monPal(C.gameData, speciesId)
    local cacheKey = speciesId .. ":" .. ((def and def.trueColor) and "TC" or (pal and table.concat(
      { pal[1][1],pal[1][2],pal[1][3], pal[2][1],pal[2][2],pal[2][3],
        pal[3][1],pal[3][2],pal[3][3], pal[4][1],pal[4][2],pal[4][3] }, ",") or "?"))
    if C.sprites[cacheKey] ~= nil then return C.sprites[cacheKey] or nil end
    local rel = def and def.spriteFront
    local img = false
    if rel then
      if def.trueColor then
        -- Same art the real battle screen shows: its own colors, no recolor.
        local ok0, i0 = pcall(love.graphics.newImage, rel)
        if ok0 then img = i0 end
      elseif pal and love.image and love.image.newImageData then
        local ok, id = pcall(love.image.newImageData, rel)
        if ok and id then
          id:mapPixel(function(_, _, r, g, b, a)
            if a == 0 then return r, g, b, a end
            -- Luminance, not just red -- true for all 4 vanilla grayscale
            -- shades (r=g=b, so this gives the same answer as before), and
            -- also correct for a real-color sprite, where red alone isn't
            -- a reliable stand-in for brightness.
            local lum = 0.299*r + 0.587*g + 0.114*b
            local col = lum > 0.83 and pal[1] or lum > 0.5 and pal[2] or lum > 0.17 and pal[3] or pal[4]
            return col[1] / 255, col[2] / 255, col[3] / 255, a
          end)
          local okImg, i = pcall(love.graphics.newImage, id)
          if okImg then img = i end
        end
      end
      if not img then
        -- fallback: just load it plain if coloring fails
        local ok2, i2 = pcall(love.graphics.newImage, rel)
        if ok2 then img = i2 end
      end
    end
    C.sprites[cacheKey] = img
    return img or nil
  end
  -- Separate cache for this mod's own icons (badges, bag icons).
  C.uiImages = C.uiImages or {}
  local function uiImage(path)
    if C.uiImages[path] ~= nil then return C.uiImages[path] or nil end
    local ok, img = pcall(love.graphics.newImage, path)
    C.uiImages[path] = ok and img or false
    return C.uiImages[path] or nil
  end

  -- ---------------------------------------------------------------------
  -- Reads the save data into something easy to draw.
  -- ---------------------------------------------------------------------
  local function currentBattle()
    local g = C.game; local stk = g and g.stack
    if not (stk and stk.states and C.BattleState) then return nil end
    for i = #stk.states, 1, -1 do
      if getmetatable(stk.states[i]) == C.BattleState then return stk.states[i] end
    end
    return nil
  end

  local function buildState()
    local game = C.game
    local save = game and game.save
    if not save then return nil end
    local data  = game.data or {}
    local dPoke = data.pokemon or {}
    local dMove = data.moves or {}
    C.dPoke = dPoke
    C.gameData = data

    local function dispTypes(raw)
      local o = {}
      for _, t in ipairs(raw or {}) do o[#o+1] = (C.TypeChart and C.TypeChart.displayName(t)) or t end
      return o
    end
    local function brief(mon)
      if not mon then return nil end
      local d = dPoke[mon.species]
      return {
        name = mon.nickname or (d and d.name) or tostring(mon.species),
        species = mon.species, level = mon.level, hp = mon.hp,
        maxhp = mon.stats and mon.stats.hp, status = mon.status or "OK",
        types = dispTypes(d and d.types),
        stats = mon.stats,
        baseSpeed = d and d.baseStats and d.baseStats.speed,
      }
    end

    local battle = currentBattle()
    local activeMon = battle and battle.player and battle.player.mon or nil
    local teamTypes = {}

    -- Which stat each badge boosts.
    local BADGE_STAT_MAP = {
      BOULDERBADGE = "attack", THUNDERBADGE = "defense",
      SOULBADGE = "speed", VOLCANOBADGE = "special",
    }
    local playerBadgeStat = {}
    if save.inventory then
      for badgeId, stat in pairs(BADGE_STAT_MAP) do
        if save.inventory[badgeId] then playerBadgeStat[stat] = true end
      end
    end

    -- party
    local party = {}
    for i, mon in ipairs(save.party or {}) do
      local def = dPoke[mon.species]
      local moves = {}
      for _, mv in ipairs(mon.moves or {}) do
        local md = dMove[mv.id]
        local pow = md and md.power or 0
        moves[#moves+1] = {
          name = (md and md.name) or mv.id, pp = mv.pp, maxpp = md and md.pp,
          type = md and md.type and C.TypeChart and C.TypeChart.displayName(md.type) or nil,
          power = pow > 0 and pow or nil,
          status = md and ((md.category == "status") or pow == 0) or nil,
        }
      end
      local raw = (def and def.types) or {}
      if #raw > 0 then teamTypes[#teamTypes+1] = raw end
      local xpProg, xpNext
      if C.Growth and def and def.growthRate and mon.exp and mon.level then
        local rates = data.growth_rates
        local cur = C.Growth.expForLevel(def.growthRate, mon.level, rates)
        local nxt = C.Growth.expForLevel(def.growthRate, mon.level + 1, rates)
        if mon.level >= 100 or nxt <= cur then xpProg, xpNext = 1, 0
        else xpProg = math.max(0, math.min(1, (mon.exp - cur)/(nxt - cur))); xpNext = math.max(0, nxt - mon.exp) end
      end
      party[i] = {
        slot = i, name = mon.nickname or (def and def.name) or tostring(mon.species),
        species = mon.species, level = mon.level, hp = mon.hp,
        maxhp = mon.stats and mon.stats.hp, status = mon.status or "OK",
        types = dispTypes(raw), moves = moves, exp = mon.exp,
        xpProgress = xpProg, xpToNext = xpNext,
        growthRate = def and def.growthRate,
        stats = mon.stats,
        badgeStat = playerBadgeStat,
        baseSpeed = def and def.baseStats and def.baseStats.speed,
        active = (activeMon ~= nil and mon == activeMon) or nil,
      }
    end

    -- trainer
    local badges, badgeCount = {}, 0
    if C.Badges and data then
      for i, e in ipairs(C.Badges.list(data)) do
        local owned = save.inventory[C.Badges.itemFor(e)] and true or false
        if owned then badgeCount = badgeCount + 1 end
        local id = e.id or ("BADGE"..i); local base = id:gsub("BADGE$", "")
        badges[i] = { name = e.name or (base:sub(1,1)..base:sub(2):lower()), owned = owned }
      end
    end
    local dex = save.pokedex or {}
    local function countTrue(t) local n=0; if t then for _,v in pairs(t) do if v then n=n+1 end end end; return n end
    local dexTotal = 0
    for _, d in pairs(dPoke) do if d.dex and d.dex > dexTotal then dexTotal = d.dex end end
    local trainer = {
      name = (save.player and save.player.name) or "", money = save.money or 0,
      version = save.version or "", playTime = math.floor(save.playTime or 0),
      badges = badges, badgeCount = badgeCount, dexSeen = countTrue(dex.seen),
      dexOwned = countTrue(dex.owned), dexTotal = dexTotal > 0 and dexTotal or nil,
      partyCount = #(save.party or {}),
      repelSteps = save.repelSteps or 0,
    }

    -- battle + matchup + catch
    local battleBlock
    if battle then
      local pMon, eMon = battle.player and battle.player.mon, battle.enemy and battle.enemy.mon
      local myTypes = (pMon and dPoke[pMon.species] and dPoke[pMon.species].types) or {}
      local enTypes = (eMon and dPoke[eMon.species] and dPoke[eMon.species].types) or {}
      local matchup
      if C.TypeChart and pMon and eMon then
        if not C.tcReady then C.tcReady = pcall(C.TypeChart.load, data) end
        local ok, res = pcall(function()
          local eff, disp, cat = C.TypeChart.effectiveness, C.TypeChart.displayName, C.TypeChart.category
          local function has(l,t) for _,x in ipairs(l) do if x==t then return true end end return false end
          local myMoves, bi, bs = {}, nil, -1
          for _, mv in ipairs(pMon.moves or {}) do
            local md = dMove[mv.id]
            if md then
              local pow = md.power or 0
              local st = (md.category == "status") or pow == 0
              local mult = eff(md.type, enTypes); local stab = has(myTypes, md.type)
              myMoves[#myMoves+1] = { name = md.name or mv.id, type = disp(md.type),
                power = pow > 0 and pow or nil, pp = mv.pp, maxpp = md.pp,
                mult = mult, stab = stab or nil, status = st or nil }
              if not st and mult > 0 then local sc = mult*pow*(stab and 15 or 10); if sc > bs then bs=sc; bi=#myMoves end end
            end
          end
          if bi then myMoves[bi].best = true end
          local enemyMoves = {}
          for _, mv in ipairs(eMon.moves or {}) do
            local md = dMove[mv.id]
            if md then
              local pow = md.power or 0
              local st2 = (md.category == "status") or pow == 0
              local mult = eff(md.type, myTypes)
              enemyMoves[#enemyMoves+1] = { name = md.name or mv.id, type = disp(md.type),
                power = pow > 0 and pow or nil, pp = mv.pp, maxpp = md.pp,
                mult = mult, status = st2 or nil }
            end
          end
          local mS, eS = pMon.stats and pMon.stats.speed, eMon.stats and eMon.stats.speed
          local faster; if mS and eS then faster = (mS>eS) and "you" or ((eS>mS) and "them" or "tie") end
          return { speed = { faster = faster }, myMoves = myMoves, enemyMoves = enemyMoves }
        end)
        if ok then matchup = res end
      end
      battleBlock = { kind = battle.kind, trainer = battle.trainer and battle.trainer.name or nil,
        enemy = brief(eMon), active = brief(pMon), matchup = matchup }
      if battleBlock.enemy and matchup and matchup.enemyMoves then
        battleBlock.enemy.moves = matchup.enemyMoves
      end
      -- Stat stage changes read straight from the battle itself.
      if battleBlock.enemy and battle.enemy then
        battleBlock.enemy.stages = battle.enemy.stages
        battleBlock.enemy.confusedTurns = battle.enemy.confusedTurns
        battleBlock.enemy.liveStats = battle.enemy.curStats
        local enBadges = battle.enemy.badges or {}
        local enBadgeStat = {}
        for badgeId, stat in pairs(BADGE_STAT_MAP) do
          if enBadges[badgeId] then enBadgeStat[stat] = true end
        end
        battleBlock.enemy.badgeStat = enBadgeStat
      end
      if party[1] and battle.player then
        party[1].stages = battle.player.stages
        party[1].confusedTurns = battle.player.confusedTurns
        party[1].liveStats = battle.player.curStats
      end
    end

    -- Adds move effectiveness info to the lead Pokemon's own move list.
    if battleBlock and battleBlock.matchup and battleBlock.matchup.myMoves
       and party[1] and party[1].moves then
      for i, mv in ipairs(party[1].moves) do
        local em = battleBlock.matchup.myMoves[i]
        if em then mv.mult = em.mult; mv.stab = em.stab; mv.best = em.best end
      end
    end

    return { active = true, party = party, trainer = trainer,
      battle = battleBlock, items = {
        bagFull = C.Bag and C.Bag.slots(save), bagCap = C.Bag and C.Bag.capacity(C.gameData) }
    }
  end

  -- ---------------------------------------------------------------------
  -- Runs every frame: reads the save and animates HP bars.
  -- ---------------------------------------------------------------------
  local function easeHP(key, target, dt)
    local cur = C.dispHP[key]
    if cur == nil then cur = target end
    cur = cur + (target - cur) * math.min(1, (dt or 0) * 7)
    if math.abs(cur - target) < 0.5 then cur = target end
    C.dispHP[key] = cur
    return cur
  end

  C.onFrame = function(dt)
    C.acc = (C.acc or 0) + (dt or 0)
    if not C.state or C.acc >= INTERVAL then
      C.acc = 0
      local ok, st = pcall(buildState)
      if ok then C.state = st
      elseif st ~= C.buildErr then C.buildErr = st; mod.log:error("kanto_ingame build: %s", tostring(st)) end
    end
    -- smoothly animate HP toward the real value
    local st = C.state
    if st then
      for i = 1, 6 do
        local m = st.party and st.party[i]
        local key = "p" .. i
        if m then
          if C.dispSp[key] ~= m.species then C.dispSp[key] = m.species; C.dispHP[key] = m.hp end
          easeHP(key, m.hp or 0, dt or 0)
        else C.dispHP[key] = nil; C.dispSp[key] = nil end
      end
      local en = st.battle and st.battle.enemy
      if en then
        if C.dispSp.enemy ~= en.species then C.dispSp.enemy = en.species; C.dispHP.enemy = en.hp end
        easeHP("enemy", en.hp or 0, dt or 0)
      else C.dispHP.enemy = nil; C.dispSp.enemy = nil end
    end
  end

  -- ---------------------------------------------------------------------
  -- Drawing helpers (sizes scale automatically to fit the screen).
  -- ---------------------------------------------------------------------
  local s = 1
  -- Swaps symbols the game's font can't display for simple text instead.
  local SUB = {
    ["\226\153\128"] = " (F)",  -- ♀ U+2640
    ["\226\153\130"] = " (M)",  -- ♂ U+2642
    ["\226\152\133"] = "*",    -- ★ U+2605 (STAB)
    ["\226\154\160"] = "!",    -- ⚠ U+26A0 (threat)
    ["\226\150\186"] = ">",    -- ► U+25BA (you first)
    ["\226\151\132"] = "<",    -- ◄ U+25C4 (enemy first)
    ["\226\151\134"] = "*",    -- ◆ U+25C6 (badge earned)
    ["\226\151\135"] = "·",    -- ◇ U+25C7 (badge not earned)
  }
  local function sanitize(str)
    if type(str) ~= "string" then str = tostring(str) end
    for k, v in pairs(SUB) do str = str:gsub(k, v) end
    return str
  end
  local function setc(c, a) love.graphics.setColor(c[1], c[2], c[3], a or 1) end
  local function rrect(mode, x, y, w, h, r)
    love.graphics.rectangle(mode, math.floor(x*s), math.floor(y*s), math.floor(w*s), math.floor(h*s),
      (r or 0)*s, (r or 0)*s)
  end
  local function txt(str, x, y, size, col, align, a)
    str = sanitize(str)
    local f = getFont(size*s); love.graphics.setFont(f); setc(col or COL.text, a)
    local X = x*s
    if align == "right" then X = X - f:getWidth(str)
    elseif align == "center" then X = X - f:getWidth(str)/2 end
    love.graphics.print(str, math.floor(X), math.floor(y*s))
  end
  local function textW(str, size) return getFont(size*s):getWidth(str) / s end
  -- Fakes bold by drawing the text twice, slightly offset.
  local function boldTxt(str, x, y, size, col, align, a)
    txt(str, x, y, size, col, align, a)
    txt(str, x + 1, y, size, col, align, a)
  end
  -- shrink a string with ".." until it fits maxW (design units)
  local function ellipsize(str, size, maxW)
    if textW(str, size) <= maxW then return str end
    local s2 = str
    while #s2 > 1 and textW(s2 .. "..", size) > maxW do s2 = s2:sub(1, #s2 - 1) end
    return s2 .. ".."
  end
  local function panel(x, y, w, h, activeGold)
    setc(COL.panel, 0.90); rrect("fill", x, y, w, h, 14)
    love.graphics.setLineWidth(math.max(1, s))
    if activeGold then setc(COL.gold, 0.85) else setc(COL.border, 0.85) end
    rrect("line", x, y, w, h, 14)
  end
  local function bar(x, y, w, h, frac, col)
    setc(COL.barbg, 0.15); rrect("fill", x, y, w, h, h/2)
    if frac and frac > 0 then setc(col, 1); rrect("fill", x, y, w*math.min(1,frac), h, h/2) end
  end
  local function hpCol(f) return f > 0.5 and COL.hi or (f > 0.2 and COL.mid or COL.lo) end
  local function chip(x, y, label, col)
    local w = textW(label, 14) + 12
    setc(col, 1); rrect("fill", x, y, w, 20, 5)
    txt(label, x + 6, y + 3, 14, COL.text)
    return w + 5
  end
  -- Status and confusion badges shown next to a Pokemon's name.
  local STATUS_BADGE = {
    SLP = { text = "ZZZ", bg = hex("6fc3ff"), fg = {0.05, 0.05, 0.05} },
    PAR = { text = "PAR", bg = hex("ffd83d"), fg = {0.08, 0.07, 0.05} },
    BRN = { text = "BRN", bg = hex("e0632c"), fg = {1, 1, 1} },
    FRZ = { text = "FRZ", bg = hex("6fc3ff"), fg = {1, 1, 1} },
    PSN = { text = "PSN", bg = hex("9a4dff"), fg = {1, 1, 1} },
  }
  local CONFUSE_BADGE = { text = "CNF", bg = hex("4dd9d9"), fg = {0.04, 0.28, 0.28} }
  local function condChip(x, y, def)
    local w = textW(def.text, 14) + 14
    setc(def.bg, 1); rrect("fill", x, y, w, 22, 6)
    boldTxt(def.text, x + w/2, y + 4, 14, def.fg, "center")
    return w + 6
  end
  local function money(n) local s2 = tostring(math.floor(n or 0)); local o = s2:reverse():gsub("(%d%d%d)","%1,"):reverse():gsub("^,",""); return "¥"..o end
  local function titleCase(s)
    s = (s or ""):lower():gsub("_", " ")
    return (s:gsub("(%a)([%w']*)", function(a, b) return a:upper() .. b end))
  end
  local function fmtTime(sec) sec = sec or 0; return string.format("%d:%02d", math.floor(sec/3600), math.floor(sec/60)%60) end
  local function fmtTimeHMS(sec)
    sec = math.floor(sec or 0)
    return string.format("%d:%02d:%02d", math.floor(sec/3600), math.floor(sec/60)%60, sec%60)
  end
  local function pct(p) if p == nil then return "—" end; if p >= 100 then return "100%" end; if p < 1 then return (p < 0.1 and "<0.1%") or (string.format("%.1f%%", p)) end; return math.floor(p+0.5).."%" end
  local EFFLBL = { [0]="×0", [2]="×¼", [5]="×½", [10]="×1", [20]="×2", [40]="×4" }
  local function effText(m) return EFFLBL[m] or ("×"..(m/10)) end

  -- ---------------------------------------------------------------------
  -- Draws each panel. Each one returns how tall it drew.
  -- ---------------------------------------------------------------------
  local COLW = 468        -- side column width
  local PAD = 16

  -- Party row style: F7 toggles full (types, HP, XP, moves) vs compact.
  local function moveRows(m) return 4 end
  local function measureMon(m, style)
    if style == 2 then return 54 end
    local hasXP = m.xpProgress ~= nil
    -- Figures out how tall this Pokemon's box needs to be.
    local bodyH = 84 + 10 + (m.growthRate and 20 or 0) + (hasXP and 34 or 0) + 6 + moveRows(m)*26
    return math.max(76, bodyH)
  end

  local function drawMonRow(m, x, y, w, key, style)
    local rowH = measureMon(m, style)
    local dispHp = C.dispHP[key] or m.hp or 0
    local frac = math.max(0, math.min(1, dispHp / (m.maxhp or 1)))

    if style == 2 then
      -- Compact style: sprite next to text.
      local sp, bodyX = 52, 66
      local bodyW = w - bodyX
      local img = getSprite(m.species, C.dPoke)
      if img then
        local iw, ih = img:getDimensions(); local sc = (sp / math.max(iw, ih)) * s
        setc(COL.text, dispHp <= 0 and 0.5 or 1)
        love.graphics.draw(img, math.floor(x*s) + iw*sc, math.floor((y + (rowH-sp)/2)*s), 0, -sc, sc)
      end
      local cy = y + 2
      txt(m.name, x + bodyX, cy, 20, COL.text)
      local tx = x + bodyX + textW(m.name, 20) + 8
      if m.types then for _, t in ipairs(m.types) do tx = tx + chip(tx, cy + 1, t, TYPE[t] or COL.dim) end end
      if m.status and m.status ~= "OK" then tx = tx + chip(tx, cy + 1, m.status, COL.lo) end
      txt("Lv " .. (m.level or "?"), x + w, cy + 2, 15, COL.dim, "right")
      cy = cy + 24
      local numStr = string.format("%d/%d", math.floor(dispHp + 0.5), m.maxhp or 0)
      local numW = textW(numStr, 15) + 10
      bar(x + bodyX, cy + 2, bodyW - numW, 10, frac, hpCol(frac))
      txt(numStr, x + w, cy, 15, COL.text, "right", 0.9)
      cy = cy + 18
      if m.xpProgress ~= nil then bar(x + bodyX, cy, bodyW, 6, m.xpProgress, COL.xp) end
      return rowH
    end

    -- Full style: sprite on the left, everything else stacked next to it.
    local cy = y
    local sp = 84
    local bodyX = sp + 14
    local bodyW = w - bodyX
    local blockTop = cy

    local img = getSprite(m.species, C.dPoke)
    if img then
      local iw, ih = img:getDimensions(); local sc = (sp / math.max(iw, ih)) * s
      setc(COL.text, dispHp <= 0 and 0.5 or 1)
      love.graphics.draw(img, math.floor(x*s) + iw*sc, math.floor(blockTop*s), 0, -sc, sc)
    end

    if m.types and #m.types > 0 then
      local tx = x + bodyX; for _, t in ipairs(m.types) do tx = tx + chip(tx, cy, t, TYPE[t] or COL.dim) end
      cy = cy + 24
    end
    bar(x + bodyX, cy, bodyW, 12, frac, hpCol(frac)); cy = cy + 18
    txt(string.format("%d / %d HP", math.floor(dispHp + 0.5), m.maxhp or 0), x + bodyX, cy, 19, COL.text, nil, 0.9)
    cy = math.max(cy + 19, blockTop + sp) + 10

    if m.growthRate then
      txt(titleCase(m.growthRate), x, cy, 16, COL.text); cy = cy + 20
    end
    if m.xpProgress ~= nil then
      bar(x, cy, w, 8, m.xpProgress, COL.xp); cy = cy + 12
      local lbl = (m.xpToNext and m.xpToNext > 0) and (money(m.xpToNext):gsub("¥","") .. " XP to Lv " .. ((m.level or 0)+1))
        or (((m.exp and money(m.exp):gsub("¥","")) or "0") .. " XP · Max")
      txt(lbl, x, cy, 17, COL.text); cy = cy + 22
    end
    cy = cy + 6
    -- Always shows 4 move rows so the panel height never changes.
    local mf = 17
    for i = 1, 4 do
      local mv = m.moves and m.moves[i]
      local my = cy + (i-1)*26
      if mv then
        if mv.best then setc(COL.hi, 0.12); rrect("fill", x - 6, my - 2, w + 12, 24, 6) end
        local cx = x
        if mv.type then cx = cx + chip(cx, my + 1, mv.type, TYPE[mv.type] or COL.dim) end
        txt(mv.name .. (mv.stab and "  *" or ""), cx, my, mf, COL.text, nil, 0.95)
        local pp = (mv.pp ~= nil and mv.maxpp ~= nil) and (mv.pp.."/"..mv.maxpp) or ""
        if mv.mult ~= nil and not mv.status then
          local tier = mv.mult == 0 and COL.lo or (mv.mult > 10 and COL.super or (mv.mult == 10 and COL.dim or COL.resist))
          txt(effText(mv.mult), x + w - 128, my, mf - 3, tier, "right")
        end
        txt((mv.power and (mv.power.." pow") or (mv.status and "STATUS" or "--")) .. "  ·  " .. pp, x + w, my, mf - 3, COL.text, "right")
      else
        txt("—", x, my, mf, COL.dim, nil, 0.5)
        txt("—  ·  —", x + w, my, mf - 3, COL.dim, "right", 0.5)
      end
    end
    return rowH
  end

  -- Only shows your lead Pokemon, not the whole party.
  local PARTY_HEADER_H = 44
  local function partyPanelHeight(m, style)
    return PAD + PARTY_HEADER_H + measureMon(m, style) + (PAD - 6)
  end
  local function party(st, x, y, styleOverride)
    local w = COLW; local style = styleOverride or 1
    local m = (st.party or {})[1]
    if not m then return 0 end
    local h = partyPanelHeight(m, style)
    panel(x, y, w, h, false)
    txt(m.name, x + PAD, y + PAD, 31, COL.text)
    local nx = x + PAD + textW(m.name, 31) + 12
    if m.status and STATUS_BADGE[m.status] then nx = nx + condChip(nx, y + PAD + 6, STATUS_BADGE[m.status]) end
    if m.confusedTurns then nx = nx + condChip(nx, y + PAD + 6, CONFUSE_BADGE) end
    txt("Lv " .. (m.level or "?"), x + w - PAD, y + PAD + 3, 19, COL.text, "right")
    local cy = y + PAD + PARTY_HEADER_H
    drawMonRow(m, x + PAD, cy, w - PAD*2, "p1", style)
    return h
  end

  -- 6 stat boxes. Crit chance uses the Pokemon's base speed stat.
  local STAT_COL = {
    HP = hex("ff8a3d"), ATK = hex("ffd83d"), DEF = hex("6fe89a"),
    SPC = hex("6fc3ff"), SPD = hex("b48bff"), CRIT = hex("ff7fc0"),
  }
  local STAT_DARK = {0.08, 0.07, 0.09}
  -- Small badge showing a stat boost/drop, only if one is active.
  local function stageBadge(x, y, w, h, stage)
    if not stage or stage == 0 then return end
    local bw, bh = 32, 26
    local bx, by = x + w - bw - 4, y + h - bh - 4
    setc({1, 1, 1}, 0.95); rrect("fill", bx, by, bw, bh, 6)
    love.graphics.setLineWidth(math.max(1, s))
    setc({0.1, 0.1, 0.12}, 0.85); rrect("line", bx, by, bw, bh, 6)
    local col = stage > 0 and {0.05, 0.45, 0.08} or {0.55, 0.05, 0.05}
    boldTxt((stage > 0 and "+" or "") .. tostring(stage), bx + bw/2, by + 4, 15, col, "center")
  end
  local function statBox(x, y, w, h, label, value, col, stage, badgeIndex)
    setc(col, 0.95); rrect("fill", x, y, w, h, 10)
    boldTxt(label, x + w/2, y + 12, 16, STAT_DARK, "center")
    local vsz = 34
    while textW(value, vsz) > w - 16 and vsz > 18 do vsz = vsz - 1 end
    boldTxt(value, x + w/2, y + 36, vsz, STAT_DARK, "center")
    stageBadge(x, y, w, h, stage)
    if badgeIndex then
      -- Shows which badge is boosting this stat.
      local img = uiImage(mod.assets:path("assets/badges/badge" .. badgeIndex .. "_true.png"))
      if img then
        local iw, ih = img:getDimensions()
        local size = 24
        local sc = (size / math.max(iw, ih)) * s
        setc(COL.text, 1)
        love.graphics.draw(img, math.floor((x+4)*s), math.floor((y+4)*s), 0, sc, sc)
      end
    end
  end
  -- Fixed height so this panel can always be anchored to the bottom.
  local STATS_BOX_H = 84
  local STATS_GAP = 12
  local STATS_PANEL_H = PAD + STATS_BOX_H*2 + STATS_GAP + PAD
  local BADGE_STAT_INDEX = { attack = 1, defense = 3, speed = 5, special = 7 }
  local function statsPanelFor(x, y, m)
    local stats = m and m.stats or {}
    local stages = (m and m.stages) or {}
    local badgeStat = (m and m.badgeStat) or {}
    local live = m and m.liveStats   -- real, live stats during battle
    local statusPenalty = m and m.status and C.Status and C.Status.RECORDS
      and C.Status.RECORDS[m.status] and C.Status.RECORDS[m.status].statPenalty
    local w = COLW; local gap = STATS_GAP
    local bw = (w - PAD*2 - gap*2) / 3
    local bh = STATS_BOX_H
    panel(x, y, w, STATS_PANEL_H, false)
    local by = y + PAD
    local critPct = m and m.baseSpeed and (m.baseSpeed / 512 * 100) or nil
    local critStr = critPct and (string.format("%.2f", critPct) .. "%") or "--"
    -- Uses the real battle stat if there is one; otherwise calculates it.
    local function adjusted(base, key)
      if live and live[key] ~= nil then return live[key] end
      if base == nil then return nil end
      local v = base
      local stg = stages[key]
      if stg and stg ~= 0 and C.Stats and C.Stats.applyStage then
        v = C.Stats.applyStage(v, stg)
      end
      if badgeStat[key] then v = math.floor(v * 9 / 8) end
      if statusPenalty and statusPenalty.stat == key then
        v = math.max(1, math.floor(v / statusPenalty.div))
      end
      return v
    end
    local row1 = {
      {"HP", stats.hp, STAT_COL.HP, stages.accuracy, nil},
      {"ATK", adjusted(stats.attack, "attack"), STAT_COL.ATK, stages.attack, badgeStat.attack and BADGE_STAT_INDEX.attack},
      {"DEF", adjusted(stats.defense, "defense"), STAT_COL.DEF, stages.defense, badgeStat.defense and BADGE_STAT_INDEX.defense},
    }
    local row2 = {
      {"SPC", adjusted(stats.special, "special"), STAT_COL.SPC, stages.special, badgeStat.special and BADGE_STAT_INDEX.special},
      {"SPD", adjusted(stats.speed, "speed"), STAT_COL.SPD, stages.speed, badgeStat.speed and BADGE_STAT_INDEX.speed},
      {"CRIT", critStr, STAT_COL.CRIT, stages.evasion, nil},
    }
    for i, e in ipairs(row1) do
      statBox(x + PAD + (i-1)*(bw+gap), by, bw, bh, e[1], tostring(e[2] or "--"), e[3], e[4], e[5])
    end
    for i, e in ipairs(row2) do
      local val = (e[1] == "CRIT") and e[2] or tostring(e[2] or "--")
      statBox(x + PAD + (i-1)*(bw+gap), by + bh + gap, bw, bh, e[1], val, e[3], e[4], e[5])
    end
    return STATS_PANEL_H
  end
  local function statsPanel(st, x, y)
    return statsPanelFor(x, y, (st.party or {})[1])
  end
  local function enemyStatsPanel(st, x, y)
    return statsPanelFor(x, y, st.battle and st.battle.enemy)
  end

  -- Play time and resets, plus a repel box that only shows up while active.
  local function statBoxPlain(x, y, w, h, label, value)
    panel(x, y, w, h, false)
    boldTxt(label, x + w/2, y + 10, 14, COL.text, "center")
    local vsz = 38
    while textW(value, vsz) > w - 20 and vsz > 18 do vsz = vsz - 1 end
    boldTxt(value, x + w/2, y + 30, vsz, COL.text, "center")
  end
  -- 8 badge slots in a single thin row, evenly spaced, filled in once earned.
  local BADGE_ICON = 28
  local BADGE_ROW_PAD_V = 14
  local BADGE_ROW_H = BADGE_ROW_PAD_V*2 + BADGE_ICON
  local REPEL_BOX_H = 62
  local function badgeRow(st, x, y)
    local w = COLW
    panel(x, y, w, BADGE_ROW_H, false)
    local badges = (st.trainer and st.trainer.badges) or {}
    local innerW = w - PAD*2
    local gapX = (innerW - 8*BADGE_ICON) / 7
    local by = y + BADGE_ROW_PAD_V
    for i = 0, 7 do
      local bx = x + PAD + i*(BADGE_ICON + gapX)
      local b = badges[i+1]
      local owned = b and b.owned
      love.graphics.setLineWidth(math.max(1, s))
      setc(COL.border, 0.5); rrect("line", bx - 2, by - 2, BADGE_ICON + 4, BADGE_ICON + 4, 5)
      local img = uiImage(mod.assets:path(
        "assets/badges/badge" .. (i+1) .. "_" .. (owned and "true" or "false") .. ".png"))
      if img then
        local iw, ih = img:getDimensions()
        local sc = (BADGE_ICON / math.max(iw, ih)) * s
        setc(COL.text, 1)
        love.graphics.draw(img, math.floor(bx*s), math.floor(by*s), 0, sc, sc)
      end
    end
    return BADGE_ROW_H
  end

  -- Bottom-right layout, built from the bottom up so nothing shifts around.
  local GT_BOX_H = 78
  local function gameTimePanel(st, x, y)
    local t = st.trainer
    local w = COLW; local gap = 16
    local bw = (w - gap) / 2
    statBoxPlain(x, y, bw, GT_BOX_H, "GAME TIME", t and fmtTimeHMS(t.playTime) or "--")
    statBoxPlain(x + bw + gap, y, bw, GT_BOX_H, "RESETS", tostring(C.resets or 0))
    return GT_BOX_H
  end

  -- Repel and bag warnings -- same box size for both, side by side.
  local REPEL_BOX_W = COLW * 0.3
  local BAG_BOX_H = 53 -- slightly smaller than before; independent of repel now that it's moved
  local BAG_BOX_W = BAG_BOX_H -- still square
  local BAG_ICON_SIZE = 44 -- same ~8% margin ratio as the last size that looked right
  local function repelPanel(st, x, y)
    local t = st.trainer
    if not (t and (t.repelSteps or 0) > 0) then return 0 end
    panel(x, y, REPEL_BOX_W, REPEL_BOX_H, false)
    boldTxt("REPEL", x + REPEL_BOX_W/2, y + 8, 13, COL.text, "center")
    local val = tostring(t.repelSteps)
    local vsz = 26
    while textW(val, vsz) > REPEL_BOX_W - 16 and vsz > 14 do vsz = vsz - 1 end
    boldTxt(val, x + REPEL_BOX_W/2, y + 26, vsz, COL.text, "center")
    return REPEL_BOX_H
  end

  local function bagPanel(st, rightEdge, y)
    local badges = (st.trainer and st.trainer.badges) or {}
    local earthOwned = badges[8] and badges[8].owned
    local it = st.items or {}
    local function log(tag, fmt, ...)
      if C.lastBagLog ~= tag then
        C.lastBagLog = tag
        mod.log:info("bagPanel: " .. fmt, ...)
      end
    end
    if earthOwned then
      log("earth", "hidden -- Earth Badge is owned")
      return 0
    end
    if not (it.bagFull and it.bagCap) then
      log("nodata", "hidden -- no bag data (bagFull=%s bagCap=%s, C.Bag=%s)",
        tostring(it.bagFull), tostring(it.bagCap), tostring(C.Bag ~= nil))
      return 0
    end
    local remaining = it.bagCap - it.bagFull
    local iconPath = remaining <= 0 and "assets/ui/bag_red.png"
      or remaining == 1 and "assets/ui/bag_yellow.png"
      or remaining == 2 and "assets/ui/bag_green.png"
    if not iconPath then
      log("toolow", "hidden -- bagFull=%d bagCap=%d (remaining=%d, not 0/1/2)", it.bagFull, it.bagCap, remaining)
      return 0
    end
    log(iconPath, "showing %s -- bagFull=%d bagCap=%d", iconPath, it.bagFull, it.bagCap)
    local x = rightEdge - BAG_BOX_W
    panel(x, y, BAG_BOX_W, BAG_BOX_H, false)
    local img = uiImage(mod.assets:path(iconPath))
    if img then
      local iw, ih = img:getDimensions()
      local sc = (BAG_ICON_SIZE / math.max(iw, ih)) * s
      setc(COL.text, 1)
      local offX = (BAG_BOX_W - BAG_ICON_SIZE) / 2
      local offY = (BAG_BOX_H - BAG_ICON_SIZE) / 2
      love.graphics.draw(img, math.floor((x + offX)*s), math.floor((y + offY)*s), 0, sc, sc)
    end
    return BAG_BOX_H
  end

  -- Enemy panel: mirrors the player's panel, sprite on the right instead.
  local ENEMY_HEADER_H = 36
  local ENEMY_ROW_H = 90 + 20 + 4*26
  local ENEMY_PANEL_H = PAD + ENEMY_HEADER_H + ENEMY_ROW_H + (PAD - 6)
  local function enemyPanel(st, x, y)
    local b = st.battle; if not b then return 0 end
    local en = b.enemy or {}; local m = b.matchup or {}
    local w = COLW
    local sp = 84
    local bodyX = 0    -- content starts at the left edge; sprite is on the right instead
    local bodyW = w - sp - 14

    local h = ENEMY_PANEL_H
    panel(x, y, w, h, false)
    txt(en.name or "?", x + PAD, y + PAD, 31, COL.text)
    local nx = x + PAD + textW(en.name or "?", 31) + 12
    if en.status and STATUS_BADGE[en.status] then nx = nx + condChip(nx, y + PAD + 6, STATUS_BADGE[en.status]) end
    if en.confusedTurns then nx = nx + condChip(nx, y + PAD + 6, CONFUSE_BADGE) end
    txt("Lv " .. (en.level or "?"), x + w - PAD, y + PAD + 3, 19, COL.text, "right")

    local cy = y + PAD + ENEMY_HEADER_H
    local blockTop = cy
    local eh = C.dispHP.enemy or en.hp or 0
    local ef = math.max(0, math.min(1, eh / (en.maxhp or 1)))

    local img = getSprite(en.species, C.dPoke)
    if img then
      local iw, ih = img:getDimensions(); local sc = (sp / math.max(iw, ih)) * s
      setc(COL.text, eh <= 0 and 0.5 or 1)
      -- Sprite faces the other way so the two Pokemon look at each other.
      love.graphics.draw(img, math.floor((x + w - sp)*s), math.floor(blockTop*s), 0, sc, sc)
    end

    if en.types and #en.types > 0 then
      local tx = x + PAD; for _, t in ipairs(en.types) do tx = tx + chip(tx, cy, t, TYPE[t] or COL.dim) end
      cy = cy + 24
    end
    bar(x + PAD, cy, bodyW - PAD, 12, ef, hpCol(ef)); cy = cy + 18
    txt(string.format("%d / %d HP", math.floor(eh + 0.5), en.maxhp or 0), x + PAD, cy, 19, COL.text, nil, 0.9)
    cy = math.max(cy + 19, blockTop + sp) + 6

    if m.speed and m.speed.faster then
      local spTxt = m.speed.faster == "you" and "> You move first" or (m.speed.faster == "them" and "< Enemy moves first" or "= Speed tie")
      txt(spTxt, x + PAD, cy, 16, COL.gold)
    end
    cy = cy + 20

    local mf = 17
    for i = 1, 4 do
      local mv = en.moves and en.moves[i]
      local my = cy + (i-1)*26
      if mv then
        local cx = x + PAD
        if mv.type then cx = cx + chip(cx, my + 1, mv.type, TYPE[mv.type] or COL.dim) end
        txt(mv.name, cx, my, mf, COL.text, nil, 0.95)
        local pp = (mv.pp ~= nil and mv.maxpp ~= nil) and (mv.pp.."/"..mv.maxpp) or ""
        if mv.mult ~= nil and not mv.status then
          local tier = mv.mult == 0 and COL.lo or (mv.mult > 10 and COL.threat or (mv.mult == 10 and COL.dim or COL.resist))
          txt(effText(mv.mult), x + w - PAD - 128, my, mf - 3, tier, "right")
        end
        txt((mv.power and (mv.power.." pow") or (mv.status and "STATUS" or "--")) .. "  ·  " .. pp, x + w - PAD, my, mf - 3, COL.text, "right")
      else
        txt("--", x + PAD, my, mf, COL.dim, nil, 0.5)
        txt("--  ·  --", x + w - PAD, my, mf - 3, COL.dim, "right", 0.5)
      end
    end
    return h
  end

  -- ---------------------------------------------------------------------
  -- Draws everything, positioned from the screen edges.
  -- ---------------------------------------------------------------------
  C.drawOverlay = function()
    local st = C.state
    if not st or not st.active then return end
    local W, H = love.graphics.getDimensions()
    s = H / REF_H
    love.graphics.push("all")
    love.graphics.origin()
    local leftMargin = 8
    local bottomMargin = 40
    local rightMargin = 8
    local gap = 16

    -- Game time, resets, and the badge row always show; everything else
    -- toggles with O/F8.
    local gtY = (H / s) - bottomMargin - GT_BOX_H
    gameTimePanel(st, leftMargin, gtY)
    local badgeRowY = gtY - gap - BADGE_ROW_H
    badgeRow(st, leftMargin, badgeRowY)
    if not C.visible or not (st.party and #st.party > 0) then
      love.graphics.pop()
      return
    end

    -- Left side, stacked bottom-up: game time/resets, badge row, stats,
    -- party info. Repel sits in its own row above the party box; bag
    -- now sits to the right of the party box, aligned to its bottom edge.
    local statsY = badgeRowY - gap - STATS_PANEL_H
    local m1 = (st.party or {})[1]
    local partyH = m1 and partyPanelHeight(m1, 1) or 0
    local partyY = statsY - gap - partyH
    party(st, leftMargin, partyY, 1)
    statsPanel(st, leftMargin, statsY)

    local rowBottomY = partyY - gap
    repelPanel(st, leftMargin, rowBottomY - REPEL_BOX_H)
    bagPanel(st, leftMargin + COLW + gap - 12 + BAG_BOX_W, partyY + partyH - BAG_BOX_H)

    -- Right side: nothing out of battle; enemy info bottom-anchored
    -- during battle, same footprint as always.
    if st.battle then
      local rx = (W / s) - COLW - rightMargin
      local enemyGap = 6
      local enemyBottomMargin = 10
      local enemyStatsY = (H / s) - enemyBottomMargin - STATS_PANEL_H
      enemyStatsPanel(st, rx, enemyStatsY)
      enemyPanel(st, rx, enemyStatsY - enemyGap - ENEMY_PANEL_H)
    end
    love.graphics.pop()
  end

  -- ---------------------------------------------------------------------
  -- Hooks into the game (won't double up if the mod reloads).
  -- ---------------------------------------------------------------------
  if not C.wrappedUpdate and C.game and C.game.update then
    C.origUpdate = C.game.update
    C.game.update = function(self, dt)
      C.origUpdate(self, dt)
      local c = _G.__KANTO_INGAME; if c and c.onFrame then pcall(c.onFrame, dt) end
    end
    C.wrappedUpdate = true
  end
  if not C.wrappedDraw then
    C.origDraw = love.draw
    love.draw = function(...)
      if C.origDraw then C.origDraw(...) end
      local c = _G.__KANTO_INGAME
      if c and c.drawOverlay then
        local ok, err = pcall(c.drawOverlay)
        if not ok and err ~= c.drawErr then c.drawErr = err; mod.log:error("kanto_ingame draw: %s", tostring(err)) end
      end
    end
    C.wrappedDraw = true
  end
  -- Key handling. Reassigned every load so F5 reload picks up changes.
  C.onKeyDown = function(_, key)
    local c = _G.__KANTO_INGAME
    if c then
      if OVERLAY_KEYS[key] then c.visible = not c.visible; return true end
      if key == RESETS_INC_KEY then
        c.resets = (c.resets or 0) + 1; mod.save:set("resets", c.resets); return true
      end
      if key == RESETS_DEC_KEY then
        c.resets = math.max(0, (c.resets or 0) - 1); mod.save:set("resets", c.resets); return true
      end
      if key == RESETS_ZERO_KEY then
        c.resets = 0; mod.save:set("resets", 0); return true
      end
    end
    return false
  end
  if not C.wrappedKeys and C.game and C.game.keypressed then
    C.origKeypressed = C.game.keypressed
    C.game.keypressed = function(self, key, ...)
      local c = _G.__KANTO_INGAME
      if c and c.onKeyDown and c.onKeyDown(self, key) then return end
      return C.origKeypressed(self, key, ...)
    end
    C.wrappedKeys = true
  end
  mod.log:info("solo_run_overlay: overlay=o/f8  resets=[, ], \\")
end
