local cli = require("git.cli")

local M = {}
M.__index = M

function M:new()
    local status = assert(cli.status())
    local branch = status[1]:sub(4)
    table.remove(status, 1)
    local staged, unstaged, unmerged, untracked = {}, {}, {}, {}
    for _, line in ipairs(status) do
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
    end
    local lines, types = {}, {}
    vim.list_extend(lines, staged)
    while #types < #lines do
        table.insert(types, "Staged")
    end
    vim.list_extend(lines, unstaged)
    while #types < #lines do
        table.insert(types, "Unstaged")
    end
    vim.list_extend(lines, unmerged)
    while #types < #lines do
        table.insert(types, "Unmerged")
    end
    vim.list_extend(lines, untracked)
    while #types < #lines do
        table.insert(types, "Untracked")
    end
    local inst = {
        branch = branch,
        lines = lines,
        types = types,
    }
    inst.staged = #staged
    inst.unstaged = #unstaged
    inst.unmerged = #unmerged
    inst.untracked = #untracked
    setmetatable(inst, M)
    return inst
end

function M:file(line)
    line = self.lines[line]
    local space = line:find(" ", 1, true)
    return line:sub(space + 1)
end

return M
