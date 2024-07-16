local utils = require("scope.utils")
local config = require("scope.config")

local M = {}

M.cache = {}
M.last_tab = 0

function M.on_tab_new_entered()
    vim.api.nvim_buf_set_option(0, "buflisted", true)
end

function M.on_tab_enter()
    if config.hooks.pre_tab_enter ~= nil then
        config.hooks.pre_tab_enter()
    end
    local tab = vim.api.nvim_get_current_tabpage()
    local buf_nums = M.cache[tab]
    if buf_nums then
        for _, k in pairs(buf_nums) do
            vim.api.nvim_buf_set_option(k, "buflisted", true)
        end
    end
    if config.hooks.post_tab_enter ~= nil then
        config.hooks.post_tab_enter()
    end
end

function M.on_tab_leave()
    if config.hooks.pre_tab_leave ~= nil then
        config.hooks.pre_tab_leave()
    end
    local tab = vim.api.nvim_get_current_tabpage()
    local buf_nums = utils.get_valid_buffers()
    M.cache[tab] = buf_nums
    for _, k in pairs(buf_nums) do
        vim.api.nvim_buf_set_option(k, "buflisted", false)
    end
    M.last_tab = tab
    if config.hooks.post_tab_leave ~= nil then
        config.hooks.post_tab_leave()
    end
end

function M.on_tab_closed()
    if config.hooks.pre_tab_close ~= nil then
        config.hooks.pre_tab_close()
    end
    M.cache[M.last_tab] = nil
    if config.hooks.post_tab_close ~= nil then
        config.hooks.post_tab_close()
    end
end

function M.revalidate()
    local tab = vim.api.nvim_get_current_tabpage()
    local buf_nums = utils.get_valid_buffers()
    M.cache[tab] = buf_nums
end

function M.print_summary()
    print("tab" .. " " .. "buf" .. " " .. "name")
    for tab, buf_item in pairs(M.cache) do
        for _, buf in pairs(buf_item) do
            local name = vim.api.nvim_buf_get_name(buf)
            print(tab .. " " .. buf .. " " .. name)
        end
    end
end

-- Check if it exists in a tab other than the CURRENT one
M.exists_in_other_tabs = function(bufnr)
    M.revalidate()
    local current_tab = vim.api.nvim_get_current_tabpage()
    local buffer_exists_in_other_tabs = false
    for tab, buffers in pairs(M.cache) do
        if tab ~= current_tab then
            for _, buffer in ipairs(buffers) do
                if buffer == bufnr then
                    buffer_exists_in_other_tabs = true
                    break
                end
            end
        end
        if buffer_exists_in_other_tabs then
            break
        end
    end
    return buffer_exists_in_other_tabs
end

-- Smart closing of a scoped buffer, this makes sure you only delete a buffer if is not currently open in any other tab.
-- If it is, then we just unlist the buffer.
-- Also if it is the only buffer in the current tab, we close the tab
-- If is not only the only buffer but also the last tab, we ask for permision to close it all
---@param opts table, if buf is not passed we are considering the current buffer
---@param opts.buf integer, if buf is not passed we are considering the current buffer
---@param opts.force boolean, default to true to force close
---@param opts.ask boolean, default to true to ask before closing the last tab ---@diagnostic disable-line
---@return nil
M.close_buffer = function(opts)
    opts = vim.tbl_deep_extend("force", {
        buf = vim.api.nvim_get_current_buf(),
        force = true,
        ask = true,
    }, opts or {})

    local underlying_buffer_delete = function()
        if not vim.api.nvim_buf_is_valid(opts.buf) then
            return
        end
        local ok, _ = pcall(vim.api.nvim_buf_delete, opts.buf, { force = opts.force })
        if not ok then
            local path = vim.api.nvim_buf_get_name(opts.buf)
            local choice = vim.fn.confirm("Unsaved changed on " .. path .. "Do you want to force it?", "&Yes\n&No")
            if choice == 1 then
                vim.api.nvim_buf_delete(opts.buf, { force = true })
            end
        end
    end

    local underlying_buffer_unlist = function()
        if not vim.api.nvim_buf_is_valid(opts.buf) or not vim.api.nvim_buf_get_option(0, "buflisted") then
            return
        end

        local ok, _ = pcall(vim.api.nvim_buf_set_option, opts.buf, "buflisted", false)

        if not ok then
            error("Scope: couldn't unlist buffer " .. tostring(opts.buf))
            return
        end

        if #utils.get_valid_buffers() >= 1 then
            vim.cmd("bprev")
        end
    end

    -- Ensure the cache is up-to-date
    M.revalidate()

    -- Why which version is correct to get the buffers in current tab
    -- local buf_nums = M.cache[current_tab]

    -- If the buffer exists in other tabs, hide it in the current tab

    local buffer_exist_in_other_tab = M.exists_in_other_tabs(opts.buf)
    local buffers = utils.get_valid_buffers()
    if buffer_exist_in_other_tab then
        underlying_buffer_unlist()
        if #buffers <= 1 then -- implicit that other tabs exist
            print("last buffer on tab, closing tab")
            vim.cmd("tabclose")
        end
    else
        -- Can be one both before and after deleting because we might have tried to close the last buffer and
        -- silently couldn't as a result we might be on the [No Name] buffer
        local tabs = vim.api.nvim_list_tabpages()
        if #buffers == 1 then
            if #tabs == 1 then
                local just_quit = true
                if opts.ask then
                    -- Ask for confirmation before quitting if it's the ONLY tab
                    local choice =
                        vim.fn.confirm("You're about to close the last tab. Do you want to quit?", "&Yes\n&No")
                    just_quit = just_quit and (choice == 1)
                end

                if just_quit then
                    vim.cmd("qa!")
                    return
                end
            else
                -- NOTE: We need to check this the case where we haver 1 buffer and more than 1 (>1) tab
                -- because the underlying_buffer_delete will not automatically change tabs upon deletion
                vim.cmd("tabclose") -- more than 1 tab so it's safe to close
            end
        else
            -- NOTE: Don't need to check anything else on the more than one buffer case,
            -- because nvim buffer delete will change focus to previous buffer regardless of number of tabs.
            -- So nothing needs to be done or checked.
            underlying_buffer_delete()
        end
    end

    -- If we got here, this buffer is unique to the current tab
    M.revalidate()
end

function M.move_current_buf(opts)
    -- ensure current buflisted
    local buflisted = vim.api.nvim_buf_get_option(0, "buflisted")
    if not buflisted then
        return
    end

    local target = tonumber(opts.args)
    if target == nil then
        -- invalid target tab, get input from user
        local input = vim.fn.input("Move buf to: ")
        if input == "" then -- user cancel
            return
        end

        target = tonumber(input)
    end

    -- bufferline always display  tab number, not the handle. When scope use tab handle to store buffer info. So need to convert
    local target_handle = vim.api.nvim_list_tabpages()[target]

    if target_handle == nil then
        vim.api.nvim_err_writeln("Invalid target tab")
        return
    end

    M.move_buf(vim.api.nvim_get_current_buf(), target_handle)
end

function M.move_buf(bufnr, target)
    -- copy current buf to target tab
    local target_bufs = M.cache[target] or {}
    target_bufs[#target_bufs + 1] = bufnr

    -- remove current buf from current tab if it is not the last one in the tab
    local buf_nums = utils.get_valid_buffers()
    if #buf_nums > 1 then
        vim.api.nvim_buf_set_option(bufnr, "buflisted", false)

        -- current buf are not in the current tab anymore, so we switch to the previous tab
        if bufnr == vim.api.nvim_get_current_buf() then
            vim.cmd("bprevious")
        end
    end
end
return M
