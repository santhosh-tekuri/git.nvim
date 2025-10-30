local M = {}

function M.find_root()
    local root = vim.fn.systemlist("git rev-parse --show-toplevel")
    if vim.v.shell_error ~= 0 then
        M.root = nil
    else
        M.root = root[1]
    end
    return M.root
end

function M.system(cmd)
    local res = vim.system(cmd, { cwd = M.root, text = true }):wait()
    return {
        code = res.code,
        stdout = res.stdout and vim.split(res.stdout, '\n', { trimempty = true }) or {},
        stderr = res.stderr and vim.split(res.stderr, '\n', { trimempty = true }) or {},
    }
end

function M.status()
    local res = M.system { "git", "--no-pager", "status", "-uall", "--porcelain=v1" }
    return res.code == 0 and res.stdout or nil
end

function M.is_tracked(file)
    return M.system { "git", "ls-files", "--error-unmatch", file }.code == 0
end

function M.diff(file, staged)
    local cmd = { "git", "--no-pager", "diff" }
    if staged then
        vim.list_extend(cmd, { "--staged", file })
        local res = M.system(cmd)
        return res.code == 0 and res.stdout or nil
    else
        local tracked = M.is_tracked(file)
        if not tracked then
            vim.list_extend(cmd, { "--no-index", "/dev/null" })
        end
        table.insert(cmd, file)
        local res = M.system(cmd)
        if not tracked then
            res.code = res.code == 0 and 1 or 0
        end
        return res.code == 0 and res.stdout or nil
    end
end

return M
