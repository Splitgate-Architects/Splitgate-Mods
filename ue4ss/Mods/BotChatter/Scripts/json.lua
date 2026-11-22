-- Lightweight pure-Lua JSON encoder/decoder (zero external C dependencies)
-- Compatible with Lua 5.3 / 5.4 / LuaJIT (RE-UE4SS)

local json = { _version = "1.0.0" }

--------------------------------------------------------------------------------
-- Encode
--------------------------------------------------------------------------------
local escape_char_map = {
    ["\\"] = "\\\\",
    ["\""] = "\\\"",
    ["\b"] = "\\b",
    ["\f"] = "\\f",
    ["\n"] = "\\n",
    ["\r"] = "\\r",
    ["\t"] = "\\t",
}

local function escape_char(c)
    return escape_char_map[c] or string.format("\\u%04x", c:byte())
end

local function encode_string(val)
    return '"' .. val:gsub('[%z\1-\31\\"]', escape_char) .. '"'
end

local function is_array(tbl)
    local count = 0
    local max_idx = 0
    for k, _ in pairs(tbl) do
        if type(k) ~= "number" or k <= 0 or math.floor(k) ~= k then
            return false
        end
        if k > max_idx then max_idx = k end
        count = count + 1
    end
    return count == max_idx
end

local encode_value

local function encode_table(tbl, seen, indent, level)
    if seen[tbl] then
        error("json.encode: circular reference detected")
    end
    seen[tbl] = true

    local res = {}
    local next_level = level + 1
    local pad = indent and ("\n" .. string.rep(indent, next_level)) or ""
    local close_pad = indent and ("\n" .. string.rep(indent, level)) or ""
    local sep = indent and ("," .. pad) or ","
    local kv_sep = indent and ": " or ":"

    if is_array(tbl) then
        if #tbl == 0 then
            seen[tbl] = nil
            return "[]"
        end
        for i = 1, #tbl do
            res[i] = encode_value(tbl[i], seen, indent, next_level)
        end
        seen[tbl] = nil
        return "[" .. pad .. table.concat(res, sep) .. close_pad .. "]"
    else
        local keys = {}
        for k, _ in pairs(tbl) do
            if type(k) == "string" then
                keys[#keys + 1] = k
            end
        end
        table.sort(keys)
        if #keys == 0 then
            seen[tbl] = nil
            return "{}"
        end
        for i = 1, #keys do
            local k = keys[i]
            res[i] = encode_string(k) .. kv_sep .. encode_value(tbl[k], seen, indent, next_level)
        end
        seen[tbl] = nil
        return "{" .. pad .. table.concat(res, sep) .. close_pad .. "}"
    end
end

encode_value = function(val, seen, indent, level)
    local t = type(val)
    if val == nil then
        return "null"
    elseif t == "boolean" then
        return val and "true" or "false"
    elseif t == "number" then
        if val ~= val or val <= -math.huge or val >= math.huge then
            error("json.encode: invalid number (NaN or Inf)")
        end
        return tostring(val)
    elseif t == "string" then
        return encode_string(val)
    elseif t == "table" then
        return encode_table(val, seen, indent, level)
    else
        error("json.encode: unsupported type '" .. t .. "'")
    end
end

function json.encode(val, pretty)
    local indent = pretty and "  " or nil
    return encode_value(val, {}, indent, 0)
end

--------------------------------------------------------------------------------
-- Decode
--------------------------------------------------------------------------------
local unescape_map = {
    ["\""] = "\"",
    ["\\"] = "\\",
    ["/"]  = "/",
    ["b"]  = "\b",
    ["f"]  = "\f",
    ["n"]  = "\n",
    ["r"]  = "\r",
    ["t"]  = "\t",
}

local function codepoint_to_utf8(cp)
    if cp <= 0x7F then
        return string.char(cp)
    elseif cp <= 0x7FF then
        return string.char(
            0xC0 + math.floor(cp / 0x40),
            0x80 + (cp % 0x40)
        )
    elseif cp <= 0xFFFF then
        return string.char(
            0xE0 + math.floor(cp / 0x1000),
            0x80 + (math.floor(cp / 0x40) % 0x40),
            0x80 + (cp % 0x40)
        )
    elseif cp <= 0x10FFFF then
        return string.char(
            0xF0 + math.floor(cp / 0x40000),
            0x80 + (math.floor(cp / 0x1000) % 0x40),
            0x80 + (math.floor(cp / 0x40) % 0x40),
            0x80 + (cp % 0x40)
        )
    end
    return "?"
end

local function decode_error(str, idx, msg)
    local line = 1
    local col = 1
    for i = 1, math.min(idx, #str) do
        if str:byte(i) == 10 then
            line = line + 1
            col = 1
        else
            col = col + 1
        end
    end
    error(string.format("json.decode: %s at line %d col %d", msg, line, col))
end

local function skip_ws(str, idx)
    local _, e = str:find("^[ \t\r\n]*", idx)
    return (e or (idx - 1)) + 1
end

local parse_value

local function parse_string(str, idx)
    idx = idx + 1 -- skip opening quote
    local out = {}
    local len = #str

    while idx <= len do
        local c = str:sub(idx, idx)
        if c == '"' then
            return table.concat(out), idx + 1
        elseif c == "\\" then
            idx = idx + 1
            local esc = str:sub(idx, idx)
            if esc == "u" then
                local hex = str:sub(idx + 1, idx + 4)
                if not hex:match("^[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]$") then
                    decode_error(str, idx, "invalid unicode escape")
                end
                local cp = tonumber(hex, 16)
                idx = idx + 5
                -- Handle UTF-16 surrogate pairs
                if cp >= 0xD800 and cp <= 0xDBFF and str:sub(idx, idx + 1) == "\\u" then
                    local hex2 = str:sub(idx + 2, idx + 5)
                    local cp2 = tonumber(hex2, 16)
                    if cp2 and cp2 >= 0xDC00 and cp2 <= 0xDFFF then
                        cp = 0x10000 + (cp - 0xD800) * 0x400 + (cp2 - 0xDC00)
                        idx = idx + 6
                    end
                end
                out[#out + 1] = codepoint_to_utf8(cp)
            elseif unescape_map[esc] then
                out[#out + 1] = unescape_map[esc]
                idx = idx + 1
            else
                decode_error(str, idx, "invalid escape '\\" .. esc .. "'")
            end
        elseif c:byte() < 32 then
            decode_error(str, idx, "unescaped control character in string")
        else
            local s_end = str:find('[\\"\0-\31]', idx)
            if not s_end then
                decode_error(str, idx, "unterminated string")
            end
            out[#out + 1] = str:sub(idx, s_end - 1)
            idx = s_end
        end
    end

    decode_error(str, idx, "unterminated string")
end

local function parse_number(str, idx)
    local s, e = str:find("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", idx)
    if not s then
        decode_error(str, idx, "invalid number")
    end
    local num_str = str:sub(s, e)
    local n = tonumber(num_str)
    if not n then
        decode_error(str, idx, "invalid number '" .. num_str .. "'")
    end
    return n, e + 1
end

local function parse_array(str, idx)
    idx = skip_ws(str, idx + 1)
    local arr = {}
    if str:sub(idx, idx) == "]" then
        return arr, idx + 1
    end
    local n = 1
    while true do
        local val
        val, idx = parse_value(str, idx)
        arr[n] = val
        n = n + 1
        idx = skip_ws(str, idx)
        local ch = str:sub(idx, idx)
        if ch == "]" then
            return arr, idx + 1
        elseif ch == "," then
            idx = skip_ws(str, idx + 1)
        else
            decode_error(str, idx, "expected ',' or ']' in array")
        end
    end
end

local function parse_object(str, idx)
    idx = skip_ws(str, idx + 1)
    local obj = {}
    if str:sub(idx, idx) == "}" then
        return obj, idx + 1
    end
    while true do
        if str:sub(idx, idx) ~= '"' then
            decode_error(str, idx, "expected string key in object")
        end
        local key
        key, idx = parse_string(str, idx)
        idx = skip_ws(str, idx)
        if str:sub(idx, idx) ~= ":" then
            decode_error(str, idx, "expected ':' after object key")
        end
        idx = skip_ws(str, idx + 1)
        local val
        val, idx = parse_value(str, idx)
        obj[key] = val
        idx = skip_ws(str, idx)
        local ch = str:sub(idx, idx)
        if ch == "}" then
            return obj, idx + 1
        elseif ch == "," then
            idx = skip_ws(str, idx + 1)
        else
            decode_error(str, idx, "expected ',' or '}' in object")
        end
    end
end

parse_value = function(str, idx)
    idx = skip_ws(str, idx)
    local ch = str:sub(idx, idx)
    if ch == '"' then
        return parse_string(str, idx)
    elseif ch == "{" then
        return parse_object(str, idx)
    elseif ch == "[" then
        return parse_array(str, idx)
    elseif ch == "-" or (ch >= "0" and ch <= "9") then
        return parse_number(str, idx)
    elseif str:sub(idx, idx + 3) == "true" then
        return true, idx + 4
    elseif str:sub(idx, idx + 4) == "false" then
        return false, idx + 5
    elseif str:sub(idx, idx + 3) == "null" then
        return nil, idx + 4
    else
        decode_error(str, idx, "unexpected character '" .. ch .. "'")
    end
end

function json.decode(str)
    if type(str) ~= "string" then
        error("json.decode: expected string, got " .. type(str))
    end
    -- Strip UTF-8 BOM if present
    if str:sub(1, 3) == "\239\187\191" then
        str = str:sub(4)
    end
    local val, idx = parse_value(str, 1)
    idx = skip_ws(str, idx)
    if idx <= #str then
        decode_error(str, idx, "trailing characters after JSON value")
    end
    return val
end

return json
