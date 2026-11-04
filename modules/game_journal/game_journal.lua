-- The Book of the Five Seals: the player's journal (extended opcode 209, JSON). Server side: data/lib/core/journal.lua.
-- client -> server: {a = "hello"}, {a = "open"}, {a = "page", tab, id}
-- server -> client: {a = "state", seals, broken, tabs = [{k, n, got, total}]}, {a = "list", tab, part, of, entries, regions},
--                   {a = "page", tab, id, title, sub, text, notes = [{t, done}], status, done, locked},
--                   {a = "unlock"}, {a = "new", tab, title}
-- Chapters: seals (the Codex and the five seals), rook and library (books read), chronicle (quest journal), atlas,
-- talk ("Hearsay": what quest and lore NPCs told the player, grouped by NPC; 04.11.2026).
local OPCODE = 209
local MIN_GAP = 200
local TABS = {'seals', 'rook', 'library', 'chronicle', 'atlas', 'talk'}
local TAB_TITLE = {seals = 'The Five Seals', rook = 'Rookgaard', library = 'The Library', chronicle = 'The Chronicle',
    atlas = "The Explorers' Atlas", talk = 'Things I Was Told'}
local GROUPED = {rook = true, library = true, talk = true}   -- entries sit under a heading (region / person)

local window = nil
local button = nil
local state = {seals = 0, broken = 0, tabs = {}}
local lists = {}          -- tab -> {entries, regions}
local building = {}       -- tab -> entries being received in parts
local current = 'seals'
local selected = {}       -- tab -> id
local pages = {}          -- 'tab:id' -> page
local rowsById = {}
local shown = {}          -- ids in the order of the left page
local lastReq, lastReqAt = nil, -1000
local lastSend = -MIN_GAP
local pendingOpen = nil

local function send(data, force)
    local now = g_clock.millis()
    if not force and now - lastSend < MIN_GAP then
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

local function decode(buffer)
    local ok, data = pcall(function() return json.decode(buffer) end)
    if not ok or type(data) ~= 'table' then
        g_logger.error('game_journal: bad message ' .. tostring(buffer))
        return nil
    end
    return data
end

local function child(id)
    return window and window:recursiveGetChildById(id)
end

local function tabInfo(k)
    for _, t in ipairs(state.tabs or {}) do
        if t.k == k then
            return t
        end
    end
end

local function chapterSub(k)
    local t = tabInfo(k)
    if k == 'seals' then
        if state.seals ~= 1 then
            return tr('A blank chapter')
        end
        return tr('%d of 5 seals broken', state.broken or 0)
    elseif not t then
        return ''
    elseif k == 'rook' or k == 'library' then
        return tr('%d of %d books copied', t.got or 0, t.total or 0)
    elseif k == 'chronicle' then
        return tr('%d stories written', t.got or 0)
    elseif k == 'atlas' then
        return tr('%d of %d places discovered', t.got or 0, t.total or 0)
    elseif k == 'talk' then
        local l = lists.talk
        return tr('%d things noted, from %d people', t.got or 0, l and l.regions and #l.regions or 0)
    end
    return ''
end

local function sealIcon(s)
    return '/game_journal/images/seal' .. tostring(math.max(0, math.min(2, tonumber(s) or 0)))
end

-- ---------------------------------------------------------------- right page
local function clearPage()
    if not window then
        return
    end
    child('page'):destroyChildren()
    child('pageTitle'):setText('')
    child('pageSub'):setText('')
    child('pageStatus'):setText('')
    child('pageSeal'):setImageSource('')
end

local function addText(text, italic)
    local label = g_ui.createWidget('JournalText', child('page'))
    if italic then
        label:setFont('verdana-11px-antialised-italic')
    end
    label:setText(text or '')
    return label
end

local function addNote(note)
    local w = g_ui.createWidget('JournalNote', child('page'))
    w:getChildById('mark'):setImageSource(note.done == 1 and '/game_journal/images/check' or '/game_journal/images/quill')
    local label = w:getChildById('text')
    label:setText(note.t or '')
    scheduleEvent(function()
        if w and not w:isDestroyed() and label and not label:isDestroyed() then
            w:setHeight(math.max(16, label:getHeight() + 2))
        end
    end, 30)
    return w
end

local function showPage(page)
    if not window or not page then
        return
    end
    clearPage()
    child('pageTitle'):setText(page.title or '')
    child('pageSub'):setText(page.sub or '')
    if page.tab == 'seals' then
        local s = page.locked == 1 and 0 or (page.done == 1 and 2 or 1)
        if page.id == 1 and page.locked ~= 1 then
            s = 2
        end
        if page.id == 1 then
            child('pageSeal'):setImageSource('/game_journal/images/codex_big')
        else
            child('pageSeal'):setImageSource('/game_journal/images/seal_big' .. s)
        end
    elseif page.tab == 'chronicle' then
        child('pageSeal'):setImageSource('/game_journal/images/seal_big1')
    end
    addText(page.text or '')
    if page.notes and #page.notes > 0 then
        addText(tr('From my notes:'), true)
        for _, n in ipairs(page.notes) do
            addNote(n)
        end
    end
    child('pageStatus'):setText(page.status or '')
end

-- chronicle and atlas entries carry their text; no server round trip
local function localPage(tab, e)
    if tab == 'chronicle' then
        return {tab = tab, id = e.id, title = e.t, sub = tr('From the Chronicle'), text = e.x or ''}
    elseif tab == 'atlas' then
        return {tab = tab, id = e.id, title = e.t, sub = tr('A place I have seen'), text = e.x or ''}
    end
end

local function entryOf(tab, id)
    local l = lists[tab]
    for _, e in ipairs(l and l.entries or {}) do
        if e.id == id then
            return e
        end
    end
end

function openEntry(tab, id)
    selected[tab] = id
    local e = entryOf(tab, id)
    if tab == 'chronicle' or tab == 'atlas' then
        if e then
            showPage(localPage(tab, e))
        end
        return
    end
    local cached = pages[tab .. ':' .. tostring(id)]
    if cached then
        showPage(cached)
    else
        clearPage()
        child('pageTitle'):setText(e and e.t or '')
        child('pageSub'):setText(tr('Turning the pages...'))
    end
    local key = tab .. ':' .. tostring(id)
    local now = g_clock.millis()
    if key ~= lastReq or now - lastReqAt > 300 then
        lastReq, lastReqAt = key, now
        send({a = 'page', tab = tab, id = id}, true)
    end
end

-- ---------------------------------------------------------------- left page
local function addRow(tab, e)
    local row = g_ui.createWidget('JournalRow', child('entries'))
    local icon = row:getChildById('icon')
    if tab == 'seals' and e.id == 1 then
        icon:setImageSource('/game_journal/images/codex_icon')   -- the Codex itself (same art as the item)
    elseif tab == 'seals' then
        icon:setImageSource(sealIcon(e.s))
    elseif tab == 'chronicle' or tab == 'talk' then
        icon:setImageSource('/game_journal/images/quill')
        icon:setSize({width = 14, height = 14})
    else
        icon:setImageSource('/game_journal/images/book_read')
        icon:setSize({width = 14, height = 14})
    end
    row:getChildById('title'):setText(e.t or '')
    if GROUPED[tab] then
        row:setHeight(22)       -- books sit under their region, sayings under their person: no second line
    else
        row:getChildById('sub'):setText(e.sub or '')
    end
    if tab == 'seals' and e.s == 0 then
        row:getChildById('title'):setColor('#8a7a66')
    end
    row.onFocusChange = function(widget, focused)
        if focused then
            openEntry(tab, e.id)
        end
    end
    rowsById[e.id] = row
    shown[#shown + 1] = e.id
    return row
end

local function addRegion(r)
    local w = g_ui.createWidget('JournalRegion', child('entries'))
    w:getChildById('name'):setText(r.r or '')
    w:getChildById('count'):setText(tostring(r.got or 0) .. ' / ' .. tostring(r.total or 0))
    return w
end

function refresh()
    if not window then
        return
    end
    for _, k in ipairs(TABS) do
        local tab = child('tab_' .. k)
        if tab then
            tab:setOn(k == current)
        end
    end
    child('chapterTitle'):setText(TAB_TITLE[current] or '')
    child('chapterSub'):setText(chapterSub(current))
    local list = child('entries')
    list:destroyChildren()
    rowsById = {}
    shown = {}
    local l = lists[current]
    local entries = l and l.entries or {}
    if GROUPED[current] then
        -- books grouped by region, sayings by person; every group shows how many of its entries are kept
        local byRegion = {}
        for _, e in ipairs(entries) do
            byRegion[e.r or ''] = byRegion[e.r or ''] or {}
            table.insert(byRegion[e.r or ''], e)
        end
        for _, r in ipairs(l and l.regions or {}) do
            addRegion(r)
            for _, e in ipairs(byRegion[r.r] or {}) do
                addRow(current, e)
            end
        end
    else
        for _, e in ipairs(entries) do
            addRow(current, e)
        end
    end
    if #entries == 0 then
        local empty = g_ui.createWidget('JournalText', list)
        empty:setFont('verdana-11px-antialised-italic')
        if current == 'rook' or current == 'library' then
            empty:setText(tr('No book copied yet. Read the books you find; your journal copies every one of them.'))
        elseif current == 'chronicle' then
            empty:setText(tr('The chronicles do not mention you yet. Go and do something worth writing down!'))
        elseif current == 'atlas' then
            empty:setText(tr('No place discovered yet. The world is waiting.'))
        elseif current == 'talk' then
            empty:setText(tr('Nobody has told you anything worth noting yet. Talk to people: what they know about the old stories and hidden places is written down here.'))
        else
            empty:setText(tr('These pages are still empty.'))
        end
    end
    local id = selected[current] or shown[1]
    if id and rowsById[id] then
        rowsById[id]:focus()
        openEntry(current, id)
    else
        clearPage()
    end
end

function selectTab(k)
    current = k
    refresh()
end

function step(delta)
    if #shown == 0 then
        return
    end
    local idx = 1
    for i, id in ipairs(shown) do
        if id == selected[current] then
            idx = i
        end
    end
    idx = math.max(1, math.min(#shown, idx + delta))
    local id = shown[idx]
    if rowsById[id] then
        rowsById[id]:focus()
        child('entries'):ensureChildVisible(rowsById[id])
    end
    openEntry(current, id)
end

-- ---------------------------------------------------------------- messages from the server
function onExtendedOpcode(protocol, opcode, buffer)
    local data = decode(buffer)
    if not data then
        return
    end
    if data.a == 'state' then
        state.seals = data.seals or 0
        state.broken = data.broken or 0
        if data.tabs then
            state.tabs = data.tabs
        end
        if button then
            button:setVisible(true)
        end
    elseif data.a == 'list' then
        local tab = data.tab
        if data.part == 1 then
            building[tab] = {entries = {}, regions = data.regions}
        end
        local b = building[tab]
        if b then
            for _, e in ipairs(data.entries or {}) do
                table.insert(b.entries, e)
            end
            if data.part == data.of then
                lists[tab] = b
                building[tab] = nil
                if window and tab == current then
                    refresh()
                end
            end
        end
    elseif data.a == 'page' then
        pages[data.tab .. ':' .. tostring(data.id)] = data
        if window and data.tab == current and selected[current] == data.id then
            showPage(data)
        end
    elseif data.a == 'unlock' then
        state.seals = 1
        pages = {}
        current = 'seals'
        selected.seals = 1
        show(true)
    elseif data.a == 'new' then
        pages = {}
        if window then
            send({a = 'open'}, true)
        else
            blink(6)
        end
    end
end

-- the journal button blinks a few times when something new was written while the book is closed
local blinkEvent = nil
function blink(times)
    if not button or blinkEvent then
        return
    end
    local n = 0
    local function tick()
        blinkEvent = nil
        if not button or window then
            return
        end
        n = n + 1
        button:setOn(n % 2 == 1)
        if n < times then
            blinkEvent = scheduleEvent(tick, 400)
        else
            button:setOn(false)
        end
    end
    tick()
end

-- ---------------------------------------------------------------- window
function show(fromServer)
    if not g_game.isOnline() then
        return
    end
    if not window then
        window = g_ui.createWidget('JournalWindow', rootWidget)
    end
    window:show()
    window:raise()
    window:focus()
    if button then
        button:setOn(true)
    end
    refresh()
    if not fromServer then
        pages = {}
        send({a = 'open'}, true)
    end
end

function hide()
    if window then
        window:destroy()
        window = nil
    end
    rowsById = {}
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
        button = modules.game_mainpanel.addToggleButton('journalButton', tr('Journal'),
            '/game_journal/images/button_journal', toggle, false, 1003)
        button:setOn(false)
    elseif (tries or 0) < 20 then
        scheduleEvent(function() addButton((tries or 0) + 1) end, 250)
    end
end

local function onGameStart()
    state = {seals = 0, broken = 0, tabs = {}}
    lists, building, pages, selected = {}, {}, {}, {}
    current = 'seals'
    addButton()
    -- tell the server the journal window is here (it then opens the book when a Codex is used)
    scheduleEvent(function() send({a = 'hello'}, true) end, 1500)
end

local function onGameEnd()
    if blinkEvent then
        removeEvent(blinkEvent)
        blinkEvent = nil
    end
    hide()
end

function init()
    g_ui.importStyle('game_journal')
    ProtocolGame.registerExtendedOpcode(OPCODE, onExtendedOpcode)
    connect(g_game, {onGameStart = onGameStart, onGameEnd = onGameEnd})
    if g_game.isOnline() then
        onGameStart()
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
