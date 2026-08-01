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

  local rows = {}
  local row = {}
  local field_chars = {}
  local in_quotes = false
  local i = 1
  local n = #content

  local function push_field()
    row[#row + 1] = table.concat(field_chars)
    field_chars = {}
  end

  local function push_row()
    push_field()
    rows[#rows + 1] = row
    row = {}
  end

  while i <= n do
    local c = content:sub(i, i)
    if in_quotes then
      if c == '"' then
        if content:sub(i + 1, i + 1) == '"' then
          field_chars[#field_chars + 1] = '"'
          i = i + 2
        else
          in_quotes = false
          i = i + 1
        end
      else
        field_chars[#field_chars + 1] = c
        i = i + 1
      end
    else
      if c == '"' then
        in_quotes = true
        i = i + 1
      elseif c == delim then
        push_field()
        i = i + 1
      elseif c == '\r' then
        if content:sub(i + 1, i + 1) == '\n' then
          push_row()
          i = i + 2
        else
          push_row()
          i = i + 1
        end
      elseif c == '\n' then
        push_row()
        i = i + 1
      else
        field_chars[#field_chars + 1] = c
        i = i + 1
      end
    end
  end

  if #field_chars > 0 or #row > 0 then
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
