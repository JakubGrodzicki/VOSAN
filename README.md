# VOSAN — Voice Over Script Auto Namer

VOSAN to skrypt dla programu REAPER. Skrypt automatycznie nazywa nagrania dubbingowe. VOSAN tworzy nazwane regiony na osi czasu podczas nagrywania.

Proces pracy:
1. Wybierz kwestię z listy w oknie VOSAN.
2. Rozpocznij nagrywanie za pomocą standardowego transportu w REAPERze.
3. Zakończ nagrywanie.
4. VOSAN automatycznie wykryje koniec nagrania.
5. VOSAN utworzy region wokół nagranego obiektu.
6. VOSAN nada regionowi nazwę wybranej kwestii.

Po zakończonej sesji wyeksportuj pliki audio. Przycisk „Wyrenderuj nagrania tej postaci” przygotuje render wsadowy jednym kliknięciem.

## Format pliku wejściowego

VOSAN obsługuje pliki w formacie CSV oraz XLSX.

> **Kluczowa zasada:**
> - **Pierwsza kolumna to ZAWSZE nazwa skryptu.**
> - **Ostatnia kolumna to ZAWSZE tekst kwestii.**
> Zasada ta obowiązuje niezależnie od liczby kolumn oraz obecności nagłówka w pliku.

Struktura kolumn w pliku:

1. **Pierwsza kolumna (wymagana):** Zawiera nazwę skryptu. VOSAN używa tej wartości jako nazwy tworzonego regionu.
2. **Ostatnia kolumna (wymagana):** Zawiera tekst kwestii dubbingowej.
3. **Kolumny środkowe (opcjonalne):** Mogą zawierać dowolne dane pomocnicze (np. nazwę pliku źródłowego lub oznaczenie postaci). VOSAN wyświetla je w tabeli oraz w panelu „Teraz nagrywasz”.

Plik może zawierać dwie kolumny (nazwa i tekst) lub więcej.

Przykład pliku z czterema kolumnami:

| Nazwa skryptu       | Plik źródłowy   | MC  | Tekst                          |
|---------------------|-----------------|-----|--------------------------------|
| DIA_Straznik_01_01  | Straznik.json   | Nie | Stój! Kto tam idzie?           |
| DIA_Bohater_03_01   | Bohater.json    | Tak | Coś tu nie gra, muszę uważać.  |

Pierwszy wiersz pliku może zawierać nagłówki kolumn. Jeśli plik posiada nagłówek, zaznacz opcję „Pierwszy wiersz to nagłówek” w oknie VOSAN. Nazwy kolumn pojawią się jako etykiety w tabeli oraz w panelu „Teraz nagrywasz”.

## Instalacja

Wykonaj poniższe kroki na każdym komputerze, na którym uruchamiasz VOSAN.

> **Wymagana wersja programu REAPER:** funkcja „Wyrenderuj nagrania tej postaci” wymaga REAPERa **7.62 lub nowszego**. Ta wersja pozwala skryptowi zaznaczyć regiony. VOSAN otwiera wtedy okno renderowania z wartościami `Source: Master mix` oraz `Bounds: Selected regions`.
>
> Starszy REAPER nie ma tej funkcji. VOSAN używa wtedy zamiennika o nazwie Region Render Matrix. Wynik renderowania jest ten sam. Okno renderowania pokazuje wtedy wartość `Source: Region render matrix`. Pozostałe funkcje skryptu nie zależą od wersji programu.

### Krok 1: Zainstaluj wtyczkę ReaPack (Wymagane)
Aplikacja wymaga wtyczki ReaPack do instalacji i obsługi biblioteki ReaImGui.
1. Pobierz odpowiednią wersję wtyczki ReaPack ze strony [reapack.com](https://reapack.com).
2. Otwórz program REAPER.
3. Otwórz folder zasobów przez menu `Options` → `Show REAPER resource path in explorer/finder`.
4. Skopiuj pobrany plik wtyczki (np. `reaper_reapack-x86_64.dll`) do folderu `UserPlugins`.
5. Zrestartuj program REAPER.

### Krok 2: Zainstaluj bibliotekę ReaImGui przez ReaPack
1. W programie REAPER otwórz menu `Extensions` → `ReaPack` → `Browse packages`.
2. Wpisz `ReaImGui` w polu wyszukiwania.
3. Kliknij prawym przyciskiem myszy pakiet `ReaImGui: ReaScript binding for Dear ImGui` i wybierz `Install`.
4. Kliknij przycisk `Apply` w prawym dolnym rogu okna.
5. Zrestartuj program REAPER po zakończeniu instalacji.

### Krok 3: Zainstaluj skrypt VOSAN
1. Otwórz folder zasobów REAPERa (`Options` → `Show REAPER resource path in explorer/finder`).
2. Skopiuj cały folder `VOSAN` do podfolderu `Scripts`.

### Krok 4: Dodaj skrypt VOSAN do listy akcji
1. W programie REAPER otwórz menu `Actions` → `Show action list...` (lub naciśnij klawisz `?`).
2. Kliknij `New action` → `Load ReaScript...`.
3. Przejdź do folderu `Scripts/VOSAN` i wybierz plik `VOSAN.lua`.
4. (Opcjonalnie) Przypisz skrót klawiszowy do dodanej akcji `Script: VOSAN.lua`.

### Krok 5: Skonfiguruj opcje nagrywania (Krok obowiązkowy)
1. Otwórz okno preferencji: `Options` → `Preferences...` (skrót `Ctrl+P` lub `Cmd+,`).
2. Przejdź do zakładki `Audio` → `Recording`.
3. Odznacz opcję `Prompt to save/delete/rename new files: on stop`.
4. Kliknij `Apply`, a następnie `OK`.

> **Uwaga:** Ten krok jest obowiązkowy. Jeśli ta opcja jest włączona, REAPER wyświetli okno po każdym nagraniu. Okno blokuje skrypt VOSAN i uniemożliwia automatyczne tworzenie regionu.

### Krok 6: Ustaw tryb HiDPI dla interfejsu (Krok obowiązkowy)
Prawidłowe wyświetlanie okna ReaImGui wymaga włączenia odpowiedniego trybu HiDPI.
1. Otwórz okno preferencji: `Options` → `Preferences...` (skrót `Ctrl+P` lub `Cmd+,`).
2. Przejdź do zakładki `General`.
3. Kliknij przycisk `Advanced UI/system settings...`.
4. Ustaw pole `HiDPI mode` na `Multimonitor aware v2 (experimental)`.
5. Kliknij `OK` w oknie ustawień zaawansowanych.
6. Kliknij `Apply`, a następnie `OK` w oknie preferencji.
7. Zrestartuj program REAPER.

### Aktualizacja skryptu do nowszej wersji

REAPER uruchamia kopię skryptu z folderu zasobów. Zmiana plików w innym folderze nie ma wpływu na działanie skryptu.

1. Skopiuj nowe pliki `.lua` do podfolderu `Scripts/VOSAN` w folderze zasobów REAPERa.
2. Zamknij okno VOSAN.
3. Uruchom akcję `Script: VOSAN.lua` ponownie.

> **Uwaga:** krok 3 jest obowiązkowy. REAPER trzyma wczytany skrypt w pamięci. Nowe pliki zaczynają działać dopiero po ponownym uruchomieniu akcji.

VOSAN nie wymaga innych zewnętrznych bibliotek. Parser CSV, parser XLSX oraz obsługa nagrywania działają w natywnym API REAPERa.

## Użycie

### Podstawowa obsługa nagrywania

1. Uruchom akcję `Script: VOSAN.lua` z listy akcji. Otworzy się okno skryptu VOSAN.
2. Kliknij przycisk „Wczytaj plik (CSV / XLSX)...”. Wybierz plik ze skryptem dubbingowym.
3. Kliknij wiersz z kwestią do nagrania. Wiersz podświetli się na pomarańczowo.
4. Sprawdź treść w panelu „Teraz nagrywasz” na górze okna.
5. Rozpocznij nagrywanie w programie REAPER (przycisk Record lub klawisz R).
6. Zakończ nagrywanie w programie REAPER (przycisk Stop lub Spacja).
7. Skrypt VOSAN automatycznie wykryje koniec nagrania, utworzy region i nada mu nazwę wybranej kwestii.

### Funkcje automatyzacji

- **Auto-przejście:** Jeśli opcja „Auto-przejście do następnej kwestii po nagraniu” jest zaznaczona (ustawienie domyślne), VOSAN automatycznie zaznaczy kolejną kwestię z listy.
- **Automatyczne przesuwanie kursora:** Jeśli opcja „Przesuń kursor na koniec nagrania automatycznie” jest zaznaczona (ustawienie domyślne), VOSAN przesunie kursor edycji za nagrany obiekt. Pole „Odstęp po nagraniu (s)” określa odległość kursora od końca nagrania (domyślnie 0.5 s).

### Powtórka nagrania (Retake)

Aby nagrać kwestię ponownie:
1. Zaznacz tę samą kwestię na liście.
2. Nagraj nowe ujęcie.
3. VOSAN usunie poprzedni region o tej samej nazwie i utworzy nowy region w miejscu nowego nagrania.

W projekcie zawsze pozostaje tylko jedna, najnowsza wersja danej kwestii.

Oznaczenia kolorów w tabeli:
- **Pomarańczowy:** Aktualnie wybrana kwestia.
- **Zielony:** Kwestia z nagranym regionem.
- **Niebieski:** Kwestia wybranej postaci oczekująca na nagranie.
- **Szary:** Kwestia drugiej postaci (kontekst rozmowy).

### Kwestie głównego bohatera (MC) i filtrowanie postaci

Skrypt VOSAN automatycznie wykrywa tryb wielu postaci, jeśli plik zawiera kolumnę określającą postać (np. `plik źródłowy`, `plik zrodlowy`, `postac`, `character`).

- Możesz zawęzić listę i widok do konkretnej postaci. Wybierz postać z rozwijanej listy **Postać (Plik źródłowy)**.
- VOSAN podświetli kwestie tej postaci na niebiesko. Kwestie innych postaci pozostaną szare. Służą one jako kontekst.

Dodatkowo, jeśli plik zawiera kolumnę `MC` (wartości `Tak` lub `Nie`), skrypt zapyta Cię „Czy nagrywamy głównego bohatera (MC)?”.
- Opcje te nie wykluczają się. Możesz filtrować po nazwie pliku źródłowego (postaci) i dodatkowo zdecydować, czy jesteś MC, czy NPC.

### Ukrywanie kolumn

Możesz dostosować widok tabeli w oknie VOSAN:
1. Rozwiń sekcję „Pokaż kolumny”.
2. Odznacz checkbox obok nazwy kolumny środkowej, aby ją ukryć.

Kolumny z nazwą skryptu oraz tekstem kwestii są widoczne zawsze.

### Brak wybranej kwestii

Jeśli nagrywanie zakończy się bez wybranej kwestii w tabeli:
1. VOSAN utworzy region z nazwą tymczasową `NIEPRZYPISANE_<data>_<godzina>`.
2. Okno skryptu wyświetli czerwony komunikat ostrzegawczy.
3. Zmień nazwę utworzonego regionu ręcznie w programie REAPER.

## Eksport plików audio i renderowanie

VOSAN przygotowuje render wsadowy kwestii wybranej postaci. Skrypt ustawia te parametry samodzielnie:

- ścieżka zapisu: Pulpit, folder `Nagrania/Nazwa_Postaci`,
- wzorzec nazwy pliku: `$region`,
- zakres renderowania: tylko nagrane kwestie wybranej postaci,
- częstotliwość próbkowania: `48000` Hz,
- liczba kanałów: `Mono`,
- dodawanie gotowych plików do projektu: wyłączone.

VOSAN nie zmienia formatu pliku. VOSAN nie zmienia opcji `Normalize/Limit`. Te ustawienia należą do Ciebie. Ustaw je raz ręcznie.

### Ustaw format pliku jako domyślny (Krok jednorazowy)

1. Otwórz menu `File` → `Render...`.
2. Ustaw opcję `Resample mode` na `r8brain free`.
3. Odznacz opcję `Normalize/Limit`.
4. W sekcji `Output format` ustaw opcję `Format` na `WAV`.
5. Ustaw opcję `WAV bit depth` na `24 bit PCM`.
6. Kliknij przycisk `Save changes and close` (Zapisz zmiany i zamknij okno renderowania).
7. Otwórz menu `File` → `Project settings...`.
8. Kliknij przycisk `Save as default project settings`.
9. Kliknij przycisk `OK`.

### Szybki eksport z VOSAN (Zalecane)

Użyj tej metody, gdy Twój plik skryptu ma kolumnę postaci (np. `plik źródłowy`).

1. Wybierz postać z rozwijanej listy `Postać (Plik źródłowy)` w oknie VOSAN.
2. Nagraj kwestie tej postaci.
3. Kliknij przycisk `Wyrenderuj nagrania tej postaci`.
4. Sprawdź pole `Source` w oknie `Render to File`. Pole ma wartość `Master mix`.
5. Sprawdź pole `Bounds`. Pole ma wartość `Selected regions`.
6. Kliknij przycisk `Render N files...`.

VOSAN otwiera okno renderowania automatycznie. Skrypt pokazuje też podsumowanie w swoim oknie. Podsumowanie podaje liczbę kwestii, folder docelowy oraz użyty tryb.

Pliki otrzymują nazwy z pierwszej kolumny arkusza.

W REAPERze starszym niż 7.62 pole `Source` ma wartość `Region render matrix`. To jest prawidłowe. Wynik renderowania jest ten sam.

> **Uwaga:** VOSAN nie otwiera okna renderowania, gdy wybrana postać nie ma nagranej kwestii. Skrypt pokazuje ostrzeżenie. To zabezpieczenie jest celowe. REAPER przy pustym wyborze renderuje wszystkie regiony projektu.

### Ręczny eksport (Dla plików bez postaci)

Użyj tej metody, gdy Twój arkusz nie ma kolumny postaci.

1. Otwórz menu `File` → `Render...`.
2. Ustaw pole `Source` na `Master mix`.
3. Ustaw pole `Bounds` na `All project regions`.
4. Wpisz `$region` w polu `File name`.
5. Kliknij przycisk `Render N files...`.

## Ograniczenia skryptu

- **Tryb nagrywania:** VOSAN obsługuje standardowy tryb nagrywania (nowy obiekt na ścieżce). Skrypt nie obsługuje trybu nakładania ujęć (tzw. tryb *tape* / wiele ujęć w jednym obiekcie).
- **Wydajność XLSX:** Import dużych plików XLSX może trwać kilkanaście sekund z powodu dekompresji w języku Lua. Dla plików zawierających wiele tysięcy wierszy użyj formatu CSV.
- **Filtrowanie tekstu:** Wyszukiwarka ignoruje wielkość liter tylko dla znaków z alfabetu łacińskiego (ASCII). Wyszukiwanie polskich znaków diakrytycznych rozróżnia wielkość liter.
- **Długość regionu:** VOSAN tworzy region o długości dokładnie równej nagranemu obiektowi audio. Skrypt nie dodaje automatycznie marginesu ciszy przed obiektem ani po obiekcie.
