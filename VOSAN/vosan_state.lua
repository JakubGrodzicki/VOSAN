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
    hidden_columns = {},      -- {[etykieta]=true} - kolumny srodkowe ukryte na zyczenie realizatora
                               -- (celowo NIE resetowane przy wczytaniu pliku - wybor ma przetrwac przeladowanie)
    mc_column_index = nil,    -- indeks w row.extras kolumny "MC", albo nil gdy plik jej nie ma
    recording_mc = false,     -- false = nagrywamy NPC (MC="Nie"), true = nagrywamy MC (MC="Tak")
    character_col_index = nil, -- indeks w row.extras kolumny "plik zrodlowy"
    available_characters = {}, -- lista unikalnych postaci z kolumny character_col_index ("Wszystkie" zawsze na poczatku)
    current_character = "Wszystkie", -- nazwa wybranej postaci lub "Wszystkie"
    raw_rows = nil,           -- ostatnio sparsowana surowa siatka (do przeladowania przy zmianie skip_header)
    filter_text = "",
    filtered = {},
    selected = nil,
    loaded_file = nil,
    load_error = nil,
    last_file_suggestion = nil,
    skip_header = true,
    auto_advance = true,
    auto_move_cursor = true, -- po nagraniu przesun kursor edycji na koniec itemu + post_record_gap
    post_record_gap = 0.5,   -- sekundy odstepu doklejane po koncu nagrania przy przesuwaniu kursora
    post_record_gap_text = "0.50", -- bufor pola tekstowego dla powyzszej wartosci (patrz vosan_ui)
    duplicates = {},
    last_warning = nil,
    last_info = nil,        -- komunikat informacyjny (np. podsumowanie przygotowanego renderu)
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

  -- Ktore wiersze surowej siatki sa naglowkami. Plik xlsx z wieloma arkuszami
  -- wnosi jeden naglowek na KAZDY arkusz (vosan_xlsx zwraca ich indeksy w polu
  -- sheet_starts); CSV i starsze siatki maja tylko wiersz pierwszy.
  local header_rows = {}
  if skip_header and #raw_rows > 0 then
    local sheet_starts = raw_rows.sheet_starts
    if sheet_starts and #sheet_starts > 0 then
      for _, idx in ipairs(sheet_starts) do header_rows[idx] = true end
    else
      header_rows[1] = true
    end
  end

  local start_i = 1
  while header_rows[start_i] do start_i = start_i + 1 end
  local extra_labels = determine_extra_labels(raw_rows, skip_header, start_i)

  -- Bufor sklejania tekstu do wyszukiwania, reuzywany miedzy wierszami, zeby
  -- nie alokowac osobnej tablicy na kazdy wiersz pliku.
  local blob_buf = {}

  for i = 1, #raw_rows do
    local r = raw_rows[i]
    local n = #r
    local script_name = trim(r[1])
    local text = (n >= 2) and trim(r[n]) or ""

    local extras = {}
    local has_extra_content = false
    for k = 2, n - 1 do
      local value = trim(r[k])
      extras[#extras + 1] = value
      if value ~= "" then has_extra_content = true end
    end

    -- Wiersz bez nazwy, bez tresci i bez zawartosci kolumn srodkowych nie jest
    -- kwestia. W arkuszu z obramowana tabela takich wierszy sa setki: komorki
    -- istnieja, bo maja formatowanie, ale nie zawieraja nic. Sprawdzanie samej
    -- LICZBY kolumn srodkowych przepuszczalo je do listy aktora.
    if not header_rows[i] and (script_name ~= "" or text ~= "" or has_extra_content) then
      local row_n = #rows + 1

      -- search_blob: wszystkie pola wiersza sklejone i zamienione na male litery
      -- RAZ, przy wczytaniu pliku. refresh_filter robil to wczesniej osobno dla
      -- kazdego pola przy KAZDYM nacisnieciu klawisza w wyszukiwarce. Separator
      -- "\1" nie wystepuje w tekscie z arkusza, wiec dopasowanie nie moze
      -- przeskoczyc granicy dwoch kolumn - tak samo jak przy szukaniu po polach.
      blob_buf[1] = script_name
      blob_buf[2] = text
      local bn = 2
      for k = 1, #extras do
        bn = bn + 1
        blob_buf[bn] = extras[k]
      end

      rows[row_n] = {
        n = row_n,
        script_name = script_name,
        script_name_safe = M.sanitize_name(script_name),
        extras = extras,
        text = text,
        recorded = false,
        search_blob = table.concat(blob_buf, "\1", 1, bn):lower(),
        -- etykieta Selectable dla tabeli; jest stala przez cale zycie wiersza,
        -- wiec nie ma powodu skladac jej na nowo w kazdej klatce (vosan_ui)
        ui_label = (script_name ~= "" and script_name or "(brak nazwy)")
          .. "##vosanrow" .. row_n,
      }
    end
  end

  state.rows = rows
  state.extra_labels = extra_labels
  state.recording_mc = false

  state.mc_column_index = nil
  state.character_col_index = nil
  state.available_characters = {"Wszystkie"}
  state.current_character = "Wszystkie"
  
  for i, label in ipairs(extra_labels) do
    local l_lower = label:lower()
    if l_lower == MC_COLUMN_LABEL then
      state.mc_column_index = i
    elseif l_lower == "plik źródłowy" or l_lower == "plik zrodlowy" or l_lower == "postac" or l_lower == "postać" or l_lower == "character" then
      state.character_col_index = i
    end
  end

  -- Fallback: jesli nie znaleziono kolumn po nazwach, uzywamy domyslnych indeksow
  -- Zgodnie z formatem VOSAN: Kolumna 1 to nazwa skryptu.
  -- Kolumna 2 (pierwsza kolumna dodatkowa, indeks 1 w extras) = Postac
  -- Kolumna 3 (druga kolumna dodatkowa, indeks 2 w extras) = MC
  if not state.character_col_index and #extra_labels >= 1 then
    state.character_col_index = 1
  end
  
  if not state.mc_column_index and #extra_labels >= 2 then
    state.mc_column_index = 2
  end

  if state.character_col_index then
    local char_set = {}
    for _, r in ipairs(rows) do
      local char_name = r.extras[state.character_col_index]
      if char_name and char_name ~= "" then
        char_set[char_name] = true
      end
    end
    for c in pairs(char_set) do
      table.insert(state.available_characters, c)
    end
    table.sort(state.available_characters, function(a, b)
      if a == "Wszystkie" then return true end
      if b == "Wszystkie" then return false end
      return a < b
    end)
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
  -- Najpierw filtr postaci (plik zrodlowy)
  if state.character_col_index and state.current_character ~= "Wszystkie" then
    local char_val = row.extras[state.character_col_index] or ""
    if char_val ~= state.current_character then
      return false
    end
  end

  -- Potem logika MC
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

--- Szuka w prekalkulowanym row.search_blob (patrz load_rows) zamiast zamieniac
--- kazde pole na male litery przy kazdym wywolaniu.
function M.refresh_filter(state)
  local q = (state.filter_text or ""):lower()
  local rows = state.rows
  local filtered = {}
  if q == "" then
    for i = 1, #rows do filtered[i] = i end
  else
    local n = 0
    for i = 1, #rows do
      if rows[i].search_blob:find(q, 1, true) then
        n = n + 1
        filtered[n] = i
      end
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
