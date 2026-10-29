--[[
Provider settings fields (PROVIDERS.md §7, DESIGN.md §9.5, decision 51).
Pure: no KOReader dependencies, so the offline tests load it.

  Fields.validate(schema)        -> true | false, reason     (Catalog.validate calls it)
  Fields.values(schema, stored)  -> { key = value }          what ctx.settings holds
  Fields.missing(schema, stored) -> key | nil                first empty required field
  Fields.isEmpty(field, value)   -> boolean                  one stored value, judged as "not set"
  Fields.nextChoice(field, value) -> the value a tap on a choice row moves to

`stored` is the raw provider_settings[id] table from the settings file. Values
of the wrong type (a hand-edited file, a field whose type changed between
versions) are ignored and the default applies. Empty text is nil (§3).
--]]
local Fields = {}

Fields.TYPES = { text = true, secret = true, toggle = true, choice = true }

local KEY_PATTERN = "^[a-z][a-z0-9_]*$"

local function is_text(field)
    return field.type == "text" or field.type == "secret"
end

local function in_choices(field, value)
    for __, c in ipairs(field.choices or {}) do
        if c == value then return true end
    end
    return false
end

local function valid_field(f)
    if type(f) ~= "table" then return false, "a settings field must be a table" end
    if type(f.key) ~= "string" or not f.key:match(KEY_PATTERN) then
        return false, "bad settings key " .. tostring(f.key) .. " (want ^[a-z][a-z0-9_]*$)"
    end
    local where = "settings field " .. f.key
    if type(f.title) ~= "string" or f.title == "" then return false, where .. " needs a title" end
    if not Fields.TYPES[f.type] then
        return false, where .. ": bad type " .. tostring(f.type) .. " (want text, secret, toggle or choice)"
    end
    if f.hint ~= nil and type(f.hint) ~= "string" then return false, where .. ": hint must be a string" end
    if f.required ~= nil and type(f.required) ~= "boolean" then
        return false, where .. ": required must be true or false"
    end
    if f.type == "toggle" then
        if f.required then return false, where .. ": a toggle cannot be required" end
        if f.default ~= nil and type(f.default) ~= "boolean" then
            return false, where .. ": a toggle default must be true or false"
        end
    elseif f.type == "choice" then
        if type(f.choices) ~= "table" or #f.choices == 0 then
            return false, where .. " needs a non-empty choices list"
        end
        for __, c in ipairs(f.choices) do
            if type(c) ~= "string" or c == "" then return false, where .. ": choices must be strings" end
        end
        if f.default ~= nil and not in_choices(f, f.default) then
            return false, where .. ": default must be one of the choices"
        end
    elseif f.default ~= nil and type(f.default) ~= "string" then
        return false, where .. ": default must be a string"
    end
    return true
end

function Fields.validate(schema)
    if schema == nil then return true end
    if type(schema) ~= "table" then return false, "settings must be a list" end
    local seen = {}
    for __, f in ipairs(schema) do
        local ok, reason = valid_field(f)
        if not ok then return false, reason end
        if seen[f.key] then return false, "duplicate settings key " .. f.key end
        seen[f.key] = true
    end
    return true
end

-- The stored value if it fits the field, else nil.
local function accepted(field, value)
    if is_text(field) and type(value) == "string" then return value end
    if field.type == "toggle" and type(value) == "boolean" then return value end
    if field.type == "choice" and in_choices(field, value) then return value end
    return nil
end

function Fields.isEmpty(field, value)
    if value == nil then return true end
    return is_text(field) and type(value) == "string" and value:match("^%s*$") ~= nil
end

local function value_of(field, stored)
    local raw = accepted(field, stored[field.key])
    if raw == nil then raw = field.default end
    if Fields.isEmpty(field, raw) then return nil end
    return raw
end

function Fields.values(schema, stored)
    stored = type(stored) == "table" and stored or {}
    local out = {}
    for __, f in ipairs(type(schema) == "table" and schema or {}) do
        out[f.key] = value_of(f, stored)
    end
    return out
end

--- A choice field's next value when tapped: cycles through `choices` in
-- order, wrapping; an unset or no-longer-offered value starts at the first.
function Fields.nextChoice(field, value)
    local choices = field.choices
    for i, c in ipairs(choices) do
        if c == value then return choices[(i % #choices) + 1] end
    end
    return choices[1]
end

function Fields.missing(schema, stored)
    stored = type(stored) == "table" and stored or {}
    for __, f in ipairs(type(schema) == "table" and schema or {}) do
        if f.required and value_of(f, stored) == nil then return f.key end
    end
    return nil
end

return Fields
