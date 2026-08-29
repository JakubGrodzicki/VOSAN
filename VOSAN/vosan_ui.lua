-- vosan_ui.lua
-- Okno ReaImGui, od gory: pasek pliku z postepem, panel "Teraz nagrywasz" na
-- cala szerokosc, poziomy pasek ustawien sesji, pasek roboczy (szukaj /
-- postac / render) i tabela kwestii (wirtualizowana ListClipperem, wiec
-- dziala plynnie nawet przy tysiacach wierszy). Zaprojektowane tak, zeby
-- podczas wlasciwego nagrywania realizator nie musial nic klikac poza wyborem
-- kolejnej kwestii - patrz panel "Teraz nagrywasz" i auto-przejscie po
-- nagraniu.
--
-- Tabela ma DYNAMICZNA liczbe kolumn: pierwsza to waski pasek statusu, druga
-- zawsze nazwa skryptu, ostatnia zawsze tresc kwestii, a miedzy nimi dowolna
-- liczba kolumn "wizualnych" (state.extra_labels/row.extras) - patrz
-- vosan_state.lua.
--
-- === Dlaczego nie ma tu BeginChild ========================================
-- Panele (kwestia, ustawienia) wygladaja na osobne "pudelka", ale NIE sa
-- zrobione przez ImGui_BeginChild. To API zmienilo miedzy ReaImGui 0.8 i 0.9
-- zarowno typ argumentu 'border' (bool -> bitowe ChildFlags), jak i regule
-- parowania z EndChild (warunkowe -> bezwarunkowe). Pomylka w ktorymkolwiek z
-- tych dwoch punktow zostawia kontekst ImGui w trwale uszkodzonym stanie -
-- dokladnie tak, jak opisano nizej przy ImGui_End. Uklad dwukolumnowy stoi
-- wiec na BeginTable (sprawdzone juz w tym pliku), a ramki paneli rysuje
-- DrawList PO narysowaniu tresci: obrys i pasek akcentu leza na krawedziach,
-- wiec nie zaslaniaja tekstu i nie wymagaja znajomosci wysokosci z gory.

local script_dir = (debug.getinfo(1, 'S').source:match([[^@?(.*[\/])[^\/]-$]])) or "./"
package.path = script_dir .. "?.lua;" .. package.path

local vosan_state = require("vosan_state")
local csv = require("vosan_csv")
local xlsx = require("vosan_xlsx")
local regions = require("vosan_regions")

local M = {}

-- === Kolory statusow (0xRRGGBBAA) =========================================
local COLOR_SELECTED = 0xFFB020FF
local COLOR_RECORDED = 0x50D070FF
local COLOR_WARNING  = 0xFF5050FF
local COLOR_DUPWARN  = 0xFFC050FF
local COLOR_DIM      = 0xAAAAAAFF -- podpowiedzi i komunikaty informacyjne
local COLOR_TARGET   = 0x4FA0E8FF -- kwestie aktualnie nagrywanej postaci (MC albo NPC)
-- Wiersze drugiej postaci sa tylko kontekstem rozmowy, wiec maja WLASNA,
-- ciemniejsza barwe zamiast COLOR_DIM: przy 0xAAAAAA konkurowaly wzrokowo z
-- kwestiami do nagrania. 0x6F7783 daje kontrast ok. 4:1 na tle okna, czyli
-- nadal da sie taka kwestie przeczytac, ale wzrok na niej nie zatrzymuje sie.
local COLOR_CONTEXT  = 0x6F7783FF

-- === Powierzchnie i tekst =================================================
local BG_WINDOW    = 0x0E1116FF
local BG_FRAME     = 0x151A21FF
local BG_TBL_HEAD  = 0x202730FF
local BG_ROW       = 0x10141AFF
local BG_ROW_ALT   = 0x141920FF
local BG_SELECTION = 0xFFB0201E -- pomaranczowy akcent na ok. 12% krycia
local BG_HOVER     = 0xFFFFFF12
local BORDER_SOFT  = 0x262C35FF
local TXT_MAIN     = 0xE6E9EEFF
local TXT_SECOND   = 0x8D97A4FF
local TXT_CUE      = 0xF4F7FAFF -- tresc kwestii w panelu "Teraz nagrywasz"
local TXT_REGION   = 0xFFD48AFF -- nazwa regionu (przygaszony pomaranczowy)
local BTN          = 0x26456BFF
local BTN_HOVER    = 0x33587FFF
local BTN_ACTIVE   = 0x1E3A5CFF
local BTN_PRIMARY  = 0x2F6FB0FF
local BTN_PRIM_HOV = 0x4287C9FF

local REGION_REFRESH_INTERVAL = 1.0 -- sekundy

-- === Czcionka dla tresci kwestii w panelu "Teraz nagrywasz" =================
-- CreateFont/PushFont zmienily sygnature miedzy ReaImGui <0.10 i >=0.10 (patrz
-- SetWindowFontScale - ktore w ogole nie istnieje w niektorych wersjach - to
-- byla wczesniejsza lekcja w tym projekcie). Probujemy obu wariantow API przy
-- starcie; jesli zaden nie zadziala, panel dziala dalej samym kolorem, bez
-- pogrubienia/powiekszenia - nigdy nie przerywa dzialania calego skryptu.
local CUE_FONT_SIZE = 26
local push_big_font = nil

function M.init_fonts(ctx)
  local font_v10 = nil
  local ok_v10 = pcall(function()
    font_v10 = reaper.ImGui_CreateFont('sans-serif', reaper.ImGui_FontFlags_Bold())
    reaper.ImGui_Attach(ctx, font_v10)
  end)
  if ok_v10 and font_v10 then
    push_big_font = function(c) reaper.ImGui_PushFont(c, font_v10, CUE_FONT_SIZE) end
    return
  end

  local font_legacy = nil
  local ok_legacy = pcall(function()
    font_legacy = reaper.ImGui_CreateFont('sans-serif', CUE_FONT_SIZE, reaper.ImGui_FontFlags_Bold())
    reaper.ImGui_Attach(ctx, font_legacy)
  end)
  if ok_legacy and font_legacy then
    push_big_font = function(c) reaper.ImGui_PushFont(c, font_legacy) end
    return
  end

  push_big_font = nil
end

-- === Drobne pomocniki tekstowe ============================================

--- Tekst zawijany (do komunikatow i tresci kwestii).
local function colored_text(ctx, color, text)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), color)
  reaper.ImGui_TextWrapped(ctx, text)
  reaper.ImGui_PopStyleColor(ctx)
end

--- Tekst NIEzawijany - do elementow ukladanych w linii przez SameLine, gdzie
--- zawijanie rozjechaloby caly wiersz.
local function colored_label(ctx, color, text)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), color)
  reaper.ImGui_Text(ctx, text)
  reaper.ImGui_PopStyleColor(ctx)
end

--- Wysokosc JEDNEJ linii czcionki panelu kwestii. Sluzy do zarezerwowania
--- stalego minimum wysokosci panelu - patrz draw_now_recording_panel.
local function cue_line_height(ctx)
  local pushed = false
  if push_big_font then
    pushed = pcall(push_big_font, ctx)
  end
  local ok, h = pcall(reaper.ImGui_GetTextLineHeight, ctx)
  if pushed then
    pcall(reaper.ImGui_PopFont, ctx)
  end
  if ok and h then return h end
  return nil
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

-- === Styl okna ============================================================
-- Kazde push jest liczone osobno i chronione pcall, bo nie wszystkie stale
-- Col_*/StyleVar_* istnieja w kazdej wersji ReaImGui. Zwracana liczba trafia
-- do PopStyleColor/PopStyleVar, wiec stos zawsze wraca do rownowagi - takze
-- wtedy, gdy czesc wpisow nie przeszla.

local function push_theme_colors(ctx)
  local n = 0
  local function col(fn, value)
    if type(fn) == "function" then
      local ok, id = pcall(fn)
      if ok and pcall(reaper.ImGui_PushStyleColor, ctx, id, value) then
        n = n + 1
      end
    end
  end

  col(reaper.ImGui_Col_WindowBg, BG_WINDOW)
  col(reaper.ImGui_Col_Text, TXT_MAIN)
  col(reaper.ImGui_Col_TextDisabled, COLOR_CONTEXT)
  col(reaper.ImGui_Col_Border, BORDER_SOFT)
  col(reaper.ImGui_Col_Separator, BORDER_SOFT)
  col(reaper.ImGui_Col_FrameBg, BG_FRAME)
  col(reaper.ImGui_Col_FrameBgHovered, 0x1B2129FF)
  col(reaper.ImGui_Col_FrameBgActive, 0x1F2731FF)
  col(reaper.ImGui_Col_Button, BTN)
  col(reaper.ImGui_Col_ButtonHovered, BTN_HOVER)
  col(reaper.ImGui_Col_ButtonActive, BTN_ACTIVE)
  col(reaper.ImGui_Col_Header, BG_SELECTION)
  col(reaper.ImGui_Col_HeaderHovered, BG_HOVER)
  col(reaper.ImGui_Col_HeaderActive, BG_SELECTION)
  col(reaper.ImGui_Col_TableHeaderBg, BG_TBL_HEAD)
  col(reaper.ImGui_Col_TableRowBg, BG_ROW)
  col(reaper.ImGui_Col_TableRowBgAlt, BG_ROW_ALT)
  col(reaper.ImGui_Col_TableBorderLight, BORDER_SOFT)
  col(reaper.ImGui_Col_TableBorderStrong, BORDER_SOFT)
  col(reaper.ImGui_Col_CheckMark, 0xFFFFFFFF)
  col(reaper.ImGui_Col_PlotHistogram, COLOR_RECORDED) -- wypelnienie ProgressBar

  return n
end

local function push_theme_vars(ctx)
  local n = 0
  local function var(fn, a, b)
    if type(fn) == "function" then
      local ok_id, id = pcall(fn)
      if not ok_id then return end
      local ok
      if b then
        ok = pcall(reaper.ImGui_PushStyleVar, ctx, id, a, b)
      else
        ok = pcall(reaper.ImGui_PushStyleVar, ctx, id, a)
      end
      if ok then n = n + 1 end
    end
  end

  var(reaper.ImGui_StyleVar_WindowPadding, 12, 12)
  var(reaper.ImGui_StyleVar_ItemSpacing, 8, 8)
  var(reaper.ImGui_StyleVar_FramePadding, 8, 5)
  -- Poziomo 6, a nie 10: przy 10 sama kolumna kropki statusu nie zeszlaby
  -- ponizej 20 px swiatla na padding, a chcemy ja miec tak waska, jak sie da.
  -- Pionowe 7 zostaje - to ono daje wierszowi tabeli oddech.
  var(reaper.ImGui_StyleVar_CellPadding, 6, 7)
  var(reaper.ImGui_StyleVar_FrameRounding, 3)
  var(reaper.ImGui_StyleVar_ScrollbarRounding, 3)

  return n
end

-- === Ramki paneli rysowane po tresci ======================================

local function get_draw_list(ctx)
  local ok, dl = pcall(reaper.ImGui_GetWindowDrawList, ctx)
  if ok then return dl end
  return nil
end

--- Zapamietuje lewy gorny rog i szerokosc obszaru, w ktorym za chwile
--- narysujemy tresc panelu.
local function block_begin(ctx)
  local x, y = reaper.ImGui_GetCursorScreenPos(ctx)
  local w = reaper.ImGui_GetContentRegionAvail(ctx)
  return { x = x, y = y, w = w or 0 }
end

--- Domyka panel: obrys wokol tresci i opcjonalny pionowy pasek akcentu przy
--- lewej krawedzi. Wywolywane PO tresci, bo dopiero wtedy znamy jej wysokosc.
local function block_end(ctx, dl, b, accent_color)
  if not dl or not b then return end
  local _, y1 = reaper.ImGui_GetCursorScreenPos(ctx)
  if not y1 or y1 <= b.y then return end
  local x1 = b.x + b.w
  pcall(reaper.ImGui_DrawList_AddRect, dl, b.x, b.y, x1, y1, BORDER_SOFT, 4)
  if accent_color then
    pcall(reaper.ImGui_DrawList_AddRectFilled, dl, b.x, b.y, b.x + 4, y1, accent_color, 0)
  end
end

--- Kolorowa kropka statusu wyrownana do srodka wiersza tekstu. Kolor tekstu
--- przestaje byc jedynym nosnikiem statusu.
local function status_dot(ctx, dl, color)
  local x, y = reaper.ImGui_GetCursorScreenPos(ctx)
  local h = 16
  local ok_h, line_h = pcall(reaper.ImGui_GetTextLineHeight, ctx)
  if ok_h and line_h then h = line_h end
  if dl and color then
    pcall(reaper.ImGui_DrawList_AddCircleFilled, dl, x + 4, y + h * 0.5, 4, color)
  end
  -- Kropka o srednicy 8 px zajmuje dokladnie tyle miejsca, ile rysuje - kazdy
  -- nadmiar tutaj to piksele odebrane kolumnie z nazwa postaci.
  reaper.ImGui_Dummy(ctx, 8, h)
end

--- Przesuwa kursor tak, zeby blok o szerokosci `block_w` zmiescil sie przy
--- PRAWEJ krawedzi tej samej linii. Zwraca true, gdy sie udalo.
---
--- Gdy miejsca brakuje, linia jest jawnie zamykana przez NewLine i funkcja
--- zwraca false. To NIE jest kosmetyka: samo SameLine bez narysowania czegos
--- po nim zostawia kursor w srodku linii, a kolejny element (u nas tabela)
--- dostaje wtedy z GetContentRegionAvail tylko resztke tej linii - i zamiast
--- calej szerokosci okna zajmuje waski pasek przy prawej krawedzi.
local function same_line_right(ctx, row_x, full_w, block_w)
  reaper.ImGui_SameLine(ctx)
  local target = row_x + full_w - block_w
  if target > reaper.ImGui_GetCursorPosX(ctx) then
    reaper.ImGui_SetCursorPosX(ctx, target)
    return true
  end
  pcall(reaper.ImGui_NewLine, ctx)
  return false
end

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

-- === Wczytywanie pliku ====================================================

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

--- Rozdziela sciezke na katalog i sama nazwe pliku. W pasku gornym nazwa jest
--- tym, czego realizator szuka wzrokiem; katalog schodzi na drugi plan.
local function split_path(path)
  local dir, name = path:match("^(.*)[\\/]([^\\/]+)$")
  if name then return dir, name end
  return nil, path
end

-- === Pasek gorny: plik + postep ===========================================

local function draw_file_controls(ctx, state)
  local row_x = reaper.ImGui_GetCursorPosX(ctx)
  local full_w = reaper.ImGui_GetContentRegionAvail(ctx) or 0

  if reaper.ImGui_Button(ctx, "Wczytaj plik (CSV / XLSX)...") then
    local ok, path = reaper.GetUserFileNameForRead("", "Wybierz plik ze skryptem dubbingowym", "")
    if ok then
      M.load_file(state, path)
    end
  end

  reaper.ImGui_SameLine(ctx)
  if state.loaded_file then
    local dir, name = split_path(state.loaded_file)
    colored_label(ctx, TXT_MAIN, name)
    if dir then
      reaper.ImGui_SameLine(ctx)
      colored_label(ctx, COLOR_CONTEXT, dir)
    end
  else
    colored_label(ctx, COLOR_CONTEXT, "Nie wczytano pliku")
  end

  -- Licznik pokazuje AKTUALNY ZAKRES (wybrana postac + MC/NPC), a nie caly
  -- plik - patrz vosan_state.refresh_target_counts.
  local total = state.target_total or 0
  if total > 0 then
    -- Postep przy prawej krawedzi; gdy sciezka pliku zajmie cala linie,
    -- same_line_right przenosi go do nowej zamiast wypychac poza okno.
    local file_total = #state.rows
    local narrowed = file_total > total
    same_line_right(ctx, row_x, full_w, narrowed and 420 or 300)

    local done = state.target_recorded or 0
    colored_label(ctx, TXT_SECOND, "Nagrano")
    reaper.ImGui_SameLine(ctx)
    local shown = pcall(reaper.ImGui_ProgressBar, ctx, done / total, 190, 14, "")
    if shown then
      reaper.ImGui_SameLine(ctx)
    end
    colored_label(ctx, done >= total and COLOR_RECORDED or TXT_MAIN, tostring(done))
    reaper.ImGui_SameLine(ctx, 0, 4)
    colored_label(ctx, TXT_SECOND, "/ " .. tostring(total))

    -- Gdy zakres jest wezszy niz plik, mowimy to wprost - inaczej "8 / 8" przy
    -- 12 wierszach na liscie wyglada jak blad licznika.
    if narrowed then
      reaper.ImGui_SameLine(ctx, 0, 8)
      colored_label(ctx, COLOR_CONTEXT, "(z " .. tostring(file_total) .. " w pliku)")
    end
  end

  if not state.loaded_file and state.last_file_suggestion then
    if reaper.ImGui_Button(ctx, "Wczytaj ostatnio uzywany plik z tego projektu") then
      M.load_file(state, state.last_file_suggestion)
    end
    reaper.ImGui_SameLine(ctx)
    colored_label(ctx, COLOR_DIM, state.last_file_suggestion)
  end
end

-- === Komunikaty ===========================================================
-- Kazdy komunikat dostaje pionowy pasek w swoim kolorze przy lewej krawedzi.
-- Sam kolorowy tekst gubil sie w scianie innych napisow.

local function draw_message(ctx, dl, color, text, dismiss_id, on_dismiss)
  local b = block_begin(ctx)
  reaper.ImGui_Dummy(ctx, 1, 2)
  reaper.ImGui_Indent(ctx, 12)
  colored_text(ctx, color, text)
  if dismiss_id then
    if reaper.ImGui_Button(ctx, dismiss_id) then
      on_dismiss()
    end
  end
  reaper.ImGui_Unindent(ctx, 12)
  reaper.ImGui_Dummy(ctx, 1, 2)
  block_end(ctx, dl, b, color)
end

local function draw_messages(ctx, state, dl)
  if state.load_error then
    draw_message(ctx, dl, COLOR_WARNING, "Blad wczytywania: " .. state.load_error)
  end

  if state.duplicates and #state.duplicates > 0 then
    draw_message(ctx, dl, COLOR_DUPWARN, string.format(
      "Uwaga: %d powtarzajacych sie nazw skryptow w pliku (retake zastapi region, wiec kolejne wystapienia nadpisza poprzednie).",
      #state.duplicates))
  end

  if state.last_warning then
    draw_message(ctx, dl, COLOR_WARNING, state.last_warning, "OK, rozumiem##dismiss_warning",
      function() state.last_warning = nil end)
  end

  if state.last_info then
    draw_message(ctx, dl, COLOR_TARGET, state.last_info, "OK##dismiss_info",
      function() state.last_info = nil end)
  end
end

-- === Panel "Teraz nagrywasz" ==============================================

local function draw_now_recording_panel(ctx, state, dl)
  local row = state.selected and state.rows[state.selected]

  local b = block_begin(ctx)
  reaper.ImGui_Dummy(ctx, 1, 3)
  reaper.ImGui_Indent(ctx, 14)

  -- Tresc kwestii jest zawijana wewnatrz panelu, wiec musi konczyc sie przed
  -- obrysem, a nie na krawedzi kolumny.
  local wrap_ok = pcall(reaper.ImGui_PushTextWrapPos, ctx,
    reaper.ImGui_GetCursorPosX(ctx) + math.max(b.w - 30, 80))

  if row then
    colored_label(ctx, COLOR_SELECTED, "TERAZ NAGRYWASZ")

    -- Kiedy wiersz jest wybrany, jego kolor w tabeli to pomaranczowy, wiec
    -- informacja "czy ta kwestia jest juz nagrana" znikala. Tutaj wraca.
    reaper.ImGui_SameLine(ctx, 0, 14)
    if row.recorded then
      colored_label(ctx, COLOR_RECORDED, "[ JUZ NAGRANA - ponowne nagranie zastapi region ]")
    else
      colored_label(ctx, COLOR_TARGET, "[ DO NAGRANIA ]")
    end

    -- Panel zajmuje cala szerokosc okna, wiec wiekszosc kwestii miesci sie w
    -- jednej linii, a dluzsze w dwoch. Bez rezerwacji minimum panel kurczylby
    -- sie i rosl przy kazdym auto-przejsciu, a razem z nim skakalaby cala
    -- tabela ponizej - i to w trakcie nagrywania, kiedy aktor na nia patrzy.
    local _, y_before = reaper.ImGui_GetCursorScreenPos(ctx)
    draw_bold_big(ctx, TXT_CUE, row.text ~= "" and row.text or "(brak tresci)")
    local _, y_after = reaper.ImGui_GetCursorScreenPos(ctx)

    local line_h = cue_line_height(ctx)
    if line_h then
      local deficit = (2 * line_h) - (y_after - y_before)
      if deficit > 0 then
        reaper.ImGui_Dummy(ctx, 1, deficit)
      end
    end

    colored_label(ctx, TXT_SECOND, "Region:")
    reaper.ImGui_SameLine(ctx, 0, 6)
    colored_label(ctx, TXT_REGION,
      row.script_name_safe ~= "" and row.script_name_safe or "(BRAK NAZWY!)")

    local first_extra = true
    for i, label in ipairs(state.extra_labels or {}) do
      if not state.hidden_columns[label] then
        local val = row.extras[i]
        if val and val ~= "" then
          if first_extra then
            first_extra = false
          else
            reaper.ImGui_SameLine(ctx, 0, 18)
          end
          colored_label(ctx, TXT_SECOND, label)
          reaper.ImGui_SameLine(ctx, 0, 6)
          colored_label(ctx, TXT_MAIN, val)
        end
      end
    end

    if state.mc_column_index and not vosan_state.row_matches_target(state, row) then
      colored_text(ctx, COLOR_DUPWARN,
        "Uwaga: ta kwestia nalezy do drugiej postaci w arkuszu (kontekst rozmowy), nie do aktualnie nagrywanej.")
    end
  else
    colored_label(ctx, COLOR_SELECTED, "TERAZ NAGRYWASZ")
    colored_text(ctx, COLOR_DIM, "Brak wybranej kwestii - kliknij wiersz w tabeli ponizej.")
  end

  if wrap_ok then
    pcall(reaper.ImGui_PopTextWrapPos, ctx)
  end

  reaper.ImGui_Unindent(ctx, 14)
  reaper.ImGui_Dummy(ctx, 1, 3)
  block_end(ctx, dl, b, COLOR_SELECTED)
end

-- === Kolumna ustawien sesji ===============================================

--- Przelacznik "kogo nagrywamy" - ten sam boolean state.recording_mc co
--- dotychczasowy checkbox, tylko pokazany jako dwa przyleglee przyciski.
--- Prawa etykieta bierze sie z naglowka kolumny MC w pliku (w produkcyjnym
--- arkuszu to "MARVIN"), wiec nie zaklada niczego o nazwie bohatera.
local function draw_mc_switch(ctx, state)
  local mc_label = "MC"
  if state.extra_labels and state.mc_column_index then
    local l = state.extra_labels[state.mc_column_index]
    if l and l ~= "" then mc_label = l end
  end

  colored_label(ctx, TXT_SECOND, "Nagrywam:")
  reaper.ImGui_SameLine(ctx)

  local function segment(caption, is_active, value)
    local pushed = 0
    if is_active then
      if pcall(reaper.ImGui_PushStyleColor, ctx, reaper.ImGui_Col_Button(), BTN_PRIMARY) then
        pushed = pushed + 1
      end
      if pcall(reaper.ImGui_PushStyleColor, ctx, reaper.ImGui_Col_ButtonHovered(), BTN_PRIM_HOV) then
        pushed = pushed + 1
      end
      if pcall(reaper.ImGui_PushStyleColor, ctx, reaper.ImGui_Col_ButtonActive(), BTN_PRIMARY) then
        pushed = pushed + 1
      end
    end
    if reaper.ImGui_Button(ctx, caption) then
      state.recording_mc = value
      -- Zmiana zakresu nie rusza regionow, wiec liczniki trzeba przeliczyc tu.
      vosan_state.refresh_target_counts(state)
    end
    if pushed > 0 then
      reaper.ImGui_PopStyleColor(ctx, pushed)
    end
  end

  segment("NPC##rec_npc", not state.recording_mc, false)
  reaper.ImGui_SameLine(ctx, 0, 0)
  segment(mc_label .. "##rec_mc", state.recording_mc, true)
end

--- Ustawienia sesji: pasek na CALA szerokosc okna, pod panelem kwestii, do
--- zwiniecia naglowkiem. To sekcja "ustaw raz i zapomnij", wiec podczas
--- samego nagrywania realizator moze ja schowac - ImGui pamieta stan
--- zwiniecia miedzy uruchomieniami skryptu.
--- Trzy grupy obok siebie stoja na BeginTable, bo kazda ma inna liczbe
--- wierszy, a tabela sama je wyrowna.
local function draw_settings_panel(ctx, state)
  -- Col_Header jest globalnie przestawiony na pomaranczowy akcent zaznaczenia
  -- wiersza w tabeli. Naglowek sekcji ma byc neutralny, wiec na czas jego
  -- narysowania podmieniamy te trzy kolory lokalnie.
  local n_col = 0
  local function hcol(fn, value)
    if type(fn) == "function" then
      local ok, id = pcall(fn)
      if ok and pcall(reaper.ImGui_PushStyleColor, ctx, id, value) then
        n_col = n_col + 1
      end
    end
  end
  hcol(reaper.ImGui_Col_Header, BG_TBL_HEAD)
  hcol(reaper.ImGui_Col_HeaderHovered, 0x2A323CFF)
  hcol(reaper.ImGui_Col_HeaderActive, BG_TBL_HEAD)

  local header_flags = 0
  local ok_flag, default_open = pcall(reaper.ImGui_TreeNodeFlags_DefaultOpen)
  if ok_flag and default_open then header_flags = default_open end

  local ok_header, open = pcall(reaper.ImGui_CollapsingHeader, ctx,
    "USTAWIENIA SESJI##vosan_settings", nil, header_flags)

  if n_col > 0 then
    reaper.ImGui_PopStyleColor(ctx, n_col)
  end

  -- Gdyby ta wersja ReaImGui nie miala CollapsingHeader, pokazujemy ustawienia
  -- na stale - lepiej to, niz schowac je bez mozliwosci rozwiniecia.
  if not ok_header then open = true end
  if not open then return end

  -- Ciasniejszy odstep pionowy TYLKO w tej sekcji: to gestwina checkboxow,
  -- ktora przy globalnych 8 px rozlazi sie na wysokosc.
  local n_var = 0
  local ok_sp, spacing_id = pcall(reaper.ImGui_StyleVar_ItemSpacing)
  if ok_sp and pcall(reaper.ImGui_PushStyleVar, ctx, spacing_id, 8, 5) then
    n_var = 1
  end

  reaper.ImGui_Indent(ctx, 8)

  if reaper.ImGui_BeginTable(ctx, "vosan_settings", 3,
    reaper.ImGui_TableFlags_SizingStretchProp()) then

    reaper.ImGui_TableNextRow(ctx)

    -- --- Grupa 1: co sie dzieje po nagraniu ---------------------------------
    reaper.ImGui_TableNextColumn(ctx)

    local ch1, v1 = reaper.ImGui_Checkbox(ctx, "Auto-przejscie do nastepnej kwestii", state.auto_advance)
    if ch1 then state.auto_advance = v1 end

    local ch4, v4 = reaper.ImGui_Checkbox(ctx, "Przesun kursor po nagraniu", state.auto_move_cursor)
    if ch4 then state.auto_move_cursor = v4 end

    if state.auto_move_cursor then
      -- W tej samej linii co checkbox, ktorego dotyczy - osobny wiersz pod
      -- spodem kosztowal cala wysokosc sekcji, bo to najwyzsza z trzech grup.
      reaper.ImGui_SameLine(ctx, 0, 14)
      colored_label(ctx, TXT_SECOND, "Odstep")
      reaper.ImGui_SameLine(ctx)
      reaper.ImGui_SetNextItemWidth(ctx, 68)
      -- InputDouble/DragDouble sa w ReaImGui niepewne co do wersji (patrz
      -- historia problemow z fontami w tym pliku) - InputText jest juz
      -- sprawdzone w tym projekcie, wiec bezpieczniej sparsowac liczbe recznie.
      -- Do widgetu wraca DOKLADNIE to, co zwrocil poprzednio. Podawanie tu
      -- string.format("%.2f", ...) nadpisywalo pole w trakcie pisania: wpisanie
      -- "0,755" bylo zaokraglane do "0.76" jeszcze przed koncem edycji.
      local ch5, v5 = reaper.ImGui_InputText(ctx, "##post_record_gap", state.post_record_gap_text)
      if ch5 then
        state.post_record_gap_text = v5
        local n = tonumber((v5:gsub(",", ".")))
        if n and n >= 0 then
          state.post_record_gap = n
        end
      end
      reaper.ImGui_SameLine(ctx)
      colored_label(ctx, TXT_SECOND, "sekundy")
    end

    -- --- Grupa 2: kogo nagrywamy --------------------------------------------
    reaper.ImGui_TableNextColumn(ctx)

    if state.mc_column_index then
      draw_mc_switch(ctx, state)
    end

    local ch2, v2 = reaper.ImGui_Checkbox(ctx, "Pierwszy wiersz to naglowek", state.skip_header)
    if ch2 then
      state.skip_header = v2
      if state.raw_rows then
        vosan_state.load_rows(state, state.raw_rows, state.skip_header)
      end
    end

    -- --- Grupa 3: widocznosc kolumn -----------------------------------------
    -- Checkboxy widocznosci dla kolumn "srodkowych" (nazwa skryptu i tresc
    -- kwestii sa zawsze widoczne - to kolumny strukturalne, nie informacyjne).
    -- Wybor jest per-etykieta i przetrwa przeladowanie pliku w tej samej sesji.
    reaper.ImGui_TableNextColumn(ctx)

    local labels = state.extra_labels or {}
    if #labels > 0 then
      colored_label(ctx, TXT_SECOND, "Pokaz kolumny:")
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

    reaper.ImGui_EndTable(ctx)
  end

  reaper.ImGui_Unindent(ctx, 8)
  if n_var > 0 then
    pcall(reaper.ImGui_PopStyleVar, ctx, n_var)
  end
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

-- === Pasek roboczy: szukaj / postac / render / legenda ====================

local function legend_item(ctx, dl, color, label)
  status_dot(ctx, dl, color)
  reaper.ImGui_SameLine(ctx, 0, 5)
  colored_label(ctx, TXT_SECOND, label)
  reaper.ImGui_SameLine(ctx, 0, 16)
end

local function draw_filter_controls(ctx, state, dl)
  local row_x = reaper.ImGui_GetCursorPosX(ctx)
  local full_w = reaper.ImGui_GetContentRegionAvail(ctx) or 0

  local has_character = state.character_col_index
    and state.available_characters and #state.available_characters > 0
  local has_render = has_character and state.current_character ~= "Wszystkie"

  -- Pola nie moga dorosnac do legendy po prawej stronie - inaczej combo
  -- "Postac" konczy sie dopiero przy krawedzi okna i legenda spada do nowej
  -- linii. Budzet to szerokosc okna minus pas zarezerwowany na legende.
  local LABELS_W = 130   -- "Szukaj:" + "Postac:" + odstepy miedzy elementami
  local RENDER_W = 290   -- przycisk "Wyrenderuj nagrania tej postaci"
  local LEGEND_BLOCK = 400
  local usable = math.max(full_w - LEGEND_BLOCK - 20, 240)
  local budget = usable - LABELS_W - (has_render and RENDER_W or 0)
  local search_w = clamp(budget * 0.45, 110, 320)
  local combo_w  = clamp(budget * 0.55, 130, 360)

  colored_label(ctx, TXT_SECOND, "Szukaj:")
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_SetNextItemWidth(ctx, search_w)
  local changed, new_val = reaper.ImGui_InputText(ctx, "##vosan_search", state.filter_text or "")
  if changed then
    state.filter_text = new_val
    vosan_state.refresh_filter(state)
    -- Filtr przestawia pozycje wierszy, wiec poprzednio wyliczone przewiniecie
    -- juz nie pasuje - wymuszamy ponowne dojechanie do wybranej kwestii.
    state._scrolled_to = nil
  end

  if has_character then
    reaper.ImGui_SameLine(ctx, 0, 14)
    colored_label(ctx, TXT_SECOND, "Postac:")
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_SetNextItemWidth(ctx, combo_w)
    if reaper.ImGui_BeginCombo(ctx, "##vosan_character", state.current_character) then
      for _, char_name in ipairs(state.available_characters) do
        local is_selected = (state.current_character == char_name)
        if reaper.ImGui_Selectable(ctx, char_name, is_selected) then
          state.current_character = char_name
          vosan_state.refresh_target_counts(state)
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

    if has_render then
      reaper.ImGui_SameLine(ctx)
      local pushed = 0
      if pcall(reaper.ImGui_PushStyleColor, ctx, reaper.ImGui_Col_Button(), BTN_PRIMARY) then
        pushed = pushed + 1
      end
      if pcall(reaper.ImGui_PushStyleColor, ctx, reaper.ImGui_Col_ButtonHovered(), BTN_PRIM_HOV) then
        pushed = pushed + 1
      end
      local render_clicked = reaper.ImGui_Button(ctx, "Wyrenderuj nagrania tej postaci")
      if pushed > 0 then
        reaper.ImGui_PopStyleColor(ctx, pushed)
      end
      if render_clicked then
        prepare_character_render(state)
      end
    end
  end

  -- Legenda wyrownana do prawej. Kolory statusow same z siebie nic nie mowia,
  -- dopoki realizator ich nie pozna - jedna linijka to zalatwia.
  if #state.rows > 0 then
    -- Legenda idzie przy prawej krawedzi. Gdy sie nie miesci, same_line_right
    -- zamyka linie i legenda laduje w nastepnej - zawsze cos rysujemy, wiec
    -- tabela ponizej dostaje pelna szerokosc okna.
    same_line_right(ctx, row_x, full_w, LEGEND_BLOCK)
    legend_item(ctx, dl, COLOR_SELECTED, "wybrana")
    legend_item(ctx, dl, COLOR_RECORDED, "nagrana")
    legend_item(ctx, dl, COLOR_TARGET, "do nagrania")
    status_dot(ctx, dl, COLOR_CONTEXT)
    reaper.ImGui_SameLine(ctx, 0, 5)
    colored_label(ctx, TXT_SECOND, "kontekst")
  end
end

-- === Tabela kwestii =======================================================

local function draw_table(ctx, state, dl)
  if #state.rows == 0 then
    colored_text(ctx, COLOR_DIM, "Wczytaj plik CSV lub XLSX, zeby zobaczyc liste kwestii.")
    return
  end

  local extra_labels = state.extra_labels or {}
  -- indeksy kolumn srodkowych, ktore NIE sa ukryte (patrz draw_settings_panel)
  local visible_extras = {}
  for i, label in ipairs(extra_labels) do
    if not state.hidden_columns[label] then
      visible_extras[#visible_extras + 1] = i
    end
  end
  local n_cols = 3 + #visible_extras -- status + nazwa skryptu + kolumny srodkowe + tresc

  local avail_w, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
  local table_flags = reaper.ImGui_TableFlags_Resizable()
    | reaper.ImGui_TableFlags_ScrollY()
    | reaper.ImGui_TableFlags_RowBg()
    | reaper.ImGui_TableFlags_BordersInnerV()
    | reaper.ImGui_TableFlags_SizingStretchProp()

  -- Czy kolumna z nazwa postaci jest w ogole widoczna - od tego zalezy, czy
  -- nazwa skryptu dzieli sie z nia szerokoscia, czy bierze cala.
  local char_visible = false
  for _, i in ipairs(visible_extras) do
    if i == state.character_col_index then char_visible = true end
  end

  -- UWAGA: ID tabeli MUSI sie zmienic przy KAZDEJ zmianie ukladu kolumn - i to
  -- dotyczy tak samo szerokosci w pikselach, jak i wag rozciagania ponizej.
  -- ImGui zapisuje jedno i drugie pod ID tabeli i przywraca PO INDEKSIE, wiec
  -- wartosci z kodu sa wtedy po prostu ignorowane. Tak wlasnie przepadl
  -- pierwszy uklad: po dolozeniu kolumny statusu na poczatek stare szerokosci
  -- przesunely sie o jedno pole i kropka odziedziczyla 220 px po "Nazwie
  -- skryptu". Kolejna zmiana wag = kolejny numer w ID.
  if reaper.ImGui_BeginTable(ctx, "vosan_table_v3", n_cols, table_flags, avail_w, avail_h) then
    local fixed = reaper.ImGui_TableColumnFlags_WidthFixed()

    -- Kolumny rozciagliwe dziela sie wolna szerokoscia proporcjonalnie do wagi.
    -- Dzieki wagom (zamiast pikseli) podzial trzyma sie przy kazdej szerokosci
    -- okna.
    --
    -- Nazwa skryptu i nazwa postaci po rowno: przy 20/80 postac dostawala
    -- ok. 477 px na wartosc dlugosci 26 znakow, a nazwa skryptu - dluzsza,
    -- bo 36-znakowa - dusila sie na 119 px.
    local W_NAME, W_CHAR, W_TEXT = 0.5, 0.5, 1.5

    -- 20 px = kropka (8) + poziomy CellPadding z obu stron (2 x 6).
    reaper.ImGui_TableSetupColumn(ctx, "##status", fixed, 20)
    reaper.ImGui_TableSetupColumn(ctx, "Nazwa skryptu", 0, char_visible and W_NAME or (W_NAME + W_CHAR))
    for _, i in ipairs(visible_extras) do
      if i == state.character_col_index then
        reaper.ImGui_TableSetupColumn(ctx, extra_labels[i], 0, W_CHAR)
      elseif i == state.mc_column_index then
        -- Kolumna MC trzyma "Tak"/"Nie", wiec staly, waski slupek wystarcza.
        reaper.ImGui_TableSetupColumn(ctx, extra_labels[i], fixed, 80)
      else
        reaper.ImGui_TableSetupColumn(ctx, extra_labels[i], fixed, 190)
      end
    end
    reaper.ImGui_TableSetupColumn(ctx, "Tresc kwestii", 0, W_TEXT)
    reaper.ImGui_TableSetupScrollFreeze(ctx, 0, 1)
    reaper.ImGui_TableHeadersRow(ctx)

    if not reaper.ImGui_ValidatePtr(state._clipper, 'ImGui_ListClipper*') then
      state._clipper = reaper.ImGui_CreateListClipper(ctx)
    end
    local clipper = state._clipper
    local filtered = state.filtered
    local span_flag = reaper.ImGui_SelectableFlags_SpanAllColumns()

    -- === Auto-przewijanie do wybranej kwestii ==============================
    -- Po auto-przejsciu (select_next) wybor potrafi wyladowac ponizej
    -- widocznego zakresu, a pasek przewijania zostaje na miejscu - aktor traci
    -- swoja kwestie z oczu. Przewijamy TYLKO wtedy, gdy wybor faktycznie
    -- wypadl poza widok, zeby nie odbierac realizatorowi recznego przewijania.
    --
    -- Wysokosc wiersza jest MIERZONA (patrz nizej), a nie zakladana: zalezy od
    -- CellPadding i wysokosci linii tekstu, wiec liczenie jej z gory
    -- rozjechaloby sie przy kazdej zmianie stylu albo skali interfejsu.
    if state.selected ~= state._scrolled_to then
      local row_h = state._row_h
      if row_h and row_h > 0 then
        local pos = nil
        for i = 1, #filtered do
          if filtered[i] == state.selected then
            pos = i
            break
          end
        end

        if pos then
          local top = (pos - 1) * row_h
          local ok_scroll, scroll = pcall(reaper.ImGui_GetScrollY, ctx)
          -- Widoczna wysokosc to wysokosc tabeli minus wiersz naglowka.
          local view = math.max((avail_h or 0) - row_h, row_h)
          if ok_scroll and scroll then
            if top < scroll then
              pcall(reaper.ImGui_SetScrollY, ctx, math.max(top - row_h, 0))
            elseif top + row_h > scroll + view then
              -- Zostawiamy jeden wiersz zapasu pod spodem, zeby bylo widac,
              -- co bedzie nastepne.
              pcall(reaper.ImGui_SetScrollY, ctx, top + 2 * row_h - view)
            end
          end
        end
        state._scrolled_to = state.selected
      end
    end

    -- Dwa kolejne wiersze wystarcza, zeby zmierzyc skok pionowy miedzy nimi.
    local probe_y1, probe_y2 = nil, nil

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
          -- drugiej postaci w arkuszu, tylko kontekst (ciemnoszary).
          local color = nil
          if idx == state.selected then
            color = COLOR_SELECTED
          elseif row.recorded then
            color = COLOR_RECORDED
          elseif state.mc_column_index then
            color = vosan_state.row_matches_target(state, row) and COLOR_TARGET or COLOR_CONTEXT
          end

          -- Kropka statusu pokazuje "nagrana" niezaleznie od tego, czy wiersz
          -- jest akurat wybrany - kolor tekstu tej informacji nie unosil.
          local dot_color = color
          if row.recorded then
            dot_color = COLOR_RECORDED
          end

          reaper.ImGui_TableNextColumn(ctx)
          if probe_y2 == nil then
            local _, probe_y = reaper.ImGui_GetCursorScreenPos(ctx)
            if probe_y1 == nil then probe_y1 = probe_y else probe_y2 = probe_y end
          end
          status_dot(ctx, dl, dot_color)

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
            local val = row.extras[i] or ""
            if i == state.mc_column_index and val ~= "" then
              -- Krotka wartosc w waskiej kolumnie czyta sie lepiej wysrodkowana.
              local cell_w = reaper.ImGui_GetContentRegionAvail(ctx)
              local ok_w, text_w = pcall(reaper.ImGui_CalcTextSize, ctx, val)
              if ok_w and text_w and cell_w and text_w < cell_w then
                reaper.ImGui_SetCursorPosX(ctx,
                  reaper.ImGui_GetCursorPosX(ctx) + (cell_w - text_w) * 0.5)
              end
            end
            colored_label(ctx, TXT_SECOND, val)
          end

          reaper.ImGui_TableNextColumn(ctx)
          if color then reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), color) end
          reaper.ImGui_Text(ctx, row.text)
          if color then reaper.ImGui_PopStyleColor(ctx) end
        end
      end
    end

    if probe_y1 and probe_y2 and probe_y2 > probe_y1 then
      state._row_h = probe_y2 - probe_y1
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

  local dl = get_draw_list(ctx)

  draw_file_controls(ctx, state)
  draw_messages(ctx, state, dl)
  draw_now_recording_panel(ctx, state, dl)
  draw_settings_panel(ctx, state)
  draw_filter_controls(ctx, state, dl)
  draw_table(ctx, state, dl)
end

--- Rysuje jedna klatke okna. Zwraca `open` (false gdy realizator zamknal okno).
--- ImGui_End MUSI byc wywolane zawsze, gdy ImGui_Begin sie powiodl - takze
--- wtedy, gdy rysowanie zawartosci (draw_contents) rzuci blad w trakcie.
--- Pominiecie End() zostawia caly kontekst ReaImGui w trwale uszkodzonym
--- stanie ("Missing End()") az do ponownego uruchomienia skryptu, dlatego
--- Begin/draw_contents sa owiniete w pcall, a End wywolywane jest osobno,
--- bezwarunkowo, jesli tylko Begin zdazyl sie wykonac.
---
--- Ta sama zasada dotyczy stylu: PushStyleVar musi zajsc PRZED Begin (inaczej
--- WindowPadding nie zadziala na to okno), a odpowiadajace mu Pop - po End,
--- bezwarunkowo. Liczby pushy sa liczone, bo czesc stalych Col_*/StyleVar_*
--- moze nie istniec w danej wersji ReaImGui.
function M.frame(ctx, state)
  local n_vars = push_theme_vars(ctx)
  local n_cols = push_theme_colors(ctx)

  local began = false
  local open = true

  local ok, err = pcall(function()
    reaper.ImGui_SetNextWindowSize(ctx, 1240, 820, reaper.ImGui_Cond_FirstUseEver())
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

  if n_cols > 0 then
    pcall(reaper.ImGui_PopStyleColor, ctx, n_cols)
  end
  if n_vars > 0 then
    pcall(reaper.ImGui_PopStyleVar, ctx, n_vars)
  end

  if not ok then
    error(err, 0)
  end

  return open
end

return M
