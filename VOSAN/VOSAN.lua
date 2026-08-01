-- VOSAN.lua - Voice Over Script Auto Namer
-- Entry point uruchamiany jako akcja REAPER. Wczytuje moduly, sprawdza
-- obecnosc ReaImGui i uruchamia glowna petle (reaper.defer), ktora co klatke:
--   1) sprawdza czy w tle wlasnie zakonczylo sie nagrywanie (vosan_recorder),
--      a jesli tak - tworzy/zastepuje region nazwany wybrana kwestia,
--   2) rysuje okno z lista kwestii (vosan_ui).
--
-- Cala logika biznesowa siedzi w modulach vosan_*.lua w tym samym folderze;
-- ten plik jest wylacznie "klejem" spinajacym je w dzialajacy skrypt.

local info = debug.getinfo(1, 'S')
local script_path = info.source:match([[^@?(.*[\/])[^\/]-$]]) or "./"
package.path = script_path .. "?.lua;" .. package.path

if not reaper.APIExists('ImGui_CreateContext') then
  reaper.ShowMessageBox(
    "Ten skrypt wymaga wtyczki ReaImGui.\n\n" ..
    "Zainstaluj ja przez: Extensions > ReaPack > Browse packages,\n" ..
    "wpisz \"ReaImGui\", zainstaluj pakiet \"ReaImGui: ReaScript binding for Dear ImGui\",\n" ..
    "a nastepnie zrestartuj REAPER i uruchom skrypt ponownie.\n\n" ..
    "Jesli w menu Extensions nie ma ReaPack, zainstaluj go najpierw z reapack.com.",
    "VOSAN - brakujaca wtyczka", 0)
  return
end

local vosan_state = require("vosan_state")
local regions = require("vosan_regions")
local recorder = require("vosan_recorder")
local ui = require("vosan_ui")

local state = vosan_state.new()

do
  local _, last_file = reaper.GetProjExtState(0, "VOSAN", "last_file")
  if last_file and last_file ~= "" then
    state.last_file_suggestion = last_file
  end
end

local ctx = reaper.ImGui_CreateContext('VOSAN - Voice Over Script Auto Namer')

-- Tworzenie/dolaczanie fontow musi sie odbyc raz, PRZED petla defer (patrz
-- komentarz w vosan_ui.lua) - pcall wewnatrz init_fonts chroni przed roznicami
-- w API miedzy wersjami ReaImGui, wiec brak fontu nie przerywa startu skryptu.
pcall(ui.init_fonts, ctx)

local function on_recording_finished(start_pos, end_pos)
  local recorded_row = state.selected and state.rows[state.selected]
  local name

  if recorded_row and recorded_row.script_name_safe ~= "" then
    name = recorded_row.script_name_safe
  elseif recorded_row then
    name = "NIEPRZYPISANE_" .. os.date("%Y%m%d_%H%M%S")
    state.last_warning = "Wybrana kwestia nie ma nazwy skryptu - region nazwano '" .. name ..
      "'. Popraw nazwe regionu recznie w REAPERze."
  else
    name = "NIEPRZYPISANE_" .. os.date("%Y%m%d_%H%M%S")
    state.last_warning = "Nie wybrano zadnej kwestii przed nagraniem - region nazwano '" .. name ..
      "'. Zaznacz wlasciwy wiersz i popraw nazwe regionu recznie."
  end

  regions.create_or_replace_region(name, start_pos, end_pos)
  state.regions_dirty = true

  if recorded_row and recorded_row.script_name_safe ~= "" and state.auto_advance then
    vosan_state.select_next(state)
  end
end

-- Jesli ten sam blad powtarza sie klatka po klatce (np. ReaImGui nie moze
-- zainicjowac klatki z powodu niezgodnosci silnika graficznego/HiDPI),
-- petla NIE MOZE probowac dalej w nieskonczonosc - zasypalaby realizatora
-- oknem bledu 30-60x/s. Po kilku powtorkach zatrzymujemy skrypt i pokazujemy
-- JEDEN czytelny komunikat zamiast spamu.
local MAX_CONSECUTIVE_UI_ERRORS = 5
local MAX_CONSECUTIVE_REC_ERRORS = 10
local consecutive_ui_errors = 0
local consecutive_rec_errors = 0

local function loop()
  local ok_rec, err_rec = pcall(recorder.poll, on_recording_finished)
  if not ok_rec then
    consecutive_rec_errors = consecutive_rec_errors + 1
    reaper.ShowConsoleMsg("VOSAN blad (recorder): " .. tostring(err_rec) .. "\n")
    if consecutive_rec_errors >= MAX_CONSECUTIVE_REC_ERRORS then
      reaper.ShowMessageBox(
        "VOSAN zatrzymal watcher nagrywania po " .. MAX_CONSECUTIVE_REC_ERRORS ..
        " kolejnych bledach.\n\nOstatni blad:\n" .. tostring(err_rec),
        "VOSAN - watcher nagrywania zatrzymany", 0)
      return
    end
  else
    consecutive_rec_errors = 0
  end

  local open = true
  local ok_ui, result = pcall(ui.frame, ctx, state)
  if not ok_ui then
    consecutive_ui_errors = consecutive_ui_errors + 1
    reaper.ShowConsoleMsg("VOSAN blad (ui): " .. tostring(result) .. "\n")
    if consecutive_ui_errors >= MAX_CONSECUTIVE_UI_ERRORS then
      reaper.ShowMessageBox(
        "VOSAN nie moze narysowac okna i zostal zatrzymany, zeby nie pokazywac\n" ..
        "tego samego bledu w kolko.\n\n" ..
        "Ostatni blad:\n" .. tostring(result) .. "\n\n" ..
        "Najczestsza przyczyna: niezgodnosc silnika graficznego ReaImGui z\n" ..
        "ustawieniami HiDPI. Sprobuj:\n" ..
        "  - Preferences > General > Advanced UI/system settings >\n" ..
        "    ustaw tryb HiDPI na \"Multimonitor aware v2\",\n" ..
        "  - albo Preferences > Plug-ins > ReaImGui > wybierz inny renderer.\n" ..
        "Po zmianie ustawien zrestartuj REAPER i uruchom VOSAN ponownie.",
        "VOSAN - okno zatrzymane", 0)
      return
    end
  else
    consecutive_ui_errors = 0
    open = result
  end

  if open then
    reaper.defer(loop)
  end
end

reaper.defer(loop)
