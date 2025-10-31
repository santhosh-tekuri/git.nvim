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

function M:header()
    for i, line in ipairs(self.lines) do
        if line:sub(1, 4) == "@@ -" then
            return i - 1
        end
    end
end

function M:is_change(line)
    local ch = self.lines[line]:sub(1, 1)
    return ch == '+' or ch == '-'
end

function M:select(step)
    local h = self:header()
    local sel = self.selection or { h + 1, h + 1 }
    local last = step == 1 and #self.lines or h + 2
    local cur = step == 1 and sel[2] or sel[1]
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
    self.selection = { vfrom, vto }
end

return M
