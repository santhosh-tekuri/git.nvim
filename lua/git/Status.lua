local M = {}
M.__index = M

function M:new(lines, categorized)
    local inst = { categorized = categorized }
    inst.branch = lines[1]:sub(4)
    table.remove(lines, 1)
    if categorized then
        local staged, unstaged, unmerged, untracked = {}, {}, {}, {}
        for _, line in ipairs(lines) do
            local ch1, ch2 = line:sub(1, 1), line:sub(2, 2)
            if ch1 == '?' and ch2 == '?' then
                table.insert(untracked, line:sub(2))
            elseif (ch1 == 'A' and ch2 == 'A') or (ch1 == 'D' and ch2 == 'D') or ch1 == 'U' or ch2 == 'U' then
                table.insert(unmerged, line)
            else
                if ch1 ~= ' ' then
                    table.insert(staged, ch1 .. line:sub(3))
                end
                if ch2 ~= ' ' then
                    table.insert(unstaged, line:sub(2))
                end
            end
            lines = {}
            vim.list_extend(lines, staged)
            vim.list_extend(lines, unstaged)
            vim.list_extend(lines, unmerged)
            vim.list_extend(lines, untracked)
            inst.lines = lines
            inst.staged = #staged
            inst.unstaged = #unstaged
            inst.unmerged = #unmerged
            inst.untracked = #untracked
        end
    else
        inst.lines = lines
    end
    setmetatable(inst, M)
    return inst
end

function M:category(line)
    if not self.categorized then
        return nil
    end
    if line <= self.staged then
        return { staged = true, name = "staged" }
    elseif line <= self.staged + self.unstaged then
        return { unstaged = true, name = "unstaged" }
    elseif line <= self.staged + self.unstaged + self.unmerged then
        return { unmerged = true, name = "unmerged" }
    else
        return { untracked = true, name = "untracked" }
    end
end

function M:file(line)
    line = self.lines[line]
    local space = line:find(" ", 1, true)
    return line:sub(space + 1)
end

return M
