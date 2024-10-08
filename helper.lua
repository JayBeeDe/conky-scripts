#!/usr/bin/env lua

-- config management functions
local config
local cache = {
    query = {}
}
local run = {
    ttl = {}
}

function _load_config(path)
    local _env = {}
    setmetatable(_env, {
        __index = _G
    })
    local f = loadfile(path, "t", _env)
    if not f then
        return {}
    end
    assert(pcall(f))
    setmetatable(_env, nil)
    return _env
end

function conky_startup()
    local config_path = os.getenv("PWD") .. "/" .. conky_config
    print("conky: Loading config from " .. config_path .. "...")
    config = _load_config(config_path)
    print("conky: Script has started and is now runing!")
end

function conky_main()
    if not conky_window then
        return
    end
end

function _sec_to_human(time)
    local days = math.floor(time / 86400)
    local hours = math.floor(math.fmod(time, 86400) / 3600)
    local minutes = math.floor(math.fmod(time, 3600) / 60)
    local seconds = math.floor(math.fmod(time, 60))
    local str = ""
    if days > 0 then
        str = str .. days .. "d "
    end
    if hours > 0 then
        str = str .. hours .. "h "
    end
    if minutes > 0 and days == 0 then
        str = str .. minutes .. "m "
    end
    if seconds > 0 and hours == 0 and days == 0 then
        str = str .. seconds .. "s "
    end
    return string.gsub(str, " $", "")
end

-- utils functions

function _query(url, method)
    local mime = require("mime")
    local http = require("ssl.https")
    local json = require("json")

    local query_id = mime.b64(method .. "." .. url)
    if not run.ttl[query_id] or not cache.query[query_id] then
        run.ttl[query_id] = 0
    end

    if run.ttl[query_id] > 0 then
        run.ttl[query_id] = run.ttl[query_id] - conky.config.update_interval
        return cache.query[query_id]
    end

    local fnret = ""
    function collect(chunk)
        if chunk then
            fnret = fnret .. chunk
        end
        return true
    end

    local _, statusCode, headers, statusText = http.request {
        url = url,
        method = method,
        headers = {
            ["Accept"] = "application/json",
            ["Accept-Language"] = "sk;q=0.8,en-US,en;q=0.6,cs;q=0.4",
            ["Accept-Charset"] = "UTF-8;q=0.8,*;q=0.7"
        },
        sink = collect
    }

    if type(fnret) == "string" then
        fnret = json.decode(fnret)
    end
    if not fnret then
        return fnret
    end
    cache.query[query_id] = fnret
    print("_query: Loading " .. method .. " " .. url .. " result to cache...")
    run.ttl[query_id] = helper.config.queries_interval

    return fnret
end

function _query_get(url)
    return _query(url, "GET")
end

function _file(path, mode, lines)
    mode = (mode and mode or "r")
    if mode ~= "r" and mode ~= "a" and mode ~= "w" then
        return nil
    end
    local file = io.open(path, mode)
    if not file then
        return nil
    end
    if mode == "r" then
        if lines then
            return nil
        end
        lines = {}
        for line in file:lines() do
            lines[#lines + 1] = line
        end
    else
        if not lines then
            return nil
        end
        for _, line in ipairs(lines) do
            file:write(line, "\n")
        end
    end
    file:close()
    return lines
end

function _file_read(path, idx)
    local fnret = _file(path, "r")
    if idx and fnret then
        return fnret[idx + 1]
    end
    return fnret
end

function _command(cmd, idx)
    local handle = io.popen(cmd .. " 2>/dev/null")
    -- local fnret = handle:read("*all")
    local fnret = {}
    for line in handle:lines() do
        fnret[#fnret] = line
        if idx == #fnret then
            return line
        end
    end
    handle:close()
    if #fnret == 0 then
        return nil
    end
    return fnret
end

function _currency2smbol(currency)
    local currency2smbol = {
        EUR = "€", --
        DOL = "$"
    }
    if not currency2smbol[currency] then
        return ""
    end
    return currency2smbol[currency]
end

function _round(num, decimalPlaces)
    local mult = 10 ^ (decimalPlaces or 0)
    return math.floor(num * mult + 0.5) / mult
end

function _merge(...)
    local result = {}
    local k = 1
    for _, t in ipairs {...} do
        for _, v in ipairs(t) do
            result[k] = v
            k = k + 1
        end
    end
    return result
end

function _shall_display(item, blacklist)
    for blacklist_attribute, blacklist_value in pairs(blacklist) do
        if type(item[blacklist_attribute]) == "function" then
            item[blacklist_attribute] = nil
        end
        if blacklist_value == "" then
            if not item[blacklist_attribute] and blacklist_value == "" then
                return false
            end
        elseif item[blacklist_attribute] then

            if type(item[blacklist_attribute]) == "string" and type(blacklist_value) == "string" then
                if string.match(item[blacklist_attribute], blacklist_value) then
                    return false
                end
            elseif type(item[blacklist_attribute]) == "table" and type(blacklist_value) == "table" then
                for _, blacklist_value_item in pairs(blacklist_value) do -- browse each blacklist item
                    for _, item_blacklist_attribute_item in pairs(item[blacklist_attribute]) do -- browse each item attribute sub item
                        if string.match(item_blacklist_attribute_item, blacklist_value_item) then
                            return false
                        end
                    end
                end
            end
        end
    end
    return true
end

function _add_attribute_value(table, attribute, value)
    if not table then
        return {}
    end
    for _, item in ipairs(table) do
        item[attribute] = (item.attribute and item.attribute or value)
    end
    return table
end

function _split(s, delimiter)
    delimiter = delimiter or ","
    local t = {}
    local i = 1
    for str in string.gmatch(s, "([^" .. delimiter .. "]+)") do
        t[i] = str
        i = i + 1
    end
    return t
end

-- conky display functions

function _table_format(items)
    local max_chars = helper.config.maximum_chars
    local columns = (helper.config.columns and helper.config.columns or 2)
    local margin_horizontal = helper.config.margin_horizontal
    local margin_vertical = helper.config.margin_vertical
    local maximum_width = conky.config.maximum_width
    local tabulation_width = helper.config.tabulation_width

    local min_item_width = math.floor((maximum_width - (2 * margin_horizontal)) / columns)

    local str_output = conky_parse("${voffset -" .. margin_vertical .. "}")
    local cursor_position = maximum_width -- to ensure to initialize properly

    for _, item in ipairs(items) do
        local item_width = math.ceil((string.len(conky_parse(item.key)) + string.len(conky_parse(item.value))) / max_chars * maximum_width) + tabulation_width -- converts characters size to pixel size
        if cursor_position + item_width + margin_horizontal > maximum_width then -- new line
            cursor_position = margin_horizontal
            str_output = str_output .. conky_parse("${voffset " .. margin_vertical .. "}$font8")
        end
        str_output = str_output .. conky_parse("${goto " .. cursor_position .. "}") .. conky_parse("$color0") .. conky_parse(item.key) .. conky_parse("$color${offset " .. tabulation_width .. "}") .. conky_parse(item.value)
        cursor_position = cursor_position + (min_item_width * math.ceil(item_width / min_item_width))
    end
    return str_output
end

function _get_header(title)
    local max_chars = helper.config.maximum_chars
    local margin_horizontal = helper.config.margin_horizontal
    local margin_vertical = helper.config.margin_vertical
    local maximum_width = conky.config.maximum_width
    local title_position = math.floor((maximum_width - math.ceil(string.len(title) / max_chars * maximum_width)) / 2)

    return conky_parse("${offset 8}${goto " .. title_position .. "}$font7$color0~$color " .. title .. " $color0~$color${voffset " .. margin_vertical .. "}")
end

function conky_display(title, ...)
    local fnrets = {}
    for _, function_name in pairs({...}) do
        local fnret = _G["conky_" .. function_name]()
        if fnret and #fnret and #fnret > 0 then
            fnrets = _merge(fnrets, fnret)
        elseif fnret and fnret.key and fnret.value then
            fnrets[#fnrets + 1] = fnret
        end
    end
    if #fnrets == 0 then
        return conky_parse("${voffset -" .. (helper.config.margin_vertical - 5) .. "}")
    end
    return _get_header(title) .. _table_format(fnrets)
end

function _debug_dump(o)
    if type(o) == "table" then
        local s = "{ "
        for k, v in pairs(o) do
            if type(k) ~= "number" then
                k = "\"" .. k .. "\""
            end
            s = s .. "[" .. k .. "] = " .. _debug_dump(v) .. ","
        end
        return s .. "} "
    else
        return tostring(o)
    end
end

-- conky system informations functions

function conky_uptime()
    local json = require("json")
    local current_timestamp = os.time(os.date("*t"))

    local fnret = _file_read("/proc/uptime", 0)
    if not fnret then
        return conky_parse("$uptime")
    end
    local uptime_sec, _ = string.gsub(fnret, "%..*", "")
    uptime_sec = tonumber(uptime_sec)

    fnret = _command("journalctl -u sleep.target MESSAGE=\"Stopped target Sleep.\" -o json -n 1 --no-pager", 0)
    if not fnret then
        return conky_parse("$uptime")
    end
    if type(fnret) == "string" then
        fnret = json.decode(fnret)
    end
    local awake_timestamp = fnret["_SOURCE_REALTIME_TIMESTAMP"]
    if not awake_timestamp then
        return _sec_to_human(uptime_sec)
    else
        awake_timestamp = math.ceil((tonumber(awake_timestamp) / 1000000) - 0.5)
    end
    local awake_sec = current_timestamp - awake_timestamp

    if awake_sec < uptime_sec then
        return _sec_to_human(awake_sec)
    end
    return _sec_to_human(uptime_sec)
end

function conky_auction()
    local url = "https://query1.finance.yahoo.com/v8/finance/chart/" .. helper.config.auction.code .. "?region=" .. helper.config.auction.region .. "&lang=" .. helper.config.auction.language .. "&interval=1m&range=1h"
    local fnret = _query_get(url)
    if not fnret or not fnret.chart or not fnret.chart.result then
        return ""
    end
    fnret = fnret.chart.result

    local regularMarketPrice = fnret[1].meta.regularMarketPrice
    local previousClose = fnret[1].meta.previousClose
    local currency = _currency2smbol(fnret[1].meta.currency)
    local symbol = fnret[1].meta.symbol
    local diff = _round(regularMarketPrice - previousClose, 2)
    regularMarketPrice = _round(regularMarketPrice, 2)

    local prefix = conky_parse("$font6${color0}") .. symbol .. conky_parse("${offset 8}$color")
    if diff < 0 then
        return prefix .. regularMarketPrice .. currency .. conky_parse("$color$font${voffset -10}${font9}$color2$font0  $font9") .. diff .. currency .. conky_parse("$font9$color")
    elseif diff > 0 then
        return prefix .. regularMarketPrice .. currency .. conky_parse("$color$font${voffset -10}${font9}$color1$font0  $font9") .. diff .. currency .. conky_parse("$font9$color")
    else
        return prefix .. regularMarketPrice .. currency .. conky_parse("${offset 30}")
    end
end

function conky_storage_partitions()
    local storage = {}
    local json = require("json")
    local fnret = _command("lsblk -J -n -p -l -x MOUNTPOINT -O | jq -cM", 0)
    if not fnret then
        return nil
    end
    if type(fnret) == "string" then
        fnret = json.decode(fnret)
    end
    if not fnret.blockdevices then
        return nil
    end
    for _, item in pairs(fnret.blockdevices) do
        if _shall_display(item, helper.config.storage.black_list) == true then
            if item.fstype == "swap" then
                item.mountpoint = "swap"
                item.fsused = string.gsub(conky_parse("$swap"), " ", "")
                item.size = string.gsub(conky_parse("$swapmax"), " ", "")
                item["fsuse%"] = conky_parse("$swapperc") .. "%"
            end
            if type(item.fssize) == "function" then
                item.fssize = item.size
            end
            storage[#storage + 1] = {
                key = item.mountpoint,
                value = item.fstype .. " " .. item.type .. ", " .. item.fsused .. " / " .. item.fssize .. " (" .. item["fsuse%"] .. ")"
            }
        end
    end
    return storage
end

function conky_storage_raid()
    local storage = {}
    local json = require("json")
    local lines = _file_read("/proc/mdstat")
    for _, line in ipairs(lines) do
        local columns = _split(line, " ")
        if columns[1] and string.match(columns[1], "^md[0-9]+$") and columns[2] and columns[2] == ":" and columns[3] and columns[4] then
            storage[#storage + 1] = {
                key = columns[1],
                value = columns[4] .. ", " .. columns[3]
            }
        elseif columns[2] and columns[2] == "blocks" and columns[3] and columns[3] == "super" and columns[6] then
            local status = "error"
            if columns[6] == "[UU]" then
                status = "ok"
            end
            storage[#storage].value = storage[#storage].value .. ", " .. status
        end
    end
    return storage
end

function conky_memory()
    return {
        key = "RAM",
        value = "${mem} / ${memmax}"
    }
end

function conky_cpu()
    local cpu_usage = conky_parse("${cpu}")
    local suffix = "   "
    if tonumber(cpu_usage) and tonumber(cpu_usage) < 100 then
        suffix = suffix .. " "
    end
    if tonumber(cpu_usage) and tonumber(cpu_usage) < 10 then
        suffix = suffix .. " "
    end
    return {
        key = "CPU",
        value = cpu_usage .. " %" .. suffix .. "@${freq_g} GHz"
    }
end

function conky_temperature()
    if not io.open("/sys/class/hwmon/hwmon" .. helper.config.temperature.sensor_device .. "/temp" .. helper.config.temperature.sensor_type .. "_input", "r") then
        print("conky_temperature: wrong sensor device (" .. helper.config.temperature.sensor_device .. ") and/or sensor type (" .. helper.config.temperature.sensor_type .. "). Trying to fix...")
        local fnret = _command("ls /sys/class/hwmon/hwmon*/temp*_input -1", 0)
        if fnret then
            fnret = string.gsub(fnret, "^/sys/class/hwmon/hwmon([0-9]+)/temp([0-9]+)_input$", "%1,%2")
        end
        if not fnret then
            return nil
        end
        helper.config.temperature.sensor_device = _split(fnret)[1]
        helper.config.temperature.sensor_type = _split(fnret)[2]
        print("conky_temperature: sensor device and sensor type configuration fixed to respective values " .. helper.config.temperature.sensor_device .. " and " .. helper.config.temperature.sensor_type)
    end
    return {
        key = "Temp",
        value = "${hwmon " .. helper.config.temperature.sensor_device .. " temp " .. helper.config.temperature.sensor_type .. "} °C"
    }
end

function conky_boot()
    if not cache.boot then
        print("conky_boot: Loading to cache...")
        local fnret = _command("test -d /sys/firmware/efi 2>&1 > /dev/null; echo $?", 0)
        local boot_type = "legacy"
        if fnret == "0" then
            boot_type = "uefi"
        end
        local tpm_type = "no TPM"
        fnret = _command("test -c /dev/" .. helper.config.boot.tpm_device .. " 2>&1 > /dev/null; echo $?", 0)
        if fnret == "0" then
            tpm_type = "TPM"
        end
        cache.boot = {
            key = "Boot",
            value = boot_type .. " (" .. tpm_type .. ")"
        }
    end
    return cache.boot
end

function conky_version_bios()
    if not cache.version_bios then
        print("conky_version_bios: Loading to cache...")
        local fnret = _file_read("/sys/devices/virtual/dmi/id/bios_version", 0)
        cache.version_bios = {
            key = "Bios",
            value = fnret
        }
    end
    return cache.version_bios
end

function conky_version_os()
    if not cache.version_os then
        print("conky_version_os: Loading to cache...")
        local fnret = _command("lsb_release -ds", 0)
        if not fnret then
            return nil
        end
        cache.version_os = {
            key = "OS",
            value = fnret
        }
    end
    return cache.version_os
end

function conky_version_kernel()
    if not cache.version_kernel then
        print("conky_version_kernel: Loading to cache...")
        cache.version_kernel = {
            key = "Kern",
            value = string.gsub(conky_parse("$kernel"), "-generic$", "")
        }
    end
    return cache.version_kernel
end

function conky_power()
    local label = "Battery"
    if not io.open("/proc/acpi/battery/" .. helper.config.power.battery, "r") and not io.open("/sys/class/power_supply/" .. helper.config.power.battery, "r") then
        return conky_boot() -- not a laptop or no battery connected for the moment, let's fall back to something else
    end
    local battery_percent = conky_parse("${battery_percent}")
    local acpi_ac_adapter = conky_parse("${acpiacadapter}")
    if acpi_ac_adapter == "on-line" and battery_percent ~= "100" then
        return {
            key = label,
            value = battery_percent .. "% (Charging)"
        }
    elseif acpi_ac_adapter == "on-line" and battery_percent == "100" then
        return {
            key = label,
            value = "Charged"
        }
    elseif acpi_ac_adapter ~= "on-line" and battery_percent ~= "0" then
        return {
            key = label,
            value = battery_percent .. "% (Discharging)"
        }
    elseif acpi_ac_adapter ~= "on-line" and battery_percent == "0" then
        return {
            key = label,
            value = "Error"
        }
    end
    return {
        key = label,
        value = "N/A"
    }
end

function conky_arch()
    if not cache.arch then
        print("conky_arch: Loading to cache...")
        local fnret = _command("arch", 0)
        if not fnret then
            return nil
        end
        cache.arch = {
            key = "Arch",
            value = fnret
        }
    end
    return cache.arch
end

function conky_version_gs()
    if not cache.version_gs then
        print("conky_version_gs: Loading to cache...")
        local fnret = _command("gnome-shell --version", 0)
        if not fnret then
            return nil
        end
        local version, _ = string.gsub(fnret, "GNOME Shell ", "")
        local session_type = "Xorg (X11)"
        if (os.getenv("XDG_SESSION_TYPE") == "wayland") then
            session_type = "wayland"
        end

        cache.version_gs = {
            key = "Gnome",
            value = version .. "  (" .. session_type .. ")"
        }
    end
    return cache.version_gs
end

function conky_network_ip(version)
    local family = (version and "inet" .. (version == 6 and version or "") or "inet")
    local ips = {}

    if (not version or version == 4) then
        local fnretIp4 = _query_get("https://api.ipify.org/?format=json")
        if fnretIp4 then
            ips[#ips + 1] = {
                value = fnretIp4.ip .. "/32",
                version = 4,
                key = "WAN"
            }
        end
    end

    if (not version or version == 6) then
        local fnretIp6 = _query_get("https://api64.ipify.org/?format=json")
        if fnretIp6 then
            ips[#ips + 1] = {
                value = fnretIp6.ip .. "/128",
                version = 6,
                key = "WAN"
            }
        end
    end

    local nic_aliases = _nic_aliases()

    local json = require("json")
    local fnret = _command("ip -j address", 0)
    if not fnret then
        return nil
    end
    local net_interfaces = fnret
    if type(fnret) == "string" then
        net_interfaces = json.decode(fnret)
    end
    for k, net_interface in ipairs(net_interfaces) do
        if net_interface.operstate == "UNKNOWN" or net_interface.operstate == "UP" then
            local if_name = net_interface.ifname
            local addr_infos = net_interface.addr_info
            for k, addr_info in ipairs(addr_infos) do
                if (not version or addr_info.family == family) and _shall_display(addr_info, helper.config.network_ip.black_list) == true then
                    local ip = {}
                    ip.key = if_name
                    if addr_info.label then
                        ip.key = addr_info.label
                    end
                    if nic_aliases[ip.key] then
                        ip.key = nic_aliases[ip.key]
                    end
                    if not version and addr_info.family == "inet6" then
                        ip.version = 6
                    elseif not version then
                        ip.version = 4
                    end
                    ip.value = addr_info["local"] .. "/" .. addr_info.prefixlen
                    ips[#ips + 1] = ip
                end
            end
        end
    end

    return ips
end

function _sort_routes(a, b)
    local ametric = (a.metric and a.metric or 0)
    ametric = (ametric == "default" and ametric - 1 or ametric)
    local bmetric = (b.metric and b.metric or 0)
    bmetric = (bmetric == "default" and bmetric - 1 or bmetric)
    if ametric == bmetric then
        bmetric = (a.dst == "default" and bmetric + 1 or bmetric)
        ametric = (b.dst == "default" and ametric + 1 or ametric)
    end
    return ametric < bmetric
end

function _nic_aliases()
    local json = require("json")
    local nic_aliases = {}
    local fnretNICs = _command("ip -j link", 0)
    if not fnretNICs then
        return nic_aliases
    end
    if type(fnretNICs) == "string" then
        fnretNICs = json.decode(fnretNICs)
    end
    for _, nic in ipairs(fnretNICs) do
        local if_name = nil
        if string.match(nic.ifname, "^enx.*$") then
            if_name = "eth" .. nic.ifindex
        end
        if string.match(nic.ifname, "^wlx.*$") then
            if_name = "wlan" .. nic.ifindex
        end
        if if_name then
            nic_aliases[nic.ifname] = if_name
        end
    end
    return nic_aliases
end

function conky_network_routes(version)
    local routes = {}

    local nic_aliases = _nic_aliases()

    local json = require("json")
    local fnretRoutesv4 = _command("ip -j route", 0)
    if type(fnretRoutesv4) == "string" then
        fnretRoutesv4 = json.decode(fnretRoutesv4)
    end
    local net_routesv4 = _add_attribute_value(fnretRoutesv4, "version", 4)
    local fnretRoutesv6 = _command("ip -j -6 route", 0)
    if type(fnretRoutesv6) == "string" then
        fnretRoutesv6 = json.decode(fnretRoutesv6)
    end
    local net_routesv6 = _add_attribute_value(fnretRoutesv6, "version", 6)
    local net_routes = _merge(net_routesv4, net_routesv6)
    table.sort(net_routes, _sort_routes)
    for k, net_route in ipairs(net_routes) do
        if (not version or net_route.version == version) and _shall_display(net_route, helper.config.network_routes.black_list) == true then
            local route = {}
            route.key = net_route.dev
            if nic_aliases[route.key] then
                route.key = nic_aliases[route.key]
            end
            route.value = net_route.dst
            if route.value == "default" then
                route.value = (net_route.version == 4 and "0.0.0.0/0" or "::/0")
            end
            route.metric = (net_route.metric and net_route.metric or 0)
            if not version then
                route.version = net_route.version
            end
            routes[#routes + 1] = route
        end
    end
    return routes
end
