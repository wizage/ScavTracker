-- ScavTracker / chat / reader
--
-- Watches game chat for component-gain messages and reports each as a parsed
-- proc via a callback. Covers:
--   Scavenging: "Your Scavenging perk adds: <col=ffa500>4 x Enhancing components."
--   Blessing:   "Materials gained: 4 x Evasive components."
--
-- Requires the "chatAccess" permission (ChatMessage won't fire without it).

local Reader = {}

-- Lowercase trigger phrases identifying a countable component-gain message.
-- The message is lowercased before matching, so needles MUST be lowercase.
local PROC_MATCHES = {
    "scavenging",        -- Scavenging perk
    "materials gained",  -- Archaeology blessing
}

local function isComponentProc(message)
    local lower = string.lower(message)
    for _, needle in ipairs(PROC_MATCHES) do
        if string.find(lower, needle, 1, true) then return true end
    end
    return false
end

-- Remove RuneScape colour/formatting tags like <col=ffa500> and </col>.
local function stripTags(s)
    return (string.gsub(s, "<[^>]->", ""))
end

-- Parse a component-gain message into (count, name). Both supported formats
-- share a "N x <item>" tail; we capture it and drop the trailing
-- "component"/"components" word so "Enhancing components" -> "Enhancing".
-- Returns nil if the message doesn't match.
local function parseComponentProc(message)
    local clean = stripTags(message)
    local count, item = string.match(clean, "(%d+)%s*x%s*(.-)%.?%s*$")
    if not (count and item and item ~= "") then return nil end
    item = string.gsub(item, "%s*[Cc]omponents?$", "")
    if item == "" then return nil end
    return tonumber(count), item
end

-- Start listening. `onProc(name, count)` is called for each detected proc.
function Reader.Start(onProc)
    Event.ChatMessage.Subscribe("scavTrackerChat", function(e)
        local message = e.chatMessage
        if message == nil or message == "" or not isComponentProc(message) then
            return
        end
        local count, item = parseComponentProc(message)
        if count and item and onProc then
            onProc(item, count)
        end
    end)
end

function Reader.Stop()
    Event.ChatMessage.Unsubscribe("scavTrackerChat")
end

return Reader
