-- PvP window: duels, Head Hunters (bounties) and guild wars (extended opcode 208, JSON).
-- The server side is data/lib/core/pvp.lua; it sends the whole state after every answer and when something happens.
local OPCODE = 208
local MIN_GAP = 200          -- ms between two requests (the server takes one message per 150 ms)

local window = nil
local button = nil
local state = nil
local tab = 'duels'
local lastSend = -MIN_GAP

local VOC = {[0] = 'none', 'Sorcerer', 'Druid', 'Paladin', 'Knight', 'Master Sorcerer', 'Elder Druid', 'Royal Paladin', 'Elite Knight'}

local function send(data)
    local now = g_clock.millis()
    if now - lastSend < MIN_GAP then
        return false
    end
    local protocol = g_game.getProtocolGame()
    if protocol then
        lastSend = now
        protocol:sendExtendedOpcode(OPCODE, json.encode(data))
        return true
    end
    return false
end

local function gold(n)
    local s = tostring(math.floor(tonumber(n) or 0)):reverse():gsub('(%d%d%d)', '%1,'):reverse()
    return s:gsub('^,', '') .. ' gold'
end

local function money(n, coins)
    return coins and (tostring(n) .. ' Premium Coins') or gold(n)
end

local function left(secs)
    secs = math.max(0, math.floor(secs or 0))
    if secs >= 86400 then
        return tr('%dd %dh', math.floor(secs / 86400), math.floor(secs % 86400 / 3600))
    elseif secs >= 3600 then
        return tr('%dh %dm', math.floor(secs / 3600), math.floor(secs % 3600 / 60))
    end
    return tr('%dm', math.max(1, math.floor(secs / 60)))
end

local function child(path)
    local w = window
    for id in path:gmatch('[^.]+') do
        if not w then
            return nil
        end
        w = w:recursiveGetChildById(id) or w:getChildById(id)
    end
    return w
end

local function panel(id)
    return window and window:getChildById(id)
end

local function setStatus(text, ok)
    if window then
        local s = window:getChildById('status')
        s:setText(text or '')
        s:setColor(ok == false and '#ff8060' or '#ffd860')
    end
end

local function number(widget)
    return tonumber((widget:getText() or ''):gsub('[^%d]', '') or '') or 0
end

local function addRow(list, text, info, buttons)
    local row = g_ui.createWidget('PvpRow', list)
    row:getChildById('text'):setText(text)
    row:getChildById('info'):setText(info or '')
    buttons = buttons or {}
    for i, b in ipairs(buttons) do
        local w = row:getChildById('btn' .. i)
        if w then
            w:setText(b[1])
            w:setVisible(true)
            w.onClick = b[2]
        end
    end
    return row
end

-- ------------------------------------------------------------------ duels
local function duelLine(d, me)
    local other = d.challenger_name == me and d.opponent_name or d.challenger_name
    return other, tr('%s, first to %d %s', gold(d.stake), d.deaths, d.deaths == 1 and tr('kill') or tr('kills'))
end

local function fillDuels()
    local p = panel('duels')
    local list = p:getChildById('list')
    list:destroyChildren()
    local r, me, now = state.rules or {}, state.me or '', state.now or os.time()
    local duels = state.duels or {}
    p:getChildById('help'):setText(tr('Both pay half of the stake. Only kills by your opponent count. A duel death is a real death and every kill is a frag. Level %d+, invitations last %d min, a duel %d h.',
        r.minLevel or 20, r.inviteMin or 15, math.floor((r.durationMin or 180) / 60)))
    local a = duels.active
    local surrender = p:getChildById('surrenderButton')
    if a and a.id then
        p:getChildById('active'):setText(tr('Duel: %s %d : %d %s for %s, first to %d. Ends in %s.', a.challenger_name, a.kills1, a.kills2,
            a.opponent_name, gold(a.stake), a.deaths, left((a.ends or now) - now)))
        surrender:setVisible(true)
        surrender.duelId = a.id
    else
        p:getChildById('active'):setText(tr('No duel right now. Challenge somebody below.'))
        surrender:setVisible(false)
    end
    for _, d in ipairs(duels.incoming or {}) do
        local id = d.id
        addRow(list, tr('%s challenges you', d.challenger_name), tr('%s - your half %s - %s left', select(2, duelLine(d, me)),
            gold(d.stake / 2), left((d.expires or now) - now)),
            {{tr('Accept'), function() send({action = 'duelAccept', id = id}) end},
             {tr('Decline'), function() send({action = 'duelDecline', id = id}) end}})
    end
    for _, d in ipairs(duels.outgoing or {}) do
        local id = d.id
        addRow(list, tr('You challenged %s', d.opponent_name), tr('%s - waiting, %s left', select(2, duelLine(d, me)), left((d.expires or now) - now)),
            {{tr('Withdraw'), function() send({action = 'duelCancel', id = id}) end}})
    end
    local names = {[2] = tr('finished'), [3] = tr('declined'), [4] = tr('withdrawn'), [5] = tr('ran out')}
    for _, d in ipairs(duels.history or {}) do
        local other, what = duelLine(d, me)
        local result = names[d.state] or ''
        if d.state == 2 then
            if d.winner == 0 then
                result = tr('draw')
            else
                result = (d.winner == d.challenger and d.challenger_name or d.opponent_name) == me and tr('you won') or tr('you lost')
            end
        end
        addRow(list, tr('%s vs %s: %s', d.challenger_name, d.opponent_name, result), tr('%d : %d - %s', d.kills1, d.kills2, what))
    end
end

-- ------------------------------------------------------------- Head Hunters
local function fillBounties()
    local p = panel('bounties')
    local list = p:getChildById('list')
    list:destroyChildren()
    local r, now = state.rules or {}, state.now or os.time()
    p:getChildById('help'):setText(tr('You pay the reward now (gold from your purse or backpack, or Premium Coins). Min %s or %d coins, %d active per account, %d days. The killer takes it; never your own characters or the same IP.',
        gold(r.bountyMinGold or 5000), r.bountyMinCoins or 25, r.bountyMax or 2, r.bountyDays or 14))
    for _, b in ipairs(state.bounties or {}) do
        local name = b.target
        addRow(list, tr('%s - %s', b.target, money(b.amount, b.coins)) .. (b.mine and ('  ' .. tr('(yours)')) or ''),
            tr('level %d %s - %s - %s left', b.level or 0, VOC[b.vocation or 0] or '', b.online and tr('online') or tr('offline'),
                left((b.expires or now) - now)),
            {{tr('Raise'), function()
                p:getChildById('bountyName'):setText(name)
            end}})
    end
    if #(state.bounties or {}) == 0 then
        addRow(list, tr('No bounties right now.'))
    end
    local lines = {}
    for _, h in ipairs(state.bountyHistory or {}) do
        lines[#lines + 1] = tr('%s took %s for %s', h.hunter_name, money(h.amount, h.coins == 1), h.target_name)
        if #lines >= 3 then
            break
        end
    end
    p:getChildById('recent'):setText(#lines > 0 and (tr('Last collected:') .. ' ' .. table.concat(lines, '; ')) or '')
end

-- --------------------------------------------------------------- guild wars
local function fillWars()
    local p = panel('wars')
    local list = p:getChildById('list')
    list:destroyChildren()
    local r, now, g = state.rules or {}, state.now or os.time(), state.guild
    local leader = type(g) == 'table' and g.leader
    if type(g) == 'table' then
        p:getChildById('guild'):setText(tr('Your guild: %s', g.name) .. (leader and ('  ' .. tr('(you lead it)')) or ''))
    else
        p:getChildById('guild'):setText(tr('You are not in a guild.'))
    end
    for _, id in ipairs({'warGuild', 'warFrags', 'warDays', 'warStake', 'declareButton'}) do
        p:getChildById(id):setEnabled(leader and true or false)
    end
    p:getChildById('help'):setText(tr('Leaders declare war (frags %d-%d, up to %d days, stake per guild). Kills count for the war and are normal frags (red skull, ban); the first guild to the limit takes both stakes. Each guild needs %d members of level %d+.',
        r.warMinFrags or 5, r.warMaxFrags or 500, r.warMaxDays or 14, r.warMinMembers or 3, r.minLevel or 20))
    local myId = type(g) == 'table' and g.id or 0
    local shown = {}
    for _, w in ipairs(state.wars or {}) do
        shown[w.id] = true
        local id = w.id
        local score = tr('%s %d : %d %s', w.name1, w.kills1, w.kills2, w.name2)
        local terms = tr('first to %d, %d days, stake %s per guild', w.frag_limit, w.days, gold(w.stake))
        if w.status == 0 then
            local buttons = {}
            if leader and w.guild2 == myId then
                buttons = {{tr('Accept'), function() send({action = 'warAccept', id = id}) end},
                    {tr('Reject'), function() send({action = 'warReject', id = id}) end}}
            elseif leader and w.guild1 == myId then
                buttons = {{tr('Withdraw'), function() send({action = 'warCancel', id = id}) end}}
            end
            addRow(list, tr('%s declared war on %s', w.name1, w.name2), terms, buttons)
        elseif w.status == 1 then
            addRow(list, tr('WAR: %s', score), terms .. ' - ' .. tr('%s left', left((w.ends_at or now) - now)),
                leader and {{tr('Surrender'), function() send({action = 'warSurrender', id = id}) end}} or nil)
        else
            local res = ({[2] = tr('rejected'), [3] = tr('withdrawn')})[w.status]
            if w.status == 4 then
                res = w.winner == 0 and tr('draw') or tr('%s won', w.winner == w.guild1 and w.name1 or w.name2)
            end
            addRow(list, tr('%s vs %s: %s', w.name1, w.name2, res or ''), score)
        end
    end
    for _, w in ipairs(state.allWars or {}) do
        if not shown[w.id] then
            addRow(list, tr('WAR: %s %d : %d %s', w.name1, w.kills1, w.kills2, w.name2),
                tr('first to %d - %s left', w.frag_limit, left((w.ends_at or now) - now)))
        end
    end
    if list:getChildCount() == 0 then
        addRow(list, tr('No guild wars right now.'))
    end
end

function refresh()
    if not window or not state then
        return
    end
    window:getChildById('purse'):setText(tr('Purse: %s   Coins: %d', gold(state.purse or 0), state.coins or 0))
    window:getChildById('withdrawButton'):setEnabled((state.purse or 0) > 0)
    fillDuels()
    fillBounties()
    fillWars()
end

function selectTab(name)
    tab = name
    if not window then
        return
    end
    for _, t in ipairs({'duels', 'bounties', 'wars'}) do
        panel(t):setVisible(t == name)
    end
    window:getChildById('tabDuels'):setOn(name == 'duels')
    window:getChildById('tabBounties'):setOn(name == 'bounties')
    window:getChildById('tabWars'):setOn(name == 'wars')
end

-- ------------------------------------------------------------------ actions
function challenge()
    local p = panel('duels')
    local name = p:getChildById('duelName'):getText():trim()
    if name == '' then
        setStatus(tr('Type the name of your opponent.'), false)
        return
    end
    send({action = 'duelChallenge', name = name, stake = number(p:getChildById('duelStake')), deaths = number(p:getChildById('duelDeaths'))})
end

function surrenderDuel()
    local b = panel('duels'):getChildById('surrenderButton')
    if b.duelId then
        send({action = 'duelSurrender', id = b.duelId})
    end
end

function onCurrencyChange()
    if not window then
        return
    end
    local p = panel('bounties')
    local opt = p:getChildById('bountyCurrency'):getCurrentOption()
    local r = state and state.rules or {}
    p:getChildById('bountyAmount'):setText(tostring(opt and opt.data == 'coins' and (r.bountyMinCoins or 25) or (r.bountyMinGold or 5000)))
end

function placeBounty()
    local p = panel('bounties')
    local name = p:getChildById('bountyName'):getText():trim()
    if name == '' then
        setStatus(tr('Type the name of the target.'), false)
        return
    end
    local opt = p:getChildById('bountyCurrency'):getCurrentOption()
    send({action = 'bountyPlace', name = name, amount = number(p:getChildById('bountyAmount')), currency = opt and opt.data or 'gold'})
end

function declareWar()
    local p = panel('wars')
    local name = p:getChildById('warGuild'):getText():trim()
    if name == '' then
        setStatus(tr('Type the name of the guild.'), false)
        return
    end
    send({action = 'warDeclare', guild = name, frags = number(p:getChildById('warFrags')), days = number(p:getChildById('warDays')),
        stake = number(p:getChildById('warStake'))})
end

function withdraw()
    send({action = 'withdraw', amount = 0})
end

-- ------------------------------------------------------------------ server
function onExtendedOpcode(protocol, opcode, buffer)
    local ok, data = pcall(function() return json.decode(buffer) end)
    if not ok or type(data) ~= 'table' then
        g_logger.error('game_pvp: bad message ' .. tostring(buffer))
        return
    end
    if data.action == 'state' then
        state = data
        refresh()
        if data.reason == 'invite' and not window and button then
            button:setOn(true)    -- light the button: somebody challenged you
        end
    elseif data.action == 'result' then
        setStatus(data.message, data.ok)
    end
end

function show()
    if not g_game.isOnline() then
        return
    end
    if not window then
        window = g_ui.createWidget('PvpWindow', rootWidget)
        local box = panel('bounties'):getChildById('bountyCurrency')
        box:addOption(tr('Gold'), 'gold')
        box:addOption(tr('Premium Coins'), 'coins')
        selectTab(tab)
    end
    window:show()
    window:raise()
    window:focus()
    if button then
        button:setOn(true)
    end
    refresh()
    send({action = 'open'})
end

function hide()
    if window then
        window:destroy()
        window = nil
    end
    if button then
        button:setOn(false)
    end
end

function toggle()
    if window and window:isVisible() then
        hide()
    else
        show()
    end
end

local function addButton(tries)
    if button then
        return
    end
    local mainpanel = g_modules.getModule('game_mainpanel')
    if modules.game_mainpanel and mainpanel and mainpanel:isLoaded() then
        button = modules.game_mainpanel.addToggleButton('pvpButton', tr('PvP: duels, Head Hunters, guild wars'),
            '/images/options/button_frags', toggle, false, 1003)
        button:setOn(false)
    elseif (tries or 0) < 20 then
        scheduleEvent(function() addButton((tries or 0) + 1) end, 250)
    end
end

local function onGameStart()
    state = nil
    addButton()
end

local function onGameEnd()
    hide()
    state = nil
end

function init()
    g_ui.importStyle('game_pvp')
    ProtocolGame.registerExtendedOpcode(OPCODE, onExtendedOpcode)
    connect(g_game, {onGameStart = onGameStart, onGameEnd = onGameEnd})
    if g_game.isOnline() then
        addButton()
    end
end

function terminate()
    disconnect(g_game, {onGameStart = onGameStart, onGameEnd = onGameEnd})
    ProtocolGame.unregisterExtendedOpcode(OPCODE)
    onGameEnd()
    if button then
        button:destroy()
        button = nil
    end
end
