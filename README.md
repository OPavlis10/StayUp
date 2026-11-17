# Stay Up

_Dříve pod názvem „Bdím“._

Malá aplikace pro macOS 26 a novější, která žije jen v řádku nabídek. Ukazuje vytížení Macu (procesor, paměť, disk, grafika, síť, nejnáročnější aplikace, příkon a výdrž) a má tři přepínače:

- **A – „Displej spí, Mac běží“**: Mac neusne nečinností, obrazovka se zhasínat může. Drží se přes `IOPMAssertion` (`PreventUserIdleSystemSleep`), bez práv správce.
- **B – „Nikdy nevypínat, ani po zavření víka“**: privilegovaný pomocný program spustí `pmset -a disablesleep 1`. Původní hodnota (obvykle 0; pokud ji už předtím měl na 1 někdo jiný, zůstane 1) se vrací při vypnutí přepínače, ukončení nebo pádu aplikace, zaseknutí aplikace, vypršení časovače, nízké baterii a přehřátí. B v sobě zahrnuje A.

- **„Úsporný režim“**: stejný pomocný program spustí `pmset -a lowpowermode 1` (na baterii i na adaptéru). Na A a B nezávisí. Původní hodnoty pro baterii a adaptér se vrací při vypnutí přepínače, ukončení nebo pádu aplikace; zdroj, který měl úsporný režim zapnutý už předtím, se nepřepisuje. Na Macu bez úsporného režimu je přepínač nedostupný.

Další funkce:

- **Bdít, jen dokud AI pracuje**: při zapnutém A nebo B aplikace každých 15 s sečte čas procesoru sledovaných procesů (výchozí `claude`, `node`, `ollama`, `codex`). Když dohromady nepracují nastavenou dobu (výchozí 10 min, práh 3 % jednoho jádra), vypne B i A a v panelu to oznámí. Seznam procesů, práh a dobu lze změnit v nastavení.
- **Kdo žere energii** a **Příkon**: tři nejnáročnější aplikace přihlášeného uživatele (CPU a odhad příkonu procesoru) a příkon počítače s výdrží baterie. Měří se jen při otevřeném panelu.
- **Hlídání sítě**: při zapnutém bdění aplikace pasivně sleduje stav síťového připojení (nic neodesílá). Po minutě bez připojení pošle oznámení a další, když se připojení vrátí. Volitelně po nastavené době výpadku bdění ukončí.

Bez závislostí, bez síťového provozu, bez telemetrie. Swift 6 s plnou kontrolou souběžnosti, SwiftUI.

## Sestavení

**S Xcode – běžná cesta.** Otevřete `StayUp.xcodeproj`, nebo z příkazové řádky:

```sh
xcodebuild -project StayUp.xcodeproj -scheme StayUp -configuration Release -derivedDataPath build/DerivedData build
```

Když `xcode-select` ukazuje na Command Line Tools, přidejte před příkaz `DEVELOPER_DIR`:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project StayUp.xcodeproj -scheme StayUp -configuration Release -derivedDataPath build/DerivedData build
```

Výsledek je `build/DerivedData/Build/Products/Release/Stay Up.app`. Projekt se generuje nástrojem XcodeGen z `project.yml`; po přidání nebo odebrání souborů spusťte `xcodegen generate`.

**Bez Xcode** (stačí Command Line Tools):

```sh
./build.sh            # sestaví build/Stay Up.app
./build.sh run        # sestaví a spustí
./build.sh install    # sestaví a zkopíruje do /Applications/Stay Up.app
```

`build.sh` použije SDK 26.5 (SDK 27 z Command Line Tools neumí makra SwiftUI), podepíše nejdřív pomocný program a potom celý balíček podpisem ad hoc. Když je k dispozici plné Xcode (vybrané přes `xcode-select`, nebo `/Applications/Xcode.app`), přeloží katalog textů nástrojem `xcstringstool` do `Contents/Resources`. Jen s Command Line Tools se katalog přeskočí; nevadí to, zdrojový jazyk je čeština a klíče jsou přímo české texty. Aplikace je jen česká.

Pro snímek rozvržení bez klikání na ikonu v řádku nabídek spusťte aplikaci s argumentem `--preview-window`: stejný panel se ukáže v běžném okně. Na normální spuštění to nemá vliv.

Pro přepínač B aplikaci nainstalujte do `/Applications`. Z jiného umístění systém registraci pomocného programu často odmítne nebo ji po přesunu ztratí.

## Rozvržení

```
App/                      aplikace (StayUpApp.swift, Models, Metrics, Energy, Activity, Connectivity, Power, Settings, UI)
App/Info.plist            pevné hodnoty, společné pro Xcode i build.sh
App/StayUp.entitlements     bez sandboxu; jen oprávnění k poloze (název Wi-Fi sítě)
App/Localizable.xcstrings katalog textů, zdrojový jazyk cs
Helper/                   pomocný program StayUpHelper + Info.plist (vkládá se do binárky)
Helper/cz.stayup.StayUp.helper.plist   popis služby pro launchd
Shared/HelperProtocol.swift        XPC rozhraní mezi aplikací a pomocným programem
project.yml               zadání pro XcodeGen
build.sh                  sestavení bez Xcode
```

Hotový balíček:

```
Stay Up.app/Contents/MacOS/StayUp
Stay Up.app/Contents/MacOS/StayUpHelper
Stay Up.app/Contents/Library/LaunchDaemons/cz.stayup.StayUp.helper.plist
```

## Proč bez sandboxu

Aplikace spouští `pmset displaysleepnow` přes `Process`, čte údaje z IOKit a připojuje se k privilegované Mach službě `cz.stayup.StayUp.helper`. Nic z toho sandbox bez výjimek nedovolí, proto aplikace v sandboxu není. Zapnutý je Hardened Runtime a jediné oprávnění `com.apple.security.personal-information.location`: bez něj systém nezobrazí žádost o přístup k poloze a macOS bez ní nevydá název Wi-Fi sítě.

## Povolení pomocného programu

Při prvním zapnutí přepínače B nebo Úsporného režimu se pomocný program zaregistruje (`SMAppService.daemon`) a systém požádá o schválení:

**Nastavení systému › Obecné › Položky přihlášení a rozšíření › oddíl „Povolit na pozadí“ › zapnout „Stay Up“.**

Potom přepínač zapněte znovu.

## Ověření

Přepínač A:

```sh
pmset -g assertions | grep -i PreventUserIdleSystemSleep
```

Při zapnutém A je v seznamu řádek procesu StayUp.

Přepínač B:

```sh
pmset -g | grep SleepDisabled
```

Zapnuto ukazuje `SleepDisabled 1`, po vypnutí hodnotu, která platila před zapnutím (obvykle `SleepDisabled 0`).

Pomocný program si původní hodnotu před zapnutím uloží do značky (`/Library/Application Support/cz.stayup.StayUp/nosleep.marker`) a vrací právě ji. Nastavení, které nezměnil, nikdy nepřepisuje. Kdyby spadl nebo byl násilně ukončen, launchd ho spustí znovu (`KeepAlive › SuccessfulExit = false`, zhruba do 10 s) a nastavení se vrátí podle značky; stejně tak po restartu Macu.

Úsporný režim:

```sh
pmset -g | grep lowpowermode
```

Zapnuto ukazuje `lowpowermode 1`, po vypnutí původní hodnotu. Původní hodnoty (zvlášť pro baterii a adaptér) jsou ve značce `/Library/Application Support/cz.stayup.StayUp/lowpower.marker` a platí pro ně stejná pravidla jako u přepínače B.

## Čisté odebrání

1. Vypněte všechny přepínače a ověřte, že se `SleepDisabled` i `lowpowermode` vrátily na původní hodnotu.
2. V Nastavení systému › Obecné › Položky přihlášení a rozšíření vypněte „Stay Up“ v oddílu „Povolit na pozadí“.
3. Ukončete aplikaci a smažte `/Applications/Stay Up.app`.

Poslední záchrana, kdyby `SleepDisabled` zůstalo na 1:

```sh
sudo pmset -a disablesleep 0
```

Po opakovaném sestavování (podpis ad hoc se s každým sestavením mění) může v systému zůstat staré schválení a pomocný program se nespustí. Pomůže `sfltool resetbtm` a restart. Pozor: příkaz vymaže schválení položek na pozadí **všech** aplikací, které pak požádají o povolení znovu.
