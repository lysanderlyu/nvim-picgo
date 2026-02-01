-- Author：lysanderlyu
-- Updated: 2026-01-25

local nvim_picgo = {}

local default_config = {
    notice = "notify",
    image_name = true,
    debug = false,
    temporary_storage = vim.loop.os_uname().sysname == "Linux",
}

local sync_lock = false
local random_filename = ""

local stop_jobs_message = {
    "%[PicGo WARN%]: can't get",
    -- Well, I did forget the full command for these 2 strings, but this will also match
    -- just doesn't look pretty ..
    "%[PicGo ERROR%]",
    "does not exist",
}

local function generate_timestamped_random_name()
    local current_time = os.date("*t")
    local timestamp = string.format(
        "%04d%02d%02d%02d%02d%02d",
        current_time.year,
        current_time.month,
        current_time.day,
        current_time.hour,
        current_time.min,
        current_time.sec
    )

    math.randomseed(os.time())
    local random_number = math.random(0, 99999)
    return timestamp .. string.format("%05d", random_number)
end

local function generate_temporary_file(mime_type)
    local temp_dir = os.getenv("TMPDIR")
        or os.getenv("TEMP")
        or os.getenv("TMP")
        or "/tmp" 

    local path_separator = package.config:sub(1, 1) -- 获取路径分隔符
    random_filename = ("%s%simage-%s.%s"):format(
        temp_dir,
        path_separator,
        generate_timestamped_random_name(),
        mime_type
    )

    return random_filename
end

local function notice(state)
    if state then
        local msg = "Upload image success"
        if default_config.notice == "notify" then
            vim.notify(msg, "info", { title = "Nvim-picgo" })
        else
            vim.api.nvim_echo({ { msg, "MoreMsg" } }, true, {})
        end
    else
        local msg = "Upload image failed"
        if default_config.notice == "notify" then
            vim.notify(msg, "error", { title = "Nvim-picgo" })
        else
            vim.api.nvim_echo({ { msg, "ErrorMsg" } }, true, {})
        end
    end
end
-- 替换 raw.githubusercontent.com 为 jsDelivr CDN 链接
local function to_jsdelivr_url(url)
    return url:gsub(
        "^https://raw%.githubusercontent%.com/([^/]+)/([^/]+)/([^/]+)/(.*)",
        "https://cdn.jsdelivr.net/gh/%1/%2@%3/%4"
    )
end


local function stdout_callbackfn(job_id, data, _type)
    if default_config.debug then
        vim.print(data)
    end

    if default_config.need_jsdeliver then
      data[2] = to_jsdelivr_url(data[2])
    end

    for _, err in ipairs(stop_jobs_message) do
        if data[1]:match(err) then
            notice(false)
            vim.fn.jobstop(job_id)
            return
        end
    end

    if data[1]:match("%[PicGo SUCCESS%]:") then
        notice(true)
        local markdown_image_link
        if default_config.image_name then
            markdown_image_link = string.format(
                "![%s](%s)",
                vim.fn.fnamemodify(data[2], ":t:r"),
                data[2]
            )
        else
            markdown_image_link = string.format("![](%s)", data[2])
        end
        vim.fn.setreg(vim.v.register, markdown_image_link)
    end
end

local function onexit_callbackfn()
    if
        default_config.temporary_storage
        and vim.fn.filereadable(vim.fn.expand(random_filename))
    then
        local success = os.remove(random_filename)

        if success ~= true then
            local msg = "Error deleting temporary file: " .. random_filename

            if default_config.notice == "notify" then
                vim.notify(msg, "error", { title = "Nvim-picgo" })
            else
                vim.api.nvim_echo({ { msg, "ErrorMsg" } }, true, {})
            end
        end
    end

    sync_lock = false
end

local function sync_upload(callback)
    return function()
        if sync_lock then
            local msg = "Please wating upload done"

            if default_config.notice == "notify" then
                vim.notify(msg, "error", { title = "Nvim-picgo" })
            else
                vim.api.nvim_echo({ { msg, "ErrorMsg" } }, true, {})
            end
            return
        end
        sync_lock = true
        callback()
    end
end

local function is_macos()
    return vim.loop.os_uname().sysname == "Darwin"
end


function nvim_picgo.setup(conf)
    if vim.fn.executable("picgo") ~= 1 then
        vim.api.nvim_echo(
            { { "Missing picgo-core dependencies", "ErrorMsg" } },
            true,
            {}
        )
        return
    end

    if default_config.temporary_storage then
        if is_macos() then
            if vim.fn.executable("pngpaste") ~= 1 then
                vim.api.nvim_echo(
                    { { "Missing pngpaste dependency on macOS", "ErrorMsg" } },
                    true,
                    {}
                )
                return
            end
        else
            if vim.fn.executable("xclip") ~= 1 then
                vim.api.nvim_echo(
                    { { "Missing xclip dependencies", "ErrorMsg" } },
                    true,
                    {}
                )
                return
            end
        end
    end

    if vim.fn.executable("convert") ~= 1 then
        vim.api.nvim_echo(
            { { "Missing convert or (imagemagick) dependencies, the Nvim-picgo may not convert the bmp to png if the clipboard has bmp file (such as using WSL)", "WarnMsg" } },
            true,
            {}
        )
    end

    default_config = vim.tbl_extend("force", default_config, conf or {})

    -- Create autocommand
    vim.api.nvim_create_user_command(
        "UploadClipboard",
        sync_upload(nvim_picgo.upload_clipboard),
        { desc = "Upload image from clipboard to picgo" }
    )
    vim.api.nvim_create_user_command(
        "UploadImagefile",
        sync_upload(nvim_picgo.upload_imagefile),
        { desc = "Upload image from filepath to picgo" }
    )
end

local function is_wayland()
    local wayland = os.getenv("WAYLAND_DISPLAY")
    if wayland then
        return true
    end
    return false
end

function nvim_picgo.upload_clipboard()
    if default_config.temporary_storage then
        local allowed_types = { "png", "bmp", "jpg", "gif" }

        local command = { "xclip -selection clipboard -t image/%s -o 2>/dev/null; echo $?", 
                          "xclip -selection clipboard -t image/%s -o > %s" }

        if is_macos() then
            local command = {
              "pngpaste - | grep -qi %s; echo $?",   -- check clipboard
              "pngpaste - > %s"           -- save to temp file
            }
        elseif is_wayland() then
            command = { "wl-paste --list-types | grep -qi image/%s; echo $?", 
                        "wl-paste --no-newline --type image/%s > %s" }
        end

        for _, mime_type in ipairs(allowed_types) do
            local has_image = vim.fn.system((command[1]):format(mime_type))

            if vim.fn.trim(has_image) ~= "1" then
                -- Generate temporary file
                generate_temporary_file(mime_type) -- sets random_filename


                -- Save clipboard image to temp file
                os.execute((command[2]):format(mime_type, random_filename))

                -- Check the generated file size
                if vim.fn.getfsize(random_filename) <= 0 then
                    vim.notify("Generated temp image file is empty", "error", { title = "Nvim-picgo" })
                    -- Clear the lock sync flag
                    onexit_callbackfn()
                    return
                end

                -- If BMP, convert to PNG
                if mime_type == "bmp" then
                    local png_file = random_filename:gsub("%.bmp$", ".png")
                    local convert_cmd = string.format('convert "%s" "%s"', random_filename, png_file)
                    local ret = os.execute(convert_cmd)
                    -- Remove the bmp file
                    os.remove(random_filename)
                    if ret ~= 0 or vim.fn.filereadable(png_file) == 0 then
                        vim.notify("Failed to convert BMP to PNG", "error", { title = "Nvim-picgo" })
                        -- Clear the lock sync flag
                        onexit_callbackfn()
                        return
                    end
                    random_filename = png_file  -- use PNG file for upload
                end

                -- Upload via PicGo
                vim.fn.jobstart({ "picgo", "u", random_filename }, {
                    on_stdout = stdout_callbackfn,
                    on_exit = onexit_callbackfn,
                })

                return
            end
        end

        vim.notify(
            "Clipboard not found image or not in supported format: " .. table.concat(allowed_types, ", "),
            "error",
            { title = "Nvim-picgo" }
        )

        return
    end

    -- If temporary_storage is false, just upload from clipboard directly
    vim.fn.jobstart({ "picgo", "u" }, {
        on_stdout = stdout_callbackfn,
        on_exit = onexit_callbackfn,
    })
end

function nvim_picgo.upload_imagefile()
    local image_path = vim.fn.input("Image path: ")

    -- If the user logs out
    if string.len(image_path) == 0 then
        return
    end

    -- Well, picgo-core doesn't support ~ relative path commits
    -- So here replace ~ with $HOME
    if image_path:find("~") then
        local home_dir =
            vim.fn.trim(vim.fn.shellescape(vim.fn.fnamemodify("~", ":p")), "'")
        image_path = home_dir .. image_path:sub(3)
    end

    assert(vim.fn.filereadable(image_path) == 1, "The image path is not valid")

    vim.fn.jobstart({ "picgo", "u", image_path }, {
        on_stdout = stdout_callbackfn,
        on_exit = onexit_callbackfn,
    })
end


return nvim_picgo
