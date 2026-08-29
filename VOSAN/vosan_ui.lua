-- vosan_ui.lua
-- Okno ReaImGui: panel "Teraz nagrywasz", tabela kwestii (wirtualizowana
-- ListClipperem, wiec dziala plynnie nawet przy tysiacach wierszy),
-- wyszukiwarka, checkboxy, licznik postepu i ostrzezenia. Zaprojektowane
-- tak, zeby podczas wlasciwego nagrywania realizator nie musial nic klikac
-- poza wyborem kolejnej kwestii - patrz panel "Teraz nagrywasz" i
-- auto-przejscie po nagraniu.
--
-- Tabela ma DYNAMICZNA liczbe kolumn: pierwsza to zawsze nazwa skryptu,
-- ostatnia zawsze tresc kwestii, a miedzy nimi dowolna liczba kolumn
-- "wizualnych" (state.extra_labels/row.extras) - patrz vosan_state.lua.

local script_dir = (debug.getinfo(1, 'S').source:match([[^@?(.*[\/])[^\/]-$]])) or "./"
package.path = script_dir .. "?.lua;" .. package.path

local vosan_state = require("vosan_state")
local csv = require("vosan_csv")
local xlsx = require("vosan_xlsx")
local regions = require("vosan_regions")

local M = {}

local COLOR_SELECTED = 0xFFB020FF
local COLOR_RECORDED = 0x50D070FF
local COLOR_WARNING  = 0xFF5050FF
local COLOR_DUPWARN  = 0xFFC050FF
local COLOR_DIM      = 0xAAAAAAFF
local COLOR_TARGET   = 0x4FA0E8FF -- kwestie aktualnie nagrywanej postaci (MC albo NPC)

local REGION_REFRESH_INTERVAL = 1.0 -- sekundy

-- === Czcionka dla tresci kwestii w panelu "Teraz nagrywasz" =================
-- CreateFont/PushFont zmienily sygnature miedzy ReaImGui <0.10 i >=0.10 (patrz
-- SetWindowFontScale - ktore w ogole nie istnieje w niektorych wersjach - to
-- byla wczesniejsza lekcja w tym projekcie). Probujemy obu wariantow API przy
-- starcie; jesli zaden nie zadziala, panel dziala dalej samym kolorem, bez
-- pogrubienia/powiekszenia - nigdy nie przerywa dzialania calego skryptu.
local push_big_font = nil

function M.init_fonts(ctx)
  local font_v10 = nil
  local ok_v10 = pcall(function()
    font_v10 = reaper.ImGui_CreateFont('sans-serif', reaper.ImGui_FontFlags_Bold())
    reaper.ImGui_Attach(ctx, font_v10)
  end)
  if ok_v10 and font_v10 then
    push_big_font = function(c) reaper.ImGui_PushFont(c, font_v10, 22) end
    return
  end

  local font_legacy = nil
  local ok_legacy = pcall(function()
    font_legacy = reaper.ImGui_CreateFont('sans-serif', 22, reaper.ImGui_FontFlags_Bold())
    reaper.ImGui_Attach(ctx, font_legacy)
  end)
  if ok_legacy and font_legacy then
    push_big_font = function(c) reaper.ImGui_PushFont(c, font_legacy) end
    return
  end

  push_big_font = nil
end

--- Rysuje tekst pogrubiona, wieksza czcionka, jesli udalo sie ja zaladowac
--- (patrz M.init_fonts); w przeciwnym razie zwykly kolorowy tekst.
local function draw_bold_big(ctx, color, text)
  local pushed = false
  if push_big_font then
    pushed = pcall(push_big_font, ctx)
  end
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), color)
  reaper.ImGui_TextWrapped(ctx, text)
  reaper.ImGui_PopStyleColor(ctx)
  if pushed then
    pcall(reaper.ImGui_PopFont, ctx)
  end
end

function M.load_file(state, path)
  local ext = path:match("%.([%a%d]+)$")
  ext = ext and ext:lower() or ""

  local raw_rows, err
  if ext == "csv" then
    raw_rows, err = csv.parse(path)
  elseif ext == "xlsx" then
    raw_rows, err = xlsx.parse(path)
  else
    err = "Nieobslugiwane rozszerzenie pliku: ." .. ext .. " (obslugiwane: .csv, .xlsx)"
  end

  if not raw_rows then
    state.load_error = err or "Nie udalo sie wczytac pliku."
    return
  end

  state.raw_rows = raw_rows
  state.loaded_file = path
  state.load_error = nil
  vosan_state.load_rows(state, raw_rows, state.skip_header)
  reaper.SetProjExtState(0, "VOSAN", "last_file", path)
end

local function colored_text(ctx, color, text)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), color)
  reaper.ImGui_TextWrapped(ctx, text)
  reaper.ImGui_PopStyleColor(ctx)
end

local function draw_file_controls(ctx, state)
  if reaper.ImGui_Button(ctx, "Wczytaj plik (CSV / XLSX)...") then
    local ok, path = reaper.GetUserFileNameForRead("", "Wybierz plik ze skryptem dubbingowym", "")
    if ok then
      M.load_file(state, path)
    end
  end

  reaper.ImGui_SameLine(ctx)
  if state.loaded_file then
    reaper.ImGui_Text(ctx, "Wczytano: " .. state.loaded_file)
  else
    reaper.ImGui_Text(ctx, "Nie wczytano pliku")
  end

  if not state.loaded_file and state.last_file_suggestion then
    if reaper.ImGui_Button(ctx, "Wczytaj ostatnio uzywany plik z tego projektu") then
      M.load_file(state, state.last_file_suggestion)
    end
    reaper.ImGui_SameLine(ctx)
    colored_text(ctx, COLOR_DIM, state.last_file_suggestion)
  end

  if state.load_error then
    colored_text(ctx, COLOR_WARNING, "Blad wczytywania: " .. state.load_error)
  end

  if state.duplicates and #state.duplicates > 0 then
    colored_text(ctx, COLOR_DUPWARN,
      string.format("Uwaga: %d powtarzajacych sie nazw skryptow w pliku (retake zastapi region, wiec kolejne wystapienia nadpisza poprzednie).", #state.duplicates))
  end
end

local function draw_now_recording_panel(ctx, state)
  reaper.ImGui_Separator(ctx)

  local row = state.selected and state.rows[state.selected]
  if row then
    colored_text(ctx, COLOR_SELECTED, "=== TERAZ NAGRYWASZ ===")
    draw_bold_big(ctx, COLOR_SELECTED, row.text ~= "" and row.text or "(brak tresci)")

    local extra_parts = {}
    for i, label in ipairs(state.extra_labels or {}) do
      if not state.hidden_columns[label] then
        local val = row.extras[i]
        if val and val ~= "" then
          extra_parts[#extra_parts + 1] = label .. ": " .. val
        end
      end
    end
    if #extra_parts > 0 then
      reaper.ImGui_Text(ctx, table.concat(extra_parts, "    "))
    end

    reaper.ImGui_Text(ctx, "Nazwa skryptu: " .. (row.script_name_safe ~= "" and row.script_name_safe or "(BRAK NAZWY!)"))

    if state.mc_column_index and not vosan_state.row_matches_target(state, row) then
      colored_text(ctx, COLOR_DIM,
        "Uwaga: ta kwestia nalezy do drugiej postaci w arkuszu (kontekst rozmowy), nie do aktualnie nagrywanej.")
    end
  else
    colored_text(ctx, COLOR_DIM, "Brak wybranej kwestii - kliknij wiersz w tabeli ponizej.")
  end

  if state.last_warning then
    reaper.ImGui_Separator(ctx)
    colored_text(ctx, COLOR_WARNING, state.last_warning)
    if reaper.ImGui_Button(ctx, "OK, rozumiem##dismiss_warning") then
      state.last_warning = nil
    end
  end

  if state.last_info then
    reaper.ImGui_Separator(ctx)
    colored_text(ctx, COLOR_DIM, state.last_info)
    if reaper.ImGui_Button(ctx, "OK##dismiss_info") then
      state.last_info = nil
    end
  end

  reaper.ImGui_Separator(ctx)
end

-- === Render wsadowy kwestii jednej postaci =================================
-- REAPER daje dwa sposoby na "wyrenderuj tylko te regiony":
--   1) Bounds "Selected regions" na zaznaczonych regionach - Source zostaje
--      "Master mix", czyli okno renderu wyglada dokladnie tak, jak po recznym
--      ustawieniu z README. Zaznaczanie regionow ZE SKRYPTU wymaga jednak
--      REAPERa 7.62+ (wczesniej nie ma pola B_UISEL w API).
--   2) Region Render Matrix - dziala w kazdej wersji, ale przestawia Source na
--      "Region render matrix" i zostawia w projekcie trwaly slad (wpisy macierzy).
-- Probujemy (1); gdy API nie ma albo zaznaczanie zawiedzie, schodzimy do (2).
--
-- UWAGA: ponizsze liczby to kody/bity z GetSetProjectInfo, NIE numery pozycji w
-- rozwijanej liscie okna renderu. RENDER_SETTINGS odpowiada polu "Source", a
-- RENDER_BOUNDSFLAG polu "Bounds" - to dwa rozne klucze i pomylenie ich
-- przestawia zupelnie inny parametr renderu.
local RENDER_SOURCE_MASTER_MIX    = 0 -- RENDER_SETTINGS: &(1|2)==0
local RENDER_SOURCE_REGION_MATRIX = 8 -- RENDER_SETTINGS: &8 = use render matrix
local RENDER_BOUNDS_ALL_REGIONS      = 3
local RENDER_BOUNDS_SELECTED_REGIONS = 5
local RENDER_SRATE = 48000 -- Hz
local RENDER_CHANNELS = 1  -- mono

--- Zbior nazw regionow ({[nazwa]=true}) juz nagranych kwestii wybranej postaci
--- oraz ich liczba.
local function collect_character_regions(state)
  local names, count = {}, 0
  for _, r in ipairs(state.rows) do
    if r.recorded and r.script_name_safe ~= ""
      and r.extras[state.character_col_index] == state.current_character
      and not names[r.script_name_safe] then
      names[r.script_name_safe] = true
      count = count + 1
    end
  end
  return names, count
end

--- Ustawia parametry renderu projektu pod kwestie wybranej postaci i otwiera
--- okno renderu. Aktorowi zostaje wtedy tylko klikniecie "Render N files...".
local function prepare_character_render(state)
  local names, count = collect_character_regions(state)

  -- Bez tego zabezpieczenia render moglby objac CALY projekt: przy pustym
  -- zaznaczeniu regionow REAPER renderuje wszystkie regiony, a pusta macierz
  -- zostawia render przy pozostalych ustawieniach projektu.
  if count == 0 then
    state.last_info = nil
    state.last_warning = "Postac '" .. state.current_character ..
      "' nie ma jeszcze nagranych kwestii - nie ma czego renderowac."
    return
  end

  local used_selection = false
  if regions.has_region_selection_api() then
    local ok, selected = pcall(regions.select_regions_by_name, names)
    used_selection = ok and type(selected) == "number" and selected > 0
  end

  if used_selection then
    reaper.GetSetProjectInfo(0, "RENDER_SETTINGS", RENDER_SOURCE_MASTER_MIX, true)
    reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", RENDER_BOUNDS_SELECTED_REGIONS, true)
  else
    regions.prepare_render_matrix(names)
    reaper.GetSetProjectInfo(0, "RENDER_SETTINGS", RENDER_SOURCE_REGION_MATRIX, true)
    reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", RENDER_BOUNDS_ALL_REGIONS, true)
  end

  local path
  if reaper.GetOS():match("^Win") then
    path = os.getenv("USERPROFILE") .. "\\Desktop\\Nagrania\\" .. state.current_character
  else
    path = os.getenv("HOME") .. "/Desktop/Nagrania/" .. state.current_character
  end
  reaper.GetSetProjectInfo_String(0, "RENDER_FILE", path, true)
  reaper.GetSetProjectInfo_String(0, "RENDER_PATTERN", "$region", true)

  -- Parametry, ktore aktor musialby inaczej ustawic recznie w oknie renderu.
  -- Samego FORMATU (WAV / bit depth) VOSAN nie dotyka - to zakodowany blob
  -- konfiguracji, wiec zostaje taki, jak w domyslnych ustawieniach projektu.
  reaper.GetSetProjectInfo(0, "RENDER_SRATE", RENDER_SRATE, true)
  reaper.GetSetProjectInfo(0, "RENDER_CHANNELS", RENDER_CHANNELS, true)
  reaper.GetSetProjectInfo(0, "RENDER_ADDTOPROJ", 0, true) -- nie wciagaj gotowych plikow z powrotem do projektu

  state.last_warning = nil
  state.last_info = string.format(
    "Przygotowano render %d kwestii postaci '%s' do folderu:\n%s\n%s",
    count, state.current_character, path,
    used_selection
      and "W oknie renderu: Source = Master mix, Bounds = Selected regions."
      or ("Ta wersja REAPERa nie pozwala zaznaczyc regionow ze skryptu " ..
          "(potrzebna 7.62 lub nowsza) - VOSAN uzyl Region Render Matrix. " ..
          "W oknie renderu: Source = Region render matrix."))

  reaper.Main_OnCommand(40015, 0) -- File: Render project...
end

local function draw_search_controls(ctx, state)
  reaper.ImGui_SetNextItemWidth(ctx, 400)
  local changed, new_val = reaper.ImGui_InputText(ctx, "Szukaj (dowolna kolumna)", state.filter_text or "")
  if changed then
    state.filter_text = new_val
    vosan_state.refresh_filter(state)
  end

  local ch1, v1 = reaper.ImGui_Checkbox(ctx, "Auto-przejscie do nastepnej kwestii po nagraniu", state.auto_advance)
  if ch1 then state.auto_advance = v1 end

  reaper.ImGui_SameLine(ctx)
  local ch2, v2 = reaper.ImGui_Checkbox(ctx, "Pierwszy wiersz to naglowek", state.skip_header)
  if ch2 then
    state.skip_header = v2
    if state.raw_rows then
      vosan_state.load_rows(state, state.raw_rows, state.skip_header)
    end
  end

  if state.mc_column_index then
    -- Usunięto SameLine(), zeby okno "Czy nagrywamy MC" bylo lepiej widoczne i nie ucinalo sie
    local ch3, v3 = reaper.ImGui_Checkbox(ctx, "Czy nagrywamy glownego bohatera (MC)?", state.recording_mc)
    if ch3 then state.recording_mc = v3 end
  end

  if state.character_col_index and state.available_characters and #state.available_characters > 0 then
    reaper.ImGui_SetNextItemWidth(ctx, 300)
    if reaper.ImGui_BeginCombo(ctx, "Postać (Plik źródłowy)", state.current_character) then
      for _, char_name in ipairs(state.available_characters) do
        local is_selected = (state.current_character == char_name)
        if reaper.ImGui_Selectable(ctx, char_name, is_selected) then
          state.current_character = char_name
          -- Zmiana wybranej postaci nie filtruje samej listy ukrywajac wiersze,
          -- tylko zmienia ich 'target' status w row_matches_target (kolory/auto-przejscie).
          -- Jednak wyszukiwarka dziala po `search_blob`, a my nie chcemy ukrywac kontekstu.
          -- Aby zaktualizowac kolory w locie: nic specjalnego nie musimy wolac, tabela odswiezy to.
        end
        if is_selected then
          reaper.ImGui_SetItemDefaultFocus(ctx)
        end
      end
      reaper.ImGui_EndCombo(ctx)
    end
    
    if state.current_character ~= "Wszystkie" then
      reaper.ImGui_SameLine(ctx)
      if reaper.ImGui_Button(ctx, "Wyrenderuj nagrania tej postaci") then
        prepare_character_render(state)
      end
    end
  end

  local ch4, v4 = reaper.ImGui_Checkbox(ctx, "Przesun kursor na koniec nagrania automatycznie", state.auto_move_cursor)
  if ch4 then state.auto_move_cursor = v4 end

  if state.auto_move_cursor then
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_SetNextItemWidth(ctx, 80)
    -- InputDouble/DragDouble sa w ReaImGui niepewne co do wersji (patrz
    -- historia problemow z fontami w tym pliku) - InputText jest juz
    -- sprawdzone w tym projekcie, wiec bezpieczniej sparsowac liczbe recznie.
    -- Do widgetu wraca DOKLADNIE to, co zwrocil poprzednio. Podawanie tu
    -- string.format("%.2f", ...) nadpisywalo pole w trakcie pisania: wpisanie
    -- "0,755" bylo zaokraglane do "0.76" jeszcze przed koncem edycji.
    local ch5, v5 = reaper.ImGui_InputText(ctx, "Odstep po nagraniu (s)", state.post_record_gap_text)
    if ch5 then
      state.post_record_gap_text = v5
      local n = tonumber((v5:gsub(",", ".")))
      if n and n >= 0 then
        state.post_record_gap = n
      end
    end
  end

  reaper.ImGui_Text(ctx, string.format("Postep: %d / %d nagranych", state.recorded_count or 0, #state.rows))
end

--- Checkboxy widocznosci dla kolumn "srodkowych" (nazwa skryptu i tresc
--- kwestii sa zawsze widoczne - to kolumny strukturalne, nie informacyjne).
--- Wybor jest per-etykieta i przetrwa przeladowanie pliku w tej samej sesji.
local function draw_column_visibility_controls(ctx, state)
  local labels = state.extra_labels or {}
  if #labels == 0 then return end

  reaper.ImGui_Text(ctx, "Pokaz kolumny:")
  for i, label in ipairs(labels) do
    reaper.ImGui_SameLine(ctx)
    local visible = not state.hidden_columns[label]
    local changed, new_val = reaper.ImGui_Checkbox(ctx, label .. "##colvis" .. i, visible)
    if changed then
      if new_val then
        state.hidden_columns[label] = nil
      else
        state.hidden_columns[label] = true
      end
    end
  end
end

local function draw_table(ctx, state)
  if #state.rows == 0 then
    colored_text(ctx, COLOR_DIM, "Wczytaj plik CSV lub XLSX, zeby zobaczyc liste kwestii.")
    return
  end

  local extra_labels = state.extra_labels or {}
  -- indeksy kolumn srodkowych, ktore NIE sa ukryte (patrz draw_column_visibility_controls)
  local visible_extras = {}
  for i, label in ipairs(extra_labels) do
    if not state.hidden_columns[label] then
      visible_extras[#visible_extras + 1] = i
    end
  end
  local n_cols = 2 + #visible_extras -- Nazwa skryptu + widoczne kolumny srodkowe + Tresc kwestii

  local avail_w, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
  local table_flags = reaper.ImGui_TableFlags_Resizable()
    | reaper.ImGui_TableFlags_ScrollY()
    | reaper.ImGui_TableFlags_RowBg()
    | reaper.ImGui_TableFlags_BordersInnerV()
    | reaper.ImGui_TableFlags_SizingStretchProp()

  if reaper.ImGui_BeginTable(ctx, "vosan_table", n_cols, table_flags, avail_w, avail_h) then
    reaper.ImGui_TableSetupColumn(ctx, "Nazwa skryptu", reaper.ImGui_TableColumnFlags_WidthFixed(), 220)
    for _, i in ipairs(visible_extras) do
      reaper.ImGui_TableSetupColumn(ctx, extra_labels[i], reaper.ImGui_TableColumnFlags_WidthFixed(), 110)
    end
    reaper.ImGui_TableSetupColumn(ctx, "Tresc kwestii", 0, 1.0)
    reaper.ImGui_TableSetupScrollFreeze(ctx, 0, 1)
    reaper.ImGui_TableHeadersRow(ctx)

    if not reaper.ImGui_ValidatePtr(state._clipper, 'ImGui_ListClipper*') then
      state._clipper = reaper.ImGui_CreateListClipper(ctx)
    end
    local clipper = state._clipper
    local filtered = state.filtered
    local span_flag = reaper.ImGui_SelectableFlags_SpanAllColumns()

    reaper.ImGui_ListClipper_Begin(clipper, #filtered)
    while reaper.ImGui_ListClipper_Step(clipper) do
      local display_start, display_end = reaper.ImGui_ListClipper_GetDisplayRange(clipper)
      for row_i = display_start, display_end - 1 do
        local idx = filtered[row_i + 1]
        local row = state.rows[idx]
        if row then
          reaper.ImGui_TableNextRow(ctx)

          -- Priorytet kolorow: wybrana (pomaranczowy) > nagrana (zielony) >
          -- kwestia aktualnie nagrywanej postaci (niebieski) > kwestia
          -- drugiej postaci w arkuszu, tylko kontekst (szary).
          local color = nil
          if idx == state.selected then
            color = COLOR_SELECTED
          elseif row.recorded then
            color = COLOR_RECORDED
          elseif state.mc_column_index then
            color = vosan_state.row_matches_target(state, row) and COLOR_TARGET or COLOR_DIM
          end

          reaper.ImGui_TableNextColumn(ctx)
          if color then reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), color) end
          -- etykieta jest skladana raz, przy wczytaniu pliku (vosan_state)
          local clicked = reaper.ImGui_Selectable(ctx, row.ui_label, idx == state.selected, span_flag)
          if color then reaper.ImGui_PopStyleColor(ctx) end
          if clicked then
            state.selected = idx
          end

          for _, i in ipairs(visible_extras) do
            reaper.ImGui_TableNextColumn(ctx)
            reaper.ImGui_Text(ctx, row.extras[i] or "")
          end

          reaper.ImGui_TableNextColumn(ctx)
          reaper.ImGui_Text(ctx, row.text)
        end
      end
    end

    reaper.ImGui_EndTable(ctx)
  end
end

local function refresh_regions_if_needed(state)
  local now = reaper.time_precise()
  if state.regions_dirty or (now - (state._last_region_refresh or 0)) > REGION_REFRESH_INTERVAL then
    local names_set = regions.get_region_names_set()
    vosan_state.refresh_recorded_status(state, names_set)
    state._last_region_refresh = now
    state.regions_dirty = false
  end
end

function M.draw_contents(ctx, state)
  refresh_regions_if_needed(state)

  draw_file_controls(ctx, state)
  draw_now_recording_panel(ctx, state)
  draw_search_controls(ctx, state)
  draw_column_visibility_controls(ctx, state)
  reaper.ImGui_Separator(ctx)
  draw_table(ctx, state)
end

--- Rysuje jedna klatke okna. Zwraca `open` (false gdy realizator zamknal okno).
--- ImGui_End MUSI byc wywolane zawsze, gdy ImGui_Begin sie powiodl - takze
--- wtedy, gdy rysowanie zawartosci (draw_contents) rzuci blad w trakcie.
--- Pominiecie End() zostawia caly kontekst ReaImGui w trwale uszkodzonym
--- stanie ("Missing End()") az do ponownego uruchomienia skryptu, dlatego
--- Begin/draw_contents sa owiniete w pcall, a End wywolywane jest osobno,
--- bezwarunkowo, jesli tylko Begin zdazyl sie wykonac.
function M.frame(ctx, state)
  local began = false
  local open = true

  local ok, err = pcall(function()
    reaper.ImGui_SetNextWindowSize(ctx, 900, 700, reaper.ImGui_Cond_FirstUseEver())
    local visible
    visible, open = reaper.ImGui_Begin(ctx, 'VOSAN - Voice Over Script Auto Namer', true)
    began = true
    if visible then
      M.draw_contents(ctx, state)
    end
  end)

  if began then
    pcall(reaper.ImGui_End, ctx)
  end

  if not ok then
    error(err, 0)
  end

  return open
end

return M
