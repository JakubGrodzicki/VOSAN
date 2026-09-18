-- vosan_scroll.lua
-- Matematyka auto-przewijania tabeli kwestii, wydzielona z vosan_ui.lua zeby
-- dalo sie ja przetestowac bez ReaImGui (patrz tests/test_scroll.lua).
--
-- Wczesniejsza wersja (bezposrednio w vosan_ui.lua) dosuwala wybrany wiersz
-- do krawedzi widoku: gdy wypadl ponizej, cel liczyl sie jako
-- `top + 2*row_h - view`, czyli wiersz nizej z jednym wierszem zapasu pod
-- spodem. Przy auto-przejsciu, ktore naraz omija kilka nagranych kwestii
-- (state.skip_recorded w vosan_state.select_next), ten wzor potrafil policzyc
-- wartosc WYZSZA niz ScrollMaxY. ReaImGui przycina taki scroll do samego dolu
-- tabeli - dla realizatora wygladalo to jak przypadkowy skok na koniec listy
-- zamiast plynnego podazania za wyborem, mimo ze wybrana kwestia mogla byc w
-- srodku listy. Centrowanie wybranego wiersza w widoku (zamiast dosuwania do
-- krawedzi) daje wynik zawsze bliski `top`, wiec ten sam wzorzec przycinania
-- juz nie przenosi widoku daleko od wyboru.

local M = {}

--- Zwraca docelowa wartosc ScrollY, ktora wysrodkowuje wiersz [top, top+row_h)
--- w widoku o wysokosci `view`, zaczynajacym sie od biezacego `scroll`.
--- Zwraca nil, gdy wiersz jest juz w calosci widoczny - realizator moze wtedy
--- swobodnie przewijac recznie, bez odbierania mu widoku przy kazdej klatce.
---
--- `max_scroll` (ScrollMaxY) jest opcjonalny: bez niego funkcja pilnuje tylko,
--- zeby wynik nie byl ujemny. Z nim wynik jest dodatkowo przyciety od gory,
--- zeby wiersz blisko konca listy nie liczyl scrolla "za tabele" (to i tak
--- przycialoby ReaImGui, ale wtedy bez gwarancji, ze wynik zostaje wysrodkowany
--- najlepiej jak sie da przy danym max_scroll).
function M.compute_scroll_target(top, row_h, view, scroll, max_scroll)
  if top >= scroll and top + row_h <= scroll + view then
    return nil
  end

  local target = top - (view - row_h) * 0.5
  if target < 0 then
    target = 0
  end
  if max_scroll and target > max_scroll then
    target = max_scroll
  end
  return target
end

return M
