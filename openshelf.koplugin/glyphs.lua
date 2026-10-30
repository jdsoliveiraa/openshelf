--[[
Icon glyphs for text widgets.

KOReader bundles no emoji font, but every TextWidget falls back to
`nerdfonts/symbols.ttf` (Nerd Font symbols, FontAwesome range in the Private
Use Area). This is the same idiom the stock OPDS browser uses. Codepoints below
were verified against the bundled font's cmap (2026-10-26).

Pure Lua: codepoints are encoded by hand so the file loads under plain Lua 5.1
(no \u{} escapes).
--]]
local Glyphs = {}

-- Encode a Unicode codepoint as a UTF-8 string.
function Glyphs.utf8(cp)
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
    elseif cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 0x1000),
            0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
    end
    return string.char(0xF0 + math.floor(cp / 0x40000),
        0x80 + math.floor(cp / 0x1000) % 0x40,
        0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
end

local CODEPOINTS = {
    search         = 0xF002,
    filter         = 0xF0B0,
    download       = 0xF019,
    cloud_download = 0xF0ED,
    cart           = 0xF07A,
    check          = 0xF00C,
    gear           = 0xF013,
    list           = 0xF0CA,
    grid           = 0xF00A,
    refresh        = 0xF021,
    history        = 0xF1DA,
    close          = 0xF00D,
    back           = 0xF060,
    trash          = 0xF1F8,
    warning        = 0xF071,
    clock          = 0xF017,
    book           = 0xF02D,
    more           = 0xF141,
    ban            = 0xF05E,
    chevron_left   = 0xF053,
    chevron_right  = 0xF054,
    folder         = 0xF07B,   -- checked against the bundled font 2026-10-30
}

for name, cp in pairs(CODEPOINTS) do
    Glyphs[name] = Glyphs.utf8(cp)
end

return Glyphs
