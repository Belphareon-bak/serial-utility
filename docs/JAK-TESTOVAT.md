# Jak MediaTool otestovat na vlastním vzorku

## 1. Automatické testy
```powershell
.\tests\Test-MediaTool.ps1
```
Musí skončit s `0 chyb`. Spusť ho ve Windows PowerShellu 5.1 nebo pwsh 7;
vytváří jen dočasná testovací data (na Linuxu také v `/dev/shm`).
Na tomto stroji prošlo 48/48 testů v PowerShellu 7.6.6 na Linuxu (2026-09-25). Otevřený blokující nález zápisu logu je v `REVIZE-3-2026-09-25.md`.

## 2. Vzorek dat
**Vždy na kopii.** Zkopíruj pár desítek souborů do `D:\vzorek\Downloads` a knihovnu
nastav na novou prázdnou složku, **ideálně na NAS** (`\\amorphis_nas\…\zkouska`) —
jen tak se projde cesta přes jiný svazek s ověřením obsahu.

Do vzorku dej:
- film, jehož název obsahuje `Max`, `Ray` nebo `Extended` (dřív se ukously),
- titulky ve dvou jazycích k jednomu filmu (`Film.2015.cz.srt`, `Film.2015.en.srt`),
- jeden díl seriálu ve dvou verzích — českou (`CZ-dabing`) a jinou,
- nějaký `cali.s6x01…` nebo podobný zápis,
- soubor s velkou příponou (`Film 2011.MKV`).

## 3. V okně (GUI)
1. **Náhled** v režimu „Setřídit do knihovny". Zkontroluj:
   - `Mad Max Fury Road (2015)`, ne `Mad Fury Road`,
   - titulky `Film (2015).cs.srt` a `Film (2015).en.srt`, ne `(2)`,
   - česká a jiná verze dílu **nejsou** DUPLICITA.
2. **Provést vybrané.** V `logs\` hned vznikne `mediatool-….csv`.
3. **Přerušení:** spusť Provést na větší dávce na NAS a **zavři okno uprostřed**.
   Porovnej přesunuté soubory s logem; při přerušení mezi přesunem a zápisem
   může poslední řádek chybět. Automaticky vrať jen zaznamenané položky a ostatní
   dohledávej ručně. Viz blokující nález v třetí revizi.
4. **Neúplné vrácení:** po Provést dej na původní místo jednoho souboru jiný soubor
   se stejným jménem a dej Vrátit. Má ohlásit, že jeden soubor vrátit nešel, a dávka
   **nesmí** dostat příponu `.undone`. Po odstranění překážky dej Vrátit znovu —
   vrátí se ten jeden soubor, ne starší dávka.
5. **Smazat duplicity:** v náhledu vyber duplicitu, pak **ponechanou kopii ručně
   přesuň jinam** a dej Smazat duplicity. Musí odmítnout s hláškou
   „NESMAZANO – ponechana kopie chybi".

## Co jde ověřit JEN na Windows
| | Proč |
|---|---|
| celé GUI (kroky 3.1–3.5) | WinForms na Linuxu neběží; ověřena je syntaxe a napojení na testované jádro |
| přesun na NAS přes `.mtpart` s ověřením SHA-256 | nový test mount pointu používá dva skutečné Linux svazky; konkrétní SMB/NAS cestu je třeba ověřit na cílovém prostředí |
| mazání do Koše | `Microsoft.VisualBasic.FileIO` je jen na Windows |
| přejmenování `Film (2015).MKV` → `Film (2015).mkv` na místě | nový regresní test běží jen na Windows; výsledek je nutné potvrdit na NTFS |
| přesun přes junction na jiný disk | na testovacích složkách dvou disků ověř, že `Test-SameVolume` vrátí `False`; pak zkus malý soubor a porovnej SHA-256 |
