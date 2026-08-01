-- vosan_state.lua
-- Model danych sesji. Format pliku jest DYNAMICZNY co do liczby kolumn:
--   - pierwsza kolumna jest ZAWSZE nazwa skryptu (nazwa regionu),
--   - ostatnia kolumna jest ZAWSZE tresc kwestii,
--   - wszystko pomiedzy to dowolna liczba kolumn "wizualnych" dla aktora
--     (np. plik zrodlowy, flaga glownej postaci) - VOSAN nie nadaje im
--     zadnego stalego znaczenia, tylko wyswietla je pod etykietami z wiersza
--     naglowka (albo generycznymi "Kolumna N", jesli naglowka nie ma).
-- Status "nagrane" jest wyliczany na zywo z listy regionow projektu (patrz
-- refresh_recorded_status) - nie jest tu trzymany jako osobny stan.

local M = {}

local INVALID_FS_CHARS = '[\\/:%*%?"<>|]'

function M.sanitize_name(name)
  name = name or ""
  name = name:gsub(INVALID_FS_CHARS, "_")
  name = name:gsub("^%s+", ""):gsub("%s+$", "")
  return name
end

local function trim(s)
  return (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

-- Nazwa kolumny (w naglowku), ktora wlacza rozroznianie glownego bohatera
-- (MC) od pozostalych postaci w arkuszu. Dopasowanie bez wzgledu na
-- wielkosc liter. Jesli plik nie ma takiej kolumny, cala funkcja
-- MC/NPC jest wylaczona i VOSAN dziala jak dotychczas (bez rozroznienia).
local MC_COLUMN_LABEL = "mc"
local MC_TRUE_VALUE = "tak"

function M.new()
  return {
    rows = {},
    extra_labels = {},       -- etykiety kolumn "srodkowych" (miedzy nazwa skryptu a trescia)
    mc_column_index = nil,    -- indeks w row.extras kolumny "MC", albo nil gdy plik jej nie ma
    recording_mc = false,     -- false = nagrywamy NPC (MC="Nie"), true = nagrywamy MC (MC="Tak")
    raw_rows = nil,           -- ostatnio sparsowana surowa siatka (do przeladowania przy zmianie skip_header)
    filter_text = "",
    filtered = {},
    selected = nil,
    loaded_file = nil,
    load_error = nil,
    last_file_suggestion = nil,
    skip_header = true,
    auto_advance = true,
    duplicates = {},
    last_warning = nil,
    recorded_count = 0,
    regions_dirty = true,
    _last_region_refresh = 0,
  }
end

--- Wyznacza etykiety kolumn srodkowych. Jesli skip_header=true, bierze je z
--- wiersza naglowka (kolumny 2..N-1); w przeciwnym razie (albo gdy naglowek
--- ma za malo kolumn) generuje "Kolumna 2", "Kolumna 3" itd. na podstawie
--- najszerszego wiersza danych.
local function determine_extra_labels(raw_rows, skip_header, data_start_i)
  local labels = {}

  if skip_header and #raw_rows > 0 then
    local header = raw_rows[1]
    for i = 2, #header - 1 do
      local label = trim(header[i])
      labels[#labels + 1] = (label ~= "") and label or ("Kolumna " .. i)
    end
  end

  if #labels == 0 then
    local max_cols = 0
    for i = data_start_i, #raw_rows do
      if #raw_rows[i] > max_cols then max_cols = #raw_rows[i] end
    end
    for i = 2, max_cols - 1 do
      labels[#labels + 1] = "Kolumna " .. i
    end
  end

  return labels
end

--- Mapuje surowa siatke wierszy (tablice tablic stringow, np. z vosan_csv/vosan_xlsx)
--- na wiersze modelu {n, script_name, script_name_safe, extras, text}.
function M.load_rows(state, raw_rows, skip_header)
  local rows = {}
  local start_i = (skip_header and #raw_rows > 0) and 2 or 1
  local extra_labels = determine_extra_labels(raw_rows, skip_header, start_i)

  for i = start_i, #raw_rows do
    local r = raw_rows[i]
    local n = #r
    local script_name = trim(r[1])
    local text = (n >= 2) and trim(r[n]) or ""

    local extras = {}
    for k = 2, n - 1 do
      extras[#extras + 1] = trim(r[k])
    end

    if script_name ~= "" or text ~= "" or #extras > 0 then
      rows[#rows + 1] = {
        n = #rows + 1,
        script_name = script_name,
        script_name_safe = M.sanitize_name(script_name),
        extras = extras,
        text = text,
        recorded = false,
      }
    end
  end

  state.rows = rows
  state.extra_labels = extra_labels
  state.recording_mc = false

  state.mc_column_index = nil
  for i, label in ipairs(extra_labels) do
    if label:lower() == MC_COLUMN_LABEL then
      state.mc_column_index = i
      break
    end
  end

  state.selected = (#rows > 0) and 1 or nil
  state.duplicates = M.find_duplicates(rows)
  state.regions_dirty = true
  M.refresh_filter(state)
  return rows
end

--- Zwraca true, jesli dany wiersz nalezy do aktualnie nagrywanej postaci
--- (MC albo NPC, wg state.recording_mc). Jesli plik nie ma kolumny "MC",
--- kazdy wiersz "pasuje" - funkcja MC/NPC jest wtedy nieaktywna.
function M.row_matches_target(state, row)
  if not state.mc_column_index then return true end
  local val = (row.extras[state.mc_column_index] or ""):lower()
  local is_mc = (val == MC_TRUE_VALUE)
  return state.recording_mc == is_mc
end

function M.find_duplicates(rows)
  local seen = {}
  local dup_names = {}
  for _, row in ipairs(rows) do
    if row.script_name ~= "" then
      if seen[row.script_name] then
        dup_names[row.script_name] = true
      end
      seen[row.script_name] = true
    end
  end
  local list = {}
  for name in pairs(dup_names) do list[#list + 1] = name end
  table.sort(list)
  return list
end

function M.refresh_filter(state)
  local q = (state.filter_text or ""):lower()
  local filtered = {}
  if q == "" then
    for i = 1, #state.rows do filtered[#filtered + 1] = i end
  else
    for i, row in ipairs(state.rows) do
      local matches = row.script_name:lower():find(q, 1, true) ~= nil
      if not matches then
        matches = row.text:lower():find(q, 1, true) ~= nil
      end
      if not matches then
        for _, ex in ipairs(row.extras) do
          if ex:lower():find(q, 1, true) then
            matches = true
            break
          end
        end
      end
      if matches then filtered[#filtered + 1] = i end
    end
  end
  state.filtered = filtered
end

function M.select_row(state, idx)
  state.selected = idx
end

--- Przesuwa wybor na KOLEJNY PASUJACY wiersz w obrebie AKTUALNIE WIDOCZNEGO
--- (odfiltrowanego) zbioru - pomija wiersze innej postaci (patrz
--- row_matches_target), zeby auto-przejscie po nagraniu nie zatrzymywalo
--- sie na kwestiach kontekstowych drugiej postaci w arkuszu. Uzywane po
--- auto-przejsciu po nagraniu.
function M.select_next(state)
  if not state.selected then return end
  local start_pos = nil
  for pos, idx in ipairs(state.filtered) do
    if idx == state.selected then
      start_pos = pos
      break
    end
  end
  if not start_pos then return end

  for pos = start_pos + 1, #state.filtered do
    local idx = state.filtered[pos]
    local row = state.rows[idx]
    if row and M.row_matches_target(state, row) then
      state.selected = idx
      return
    end
  end
end

--- Odswieza flage "recorded" kazdego wiersza na podstawie zbioru nazw
--- istniejacych regionow projektu (region_names_set: {[nazwa]=true}).
function M.refresh_recorded_status(state, region_names_set)
  local count = 0
  for _, row in ipairs(state.rows) do
    local rec = row.script_name_safe ~= "" and region_names_set[row.script_name_safe] or false
    row.recorded = rec
    if rec then count = count + 1 end
  end
  state.recorded_count = count
end

return M
