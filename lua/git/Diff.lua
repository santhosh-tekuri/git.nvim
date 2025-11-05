local M = {}
M.__index = M

function M:new(lines, line_mode)
    local inst = { lines = lines, line_mode = line_mode }
    setmetatable(inst, M)
    return inst
end

function M:empty()
    return #self.lines == 0
end

function M:is_header(i)
    local line = self.lines[i]
    local ch = line:sub(1, 1)
    if ch == "@" then
        return false
    end
    if ch == "+" or ch == '-' then
        for j = i - 1, 1, -1 do
            ch = self.lines[j]:sub(1, 1)
            if ch == "@" then
                return false
            elseif ch == "d" then
                return true
            end
        end
    end
    assert(false)
end

function M:header()
    for i, line in ipairs(self.lines) do
        if line:sub(1, 4) == "@@ -" then
            return i - 1
        end
    end
    return #self.lines -- no hunks
end

function M:is_change(line)
    local ch = self.lines[line]:sub(1, 1)
    return (ch == '+' or ch == '-') and not self:is_header(line)
end

function M:select(step, selection)
    if #self.lines == 0 then
        return
    end
    local h = self:header()
    local sel = selection or self.selection or { h + 1, h + 1 }
    local last = step == 1 and #self.lines or h + 2
    local cur = step == 1 and sel[2] or math.min(sel[1], #self.lines + 1)
    for i = cur + step, last, step do
        if self:is_change(i) then
            if self.line_mode then
                self.selection = { i, i }
            else
                local j = i
                for t = i + step, last, step do
                    if not self:is_change(t) then
                        break
                    end
                    j = t
                end
                self.selection = { math.min(i, j), math.max(i, j) }
            end
            return self.selection
        end
    end
end

function M:selection_loc()
    local change = 0
    local tmp = self.selection[1]
    while true do
        local ch = self.lines[tmp]:sub(1, 1)
        if ch == '+' or ch == '-' then
            change = change + 1
            tmp = tmp - 1
        else
            break
        end
    end
    local begin = 0
    while true do
        local ch = self.lines[tmp]:sub(1, 1)
        if ch == '-' or ch == ' ' then
            begin = begin + 1
        elseif ch == '@' then
            local x, y = self.lines[tmp]:match("^@@ %-(%d+),(%d+) ")
            if x then
                begin = begin + tonumber(x)
                if tonumber(y) > 0 then
                    begin = begin - 1
                end
            end
            break
        end
        tmp = tmp - 1
    end
    return { begin, change }
end

function M:toggle_mode()
    self.line_mode = not self.line_mode
    local vfrom, vto = unpack(self.selection)
    while self:is_change(vfrom) do
        vfrom = vfrom - 1
    end
    vto = vfrom - 1
    return self:select(1, { vfrom, vto })
end

local function parse_hunk_range(line)
    local old, new, section = line:match("^@@ %-(%S+) %+(%S+) @@(.*)$")
    local function range(s)
        local comma = s:find(',', 1, true)
        if comma then
            local t = { tonumber(s:sub(1, comma - 1)), tonumber(s:sub(comma + 1)) }
            if t[2] == 0 then
                t[1] = t[1] + 1
            end
            return t
        else
            return { tonumber(s), 1 }
        end
    end
    return { old = range(old), new = range(new), section = section:sub(2) }
end

local function hunk_range_line(hunk)
    local function range(arr)
        if arr[2] == 0 then
            return ("%d,0"):format(arr[1] - 1)
        elseif arr[2] == 1 then
            return ("%d"):format(arr[1])
        else
            return ("%d,%d"):format(arr[1], arr[2])
        end
    end
    local s = "@@ -" .. range(hunk.old) .. " +" .. range(hunk.new) .. " @@"
    if #hunk.section > 0 then
        s = s .. " " .. hunk.section
    end
    return s
end

function M:patch_with_selection()
    local patch = {}

    -- add header
    local h = self:header()
    for i = 1, h do
        table.insert(patch, self.lines[i])
    end

    -- locate hunk start
    local from, to = unpack(self.selection)
    local i = from - 1
    while self.lines[i]:sub(1, 1) ~= '@' do
        i = i - 1
    end

    table.insert(patch, self.lines[i])
    i = i + 1
    local olen, nlen = 0, 0
    while i <= #self.lines and self.lines[i]:sub(1, 1) ~= '@' do
        local ch = self.lines[i]:sub(1, 1)
        if i >= from and i <= to then
            table.insert(patch, self.lines[i])
            if ch == '+' then
                nlen = nlen + 1
            else
                olen = olen + 1
            end
        else
            local line
            if ch == ' ' then
                line = self.lines[i]
            elseif ch == '-' then
                line = ' ' .. self.lines[i]:sub(2)
            end
            if line then
                table.insert(patch, line)
                olen = olen + 1
                nlen = nlen + 1
            end
        end
        i = i + 1
    end

    local range = parse_hunk_range(patch[h + 1])
    range.old[2] = olen
    range.new[2] = nlen
    patch[h + 1] = hunk_range_line(range)
    return patch
end

function M:patch_without_selection()
    local patch = {}

    -- add header
    local h = self:header()
    for i = 1, h do
        table.insert(patch, self.lines[i])
    end

    -- locate hunk start
    local from, to = unpack(self.selection)
    local i = from - 1
    while self.lines[i]:sub(1, 1) ~= '@' do
        i = i - 1
    end

    -- add hunks before selection
    for j = h + 1, i - 1 do
        local line = self.lines[j]
        table.insert(patch, line)
    end

    local hunk = { self.lines[i] }
    i = i + 1
    local olen, nlen, changes = 0, 0, false
    while i <= #self.lines and self.lines[i]:sub(1, 1) ~= '@' do
        local ch = self.lines[i]:sub(1, 1)
        if i >= from and i <= to then
            local line
            if ch == '-' then
                line = ' ' .. self.lines[i]:sub(2)
                table.insert(hunk, line)
                olen = olen + 1
                nlen = nlen + 1
            end
        else
            table.insert(hunk, self.lines[i])
            if ch == '+' then
                changes = true
                nlen = nlen + 1
            elseif ch == '-' then
                changes = true
                olen = olen + 1
            else
                olen = olen + 1
                nlen = nlen + 1
            end
        end
        i = i + 1
    end
    if changes then
        local range = parse_hunk_range(hunk[1])
        range.old[2] = olen
        range.new[2] = nlen
        hunk[1] = hunk_range_line(range)
        vim.list_extend(patch, hunk)
    end

    -- add hunks after selection
    for j = i, #self.lines do
        local line = self.lines[j]
        table.insert(patch, line)
    end

    return #patch > h and patch or nil
end

return M
