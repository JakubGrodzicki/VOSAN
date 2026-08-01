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
  for si_content in xml:gmatch("<si[^>]*>(.-)</si>") do
    local parts = {}
    for t_content in si_content:gmatch("<t[^>]*>(.-)</t>") do
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
  local sheet_data = sheet_xml:match("<sheetData>(.-)</sheetData>")
  if not sheet_data then return rows end

  for row_content in sheet_data:gmatch("<row[^>]*>(.-)</row>") do
    local row = {}
    local max_col = 0
    for cell_tag, cell_content in row_content:gmatch("(<c[^>]*>)(.-)</c>") do
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

-- ustala plik pierwszego arkusza (kolejnosc zakladek) przez xl/workbook.xml +
-- xl/_rels/workbook.xml.rels, bo nazwa pliku arkusza (np. sheet2.xml) nie
-- zawsze odpowiada kolejnosci zakladek we wszystkich programach.
local function resolve_first_sheet_path(data, entries)
  local fallback = "xl/worksheets/sheet1.xml"

  local wb_entry = entries["xl/workbook.xml"]
  if not wb_entry then return fallback end
  local wb_xml = extract_entry(data, wb_entry)
  if not wb_xml then return fallback end

  local rid = wb_xml:match('<sheet[^>]-r:id="([^"]+)"')
    or wb_xml:match('<sheet[^>]-[%w]*:id="([^"]+)"')
  if not rid then return fallback end

  local rels_entry = entries["xl/_rels/workbook.xml.rels"]
  if not rels_entry then return fallback end
  local rels_xml = extract_entry(data, rels_entry)
  if not rels_xml then return fallback end

  local rid_pat = esc_pattern(rid)
  local target = rels_xml:match('Id="' .. rid_pat .. '"[^>]-Target="([^"]+)"')
    or rels_xml:match('Target="([^"]+)"[^>]-Id="' .. rid_pat .. '"')
  if not target then return fallback end

  if target:sub(1, 1) == "/" then
    return target:sub(2)
  end
  return "xl/" .. target
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

    local sheet_path = resolve_first_sheet_path(data, entries)
    local sheet_entry = entries[sheet_path]
    if not sheet_entry then
      error("Plik xlsx wskazuje na arkusz '" .. sheet_path .. "', ktorego nie ma w archiwum.", 0)
    end
    local sheet_xml, serr = extract_entry(data, sheet_entry)
    if not sheet_xml then error(serr, 0) end

    local shared_strings = {}
    local ss_entry = entries["xl/sharedStrings.xml"]
    if ss_entry then
      local ss_xml = extract_entry(data, ss_entry)
      if ss_xml then
        shared_strings = parse_shared_strings(ss_xml)
      end
    end

    return parse_sheet_rows(sheet_xml, shared_strings)
  end)

  if not ok then
    return nil, "Blad odczytu pliku xlsx: " .. tostring(rows_or_err)
  end

  if #rows_or_err == 0 then
    return nil, "Nie znaleziono zadnych wierszy w pierwszym arkuszu pliku xlsx."
  end

  return rows_or_err
end

return M
