-- vosan_csv.lua
-- Parser plikow CSV: cudzyslowy, escapowane "", BOM UTF-8, auto-detekcja separatora (, albo ;).
-- Zwraca surowa siatke wierszy/kolumn (tablica tablic stringow) - mapowanie na
-- kolumny "Nazwa Skryptu / Postac / Tresc" robi vosan_state.lua.

local M = {}

local SIG_BOM = "\239\187\191"

function M.detect_delimiter(first_line)
  local comma_count, semi_count = 0, 0
  local in_quotes = false
  local i = 1
  local n = #first_line
  while i <= n do
    local c = first_line:sub(i, i)
    if c == '"' then
      in_quotes = not in_quotes
    elseif not in_quotes then
      if c == ',' then
        comma_count = comma_count + 1
      elseif c == ';' then
        semi_count = semi_count + 1
      end
    end
    i = i + 1
  end
  if semi_count > comma_count then
    return ';'
  end
  return ','
end

--- Parsuje zawartosc CSV (string) na tablice wierszy (tablice pol-stringow).
function M.parse_string(content)
  if content:sub(1, 3) == SIG_BOM then
    content = content:sub(4)
  end

  local first_line_end = content:find("[\r\n]") or (#content + 1)
  local delim = M.detect_delimiter(content:sub(1, first_line_end - 1))

  -- Klasa znakow konczacych pole. Ani ',' ani ';' nie sa znakami magicznymi w
  -- klasie znakow Lua, wiec separator mozna wstawic wprost.
  local stop_class = '["\r\n' .. delim .. ']'
  local find, sub = string.find, string.sub

  local rows = {}
  local row = {}
  -- Czesci biezacego pola. Bufor jest reuzywany (licznik pn) zamiast tworzony
  -- na nowo dla kazdego pola. Pole bez cudzyslowow ma dokladnie jedna czesc,
  -- wiec w typowym pliku nie ma tu ani table.concat, ani alokacji tablicy.
  local parts, pn = {}, 0
  local in_quotes = false
  local i = 1
  local n = #content

  local function push_field()
    local value
    if pn == 0 then
      value = ""
    elseif pn == 1 then
      value = parts[1]
    else
      value = table.concat(parts, "", 1, pn)
    end
    row[#row + 1] = value
    pn = 0
  end

  local function push_row()
    push_field()
    rows[#rows + 1] = row
    row = {}
  end

  -- Zamiast czytac znak po znaku, skaczemy find-em do najblizszego znaku
  -- specjalnego i bierzemy cala reszte pola jednym sub.
  while i <= n do
    if in_quotes then
      local q = find(content, '"', i, true)
      if not q then
        -- niedomkniety cudzyslow: reszta pliku jest trescia pola
        pn = pn + 1
        parts[pn] = sub(content, i)
        i = n + 1
      else
        if q > i then
          pn = pn + 1
          parts[pn] = sub(content, i, q - 1)
        end
        if sub(content, q + 1, q + 1) == '"' then
          pn = pn + 1
          parts[pn] = '"'
          i = q + 2
        else
          in_quotes = false
          i = q + 1
        end
      end
    else
      local s = find(content, stop_class, i)
      if not s then
        pn = pn + 1
        parts[pn] = sub(content, i)
        i = n + 1
      else
        if s > i then
          pn = pn + 1
          parts[pn] = sub(content, i, s - 1)
        end
        local c = sub(content, s, s)
        if c == '"' then
          in_quotes = true
          i = s + 1
        elseif c == delim then
          push_field()
          i = s + 1
        elseif c == '\r' then
          push_row()
          i = (sub(content, s + 1, s + 1) == '\n') and (s + 2) or (s + 1)
        else -- '\n'
          push_row()
          i = s + 1
        end
      end
    end
  end

  if pn > 0 or #row > 0 then
    push_row()
  end

  -- usun ewentualne puste wiersze na koncu pliku (np. z koncowego pustego wiersza po \n\n)
  while #rows > 0 do
    local last = rows[#rows]
    if #last == 1 and last[1] == "" then
      rows[#rows] = nil
    else
      break
    end
  end

  return rows
end

--- Wczytuje plik z dysku i parsuje. Zwraca rows, err.
function M.parse(path)
  local f, open_err = io.open(path, "rb")
  if not f then
    return nil, "Nie mozna otworzyc pliku: " .. tostring(open_err)
  end
  local content = f:read("*a")
  f:close()

  if not content or content == "" then
    return nil, "Plik jest pusty."
  end

  local ok, rows_or_err = pcall(M.parse_string, content)
  if not ok then
    return nil, "Blad parsowania CSV: " .. tostring(rows_or_err)
  end

  return rows_or_err
end

return M
