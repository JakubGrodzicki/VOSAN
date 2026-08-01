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
      local val = row.extras[i]
      if val and val ~= "" then
        extra_parts[#extra_parts + 1] = label .. ": " .. val
      end
    end
    if #extra_parts > 0 then
      reaper.ImGui_Text(ctx, table.concat(extra_parts, "    "))
    end

    reaper.ImGui_Text(ctx, "Nazwa skryptu: " .. (row.script_name_safe ~= "" and row.script_name_safe or "(BRAK NAZWY!)"))
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

  reaper.ImGui_Separator(ctx)
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

  reaper.ImGui_Text(ctx, string.format("Postep: %d / %d nagranych", state.recorded_count or 0, #state.rows))
end

local function draw_table(ctx, state)
  if #state.rows == 0 then
    colored_text(ctx, COLOR_DIM, "Wczytaj plik CSV lub XLSX, zeby zobaczyc liste kwestii.")
    return
  end

  local extra_labels = state.extra_labels or {}
  local n_cols = 2 + #extra_labels -- Nazwa skryptu + kolumny srodkowe + Tresc kwestii

  local avail_w, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
  local table_flags = reaper.ImGui_TableFlags_Resizable()
    | reaper.ImGui_TableFlags_ScrollY()
    | reaper.ImGui_TableFlags_RowBg()
    | reaper.ImGui_TableFlags_BordersInnerV()
    | reaper.ImGui_TableFlags_SizingStretchProp()

  if reaper.ImGui_BeginTable(ctx, "vosan_table", n_cols, table_flags, avail_w, avail_h) then
    reaper.ImGui_TableSetupColumn(ctx, "Nazwa skryptu", reaper.ImGui_TableColumnFlags_WidthFixed(), 220)
    for _, label in ipairs(extra_labels) do
      reaper.ImGui_TableSetupColumn(ctx, label, reaper.ImGui_TableColumnFlags_WidthFixed(), 110)
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

          local color = nil
          if idx == state.selected then
            color = COLOR_SELECTED
          elseif row.recorded then
            color = COLOR_RECORDED
          end

          reaper.ImGui_TableNextColumn(ctx)
          if color then reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), color) end
          local label = (row.script_name ~= "" and row.script_name or "(brak nazwy)") .. "##vosanrow" .. idx
          local clicked = reaper.ImGui_Selectable(ctx, label, idx == state.selected, span_flag)
          if color then reaper.ImGui_PopStyleColor(ctx) end
          if clicked then
            state.selected = idx
          end

          for i = 1, #extra_labels do
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
