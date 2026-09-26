# MediaTool

Hromadné přejmenování, hledání duplicit a setřídění médií. PowerShell 5.1, bez závislostí.
Funguje na lokálním disku i na Synology namountované jako síťový disk (`Z:\video`) nebo přes UNC (`\NAS\video`).

## Pravidlo číslo jedna

Bez `-Apply` se nikdy nic nezmění. Všechno ostatní je jen náhled.

## GUI (doporučeno)

Dvojklik na **`MediaTool.exe`** (nebo `MediaTool.cmd`). Nic se neinstaluje.

Exe je záměrně jen tenký spouštěč s ikonou — otevře `media-tool-gui.ps1`, který
leží vedle něj. Logika tak zůstává v čitelných skriptech, které jde kdykoli
upravit bez překládání. Když si skript změníš, exe se překládat nemusí.

Přeložit znovu (třeba po změně ikony):

```powershell
.\make-icon.ps1     # překreslí mediatool.ico
.\build-exe.ps1     # sestaví MediaTool.exe systémovým csc.exe, nic nestahuje
```

1. Nahoře vyber **zdrojovou složku** (výchozí Downloads), případně **knihovnu**
   (klidně `Z:\video` nebo `\\DiskStation\video`)
2. Vyber, co se má stát: *Přejmenovat na místě* / *Setřídit do knihovny* /
   *Odklidit duplicity do _Duplicity*
3. **Náhled** — vypíše tabulku, co by se stalo, barevně podle akce
4. Zaškrtávátky vyber řádky. **Nový název jde v tabulce rovnou přepsat**, když se
   ti nelíbí, co skript vymyslel
5. **Provést vybrané**. Každý přesun má záznam záměru před změnou souboru. **Vrátit poslední dávku** ověřuje SHA-256; změněný nebo nejednoznačný soubor nechá na místě k ruční kontrole.

Dvojklik na řádek otevře soubor v Průzkumníku. Řádky, které nejdou provést
(poškozené a nedostažené soubory), jsou šedé a nezaškrtnutelné.

**Cílová složka nemusí existovat.** Když ji nemáš, okno se zeptá
„Cílová knihovna neexistuje – mám ji vytvořit?" a založí ji. Existující složka
se použije bez ptaní. Podsložky (`Serialy\…\Season 01`) vznikají samy.

### Panel Nastavení

Tlačítko **Nastavení** vpravo dole vysune postranní panel:

| Sekce | Co v něm je |
|---|---|
| Vzhled | **Motiv tmavý/světlý** (paleta VS Code Dark+/Light+), velikost písma 8–14, střídání barvy řádků |
| Pojmenování | šablony pro seriál a film (`{show} {season} {episode} {title} {year}`), ponechání tagů |
| Prohledávání | podsložky, titulky, přesné SHA256, filmy bez podsložek, hranice „malý soubor = odpad" |
| Duplicity | přesouvat do `_Duplicity` vs. jen vypsat; přepínač trvalého mazání |
| Slovník | rip skupiny k vyhození a slučování názvů seriálů (`regex = Název`) |

Změny se pamatují v `settings.json` vedle skriptu — ukládá se tlačítkem
i při zavření okna.

### Mazání duplicit

Tlačítko **Smazat duplicity** smaže zaškrtnuté řádky s akcí `DUPLICITA`.

- **Výchozí je do Koše**, odkud je můžeš obnovit
- Trvalé mazání se musí zapnout v nastavení a ptá se dvakrát
- **Mazání je zablokované, pokud je mazaný nebo ponechaný soubor na síťovém, odkazovaném či neověřeném svazku.** Duplicity tam přesuň do `_Duplicity`.
- Automaticky lze mazat jen bajtově shodné duplicity po úplném ověření SHA-256 obou souborů. Různé verze stejného dílu zůstávají k ručnímu posouzení.
- Smazání se zapisuje do `logs\smazano-*.csv`, ale **„Vrátit poslední dávku"
  ho vrátit neumí** — přesuny ano; soubory poslané do Koše obnovuj z Koše,
  trvale smazané soubory aplikace neobnoví

Okno i příkazová řádka sdílejí stejný engine i stejný log. Nové přesuny mají trvalý záměr před změnou souboru a SHA-256 v CSV. Staré CSV bez otisku se automaticky nevrací, protože nelze ověřit totožnost cíle. Vedle `media-tool.ps1` musí ležet také `media-tool-journal.ps1`; spouštěcí exe se znovu překládat nemusí.

## Příkazová řádka

```powershell
cd C:\Users\geofe\Scripts\MediaTool

# 1) co to chce udělat
.\media-tool.ps1 scan

# 2) jen duplicity a kolik místa žerou
.\media-tool.ps1 dupes

# 3) přejmenovat na místě, v Downloads
.\media-tool.ps1 rename -Apply

# 4) přejmenovat a přesunout na NAS
.\media-tool.ps1 sort -Library "Z:\video" -Apply

# 5) vrátit poslední dávku
.\media-tool.ps1 undo -Apply
```

Pokud PowerShell odmítne skript spustit:
`powershell -ExecutionPolicy Bypass -File .\media-tool.ps1 scan`

## Doporučený postup na NAS

Nezačínej celým Downloads. Nejdřív jeden seriál, ať vidíš výsledek:

```powershell
.\media-tool.ps1 sort -Filter Bluey -Library "Z:\video"          # náhled
.\media-tool.ps1 sort -Filter Bluey -Library "Z:\video" -Apply   # ostře
```

Teprve pak zbytek. Kopie na NAS se ověřuje délkou i úplným SHA-256 — zdroj se maže
až když cíl sedí. Při přerušeném přenosu aplikace při dalším spuštění ověří zdroj
a uklidí svou vlastní nedokončenou `.mtpart` kopii podle uloženého záměru.

## Výsledná struktura

```
Z:\video\
  Serialy\Bluey\Season 01\Bluey - S01E01 - Kouzelný xylofon.mkv
  Filmy\Thor 1 (2011)\Thor 1 (2011).mkv
  _Duplicity\        kopie navíc (nic se nemaže, jen odklízí)
  _Kekontrole\       co si nebyl jistý (film bez roku apod.)
```

Pojmenování odpovídá tomu, co čekají Plex, Jellyfin i Synology Video Station.

## Parametry

| Parametr | Význam |
|---|---|
| `-Path` | kde hledat (výchozí `~\Downloads`), jde zadat víc cest |
| `-Recurse` | i podsložky |
| `-Filter` | jen soubory obsahující text, např. `-Filter Bluey` |
| `-Library` | kořen knihovny pro `sort` |
| `-Apply` | provést změny (bez toho jen náhled) |
| `-FullHash` | úplné SHA256 místo rychlého otisku (pomalé, po síti velmi) |
| `-NoSubs` | ignorovat titulky (jinak jdou s videem) |
| `-Flat` | filmy rovnou do `Filmy\` bez složky na film |
| `-KeepTags` | nechat v názvu `[1080p x265]` |
| `-MinVideoKB` | pod touhle velikostí se video považuje za nedostažené (výchozí 100) |
| `-SeriesTemplate` | výchozí `{show} - S{season}E{episode} - {title}` |
| `-MovieTemplate` | výchozí `{title} ({year})` |

## Jak se hledají duplicity

1. **Shodná data** — stejná velikost → otisk z prvního a posledního MB + délky.
   Přes SMB je to řádově rychlejší než číst celý soubor. `-FullHash` dopočítá SHA256.
2. **Stejný díl, jiná data** — stejný seriál/série/díl, ale jiný rip.
   Ponechá se větší soubor, zbytek jde do `_Duplicity`. **Nic se nikdy nemaže.**

## Když něco přejmenuje blbě

V hlavičce skriptu jsou tři seznamy k úpravě:

- `$TagPattern` — technické tagy, které se z názvu vyhazují (`1080p`, `WEB-DL`, `CZ`…)
- `$DropWords` — jména rip skupin (`chmeli`, `rarbg`, …)
- `$ShowAliases` — sjednocení názvu seriálu, aby nevznikly dvě složky.
  Proto se z `Game of Thrones Hra o trůny S08E02` stane `Game of Thrones - S08E02`.

## Co utilita neumí

- Nedohledává názvy dílů online. Chybějící název doplní jen z jiné varianty
  téhož dílu ve stejné dávce — proto `Bluey - S01E35.mkv` zůstane bez názvu.
- Nepozná duplicitu dvou různých ripů téhož **filmu** (u seriálů ano, podle SxxEyy).
- Nesahá na `@eaDir`, `#recycle`, `#snapshot` — služební složky Synology.
