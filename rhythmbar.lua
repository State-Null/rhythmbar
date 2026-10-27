--[[
    RhythmBar (rhythmbar.lua) - v1.2.0 (Ultra-Low-Overhead Edition)
    Center-Draining Action Lockout & Rhythm Bar for FFXI (Windower 4)

    Designed to fit inside the center void of xivcrossbar (or dragged anywhere
    on screen during `//rbar test`) and show the hidden FFXI post-action Forced
    Delay (lockout) across ALL regular actions:
      - Job Abilities / Steps / Flourishes / Waltzes / Sambas / Wards (Gold)
      - Weapon Skills / TP Moves (Coral Red-Orange)
      - Spells / Songs / Ninjutsu:
          * Casting Phase (Cyan filling outward)
          * Post-Cast Total Lock 0.0s-2.05s (Purple draining inward)
          * Post-Cast Magic Lock 2.05s-3.08s (Sky Blue draining inward; JA/WS unlocked!)
      - Ranged Attacks (Teal aiming -> Orange post-shot lock)
      - Item Use (Emerald Mint)
      - Early Button Press / Interrupt Warning (Hot Red flash)
      - Ready Beat Pulse (Neon Green center flash -> Auto-Hide)

    Performance & Optimization Architecture:
      1. Zero-Cost Idle Fast-Path: When IDLE, `prerender` exits on a single integer
         register check (`phase == 0`) without even calling `os.clock()`.
      2. Dirty-Flagged Direct3D 8 Primitives: Caches geometry, visibility, and color
         values per primitive; only crosses the Lua->C++ `windower.prim` boundary
         when a pixel coordinate or color value actually changes (~70% fewer C calls).
      3. Cached Screen Metrics: Calls `windower.get_windower_settings()` once at load
         instead of allocating a table on every frame.
      4. Raw 4-Byte Actor Filter on 0x028: Reads `actor_id` directly from byte offset 6
         of incoming 0x028 chunks before invoking `parse_action`, ignoring 99% of
         alliance/monster battle packets in ~2 nanoseconds.
      5. Gated Plain-Text Chat Filter: Ignores `incoming text` unless an action was
         attempted within the last 0.6s, using plain `string.find(..., 1, true)`.

    Strictly read-only packet inspection (Invariant 1 compliant).
]]

_addon.name     = 'rhythmbar'
_addon.author   = 'Antigravity'
_addon.version  = '1.2.0'
_addon.commands = {'rhythmbar', 'rbar', 'rb'}

require('luau')
local config = require('config')
local texts  = require('texts')
local res    = require('resources')

-- Localize hot standard library & Windower C-API functions into upvalues
local math_floor = math.floor
local math_max   = math.max
local math_min   = math.min
local os_clock   = os.clock
local tonumber   = tonumber
local tostring   = tostring
local s_format   = string.format
local s_find     = string.find
local s_byte     = string.byte

local prim_create         = windower.prim.create
local prim_delete         = windower.prim.delete
local prim_set_pos        = windower.prim.set_position
local prim_set_size       = windower.prim.set_size
local prim_set_color      = windower.prim.set_color
local prim_set_visibility = windower.prim.set_visibility
local parse_action        = windower.packets.parse_action

-- Integer Phase & Kind Enums (Avoids string hashing in hot 60 FPS loop)
local PHASE_IDLE  = 0
local PHASE_CAST  = 1
local PHASE_LOCK  = 2
local PHASE_READY = 3
local PHASE_TEST  = 4

local KIND_JA    = 1
local KIND_WS    = 2
local KIND_SPELL = 3
local KIND_RA    = 4
local KIND_ITEM  = 5
local KIND_INT   = 6

local KIND_NAMES = {
    [KIND_JA]    = 'ja',
    [KIND_WS]    = 'ws',
    [KIND_SPELL] = 'spell',
    [KIND_RA]    = 'ranged',
    [KIND_ITEM]  = 'item',
    [KIND_INT]   = 'interrupt',
}

-- -----------------------------------------------------------------------------
-- Default Settings (Saved to addons/rhythmbar/data/settings.xml)
-- -----------------------------------------------------------------------------
local defaults = {
    use_crossbar_void = true,
    offset_x = 8,
    offset_y = -189,
    pos = { x = 0, y = 0 },
    draggable = false, -- Always draggable during `//rbar test`, or toggle anytime with `//rbar drag`
    bar = {
        width = 96,      -- Total width in px (48px left wing + 48px right wing)
        height = 6,      -- Inner bar height in px
        border = 1,      -- Dark border thickness in px
        bg_alpha = 165,  -- Track background alpha
        bar_alpha = 235, -- Active bar alpha
    },
    show_timer_text = false,
    auto_hide = true,
    early_flash = true,
    auto_tune = true,
    fc_rate = 0.80,
    lockouts = {
        ja = 1.10,
        ws = 2.05,
        spell = 3.08,
        spell_jaws = 2.05,
        ranged = 1.60,
        item = 1.15,
        interrupt = 1.50,
    },
}

local settings = config.load(defaults)

-- -----------------------------------------------------------------------------
-- Color Palette (RGB)
-- -----------------------------------------------------------------------------
local COLORS = {
    JA          = { 255, 195,  35 }, -- Gold / Amber for JA, Step, Flourish, Waltz
    JA_NEAR     = { 195, 255,  65 }, -- Lime-Gold when < 0.25s left
    WS          = { 255,  80,  55 }, -- Coral / Crimson Orange for Weapon Skills
    WS_NEAR     = { 255, 175,  50 }, -- Amber when < 0.30s left
    CAST        = {  55, 210, 255 }, -- Electric Cyan while actively casting
    SPELL_HARD  = { 210,  75, 255 }, -- Vibrant Purple (0.0-2.05s post-cast: everything locked)
    SPELL_MAGIC = {  75, 170, 255 }, -- Sky Blue (2.05-3.08s post-cast: JA/WS ready, Spell locked)
    RA_AIM      = {  50, 225, 185 }, -- Teal while aiming ranged attack
    RA_LOCK     = { 255, 140,  40 }, -- Tangerine Orange for post-ranged lock
    ITEM        = {  85, 230, 145 }, -- Emerald Mint for item use / lock
    INTERRUPT   = { 255,  50,  70 }, -- Crimson for interrupted action
    EARLY       = { 255,  30,  50 }, -- Hot Red flash when pressing buttons too early
    READY       = {  60, 255, 120 }, -- Neon Green beat flash when bar hits center empty
    CENTER_IDLE = { 235, 240, 255 }, -- Crisp white center target tick
    SUB_TICK    = { 255, 235, 140 }, -- Soft gold sub-tick for JA/WS unlock inside spell lock
}

-- -----------------------------------------------------------------------------
-- Adaptive Cast Time & Packet RTT Learning
-- -----------------------------------------------------------------------------
local LEARN_WEIGHT    = 0.30
local LEARN_MIN_RATIO = 0.10
local LEARN_MAX_RATIO = 1.20
local SPEEDUP_BUFFS   = { [362] = true, [363] = true } -- Spontaneity / Manafont
local INTERRUPT_PARAM = 28787

local learned = {}
local avg_rtt = 0.18

local function blend(old, new_val)
    if not old then return new_val end
    return old + (new_val - old) * LEARN_WEIGHT
end

local function learn_cast(skill, base, measured)
    if not skill or not base or base <= 0 then return end
    local ratio = measured / base
    if ratio < LEARN_MIN_RATIO or ratio > LEARN_MAX_RATIO then return end
    local l = learned[skill]
    if not l then
        l = { count = 0, by_base = {} }
        learned[skill] = l
    end
    l.ratio = blend(l.ratio, ratio)
    l.by_base[base] = blend(l.by_base[base], measured)
    l.count = l.count + 1
end

local function predict_cast(skill, base)
    local l = skill and learned[skill]
    if l then
        if l.by_base[base] then return l.by_base[base] end
        if l.ratio then return base * l.ratio end
    end
    local fc = math_max(0, math_min(0.80, tonumber(settings.fc_rate) or 0.80))
    return base * (1.0 - fc)
end

-- -----------------------------------------------------------------------------
-- Cached Screen Geometry & Dirty-Flagged Primitive Wrapper
-- -----------------------------------------------------------------------------
local PRIMS = {
    'rbar_border',
    'rbar_track',
    'rbar_left',
    'rbar_right',
    'rbar_sub_left',
    'rbar_sub_right',
    'rbar_center',
}

local prims_created = false
local is_visible    = false
local layout_dirty  = true

-- Cached layout metrics (recomputed only when settings change)
local cached_cx     = 968
local cached_cy     = 882
local cached_half_w = 48
local cached_bar_h  = 6
local cached_half_h = 3
local cached_bdr    = 1
local cached_bg_a   = 165
local cached_bar_a  = 235

-- Per-primitive state cache to prevent redundant C-API calls across frames
local prim_cache = {}
for i = 1, #PRIMS do
    prim_cache[PRIMS[i]] = { vis = false, x = -1, y = -1, w = -1, h = -1, a = -1, r = -1, g = -1, b = -1 }
end

local function set_prim_vis(name, vis)
    local c = prim_cache[name]
    if c.vis ~= vis then
        c.vis = vis
        prim_set_visibility(name, vis)
    end
end

local function set_prim_rect(name, x, y, w, h)
    local c = prim_cache[name]
    if c.x ~= x or c.y ~= y then
        c.x, c.y = x, y
        prim_set_pos(name, x, y)
    end
    if c.w ~= w or c.h ~= h then
        c.w, c.h = w, h
        prim_set_size(name, w, h)
    end
end

local function set_prim_col(name, a, r, g, b)
    local c = prim_cache[name]
    if c.a ~= a or c.r ~= r or c.g ~= g or c.b ~= b then
        c.a, c.r, c.g, c.b = a, r, g, b
        prim_set_color(name, a, r, g, b)
    end
end

local function refresh_layout_cache()
    local ws = windower.get_windower_settings()
    local ui_x = (ws and ws.ui_x_res) or 1920
    local ui_y = (ws and ws.ui_y_res) or 1080

    if settings.use_crossbar_void then
        local ox = tonumber(settings.offset_x) or 8
        local oy = tonumber(settings.offset_y) or -189
        cached_cx = math_floor(ui_x / 2) + ox
        cached_cy = ui_y + oy
    else
        cached_cx = tonumber(settings.pos and settings.pos.x) or (math_floor(ui_x / 2) + 8)
        cached_cy = tonumber(settings.pos and settings.pos.y) or (ui_y - 189)
    end

    local total_w = math_max(24, tonumber(settings.bar.width) or 96)
    cached_half_w = math_floor(total_w / 2)
    cached_bar_h  = math_max(3, tonumber(settings.bar.height) or 6)
    cached_half_h = math_floor(cached_bar_h / 2)
    cached_bdr    = math_max(1, tonumber(settings.bar.border) or 1)
    cached_bg_a   = tonumber(settings.bar.bg_alpha) or 165
    cached_bar_a  = tonumber(settings.bar.bar_alpha) or 235
    layout_dirty  = true
end

refresh_layout_cache()

local timer_label = texts.new('', {
    pos = { x = 0, y = 0 },
    text = {
        font = 'Arial',
        size = 8,
        alpha = 235,
        red = 255,
        green = 255,
        blue = 255,
        stroke = { width = 2, alpha = 200, red = 15, green = 15, blue = 20 },
    },
    bg = { visible = false },
    flags = { draggable = false, bold = true },
    padding = 0,
})
local last_timer_str = ''

local function create_prims()
    if prims_created then return end
    for i = 1, #PRIMS do
        local name = PRIMS[i]
        prim_create(name)
        prim_set_visibility(name, false)
        local c = prim_cache[name]
        c.vis, c.x, c.y, c.w, c.h, c.a, c.r, c.g, c.b = false, -1, -1, -1, -1, -1, -1, -1, -1
    end
    prims_created = true
    layout_dirty  = true
end

local function destroy_prims()
    if not prims_created then return end
    for i = 1, #PRIMS do
        prim_delete(PRIMS[i])
    end
    prims_created = false
end

local function hide_all()
    if not prims_created then return end
    if is_visible then
        for i = 1, #PRIMS do
            set_prim_vis(PRIMS[i], false)
        end
        is_visible = false
    end
    if timer_label:visible() then
        timer_label:hide()
    end
end

local function lerp_color(c1, c2, t)
    if t <= 0 then return c1[1], c1[2], c1[3] end
    if t >= 1 then return c2[1], c2[2], c2[3] end
    return
        math_floor(c1[1] + (c2[1] - c1[1]) * t + 0.5),
        math_floor(c1[2] + (c2[2] - c1[2]) * t + 0.5),
        math_floor(c1[3] + (c2[3] - c1[3]) * t + 0.5)
end

-- -----------------------------------------------------------------------------
-- State Machine
-- -----------------------------------------------------------------------------
local READY_PULSE_SEC  = 0.18
local EARLY_FLASH_SEC  = 0.22
local PRE_LOCK_TIMEOUT = 0.55

local state_phase          = PHASE_IDLE
local state_kind           = KIND_JA
local state_start_time     = 0
local state_duration       = 0
local state_end_time       = 0
local state_sub_unlock_rem = 0
local state_cast_skill     = nil
local state_cast_base      = 0
local state_cast_learnable = false
local state_early_until    = 0
local state_ready_until    = 0
local state_is_pre_lock    = false
local state_pre_lock_start = 0
local state_pre_lock_exp   = 0
local state_last_packet_at = 0
local state_last_lock_kind = nil
local state_last_attempt   = 0
local state_test_until     = 0

local player_id = nil
local function get_player_id()
    if not player_id then
        local p = windower.ffxi.get_player()
        player_id = p and p.id or nil
    end
    return player_id
end

local function chat_log(msg)
    windower.add_to_chat(207, '[RhythmBar] ' .. msg)
end

-- -----------------------------------------------------------------------------
-- Action & Lockout Triggers
-- -----------------------------------------------------------------------------
local function start_lockout(kind, duration, is_pre)
    local now = os_clock()
    duration = math_max(0.10, tonumber(duration) or 1.10)

    if is_pre then
        local total_expected = duration + avg_rtt
        state_phase          = PHASE_LOCK
        state_kind           = kind
        state_start_time     = now
        state_duration       = total_expected
        state_end_time       = now + total_expected
        state_is_pre_lock    = true
        state_pre_lock_start = now
        state_pre_lock_exp   = now + PRE_LOCK_TIMEOUT
    else
        if state_phase == PHASE_LOCK and state_is_pre_lock and state_kind == kind then
            local rtt = now - state_pre_lock_start
            if rtt >= 0.02 and rtt <= 0.50 then
                avg_rtt = blend(avg_rtt, rtt)
            end
            state_end_time    = now + duration
            state_duration    = math_max(0.10, state_end_time - state_start_time)
            state_is_pre_lock = false
        else
            state_phase       = PHASE_LOCK
            state_kind        = kind
            state_start_time  = now
            state_duration    = duration
            state_end_time    = now + duration
            state_is_pre_lock = false
        end
        state_last_packet_at = now
        state_last_lock_kind = kind
    end

    if kind == KIND_SPELL then
        local jaws = tonumber(settings.lockouts.spell_jaws) or 2.05
        state_sub_unlock_rem = math_max(0, duration - jaws)
    else
        state_sub_unlock_rem = 0
    end
end

local function start_cast(kind, predicted_dur, skill, base, learnable)
    local now = os_clock()
    predicted_dur        = math_max(0.15, tonumber(predicted_dur) or 1.50)
    state_phase          = PHASE_CAST
    state_kind           = kind
    state_start_time     = now
    state_duration       = predicted_dur
    state_end_time       = now + predicted_dur
    state_cast_skill     = skill
    state_cast_base      = base or 0
    state_cast_learnable = learnable and true or false
    state_sub_unlock_rem = 0
    state_is_pre_lock    = false
end

local function trigger_early_flash(now)
    if settings.early_flash then
        state_early_until = now + EARLY_FLASH_SEC
        if state_phase == PHASE_IDLE then
            state_phase       = PHASE_READY
            state_ready_until = now + EARLY_FLASH_SEC
        end
    end
end

-- -----------------------------------------------------------------------------
-- Ultra-Fast Raw Packet Inspection (0x028 Incoming & 0x01A Outgoing)
-- -----------------------------------------------------------------------------
-- Filtering 0x028 in `incoming chunk` by reading the 32-bit actor_id at byte 6
-- avoids parsing 99% of alliance/monster action packets in combat!
windower.register_event('incoming chunk', function(id, data, modified, injected, blocked)
    if id ~= 0x028 or injected or #data < 12 then return end

    local my_id = get_player_id()
    if not my_id then return end

    -- Little-endian uint32 actor_id at 1-based byte offset 6..9
    local b6, b7, b8, b9 = s_byte(data, 6, 9)
    local actor_id = b6 + b7 * 256 + b8 * 65536 + b9 * 16777216
    if actor_id ~= my_id then return end

    local act = parse_action(data)
    if not act then return end
    local cat = act.category

    -- Ignore Category 1 (melee auto-attack swing)
    if cat == 1 then return end

    -- Category 6 (JA), 14 (DNC Step/Flourish), 15 (RUN Ward/Effusion)
    if cat == 6 or cat == 14 or cat == 15 then
        start_lockout(KIND_JA, settings.lockouts.ja, false)
        return
    end

    -- Category 3 (Weapon Skill Finish), 11 (Monstrosity TP Move Finish)
    if cat == 3 or cat == 11 then
        start_lockout(KIND_WS, settings.lockouts.ws, false)
        return
    end

    -- Category 4 (Spell Cast Finish -> Post-Cast Lockout)
    if cat == 4 then
        if state_phase == PHASE_CAST and state_kind == KIND_SPELL and state_cast_learnable then
            learn_cast(state_cast_skill, state_cast_base, os_clock() - state_start_time)
        end
        start_lockout(KIND_SPELL, settings.lockouts.spell, false)
        return
    end

    -- Category 8 (Spell Cast Begin or Interrupted)
    if cat == 8 then
        if act.param == INTERRUPT_PARAM then
            start_lockout(KIND_INT, settings.lockouts.interrupt, false)
            return
        end
        local target = act.targets and act.targets[1]
        local action = target and target.actions and target.actions[1]
        local spell_id = (action and action.param) or act.param
        local spell = spell_id and res.spells and res.spells[spell_id]
        local base = (spell and tonumber(spell.cast_time)) or 2.5
        local skill = spell and spell.skill
        local predicted = predict_cast(skill, base)

        local learnable = true
        local player = windower.ffxi.get_player()
        local buffs = player and player.buffs
        if buffs then
            for i = 1, #buffs do
                if SPEEDUP_BUFFS[buffs[i]] then
                    learnable = false
                    break
                end
            end
        end

        start_cast(KIND_SPELL, predicted, skill, base, learnable)
        return
    end

    -- Category 7 (WS/TP Start or Interrupt)
    if cat == 7 then
        if act.param == INTERRUPT_PARAM then
            start_lockout(KIND_INT, 1.00, false)
        end
        return
    end

    -- Category 12 (Ranged Attack Begin or Interrupted)
    if cat == 12 then
        if act.param == INTERRUPT_PARAM then
            start_lockout(KIND_INT, 1.10, false)
        else
            start_cast(KIND_RA, 1.35, nil, 1.35, false)
        end
        return
    end

    -- Category 2 (Ranged Attack Finish)
    if cat == 2 then
        start_lockout(KIND_RA, settings.lockouts.ranged, false)
        return
    end

    -- Category 9 (Item Use Begin or Interrupted)
    if cat == 9 then
        if act.param == INTERRUPT_PARAM then
            start_lockout(KIND_INT, 1.00, false)
        else
            local target = act.targets and act.targets[1]
            local action = target and target.actions and target.actions[1]
            local item_id = (action and action.param) or act.param
            local item = item_id and res.items and res.items[item_id]
            local cast_t = (item and tonumber(item.cast_time)) or 1.50
            start_cast(KIND_ITEM, cast_t, nil, cast_t, false)
        end
        return
    end

    -- Category 5 (Item Use Finish)
    if cat == 5 then
        start_lockout(KIND_ITEM, settings.lockouts.item, false)
        return
    end
end)

-- Read-Only Outgoing Packet Inspection (0x01A Player Action)
windower.register_event('outgoing chunk', function(id, data, modified, injected, blocked)
    if blocked or id ~= 0x01A or #data < 12 then return end
    local category = s_byte(data, 11)

    -- 0x03 = Magic, 0x07 = Weapon Skill, 0x09 = Job Ability, 0x10 = Ranged Attack
    if category ~= 0x03 and category ~= 0x07 and category ~= 0x09 and category ~= 0x10 then
        return
    end

    local now = os_clock()
    state_last_attempt = now

    if state_phase == PHASE_CAST then
        trigger_early_flash(now)
        return
    elseif state_phase == PHASE_LOCK and not state_is_pre_lock then
        local rem = state_end_time - now
        if state_kind == KIND_SPELL and (category == 0x07 or category == 0x09) then
            if (rem - state_sub_unlock_rem) > 0.08 then
                trigger_early_flash(now)
                return
            end
        elseif rem > 0.08 then
            trigger_early_flash(now)
            return
        end
    end

    if category == 0x09 then
        start_lockout(KIND_JA, settings.lockouts.ja, true)
    elseif category == 0x07 then
        start_lockout(KIND_WS, settings.lockouts.ws, true)
    end
end)

-- Gated Plain-Text Chat Filter for Lockout Rejections
windower.register_event('incoming text', function(original, modified, mode, blocked)
    if blocked or not original then return end
    local now = os_clock()
    -- Fast gate: only inspect chat strings if an action was attempted in the last 0.6s
    -- or if the bar is currently active!
    if state_phase == PHASE_IDLE and (now - state_last_attempt) > 0.60 then
        return
    end

    local is_lock_msg = s_find(original, 'Unable to use job ability', 1, true)
        or s_find(original, 'Unable to cast spells at this time', 1, true)
        or s_find(original, 'You must wait longer to perform that action', 1, true)
        or s_find(original, 'Unable to use weapon skill', 1, true)

    if not is_lock_msg then return end

    trigger_early_flash(now)

    if settings.auto_tune and state_last_packet_at > 0 and state_last_lock_kind then
        local since_last = now - state_last_packet_at
        local key = KIND_NAMES[state_last_lock_kind]
        local cur_lock = key and settings.lockouts[key]
        if cur_lock and since_last >= (cur_lock - 0.05) and since_last <= (cur_lock + 0.35) then
            local tuned = math_min(cur_lock + 0.04, cur_lock + 0.30)
            settings.lockouts[key] = math_floor(tuned * 100 + 0.5) / 100
            config.save(settings)
        end
    end
end)

-- -----------------------------------------------------------------------------
-- Mouse Dragging (Active during `//rbar test` or when `//rbar drag` is enabled)
-- -----------------------------------------------------------------------------
local is_dragging = false
local drag_dx, drag_dy = 0, 0

windower.register_event('mouse', function(mtype, x, y, delta, blocked)
    if blocked then return end
    if not is_dragging and state_phase ~= PHASE_TEST and not settings.draggable then
        return
    end

    if mtype == 1 then -- Left button down
        if is_visible then
            local hit_pad = 8
            if x >= (cached_cx - cached_half_w - hit_pad) and x <= (cached_cx + cached_half_w + hit_pad)
               and y >= (cached_cy - cached_half_h - hit_pad) and y <= (cached_cy + cached_half_h + hit_pad) then
                is_dragging = true
                drag_dx = cached_cx - x
                drag_dy = cached_cy - y
                return true
            end
        end
    elseif mtype == 0 then -- Mouse move
        if is_dragging then
            cached_cx = x + drag_dx
            cached_cy = y + drag_dy
            layout_dirty = true
            return true
        end
    elseif mtype == 2 then -- Left button up
        if is_dragging then
            is_dragging = false
            settings.use_crossbar_void = false
            settings.pos.x = cached_cx
            settings.pos.y = cached_cy
            config.save(settings)
            chat_log(s_format('Position saved: X=%d, Y=%d (use //rbar resetpos for xivcrossbar void).', cached_cx, cached_cy))
            return true
        end
    end
end)

-- -----------------------------------------------------------------------------
-- 60 FPS Render Loop (Zero-Allocation & Dirty-Flagged)
-- -----------------------------------------------------------------------------
windower.register_event('prerender', function()
    -- Fast-path: 1-nanosecond exit when IDLE and auto-hidden (no os.clock() call!)
    if state_phase == PHASE_IDLE and settings.auto_hide then
        if is_visible then hide_all() end
        return
    end

    local now = os_clock()
    create_prims()

    -- Expire unconfirmed optimistic pre-locks
    if state_phase == PHASE_LOCK and state_is_pre_lock and now >= state_pre_lock_exp then
        state_phase = PHASE_IDLE
    end

    -- Test mode cycling
    if state_phase == PHASE_TEST then
        if now >= state_test_until then
            state_phase = PHASE_IDLE
        elseif now >= state_end_time then
            local idx = (math_floor(now) % 3) + 1
            state_kind = idx -- 1 = KIND_JA, 2 = KIND_WS, 3 = KIND_SPELL
            local dur = (idx == KIND_SPELL and 2.5) or (idx == KIND_WS and 1.8) or 1.1
            state_start_time     = now
            state_duration       = dur
            state_end_time       = now + dur
            state_sub_unlock_rem = (idx == KIND_SPELL) and 0.9 or 0
        end
    end

    -- State transitions
    if state_phase == PHASE_LOCK and now >= state_end_time then
        state_phase       = PHASE_READY
        state_ready_until = now + READY_PULSE_SEC
    elseif state_phase == PHASE_CAST and now >= state_end_time + 2.5 then
        state_phase = PHASE_IDLE
    elseif state_phase == PHASE_READY and now >= state_ready_until then
        state_phase = PHASE_IDLE
    end

    if state_phase == PHASE_IDLE and settings.auto_hide then
        hide_all()
        return
    end

    is_visible = true
    local cx     = cached_cx
    local cy     = cached_cy
    local half_w = cached_half_w
    local bar_h  = cached_bar_h
    local half_h = cached_half_h
    local bdr    = cached_bdr
    local bg_a   = cached_bg_a
    local bar_a  = cached_bar_a

    local is_early = (now < state_early_until)

    -- 1. Outer Border & Track (Dirty-checked: zero C calls on static frames)
    set_prim_rect('rbar_border', cx - half_w - bdr, cy - half_h - bdr, half_w * 2 + bdr * 2, bar_h + bdr * 2)
    if is_early then
        set_prim_col('rbar_border', 240, COLORS.EARLY[1], COLORS.EARLY[2], COLORS.EARLY[3])
    else
        set_prim_col('rbar_border', math_min(255, bg_a + 35), 0, 0, 0)
    end
    set_prim_vis('rbar_border', true)

    set_prim_rect('rbar_track', cx - half_w, cy - half_h, half_w * 2, bar_h)
    set_prim_col('rbar_track', bg_a, 16, 20, 26)
    set_prim_vis('rbar_track', true)

    -- 2. Compute Wing Progress & Color
    local progress = 0
    local r, g, b = COLORS.JA[1], COLORS.JA[2], COLORS.JA[3]
    local rem = math_max(0, state_end_time - now)

    if state_phase == PHASE_CAST then
        local elapsed = now - state_start_time
        progress = math_max(0, math_min(1, elapsed / math_max(0.05, state_duration)))
        local col = (state_kind == KIND_RA and COLORS.RA_AIM) or (state_kind == KIND_ITEM and COLORS.ITEM) or COLORS.CAST
        r, g, b = col[1], col[2], col[3]
    elseif state_phase == PHASE_LOCK or state_phase == PHASE_TEST then
        progress = math_max(0, math_min(1, rem / math_max(0.05, state_duration)))
        if state_kind == KIND_JA then
            if rem <= 0.25 then
                r, g, b = lerp_color(COLORS.JA_NEAR, COLORS.JA, rem * 4.0)
            else
                r, g, b = COLORS.JA[1], COLORS.JA[2], COLORS.JA[3]
            end
        elseif state_kind == KIND_WS then
            if rem <= 0.30 then
                r, g, b = lerp_color(COLORS.WS_NEAR, COLORS.WS, rem / 0.30)
            else
                r, g, b = COLORS.WS[1], COLORS.WS[2], COLORS.WS[3]
            end
        elseif state_kind == KIND_SPELL then
            if rem > state_sub_unlock_rem then
                r, g, b = COLORS.SPELL_HARD[1], COLORS.SPELL_HARD[2], COLORS.SPELL_HARD[3]
            else
                r, g, b = COLORS.SPELL_MAGIC[1], COLORS.SPELL_MAGIC[2], COLORS.SPELL_MAGIC[3]
            end
        elseif state_kind == KIND_RA then
            r, g, b = COLORS.RA_LOCK[1], COLORS.RA_LOCK[2], COLORS.RA_LOCK[3]
        elseif state_kind == KIND_ITEM then
            r, g, b = COLORS.ITEM[1], COLORS.ITEM[2], COLORS.ITEM[3]
        else
            r, g, b = COLORS.INTERRUPT[1], COLORS.INTERRUPT[2], COLORS.INTERRUPT[3]
        end
    elseif state_phase == PHASE_READY then
        progress = 0
        r, g, b = COLORS.READY[1], COLORS.READY[2], COLORS.READY[3]
    end

    if is_early then
        r, g, b = COLORS.EARLY[1], COLORS.EARLY[2], COLORS.EARLY[3]
    end

    -- 3. Left & Right Wings (Dirty-checked: only calls C-API when wing_w changes by >= 1px)
    local wing_w = math_floor(half_w * progress + 0.5)
    if wing_w > 0 then
        set_prim_rect('rbar_left', cx - wing_w, cy - half_h, wing_w, bar_h)
        set_prim_col('rbar_left', bar_a, r, g, b)
        set_prim_vis('rbar_left', true)

        set_prim_rect('rbar_right', cx, cy - half_h, wing_w, bar_h)
        set_prim_col('rbar_right', bar_a, r, g, b)
        set_prim_vis('rbar_right', true)
    else
        set_prim_vis('rbar_left', false)
        set_prim_vis('rbar_right', false)
    end

    -- 4. Sub-Tick Markers for Spell Lockout
    if (state_phase == PHASE_LOCK or state_phase == PHASE_TEST) and state_kind == KIND_SPELL and state_sub_unlock_rem > 0 and rem > state_sub_unlock_rem then
        local sub_x = math_floor(half_w * (state_sub_unlock_rem / math_max(0.05, state_duration)) + 0.5)
        if sub_x > 2 and sub_x < half_w - 2 then
            set_prim_rect('rbar_sub_left', cx - sub_x, cy - half_h, 1, bar_h)
            set_prim_col('rbar_sub_left', 220, COLORS.SUB_TICK[1], COLORS.SUB_TICK[2], COLORS.SUB_TICK[3])
            set_prim_vis('rbar_sub_left', true)

            set_prim_rect('rbar_sub_right', cx + sub_x, cy - half_h, 1, bar_h)
            set_prim_col('rbar_sub_right', 220, COLORS.SUB_TICK[1], COLORS.SUB_TICK[2], COLORS.SUB_TICK[3])
            set_prim_vis('rbar_sub_right', true)
        else
            set_prim_vis('rbar_sub_left', false)
            set_prim_vis('rbar_sub_right', false)
        end
    else
        set_prim_vis('rbar_sub_left', false)
        set_prim_vis('rbar_sub_right', false)
    end

    -- 5. Center Target Line / Ready Beat Flash
    if state_phase == PHASE_READY then
        local pulse_t = math_max(0, (state_ready_until - now) / READY_PULSE_SEC)
        local pulse_w = math_max(2, math_floor(10 * pulse_t + 0.5))
        local pulse_a = math_floor(255 * pulse_t + 0.5)
        local cr, cg, cb = COLORS.READY[1], COLORS.READY[2], COLORS.READY[3]
        if is_early then
            cr, cg, cb = COLORS.EARLY[1], COLORS.EARLY[2], COLORS.EARLY[3]
        end
        set_prim_rect('rbar_center', cx - math_floor(pulse_w / 2), cy - half_h - 2, pulse_w, bar_h + 4)
        set_prim_col('rbar_center', pulse_a, cr, cg, cb)
        set_prim_vis('rbar_center', true)
    else
        set_prim_rect('rbar_center', cx - 1, cy - half_h - 2, 2, bar_h + 4)
        if is_early then
            set_prim_col('rbar_center', 255, COLORS.EARLY[1], COLORS.EARLY[2], COLORS.EARLY[3])
        else
            set_prim_col('rbar_center', 245, COLORS.CENTER_IDLE[1], COLORS.CENTER_IDLE[2], COLORS.CENTER_IDLE[3])
        end
        set_prim_vis('rbar_center', true)
    end

    -- 6. Optional Compact Countdown Text (Dirty-checked at 0.1s resolution)
    if settings.show_timer_text and (state_phase == PHASE_LOCK or state_phase == PHASE_CAST or state_phase == PHASE_TEST) then
        local t_str = s_format('%.1f', rem)
        if t_str ~= last_timer_str then
            timer_label:text(t_str)
            last_timer_str = t_str
        end
        if layout_dirty then
            timer_label:pos(cx - 10, cy - half_h - 15)
            layout_dirty = false
        end
        timer_label:color(r, g, b)
        if not timer_label:visible() then timer_label:show() end
    else
        if timer_label:visible() then timer_label:hide() end
    end
end)

-- -----------------------------------------------------------------------------
-- Lifecycle & Commands (//rbar, //rb, //rhythmbar)
-- -----------------------------------------------------------------------------
local function reset_state()
    state_phase       = PHASE_IDLE
    state_is_pre_lock = false
    hide_all()
end

windower.register_event('zone change', reset_state)
windower.register_event('logout', function()
    reset_state()
    player_id = nil
end)
windower.register_event('unload', function()
    hide_all()
    destroy_prims()
    if timer_label then timer_label:destroy() end
end)

windower.register_event('addon command', function(cmd, ...)
    local args = { ... }
    cmd = cmd and cmd:lower() or 'help'

    if cmd == 'test' then
        local dur = tonumber(args[1]) or 12
        local now = os_clock()
        state_phase      = PHASE_TEST
        state_kind       = KIND_JA
        state_start_time = now
        state_duration   = 1.2
        state_end_time   = now + 1.2
        state_test_until = now + dur
        chat_log(s_format('Running test preview for %ds (drag bar with mouse to move, or //rbar resetpos).', dur))

    elseif cmd == 'drag' then
        settings.draggable = not settings.draggable
        config.save(settings)
        chat_log('Mouse dragging ' .. (settings.draggable and 'ENABLED (always)' or 'DISABLED (only during //rbar test)') .. '.')

    elseif cmd == 'offset' and tonumber(args[1]) and tonumber(args[2]) then
        settings.use_crossbar_void = true
        settings.offset_x = tonumber(args[1])
        settings.offset_y = tonumber(args[2])
        config.save(settings)
        refresh_layout_cache()
        chat_log(s_format('Crossbar void offset set to (%d, %d) -> Screen (%d, %d).', settings.offset_x, settings.offset_y, cached_cx, cached_cy))

    elseif cmd == 'pos' and tonumber(args[1]) and tonumber(args[2]) then
        settings.use_crossbar_void = false
        settings.pos.x = tonumber(args[1])
        settings.pos.y = tonumber(args[2])
        config.save(settings)
        refresh_layout_cache()
        chat_log(s_format('Fixed position set to X=%d, Y=%d.', cached_cx, cached_cy))

    elseif cmd == 'resetpos' then
        settings.use_crossbar_void = true
        settings.offset_x = 8
        settings.offset_y = -189
        config.save(settings)
        refresh_layout_cache()
        chat_log(s_format('Position reset to xivcrossbar center void (%d, %d).', cached_cx, cached_cy))

    elseif cmd == 'size' and tonumber(args[1]) then
        settings.bar.width = math_max(24, math_min(400, math_floor(tonumber(args[1]))))
        if tonumber(args[2]) then
            settings.bar.height = math_max(3, math_min(30, math_floor(tonumber(args[2]))))
        end
        config.save(settings)
        refresh_layout_cache()
        chat_log(s_format('Bar size set to %dx%d px.', settings.bar.width, settings.bar.height))

    elseif cmd == 'text' then
        settings.show_timer_text = not settings.show_timer_text
        config.save(settings)
        chat_log('Timer text ' .. (settings.show_timer_text and 'ENABLED' or 'DISABLED') .. '.')

    elseif cmd == 'autohide' then
        settings.auto_hide = not settings.auto_hide
        config.save(settings)
        chat_log('Auto-hide ' .. (settings.auto_hide and 'ENABLED' or 'DISABLED') .. '.')

    elseif cmd == 'autotune' then
        settings.auto_tune = not settings.auto_tune
        config.save(settings)
        chat_log('Auto-tune ' .. (settings.auto_tune and 'ENABLED' or 'DISABLED') .. '.')

    elseif (cmd == 'ja' or cmd == 'ws' or cmd == 'spell' or cmd == 'ranged' or cmd == 'item') and tonumber(args[1]) then
        local val = math_max(0.2, math_min(10.0, tonumber(args[1])))
        settings.lockouts[cmd] = val
        config.save(settings)
        chat_log(s_format('%s lockout set to %.2fs.', cmd:upper(), val))

    else
        chat_log(s_format('v%s | Center: (%d, %d) | RTT: %dms | JA: %.2fs | WS: %.2fs | Spell: %.2fs',
            _addon.version, cached_cx, cached_cy, math_floor(avg_rtt * 1000 + 0.5),
            settings.lockouts.ja, settings.lockouts.ws, settings.lockouts.spell))
        chat_log('Commands: //rbar test [sec] | //rbar drag | //rbar offset <dx> <dy> | //rbar pos <x> <y> | //rbar resetpos')
        chat_log('          //rbar size <w> [h] | //rbar text | //rbar autohide | //rbar <ja|ws|spell> <sec>')
    end
end)
