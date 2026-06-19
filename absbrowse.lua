--[[--
Audiobookshelf Library Browser UI
KOReader menu widgets for browsing ABS libraries and items.
Follows the menu patterns from menubuilder.lua and mediasync.lua.

@module absbrowse
--]]

local _ = require("gettext")
local T = require("ffi/util").template
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local logger = require("logger")
local Screen = require("device").screen
local Menu = require("ui/widget/menu")
local CenterContainer = require("ui/widget/container/centercontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local Geom = require("ui/geometry")

local ABSBrowse = {}

-- ---------------------------------------------------------------------------
-- Main menu builder
-- ---------------------------------------------------------------------------

--[[--
Build the Audiobookshelf submenu for addToMainMenu().
This is a factory function called each time the menu opens (sub_item_table_func).
@param plugin Audiobook instance
@return table  Menu item array
--]]
function ABSBrowse.buildMainMenu(plugin)
    local menu = {}

    -- Load modules dynamically (same pattern as main.lua Phase 1)
    local pp = plugin.path and (plugin.path .. "/") or "./"
    local ABSClient, ABSCache, ABSSync
    pcall(function()
        ABSClient = dofile(pp .. "absclient.lua")
        ABSCache = dofile(pp .. "abscache.lua")
        ABSSync = dofile(pp .. "abssync.lua")
    end)

    local is_logged_in = plugin:getSetting("abs_api_token", "") ~= ""
    local server_url = plugin:getSetting("abs_server_url", "")

    local cache = nil
    if ABSCache then
        cache = ABSCache:new{ plugin_dir = pp:sub(1, -2) }
    end

    -- ── Server status / settings ──
    table.insert(menu, {
        text_func = function()
            if not server_url or server_url == "" then
                return _("Server: not configured")
            end
            if is_logged_in then
                return T(_("Server: %1 (connected)"), server_url)
            else
                return T(_("Server: %1 (not logged in)"), server_url)
            end
        end,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            ABSBrowse._showServerSettings(plugin, touchmenu_instance)
        end,
    })

    -- ── Sync now ──
    if is_logged_in and cache and cache:count() > 0 then
        table.insert(menu, {
            text = _("Sync progress now"),
            keep_menu_open = true,
            callback = function()
                ABSBrowse._manualSync(plugin)
            end,
        })
    end

    -- ── Log in ──
    if not is_logged_in then
        table.insert(menu, {
            text = _("Log in…"),
            enabled_func = function()
                return server_url ~= ""
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                ABSBrowse._showLoginDialog(plugin, touchmenu_instance)
            end,
        })
    end

    -- ── Browse libraries ──
    if is_logged_in then
        table.insert(menu, {
            text = _("Browse libraries…"),
            keep_menu_open = true,
            callback = function()
                ABSBrowse._browseLibraries(plugin)
            end,
        })
    end

    -- ── Downloaded items ──
    table.insert(menu, {
        text_func = function()
            local n = cache and cache:count() or 0
            if n == 0 then
                return _("Downloaded items (none)")
            end
            return T(_("Downloaded items (%1)"), n)
        end,
        enabled_func = function()
            return cache and cache:count() > 0
        end,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            ABSBrowse._showDownloadedItems(plugin, cache, touchmenu_instance)
        end,
    })

    -- ── Continue listening ──
    table.insert(menu, {
        text = _("Continue listening"),
        enabled_func = function()
            local lid = plugin:getSetting("abs_last_item_id", "")
            return lid ~= "" and cache and cache:isDownloaded(lid)
        end,
        keep_menu_open = true,
        callback = function()
            local lid = plugin:getSetting("abs_last_item_id", "")
            if lid ~= "" then
                ABSBrowse._playCachedItem(plugin, cache, lid)
            end
        end,
    })

    -- ── Log out ──
    if is_logged_in then
        table.insert(menu, {
            text = _("Log out"),
            keep_menu_open = true,
            callback = function()
                plugin:setSetting("abs_api_token", "")
                plugin:setSetting("abs_user_id", "")
                UIManager:show(InfoMessage:new{
                    text = _("Logged out from Audiobookshelf."),
                    timeout = 2,
                })
            end,
        })
    end

    -- ── Cache info ──
    if cache then
        table.insert(menu, {
            text_func = function()
                local size = cache:getTotalSize()
                return T(_("Cache size: %1"), cache:formatSize(size))
            end,
            enabled = false,
        })
    end

    return menu
end

-- ---------------------------------------------------------------------------
-- Server settings dialog
-- ---------------------------------------------------------------------------

function ABSBrowse._showServerSettings(plugin, touchmenu_instance)
    local InputDialog = require("ui/widget/inputdialog")
    local current_url = plugin:getSetting("abs_server_url", "")

    local dialog
    dialog = InputDialog:new{
        title = _("Audiobookshelf Server URL"),
        input = current_url,
        input_hint = _("http://192.168.1.100:13378"),
        description = _("Enter the URL of your Audiobookshelf server."),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local url = dialog:getInputText()
                        -- Strip trailing slash
                        url = url:gsub("/+$", "")
                        plugin:setSetting("abs_server_url", url)
                        UIManager:close(dialog)
                        -- Refresh the parent menu so the new URL appears immediately
                        if touchmenu_instance then
                            touchmenu_instance:updateItems()
                        end
                        UIManager:show(InfoMessage:new{
                            text = _("Server URL saved."),
                            timeout = 2,
                        })
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

-- ---------------------------------------------------------------------------
-- Login dialog
-- ---------------------------------------------------------------------------

function ABSBrowse._showLoginDialog(plugin, touchmenu_instance)
    local server_url = plugin:getSetting("abs_server_url", "")
    if not server_url or server_url == "" then
        UIManager:show(InfoMessage:new{
            text = _("Please configure the server URL first."),
            timeout = 3,
        })
        return
    end

    local ABSClient
    local pp = plugin.path and (plugin.path .. "/") or "./"
    pcall(function()
        ABSClient = dofile(pp .. "absclient.lua")
    end)
    if not ABSClient then
        UIManager:show(InfoMessage:new{
            text = _("Could not load ABS client module."),
            timeout = 3,
        })
        return
    end

    local InputDialog = require("ui/widget/inputdialog")
    local MultiInputDialog = require("ui/widget/multiinputdialog")

    -- Use MultiInputDialog for username + password
    local dialog
    dialog = MultiInputDialog:new{
        title = T(_("Log in to %1"), server_url),
        fields = {
            {
                text = "",
                hint = _("Username"),
            },
            {
                text = "",
                hint = _("Password"),
                text_type = "password",
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Log in"),
                    is_enter_default = true,
                    callback = function()
                        local fields = dialog:getFields()
                        local username = fields[1] or ""
                        local password = fields[2] or ""
                        UIManager:close(dialog)

                        local busy = InfoMessage:new{
                            text = _("Logging in…"),
                            timeout = 0,
                        }
                        UIManager:show(busy)

                        -- Defer login to let the busy dialog render
                        UIManager:scheduleIn(0.1, function()
                            local client = ABSClient:new{ server_url = server_url }
                            local token, user, err = client:login(username, password)

                            UIManager:close(busy)

                            if token then
                                plugin:setSetting("abs_api_token", token)
                                if user and user.id then
                                    plugin:setSetting("abs_user_id", user.id)
                                end
                                -- Refresh the parent menu so "Log in" becomes "Log out"
                                -- and new options (Browse libraries, etc.) appear
                                if touchmenu_instance then
                                    touchmenu_instance:updateItems()
                                end
                                UIManager:show(InfoMessage:new{
                                    text = _("Logged in successfully."),
                                    timeout = 2,
                                })
                            else
                                UIManager:show(InfoMessage:new{
                                    text = _("Login failed: ") .. (err or _("unknown error")),
                                    timeout = 5,
                                })
                            end
                        end)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

-- ---------------------------------------------------------------------------
-- Library browser
-- ---------------------------------------------------------------------------

function ABSBrowse._browseLibraries(plugin)
    local server_url = plugin:getSetting("abs_server_url", "")
    local token = plugin:getSetting("abs_api_token", "")

    if not server_url or server_url == "" or not token or token == "" then
        UIManager:show(InfoMessage:new{
            text = _("Not connected to an Audiobookshelf server."),
            timeout = 3,
        })
        return
    end

    local ABSClient
    local pp = plugin.path and (plugin.path .. "/") or "./"
    pcall(function()
        ABSClient = dofile(pp .. "absclient.lua")
    end)
    if not ABSClient then
        UIManager:show(InfoMessage:new{
            text = _("Could not load ABS client module."),
            timeout = 3,
        })
        return
    end

    local busy = InfoMessage:new{
        text = _("Loading libraries…"),
        timeout = 0,
    }
    UIManager:show(busy)

    UIManager:scheduleIn(0.1, function()
        local client = ABSClient:new{ server_url = server_url, token = token }
        local libraries, err = client:getLibraries()

        UIManager:close(busy)

        if not libraries then
            UIManager:show(InfoMessage:new{
                text = _("Failed to load libraries: ") .. (err or _("unknown error")),
                timeout = 5,
            })
            return
        end

        if #libraries == 0 then
            UIManager:show(InfoMessage:new{
                text = _("No libraries found on this server."),
                timeout = 3,
            })
            return
        end

        -- Build menu items
        local menu_items = {}
        for idx, lib in ipairs(libraries) do
            table.insert(menu_items, {
                text = lib.name or _("Unnamed Library"),
                callback = function()
                    ABSBrowse._showLibraryItems(plugin, client, lib.id, lib.name)
                end,
            })
        end

        local menu = Menu:new{
            title = _("Libraries"),
            item_table = menu_items,
            width = Screen:getWidth() * 0.8,
            height = Screen:getHeight() * 0.7,
        }

        local centered = CenterContainer:new{
            dimen = Screen:getSize(),
            menu,
        }

        local window = InputContainer:new{
            dimen = Screen:getSize(),
            centered,
        }

        local menu_w = Screen:getWidth() * 0.8
        local menu_h = Screen:getHeight() * 0.7
        local menu_rect = Geom:new{
            x = math.floor((Screen:getWidth() - menu_w) / 2),
            y = math.floor((Screen:getHeight() - menu_h) / 2),
            w = menu_w,
            h = menu_h,
        }

        function window:onTap(arg, ges_ev)
            if ges_ev.pos:notIntersectWith(menu_rect) then
                UIManager:close(self)
                return true
            end
            return false
        end

        function window:onSwipe(arg, ges_ev)
            if ges_ev.pos:notIntersectWith(menu_rect) then
                UIManager:close(self)
                return true
            end
            -- Drive Menu pagination explicitly and force a full-screen refresh.
            -- Letting the event propagate sometimes leaves the new page invisible
            -- on e-ink until the next suspend/resume cycle.
            local direction = ges_ev.direction
            if direction == "west" then
                menu:onNextPage()
            elseif direction == "east" then
                menu:onPrevPage()
            else
                return false
            end
            UIManager:setDirty(nil, "ui")
            return true
        end

        menu.close_callback = function()
            UIManager:close(window)
        end

        UIManager:show(window)
    end)
end

-- ---------------------------------------------------------------------------
-- Library items list
-- ---------------------------------------------------------------------------

function ABSBrowse._showLibraryItems(plugin, client, library_id, library_name, page)
    page = page or 0
    local page_size = 50
    local busy = InfoMessage:new{
        text = _("Loading items…"),
        timeout = 0,
    }
    UIManager:show(busy)

    UIManager:scheduleIn(0.1, function()
        local data, err = client:getLibraryItems(library_id, page_size, page)
        UIManager:close(busy)

        if not data then
            UIManager:show(InfoMessage:new{
                text = _("Failed to load items: ") .. (err or _("unknown error")),
                timeout = 5,
            })
            return
        end

        local items = data.results or {}
        if #items == 0 then
            UIManager:show(InfoMessage:new{
                text = _("No items in this library."),
                timeout = 3,
            })
            return
        end

        -- Load cache to check download status
        local ABSCache
        local pp = plugin.path and (plugin.path .. "/") or "./"
        pcall(function()
            ABSCache = dofile(pp .. "abscache.lua")
        end)
        local cache = ABSCache and ABSCache:new{ plugin_dir = pp:sub(1, -2) }

        -- Forward declaration so page-turn closures can close over the window.
        local window
        local menu_items = {}

        -- Previous page entry
        if page > 0 then
            table.insert(menu_items, {
                text = _("← Previous page"),
                callback = function()
                    UIManager:close(window)
                    ABSBrowse._showLibraryItems(plugin, client, library_id, library_name, page - 1)
                end,
            })
        end

        for idx, item in ipairs(items) do
            local meta = item.media and item.media.metadata or {}
            local title = meta.title or _("Untitled")
            local author = meta.authorName or ""
            local duration = item.media and item.media.duration or 0
            local dur_str = ABSBrowse._formatDuration(duration)

            local is_downloaded = cache and cache:isDownloaded(item.id)
            local status_str = is_downloaded and _(" ✓") or ""

            -- Capture item in a factory to avoid Lua 5.1 closure reuse bug
            local function make_callback(it, downloaded)
                return function()
                    ABSBrowse._showItemDetail(plugin, client, it, cache, downloaded)
                end
            end

            table.insert(menu_items, {
                text = title .. (author ~= "" and "  — " .. author or "") .. "  (" .. dur_str .. ")" .. status_str,
                callback = make_callback(item, is_downloaded),
            })
        end

        -- Next page entry
        local total = tonumber(data.total) or #items
        if (page + 1) * page_size < total then
            table.insert(menu_items, {
                text = _("Next page →"),
                callback = function()
                    UIManager:close(window)
                    ABSBrowse._showLibraryItems(plugin, client, library_id, library_name, page + 1)
                end,
            })
        end

        local menu = Menu:new{
            title = library_name or _("Library Items"),
            item_table = menu_items,
            width = Screen:getWidth() * 0.85,
            height = Screen:getHeight() * 0.75,
        }

        local centered = CenterContainer:new{
            dimen = Screen:getSize(),
            menu,
        }

        window = InputContainer:new{
            dimen = Screen:getSize(),
            centered,
        }

        local menu_w = Screen:getWidth() * 0.85
        local menu_h = Screen:getHeight() * 0.75
        local menu_rect = Geom:new{
            x = math.floor((Screen:getWidth() - menu_w) / 2),
            y = math.floor((Screen:getHeight() - menu_h) / 2),
            w = menu_w,
            h = menu_h,
        }

        function window:onTap(arg, ges_ev)
            if ges_ev.pos:notIntersectWith(menu_rect) then
                UIManager:close(self)
                return true
            end
            return false
        end

        function window:onSwipe(arg, ges_ev)
            if ges_ev.pos:notIntersectWith(menu_rect) then
                UIManager:close(self)
                return true
            end
            -- Drive Menu pagination explicitly and force a full-screen refresh.
            -- Letting the event propagate sometimes leaves the new page invisible
            -- on e-ink until the next suspend/resume cycle.
            local direction = ges_ev.direction
            if direction == "west" then
                menu:onNextPage()
            elseif direction == "east" then
                menu:onPrevPage()
            else
                return false
            end
            UIManager:setDirty(nil, "ui")
            return true
        end

        menu.close_callback = function()
            UIManager:close(window)
        end

        UIManager:show(window)
    end)
end

-- ---------------------------------------------------------------------------
-- Item detail view
-- ---------------------------------------------------------------------------

function ABSBrowse._showItemDetail(plugin, client, item, cache, is_downloaded)
    local meta = item.media and item.media.metadata or {}
    local title = meta.title or _("Untitled")
    local author = meta.authorName or ""
    local duration = item.media and item.media.duration or 0
    local chapters = item.media and item.media.chapters or {}
    local audio_files = item.media and item.media.audioFiles or {}

    -- The /api/libraries/{id}/items endpoint returns lightweight items that
    -- often omit audioFiles.  Fetch full details if needed.
    local has_audio_files = audio_files and #audio_files > 0

    -- Build a compact title with metadata
    local menu_title = title
    if author ~= "" then
        menu_title = menu_title .. "  — " .. author
    end

    local menu_items = {}

    -- Action buttons ONLY — no metadata lines that push them off-screen.
    -- Emoji are avoided; some e-ink fonts do not render them.
    if is_downloaded then
        table.insert(menu_items, {
            text = _("Play"),
            callback = function()
                ABSBrowse._playCachedItem(plugin, cache, item.id)
            end,
        })
        table.insert(menu_items, {
            text = _("Delete from device"),
            callback = function()
                ABSBrowse._deleteCachedItem(plugin, cache, item.id)
            end,
        })
    else
        local btn_text
        if has_audio_files then
            btn_text = T(_("Download (%1 files, %2)"), #audio_files, ABSBrowse._formatDuration(duration))
        else
            btn_text = _("Download")
        end
        table.insert(menu_items, {
            text = btn_text,
            enabled = has_audio_files,
            callback = function()
                if has_audio_files then
                    ABSBrowse._downloadItem(plugin, client, item, cache)
                else
                    -- Fetch full details then try download
                    ABSBrowse._fetchAndDownload(plugin, client, item, cache)
                end
            end,
        })
    end

    -- Show a short info toast with metadata so the user still sees details,
    -- but keep the menu itself minimal so buttons are always visible.
    UIManager:show(InfoMessage:new{
        text = menu_title .. "\n" .. T(_("Chapters: %1  •  Duration: %2"), #chapters, ABSBrowse._formatDuration(duration)),
        timeout = 3,
    })

    local menu = Menu:new{
        title = menu_title,
        item_table = menu_items,
        width = Screen:getWidth() * 0.85,
        height = Screen:getHeight() * 0.5,
    }

    local centered = CenterContainer:new{
        dimen = Screen:getSize(),
        menu,
    }

    local window = InputContainer:new{
        dimen = Screen:getSize(),
        centered,
    }

    local menu_w = Screen:getWidth() * 0.85
    local menu_h = Screen:getHeight() * 0.75
    local menu_rect = Geom:new{
        x = math.floor((Screen:getWidth() - menu_w) / 2),
        y = math.floor((Screen:getHeight() - menu_h) / 2),
        w = menu_w,
        h = menu_h,
    }

    function window:onTap(arg, ges_ev)
        if ges_ev.pos:notIntersectWith(menu_rect) then
            UIManager:close(self)
            return true
        end
        return false
    end

    function window:onSwipe(arg, ges_ev)
        if ges_ev.pos:notIntersectWith(menu_rect) then
            UIManager:close(self)
            return true
        end
        -- Drive Menu pagination explicitly and force a full-screen refresh.
        -- Letting the event propagate sometimes leaves the new page invisible
        -- on e-ink until the next suspend/resume cycle.
        local direction = ges_ev.direction
        if direction == "west" then
            menu:onNextPage()
        elseif direction == "east" then
            menu:onPrevPage()
        else
            return false
        end
        UIManager:setDirty(nil, "ui")
        return true
    end

    menu.close_callback = function()
        UIManager:close(window)
    end

    UIManager:show(window)
end

-- ---------------------------------------------------------------------------
-- Downloaded items list
-- ---------------------------------------------------------------------------

function ABSBrowse._showDownloadedItems(plugin, cache, touchmenu_instance)
    if not cache then
        return
    end

    local items = cache:listCachedItems()
    if #items == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No downloaded items."),
            timeout = 2,
        })
        return
    end

    local menu_items = {}
    for idx, item in ipairs(items) do
        local dur_str = ABSBrowse._formatDuration(item.duration or 0)

        -- Capture item_id in a factory to avoid Lua 5.1 closure reuse bug
        local function make_play_callback(item_id)
            return function()
                ABSBrowse._playCachedItem(plugin, cache, item_id)
            end
        end

        local function make_delete_callback(it)
            return function()
                local ConfirmBox = require("ui/widget/confirmbox")
                UIManager:show(ConfirmBox:new{
                    text = T(_("Delete %1 from device?\nThis will remove the downloaded audio files."), it.title),
                    ok_text = _("Delete"),
                    ok_callback = function()
                        cache:deleteItem(it.id)
                        UIManager:show(InfoMessage:new{
                            text = _("Item deleted."),
                            timeout = 2,
                        })
                        -- Refresh the menu by closing and reopening
                        UIManager:close(window)
                        ABSBrowse._showDownloadedItems(plugin, cache)
                    end,
                })
            end
        end

        table.insert(menu_items, {
            text = item.title .. (item.author ~= "" and "  — " .. item.author or "") .. "  (" .. dur_str .. ")",
            callback = make_play_callback(item.id),
            _abs_item_id = item.id,
            _abs_item_title = item.title,
        })
    end

    local menu = Menu:new{
        title = _("Downloaded Items"),
        item_table = menu_items,
        width = Screen:getWidth() * 0.85,
        height = Screen:getHeight() * 0.75,
    }

    function menu:onMenuHold(item)
        if item and item._abs_item_id then
            local ConfirmBox = require("ui/widget/confirmbox")
            UIManager:show(ConfirmBox:new{
                text = T(_("Delete %1 from device?\nThis will remove the downloaded audio files."), item._abs_item_title or _("this item")),
                ok_text = _("Delete"),
                ok_callback = function()
                    cache:deleteItem(item._abs_item_id)
                    -- Clear "last played" if it was this item
                    local last_id = plugin:getSetting("abs_last_item_id", "")
                    if last_id == item._abs_item_id then
                        plugin:setSetting("abs_last_item_id", "")
                    end
                    UIManager:show(InfoMessage:new{
                        text = _("Item deleted."),
                        timeout = 2,
                    })
                    -- Refresh the downloaded-items menu
                    UIManager:close(window)
                    ABSBrowse._showDownloadedItems(plugin, cache, touchmenu_instance)
                    -- Refresh the parent menu so counts and "Continue listening" update
                    if touchmenu_instance and touchmenu_instance.updateItems then
                        touchmenu_instance:updateItems()
                    end
                end,
            })
        end
        return true
    end

    local centered = CenterContainer:new{
        dimen = Screen:getSize(),
        menu,
    }

    local window = InputContainer:new{
        dimen = Screen:getSize(),
        centered,
    }

    local menu_w = Screen:getWidth() * 0.85
    local menu_h = Screen:getHeight() * 0.75
    local menu_rect = Geom:new{
        x = math.floor((Screen:getWidth() - menu_w) / 2),
        y = math.floor((Screen:getHeight() - menu_h) / 2),
        w = menu_w,
        h = menu_h,
    }

    function window:onTap(arg, ges_ev)
        if ges_ev.pos:notIntersectWith(menu_rect) then
            UIManager:close(self)
            return true
        end
        return false
    end

    function window:onSwipe(arg, ges_ev)
        if ges_ev.pos:notIntersectWith(menu_rect) then
            UIManager:close(self)
            return true
        end
        -- Drive Menu pagination explicitly and force a full-screen refresh.
        -- Letting the event propagate sometimes leaves the new page invisible
        -- on e-ink until the next suspend/resume cycle.
        local direction = ges_ev.direction
        if direction == "west" then
            menu:onNextPage()
        elseif direction == "east" then
            menu:onPrevPage()
        else
            return false
        end
        UIManager:setDirty(nil, "ui")
        return true
    end

    menu.close_callback = function()
        UIManager:close(window)
    end

    UIManager:show(window)
end

-- ---------------------------------------------------------------------------
-- Download logic
-- ---------------------------------------------------------------------------

--[[--
Fetch full item details from ABS then start download.
Used when the lightweight list view does not include audioFiles.
--]]
function ABSBrowse._fetchAndDownload(plugin, client, item, cache)
    local busy = InfoMessage:new{
        text = T(_("Fetching details for %1…"), item.media and item.media.metadata and item.media.metadata.title or _("item")),
        timeout = 0,
    }
    UIManager:show(busy)

    UIManager:scheduleIn(0.1, function()
        local full_item, err = client:getItemDetails(item.id)
        UIManager:close(busy)

        if not full_item then
            UIManager:show(InfoMessage:new{
                text = _("Could not fetch item details: ") .. (err or _("unknown error")),
                timeout = 5,
            })
            return
        end

        -- Merge full details into the lightweight item
        item.media = full_item.media or item.media
        ABSBrowse._downloadItem(plugin, client, item, cache)
    end)
end

function ABSBrowse._downloadItem(plugin, client, item, cache)
    if not cache then
        UIManager:show(InfoMessage:new{
            text = _("Cache manager not available."),
            timeout = 3,
        })
        return
    end

    -- Audio files may live in different fields depending on ABS version/item type.
    local audio_files = {}
    local media = item.media or {}
    if media.audioFiles and #media.audioFiles > 0 then
        audio_files = media.audioFiles
    elseif media.tracks and #media.tracks > 0 then
        audio_files = media.tracks
    elseif media.parts then
        for pidx, part in ipairs(media.parts) do
            if part.audioFiles then
                for aidx, af in ipairs(part.audioFiles) do
                    table.insert(audio_files, af)
                end
            end
        end
    end

    if #audio_files == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No audio files available for this item.\n\nThe server may not have scanned this book yet, or the files may be missing."),
            timeout = 5,
        })
        return
    end

    -- Update the item's audioFiles so the rest of the flow uses the resolved list
    item.media = item.media or {}
    item.media.audioFiles = audio_files

    -- Show busy dialog
    local busy = InfoMessage:new{
        text = T(_("Downloading %1…\nPreparing…"), item.media.metadata and item.media.metadata.title or _("item")),
        timeout = 0,
    }
    UIManager:show(busy)
    UIManager:forceRePaint()

    local item_dir = cache:getItemCacheDir(item.id)
    local audio_dir = cache:getItemAudioDir(item.id)
    local downloaded_paths = {}
    local failed = false

    -- Download audio files one by one
    local function downloadNext(idx)
        if failed then
            UIManager:close(busy)
            return
        end

        if idx > #audio_files then
            -- All audio files done; download cover
            ABSBrowse._downloadCover(client, item.id, item_dir .. "/cover.jpg", function(cover_ok, cover_path)
                -- Extract chapters via m4bparser if possible
                local chapters = item.media and item.media.chapters or {}
                if #downloaded_paths > 0 and #chapters == 0 then
                    local ok, MetadataParser = pcall(dofile, plugin.path .. "/m4bparser.lua")
                    if ok and MetadataParser then
                        local parser = MetadataParser:new{ plugin_dir = plugin.path }
                        chapters = parser:parse(downloaded_paths[1]) or {}
                    end
                end

                -- Add to cache index
                cache:addItem(item, downloaded_paths, cover_ok and cover_path or nil)

                -- Keep the busy banner visible briefly so the user sees the
                -- download is complete before the UI unfreezes.
                UIManager:scheduleIn(1.5, function()
                    UIManager:close(busy)
                    UIManager:show(InfoMessage:new{
                        text = T(_("Downloaded: %1"), item.media.metadata.title or _("item")),
                        timeout = 3,
                    })
                end)
            end)
            return
        end

        local af = audio_files[idx]

        -- Build the download URL. The authenticated ABS API endpoint
        -- /api/items/{id}/file/{ino}/download requires a Bearer token.
        -- Fall back to contentUrl or other patterns if ino is unavailable.
        local file_url = nil
        if af.ino then
            file_url = client.server_url .. "/api/items/" .. item.id .. "/file/" .. af.ino .. "/download"
        elseif af.contentUrl then
            file_url = client.server_url .. af.contentUrl
        elseif af.url then
            file_url = client.server_url .. af.url
        elseif af.path then
            file_url = client.server_url .. "/s/item/" .. item.id .. "/" .. af.path:gsub(".*/", "")
        elseif af.metadata and af.metadata.path then
            file_url = client.server_url .. "/s/item/" .. item.id .. "/" .. af.metadata.path:gsub(".*/", "")
        end

        if not file_url then
            logger.err("ABSBrowse: cannot determine URL for audio file", idx, "fields:", table.concat({"ino=" .. tostring(af.ino), "contentUrl=" .. tostring(af.contentUrl), "url=" .. tostring(af.url), "path=" .. tostring(af.path)}, " "))
            failed = true
            UIManager:close(busy)
            UIManager:show(InfoMessage:new{
                text = T(_("Cannot download file %1: missing URL."), idx),
                timeout = 5,
            })
            return
        end

        local dest_name = (af.metadata and af.metadata.filename) or (af.path and af.path:gsub(".*/", "")) or ("track_" .. idx .. ".mp3")
        local dest_path = audio_dir .. "/" .. dest_name

        -- Update busy dialog and force an immediate e-ink refresh so the user
        -- sees the progress text before the blocking download freezes the UI.
        busy.text = T(_("Downloading %1…\nFile %2 / %3"),
            item.media.metadata.title or _("item"),
            idx,
            #audio_files)
        UIManager:setDirty(busy, function()
            return "ui", busy.dimen
        end)
        UIManager:forceRePaint()

        -- Download via ABSClient so the Bearer token is sent automatically.
        -- This avoids needing curl/wget on the device.
        -- NOTE: socket.http blocks the UI thread; the screen is frozen until
        -- the file finishes downloading.  The dialog above tells the user why.
        local ok, err = client:downloadFile(file_url, dest_path)
        if ok then
            table.insert(downloaded_paths, dest_path)
            logger.warn("ABSBrowse: downloaded", dest_path)
            UIManager:scheduleIn(0.1, function()
                downloadNext(idx + 1)
            end)
        else
            failed = true
            logger.err("ABSBrowse: download failed:", err)
            UIManager:close(busy)
            UIManager:show(InfoMessage:new{
                text = T(_("Download failed for file %1: %2"), idx, err or _("unknown error")),
                timeout = 5,
            })
        end
    end

    -- Start downloading
    UIManager:scheduleIn(0.1, function()
        downloadNext(1)
    end)
end

function ABSBrowse._downloadCover(client, item_id, dest_path, callback)
    local cover_url = client:getCoverUrl(item_id)

    -- Download via ABSClient so the Bearer token is sent automatically.
    local ok, err = client:downloadFile(cover_url, dest_path)
    if not ok then
        logger.err("ABSBrowse: cover download failed:", err)
    end
    if callback then
        callback(ok, ok and dest_path or nil)
    end
end

-- ---------------------------------------------------------------------------
-- Play cached item
-- ---------------------------------------------------------------------------

function ABSBrowse._playCachedItem(plugin, cache, item_id)
    if not cache or not plugin then
        return
    end

    -- The media player can fail to initialize on some firmware.  Surfacing
    -- the error here lets the user know why playback is unavailable instead
    -- of silently doing nothing.
    if not plugin._init_ok or not plugin.media_sync then
        UIManager:show(InfoMessage:new{
            text = _("Playback unavailable. The media player failed to initialize. Please restart KOReader and, if the problem persists, generate a bug report."),
            timeout = 5,
        })
        return
    end

    local item = cache:getItem(item_id)
    if not item then
        UIManager:show(InfoMessage:new{
            text = _("Item not found in cache."),
            timeout = 3,
        })
        return
    end

    local audio_path = cache:getFirstAudioPath(item_id)
    if not audio_path then
        UIManager:show(InfoMessage:new{
            text = _("No audio file available for this item."),
            timeout = 3,
        })
        return
    end

    -- Check if file exists
    local f = io.open(audio_path, "r")
    if not f then
        UIManager:show(InfoMessage:new{
            text = _("Audio file missing. Please re-download."),
            timeout = 3,
        })
        return
    end
    f:close()

    -- Update "last played" settings
    plugin:setSetting("abs_last_item_id", item_id)
    plugin:setSetting("abs_last_library_id", item.library_id or "")

    -- Normalize chapter format: cache stores start/end but MediaSync expects
    -- start_time/end_time.
    local normalized_chapters = {}
    if item.chapters then
        for cidx, ch in ipairs(item.chapters) do
            table.insert(normalized_chapters, {
                start_time = ch.start or ch.start_time or 0,
                end_time = ch["end"] or ch.end_time or 0,
                title = ch.title or (""),
            })
        end
    end

    -- Build metadata for playback
    local metadata = {
        title = item.title,
        author = item.author,
        narrator = item.narrator,
        duration = item.duration,
        chapters = normalized_chapters,
        cover_path = item.cover_path,
    }

    -- Use the plugin's playback method
    if plugin._playAbsItem then
        plugin:_playAbsItem(item_id, audio_path, metadata)
    else
        -- Fallback: play directly
        local cover = item.cover_path
        if cover then
            local cf = io.open(cover, "r")
            if not cf then
                cover = nil
            else
                cf:close()
            end
        end

        -- Reuse existing _doPlayAudioFile but with ABS metadata
        if plugin._doPlayAudioFile then
            plugin:_doPlayAudioFile(audio_path, nil, 0, item_id, metadata)
        else
            UIManager:show(InfoMessage:new{
                text = _("Playback not available."),
                timeout = 3,
            })
        end
    end
end

-- ---------------------------------------------------------------------------
-- Delete cached item
-- ---------------------------------------------------------------------------

function ABSBrowse._deleteCachedItem(plugin, cache, item_id)
    if not cache then
        return
    end

    local ConfirmBox = require("ui/widget/confirmbox")
    local item = cache:getItem(item_id)
    local title = item and item.title or _("this item")

    UIManager:show(ConfirmBox:new{
        text = T(_("Delete %1 from device?\nThis will remove the downloaded audio files."), title),
        ok_text = _("Delete"),
        ok_callback = function()
            cache:deleteItem(item_id)
            UIManager:show(InfoMessage:new{
                text = _("Item deleted."),
                timeout = 2,
            })
        end,
    })
end

-- ---------------------------------------------------------------------------
-- Manual sync
-- ---------------------------------------------------------------------------

function ABSBrowse._manualSync(plugin)
    local server_url = plugin:getSetting("abs_server_url", "")
    local token = plugin:getSetting("abs_api_token", "")

    if not server_url or server_url == "" or not token or token == "" then
        UIManager:show(InfoMessage:new{
            text = _("Not connected to an Audiobookshelf server."),
            timeout = 3,
        })
        return
    end

    local ABSClient, ABSCache, ABSSync
    local pp = plugin.path and (plugin.path .. "/") or "./"
    pcall(function()
        ABSClient = dofile(pp .. "absclient.lua")
        ABSCache = dofile(pp .. "abscache.lua")
        ABSSync = dofile(pp .. "abssync.lua")
    end)

    if not ABSClient or not ABSCache or not ABSSync then
        UIManager:show(InfoMessage:new{
            text = _("Could not load ABS modules."),
            timeout = 3,
        })
        return
    end

    local busy = InfoMessage:new{
        text = _("Syncing progress…"),
        timeout = 0,
    }
    UIManager:show(busy)

    UIManager:scheduleIn(0.1, function()
        local client = ABSClient:new{ server_url = server_url, token = token }
        local cache = ABSCache:new{ plugin_dir = pp:sub(1, -2) }
        local sync = ABSSync:new{ plugin = plugin, plugin_dir = pp:sub(1, -2) }

        local ok, err = sync:syncAllLocalItems(client, cache)

        UIManager:close(busy)

        if ok then
            UIManager:show(InfoMessage:new{
                text = _("Progress synced successfully."),
                timeout = 2,
            })
        else
            UIManager:show(InfoMessage:new{
                text = _("Sync failed: ") .. (err or _("unknown error")),
                timeout = 5,
            })
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Utilities
-- ---------------------------------------------------------------------------

function ABSBrowse._formatDuration(seconds)
    seconds = math.floor(seconds or 0)
    local hours = math.floor(seconds / 3600)
    local mins = math.floor((seconds % 3600) / 60)
    if hours > 0 then
        return string.format("%dh %02dm", hours, mins)
    end
    return string.format("%dm", mins)
end

return ABSBrowse
