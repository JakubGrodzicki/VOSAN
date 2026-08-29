-- vosan_xlsx.lua
-- Parser plikow .xlsx w czystym Lua, bez zewnetrznych zaleznosci.
-- .xlsx to archiwum ZIP: czytamy centralny katalog ZIP, dekompresujemy
-- (metoda DEFLATE - vosan_deflate.lua) xl/workbook.xml + rels + arkusz +
-- xl/sharedStrings.xml, i wyciagamy tresc komorek wzorcami Lua (bez pelnego
-- parsera XML - struktura arkuszy z Excela/Sheets/LibreOffice jest
-- wystarczajaco regularna).

local script_dir = (debug.getinfo(1, 'S').source:match([[^@?(.*[\/])[^\/]-$]])) or "./"
package.path = script_dir .. "?.lua;" .. package.path
local deflate = require("vosan_deflate")

local M = {}

local SIG_LOCAL = string.char(0x50, 0x4B, 0x03, 0x04)
local SIG_CENTRAL = string.char(0x50, 0x4B, 0x01, 0x02)
local SIG_EOCD = string.char(0x50, 0x4B, 0x05, 0x06)

local function u16(data, pos)
  local a, b = string.byte(data, pos, pos + 1)
  return a + b * 256
end

local function u32(data, pos)
  local a, b, c, d = string.byte(data, pos, pos + 3)
  return a + b * 256 + c * 65536 + d * 16777216
end

local function esc_pattern(s)
  return (s:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%1"))
end

-- === ZIP =====================================================================

local function find_eocd(data)
  local n = #data
  if n < 22 then return nil, "Plik jest za maly, zeby byl poprawnym archiwum ZIP." end
  local lo = math.max(1, n - 65535 - 21)
  for p = n - 21, lo, -1 do
    if data:sub(p, p + 3) == SIG_EOCD then
      return p
    end
  end
  return nil, "Nie znaleziono struktury End Of Central Directory - plik nie wyglada na poprawny .xlsx."
end

local function parse_central_directory(data, cd_offset, total_entries)
  local entries = {}
  local pos = cd_offset + 1
  for _ = 1, total_entries do
    if data:sub(pos, pos + 3) ~= SIG_CENTRAL then
      break
    end
    local method = u16(data, pos + 10)
    local comp_size = u32(data, pos + 20)
    local uncomp_size = u32(data, pos + 24)
    local fname_len = u16(data, pos + 28)
    local extra_len = u16(data, pos + 30)
    local comment_len = u16(data, pos + 32)
    local local_offset = u32(data, pos + 42)
    local fname = data:sub(pos + 46, pos + 46 + fname_len - 1)
    entries[fname] = {
      method = method,
      comp_size = comp_size,
      uncomp_size = uncomp_size,
      local_offset = local_offset,
    }
    pos = pos + 46 + fname_len + extra_len + comment_len
  end
  return entries
end

local function extract_entry(data, entry)
  local lp = entry.local_offset + 1
  if data:sub(lp, lp + 3) ~= SIG_LOCAL then
    return nil, "Uszkodzony wpis ZIP (bledny offset lokalnego naglowka)."
  end
  local fname_len = u16(data, lp + 26)
  local extra_len = u16(data, lp + 28)
  local data_start = lp + 30 + fname_len + extra_len
  local raw = data:sub(data_start, data_start + entry.comp_size - 1)
  if entry.method == 0 then
    return raw
  elseif entry.method == 8 then
    local ok, result = pcall(deflate.inflate, raw)
    if not ok then
      return nil, "Blad dekompresji wpisu ZIP: " .. tostring(result)
    end
    return result
  else
    return nil, "Nieobslugiwana metoda kompresji w pliku xlsx: " .. tostring(entry.method)
  end
end

-- === XML (wzorce, bez pelnego parsera) =====================================

--- Iterator po elementach <tag ...>tresc</tag> ORAZ <tag .../> w podanym XML.
--- Zwraca pare (znacznik_otwierajacy, tresc); dla znacznika samozamykajacego
--- tresc jest pustym ciagiem.
---
--- Excel zapisuje KAZDA pusta komorke, ktora ma jakiekolwiek formatowanie
--- (obramowanie, wypelnienie, czcionke), jako <c r="B2" s="5"/> - bez </c>.
--- Wczesniejszy wzorzec "(<c[^>]*>)(.-)</c>" brał wtedy za tresc pustej komorki
--- cala NASTEPNA komorke: pusta komorka dostawala surowy indeks z sharedStrings,
--- nastepna znikala, a typ t="s" przepadal, wiec tekst nie byl rozwijany.
--- W arkuszu z obramowana tabela dotyczy to wiekszosci komorek.
local function each_element(xml, tag)
  local open_pattern = "<" .. tag .. "[^>]*>"
  local close_tag = "</" .. tag .. ">"
  local pos = 1
  return function()
    local s, e = xml:find(open_pattern, pos)
    if not s then return nil end
    local open_tag = xml:sub(s, e)
    if open_tag:sub(-2) == "/>" then
      pos = e + 1
      return open_tag, ""
    end
    local cs, ce = xml:find(close_tag, e + 1, true)
    if not cs then
      -- brak znacznika zamykajacego: bierzemy reszte, zamiast gubic dane
      pos = #xml + 1
      return open_tag, xml:sub(e + 1)
    end
    pos = ce + 1
    return open_tag, xml:sub(e + 1, cs - 1)
  end
end

function M.xml_unescape(s)
  s = s:gsub("&lt;", "<")
  s = s:gsub("&gt;", ">")
  s = s:gsub("&quot;", '"')
  s = s:gsub("&apos;", "'")
  s = s:gsub("&#x(%x+);", function(hex)
    local ok, ch = pcall(utf8.char, tonumber(hex, 16))
    return ok and ch or ""
  end)
  s = s:gsub("&#(%d+);", function(dec)
    local ok, ch = pcall(utf8.char, tonumber(dec))
    return ok and ch or ""
  end)
  s = s:gsub("&amp;", "&") -- musi byc na koncu, zeby nie rozwinac &amp;lt; podwojnie
  return s
end

local function parse_shared_strings(xml)
  local strings = {}
  for _, si_content in each_element(xml, "si") do
    local parts = {}
    for _, t_content in each_element(si_content, "t") do
      parts[#parts + 1] = M.xml_unescape(t_content)
    end
    strings[#strings + 1] = table.concat(parts)
  end
  return strings
end

local function col_letters_to_index(ref)
  local letters = ref:match("^(%a+)")
  if not letters then return nil end
  local idx = 0
  for i = 1, #letters do
    idx = idx * 26 + (string.byte(letters, i) - string.byte("A") + 1)
  end
  return idx
end

local function parse_sheet_rows(sheet_xml, shared_strings)
  local rows = {}
  local sheet_data = sheet_xml:match("<sheetData[^>]*>(.-)</sheetData>")
  if not sheet_data then return rows end

  for _, row_content in each_element(sheet_data, "row") do
    local row = {}
    local max_col = 0
    for cell_tag, cell_content in each_element(row_content, "c") do
      local ref = cell_tag:match('r="([^"]+)"')
      local ctype = cell_tag:match('t="([^"]+)"')
      local col = (ref and col_letters_to_index(ref)) or (max_col + 1)

      local value = ""
      if ctype == "inlineStr" then
        local t = cell_content:match("<t[^>]*>(.-)</t>")
        value = t and M.xml_unescape(t) or ""
      else
        local v = cell_content:match("<v[^>]*>(.-)</v>")
        if v then
          if ctype == "s" then
            local sidx = tonumber(v)
            value = (sidx and shared_strings[sidx + 1]) or ""
          else
            value = M.xml_unescape(v)
          end
        end
      end

      row[col] = value
      if col > max_col then max_col = col end
    end

    local ordered = {}
    for i = 1, max_col do
      ordered[i] = row[i] or ""
    end
    rows[#rows + 1] = ordered
  end

  return rows
end

-- ustala pliki WSZYSTKICH arkuszy w kolejnosci zakladek, przez xl/workbook.xml +
-- xl/_rels/workbook.xml.rels, bo nazwa pliku arkusza (np. sheet2.xml) nie
-- zawsze odpowiada kolejnosci zakladek we wszystkich programach.
local function resolve_sheet_paths(data, entries)
  local fallback = { "xl/worksheets/sheet1.xml" }

  local wb_entry = entries["xl/workbook.xml"]
  if not wb_entry then return fallback end
  local wb_xml = extract_entry(data, wb_entry)
  if not wb_xml then return fallback end

  local rels_entry = entries["xl/_rels/workbook.xml.rels"]
  if not rels_entry then return fallback end
  local rels_xml = extract_entry(data, rels_entry)
  if not rels_xml then return fallback end

  local paths = {}
  for sheet_tag in wb_xml:gmatch("<sheet[^>]*>") do
    -- <sheets> i inne znaczniki zaczynajace sie tak samo nie maja r:id,
    -- wiec wypadaja same
    local rid = sheet_tag:match('r:id="([^"]+)"')
      or sheet_tag:match('[%w]*:id="([^"]+)"')
    if rid then
      local rid_pat = esc_pattern(rid)
      local target = rels_xml:match('Id="' .. rid_pat .. '"[^>]-Target="([^"]+)"')
        or rels_xml:match('Target="([^"]+)"[^>]-Id="' .. rid_pat .. '"')
      if target then
        paths[#paths + 1] = (target:sub(1, 1) == "/") and target:sub(2) or ("xl/" .. target)
      end
    end
  end

  if #paths == 0 then return fallback end
  return paths
end

--- Wczytuje plik .xlsx z dysku i zwraca surowa siatke wierszy pierwszego
--- arkusza (tablice tablic stringow), tak samo jak vosan_csv.parse.
function M.parse(path)
  local f, open_err = io.open(path, "rb")
  if not f then
    return nil, "Nie mozna otworzyc pliku: " .. tostring(open_err)
  end
  local data = f:read("*a")
  f:close()

  if not data or #data == 0 then
    return nil, "Plik jest pusty."
  end

  local ok, rows_or_err = pcall(function()
    local eocd_pos, eerr = find_eocd(data)
    if not eocd_pos then error(eerr, 0) end

    local cd_offset = u32(data, eocd_pos + 16)
    local total_entries = u16(data, eocd_pos + 10)
    local entries = parse_central_directory(data, cd_offset, total_entries)

    local shared_strings = {}
    local ss_entry = entries["xl/sharedStrings.xml"]
    if ss_entry then
      local ss_xml = extract_entry(data, ss_entry)
      if ss_xml then
        shared_strings = parse_shared_strings(ss_xml)
      end
    end

    -- Wszystkie arkusze skoroszytu ida do jednej siatki, w kolejnosci zakladek.
    -- Aktor gra wiele postaci, a kazda postac ma wlasny arkusz; glowny bohater
    -- czyta swoje kwestie z arkuszy wszystkich postaci. Indeksy poczatkow
    -- arkuszy wracaja w polu sheet_starts, zeby vosan_state mogl pominac wiersz
    -- naglowka w KAZDYM arkuszu, a nie tylko w pierwszym.
    local all_rows = {}
    local sheet_starts = {}

    for _, sheet_path in ipairs(resolve_sheet_paths(data, entries)) do
      local sheet_entry = entries[sheet_path]
      if sheet_entry then
        local sheet_xml, serr = extract_entry(data, sheet_entry)
        if not sheet_xml then error(serr, 0) end
        local sheet_rows = parse_sheet_rows(sheet_xml, shared_strings)
        if #sheet_rows > 0 then
          sheet_starts[#sheet_starts + 1] = #all_rows + 1
          table.move(sheet_rows, 1, #sheet_rows, #all_rows + 1, all_rows)
        end
      end
    end

    all_rows.sheet_starts = sheet_starts
    return all_rows
  end)

  if not ok then
    return nil, "Blad odczytu pliku xlsx: " .. tostring(rows_or_err)
  end

  if #rows_or_err == 0 then
    return nil, "Nie znaleziono zadnych wierszy w zadnym arkuszu pliku xlsx."
  end

  return rows_or_err
end

return M
