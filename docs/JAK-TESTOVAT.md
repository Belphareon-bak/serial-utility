# Jak MediaTool otestovat na vlastním vzorku

## 1. Automatické testy
```powershell
.\tests\Test-MediaTool.ps1
```
Musí skončit `Vysledek: 35 v poradku, 0 chyb`. Běží ve Windows PowerShellu 5.1 i v pwsh 7
a na disk sahá jen do dočasné složky.

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
   Log musí existovat a obsahovat soubory, které se stihly přesunout.
   Pak **Vrátit poslední dávku** — musí je vrátit.
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
| přesun na NAS přes `.mtpart` s ověřením SHA-256 | na Linuxu je kořen cesty vždy `/`, cesta se testovala podvržením |
| mazání do Koše | `Microsoft.VisualBasic.FileIO` je jen na Windows |
| přejmenování `Film 2011.MKV` → `.mkv` na místě | NTFS nerozlišuje velikost písmen; podezření na přidané `(2)` — viz známá omezení |
