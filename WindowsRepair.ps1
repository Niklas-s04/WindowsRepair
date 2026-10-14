#requires -Version 5.1
<#
.SYNOPSIS
  WindowsRepair - interaktives Reparatur- und Diagnosetool fuer Windows 10/11.
.DESCRIPTION
  Presets, freie Mehrfachauswahl, Sicherheitsabfragen und exportierbare Sitzungslogs.
  Ausschliesslich integrierte Windows-Befehle; keine Downloads und keine Fremdmodule.
  Die Ausfuehrung erfolgt in der Windows PowerShell 5.1 (64-Bit empfohlen).
  Version 1.0, 2026-10-14.
.NOTES
  Riskante Boot-/Partitionsoperationen werden absichtlich NICHT automatisiert.
  Bei einem Fehler wird der jeweilige Schritt protokolliert; der Rest laeuft weiter.
#>

$ErrorActionPreference = 'Stop'
$script:Version = '1.0.0'

if ($env:OS -ne 'Windows_NT') {
    Write-Host 'Dieses Tool funktioniert ausschliesslich unter Windows.' -ForegroundColor Red
    return
}

# Rechte anfordern. Den eigenen Skriptpfad nicht ueber einen Shell-Befehl ausfuehren.
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host 'Administratorrechte werden ueber die Windows-UAC angefordert ...' -ForegroundColor Yellow
    try {
        $argLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath.Replace('"', '')
        Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $argLine -Verb RunAs -ErrorAction Stop
    } catch {
        Write-Host ("UAC abgebrochen oder Start nicht moeglich: {0}" -f $_.Exception.Message) -ForegroundColor Red
        Write-Host 'Bitte ueber die mitgelieferte CMD-Datei oder als Administrator starten.'
    }
    return
}

# 64-Bit PowerShell bevorzugen. 32-Bit Hosts koennen System32 umleiten.
if (-not [Environment]::Is64BitProcess -and [Environment]::Is64BitOperatingSystem) {
    Write-Host 'Bitte die 64-Bit Windows PowerShell starten (nicht SysWOW64).' -ForegroundColor Red
    return
}

$script:StartedAt = Get-Date
$script:Stamp = $script:StartedAt.ToString('yyyyMMdd-HHmmss-fff')
$script:SessionDir = Join-Path $env:TEMP (Join-Path 'WindowsRepair-Sessions' $script:Stamp)
New-Item -ItemType Directory -Path $script:SessionDir -Force | Out-Null
$script:LogFile = Join-Path $script:SessionDir 'WindowsRepair.log'
$script:LogWriter = [System.IO.StreamWriter]::new($script:LogFile, $false, [System.Text.UTF8Encoding]::new($true))
$script:LogWriter.AutoFlush = $true
$script:History = [System.Collections.Generic.List[object]]::new()
$script:StepWarning = $false
$script:RestartRecommended = $false
$script:ExportedPaths = [System.Collections.Generic.List[string]]::new()
$script:SystemDrive = $env:SystemDrive
if ([string]::IsNullOrWhiteSpace($script:SystemDrive)) { $script:SystemDrive = 'C:' }
$script:Tasks = [ordered]@{}
$script:Presets = [ordered]@{}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [ValidateSet('INFO','RUN','OK','WARN','ERROR','OUT')][string]$Level = 'INFO',
        [switch]$OnlyFile
    )
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Text
    $script:LogWriter.WriteLine($line)
    if (-not $OnlyFile) {
        $color = switch ($Level) {
            'OK'    { 'Green' }
            'WARN'  { 'Yellow' }
            'ERROR' { 'Red' }
            'RUN'   { 'Cyan' }
            'OUT'   { 'Gray' }
            default { 'White' }
        }
        Write-Host $line -ForegroundColor $color
    }
}

function Ask-YesNo {
    param([string]$Prompt, [bool]$Default = $false)
    $suffix = if ($Default) { '[J/n]' } else { '[j/N]' }
    $response = Read-Host "$Prompt $suffix"
    if ([string]::IsNullOrWhiteSpace($response)) { return $Default }
    return ($response.Trim().ToLowerInvariant() -in @('j','ja','y','yes'))
}

function Show-TextResult {
    param([object]$Object, [int]$Width = 170)
    if ($null -eq $Object) {
        Write-Log 'Keine Eintraege gefunden.'
        return
    }
    $formatted = $Object | Out-String -Width $Width
    foreach ($line in ($formatted -split '\r?\n')) {
        if (-not [string]::IsNullOrWhiteSpace($line)) { Write-Log $line 'OUT' }
    }
}

function Invoke-External {
    param(
        [Parameter(Mandatory = $true)][string]$File,
        [string[]]$Arguments = @(),
        [switch]$AllowNonZero
    )
    $exe = Get-Command -Name $File -CommandType Application -ErrorAction Stop
    Write-Log ('Befehl: {0} {1}' -f $File, ($Arguments -join ' ')) 'RUN'
    # Native stderr als Ausgabe abfangen, ohne dass PowerShell 5.1 daraus
    # aufgrund der globalen ErrorActionPreference eine terminating exception macht.
    $ErrorActionPreference = 'Continue'
    $global:LASTEXITCODE = 0
    & $exe.Source @Arguments 2>&1 | ForEach-Object {
        $string = $_.ToString()
        foreach ($line in ($string -split '\r?\n')) {
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                Write-Log $line.TrimEnd() 'OUT'
            }
        }
    }
    $exit = $global:LASTEXITCODE
    Write-Log ("Exitcode: {0}" -f $exit) 'INFO'
    if ($exit -ne 0 -and -not $AllowNonZero) {
        throw ('{0} endete mit Exitcode {1}. Details stehen im Sitzungslog.' -f $File, $exit)
    }
    if ($exit -ne 0) {
        $script:StepWarning = $true
        Write-Log ('Nicht-Null-Exitcode: {0} (Ergebnis im Log pruefen).' -f $exit) 'WARN'
    }
}

function Add-Task {
    param([string]$Id, [string]$Category, [string]$Name,
          [string]$Explanation, [string]$Command,
          [ValidateSet('Info','Standard','Rueckfrage')][string]$Risk = 'Info')
    if ($script:Tasks.Contains($Id)) { throw "Doppelte Task-ID: $Id" }
    $script:Tasks[$Id] = [pscustomobject]@{
        Id = $Id; Category = $Category; Name = $Name;
        Explanation = $Explanation; Command = $Command; Risk = $Risk
    }
}

function Add-Preset {
    param([string]$Number, [string]$Name, [string]$Explanation, [string[]]$Ids)
    foreach ($id in $Ids) {
        if (-not $script:Tasks.Contains($id)) { throw "Unbekannte Task-ID in Preset: $id" }
    }
    $script:Presets[$Number] = [pscustomobject]@{
        Number = $Number; Name = $Name; Explanation = $Explanation; Ids = $Ids
    }
}

# ----- Katalog: bewusst keine ungefragten /ResetBase-, Bootrec- oder WMI-Resets -----
Add-Task 'dism-check'     'Windows / DISM' 'DISM Schnellstatus' 'Prueft gespeicherten Beschaedigungsstatus.' 'DISM /Online /Cleanup-Image /CheckHealth'
Add-Task 'dism-scan'      'Windows / DISM' 'DISM Tiefenscan' 'Durchsucht den Komponentenspeicher vollstaendig.' 'DISM /Online /Cleanup-Image /ScanHealth'
Add-Task 'dism-repair'    'Windows / DISM' 'DISM Reparatur' 'Repariert den Komponentenspeicher, ggf. ueber Windows Update.' 'DISM /Online /Cleanup-Image /RestoreHealth' 'Standard'
Add-Task 'sfc-verify'     'Windows / DISM' 'SFC nur pruefen' 'Prueft geschuetzte Systemdateien ohne Reparatur.' 'sfc /verifyonly'
Add-Task 'sfc-repair'     'Windows / DISM' 'SFC reparieren' 'Prueft und repariert geschuetzte Systemdateien.' 'sfc /scannow' 'Standard'
Add-Task 'sfc-cbs'        'Windows / DISM' 'SFC-CBS-Protokoll' 'Extrahiert [SR]-Eintraege aus CBS.log in die Sitzungsdaten.' 'Select-String CBS.log [SR]'
Add-Task 'dism-analyze'   'Windows / DISM' 'Komponentenspeicher analysieren' 'Zeigt, ob WinSxS-Bereinigung empfehlenswert ist.' 'DISM /Online /Cleanup-Image /AnalyzeComponentStore'
Add-Task 'dism-clean'     'Windows / DISM' 'WinSxS bereinigen' 'Entfernt ersetzte Komponentenversionen; kann Update-Rollback beeinflussen.' 'DISM /Online /Cleanup-Image /StartComponentCleanup' 'Rueckfrage'
Add-Task 'dism-source'    'Windows / DISM' 'DISM mit ISO-Reparaturquelle' 'Fragt nach install.wim/install.esd und passendem Image-Index.' 'DISM /Online /Cleanup-Image /RestoreHealth /Source:... /LimitAccess' 'Rueckfrage'

Add-Task 'disk-scan'      'Laufwerk' 'CHKDSK Online-Scan' 'Prueft das Windows-NTFS-Dateisystem waehrend des Betriebs.' 'chkdsk C: /scan'
Add-Task 'disk-spotfix'   'Laufwerk' 'CHKDSK Spotfix' 'Repariert erfasste NTFS-Fehler; ggf. Offline-Phase/Neustart.' 'chkdsk C: /spotfix' 'Rueckfrage'
Add-Task 'disk-fix'       'Laufwerk' 'CHKDSK /f' 'Repariert Dateisystemfehler; auf C: oft Neustartplanung.' 'chkdsk C: /f' 'Rueckfrage'
Add-Task 'disk-r'         'Laufwerk' 'CHKDSK /r' 'Sehr langsamer Sektorscan mit Reparaturversuch, nur gezielt nutzen!' 'chkdsk C: /r' 'Rueckfrage'
Add-Task 'disk-health'    'Laufwerk' 'Laufwerke-Status' 'Zeigt HealthStatus und OperationalStatus aus Windows Storage.' 'Get-PhysicalDisk'
Add-Task 'disk-reliable'  'Laufwerk' 'Laufwerk-Zuverlaessigkeit' 'Zeigt verfuegbare Verschleiss-/Fehlerzaehler.' 'Get-StorageReliabilityCounter'

Add-Task 'upd-services'   'Windows Update' 'Update-Dienste pruefen' 'Zeigt Status von Windows Update, BITS und CryptSvc.' 'Get-Service wuauserv,bits,cryptsvc'
Add-Task 'upd-start'      'Windows Update' 'Update-Dienste starten' 'Startet erforderliche Update-Dienste, wenn gestoppt.' 'Start-Service wuauserv,bits,cryptsvc' 'Standard'
Add-Task 'upd-log'        'Windows Update' 'Windows-Update-Protokoll erzeugen' 'Konvertiert ETL-Protokolle; speichert sie nur im Sitzungsordner.' 'Get-WindowsUpdateLog'
Add-Task 'upd-cache'      'Windows Update' 'Update-Caches zuruecksetzen' 'Stoppt Dienste, benennt Caches um und startet Dienste erneut; erneute Downloads.' 'SoftwareDistribution/catroot2 umbenennen' 'Rueckfrage'

Add-Task 'net-adapters'   'Netzwerk' 'Adapter-Status' 'Zeigt physische und virtuelle Netzwerkadapter.' 'Get-NetAdapter'
Add-Task 'net-dns'        'Netzwerk' 'DNS-Server anzeigen' 'Zeigt die eingestellten DNS-Resolver pro Adapter.' 'Get-DnsClientServerAddress'
Add-Task 'net-test'       'Netzwerk' 'Netzwerk/HTTPS-Test' 'Testet DNS und TCP 443 gegen microsoft.com.' 'Test-NetConnection microsoft.com -Port 443'
Add-Task 'net-flush'      'Netzwerk' 'DNS-Cache leeren' 'Entfernt lokal zwischengespeicherte DNS-Eintraege.' 'Clear-DnsClientCache' 'Standard'
Add-Task 'net-register'   'Netzwerk' 'DNS neu registrieren' 'Stoesst dynamische DNS-Registrierung an.' 'ipconfig /registerdns' 'Standard'
Add-Task 'net-proxy'      'Netzwerk' 'WinHTTP-Proxy anzeigen' 'Zeigt die WinHTTP-Proxykonfiguration.' 'netsh winhttp show proxy'
Add-Task 'net-winsock'    'Netzwerk' 'Winsock-Reset' 'Aendert den Winsock-Katalog; Neustart erforderlich, VPN-Software beachten.' 'netsh winsock reset' 'Rueckfrage'
Add-Task 'net-ipreset'    'Netzwerk' 'TCP/IP-Reset' 'Setzt Teile der IP-Konfiguration zurueck. Statische IP/VPN koennen betroffen sein.' 'netsh int ip reset' 'Rueckfrage'
Add-Task 'net-proxyreset' 'Netzwerk' 'WinHTTP-Proxy zuruecksetzen' 'Entfernt einen bewusst konfigurierten WinHTTP-Proxy!' 'netsh winhttp reset proxy' 'Rueckfrage'
Add-Task 'net-renew'      'Netzwerk' 'DHCP-Lease erneuern' 'Gibt IPv4-Leases frei und fordert neue an; trennt ggf. Netzwerk/Remote-Sitzung.' 'ipconfig /release und /renew' 'Rueckfrage'

Add-Task 'store-status'   'Apps / Store' 'Store-Paket pruefen' 'Zeigt die Store-Paketregistrierung des aktuellen Benutzers.' 'Get-AppxPackage -Name Microsoft.WindowsStore'
Add-Task 'store-wsreset'  'Apps / Store' 'Store-Cache bereinigen' 'Leert den Microsoft-Store-Cache; kann Store-Fenster oeffnen.' 'wsreset.exe' 'Standard'
Add-Task 'store-register' 'Apps / Store' 'Store neu registrieren' 'Registriert die vorhandene Store-Installation erneut.' 'Add-AppxPackage -Register AppxManifest.xml' 'Rueckfrage'
Add-Task 'store-reset'    'Apps / Store' 'Store-App zuruecksetzen' 'Setzt Store-Einstellungen/Daten fuer aktuellen Benutzer zurueck.' 'Reset-AppxPackage Microsoft.WindowsStore' 'Rueckfrage'
Add-Task 'store-log'      'Apps / Store' 'AppX-Fehlerlog' 'Zeigt letzte Paket-Bereitstellungsereignisse.' 'Get-AppxLog'

Add-Task 'driver-problems' 'Treiber / Dienste' 'Problemgeraete anzeigen' 'Listet Windows-Geraete mit Fehlerstatus.' 'pnputil /enum-devices /problem'
Add-Task 'driver-list'    'Treiber / Dienste' 'Treiberpakete anzeigen' 'Listet Drittanbieter-Treiberpakete.' 'pnputil /enum-drivers'
Add-Task 'driver-rescan'  'Treiber / Dienste' 'Hardware neu erkennen' 'Loest erneute Hardwareerkennung aus.' 'pnputil /scan-devices' 'Standard'
Add-Task 'service-state'  'Treiber / Dienste' 'Dienststatus anzeigen' 'Zeigt wichtige Systemdienste.' 'Get-Service wuauserv,bits,cryptsvc,WSearch,Spooler'
Add-Task 'spooler-restart' 'Treiber / Dienste' 'Druckwarteschlange neu starten' 'Kann aktive Druckauftraege stoeren.' 'Restart-Service Spooler' 'Rueckfrage'
Add-Task 'search-restart' 'Treiber / Dienste' 'Windows-Suche neu starten' 'Startet den WSearch-Dienst neu.' 'Restart-Service WSearch' 'Rueckfrage'

Add-Task 'event-errors'   'Diagnose' 'System-Fehler (7 Tage)' 'Liest max. 40 letzte Systemfehler der letzten 7 Tage.' 'Get-WinEvent -FilterHashtable ...'
Add-Task 'event-apps'     'Diagnose' 'App-Fehler (7 Tage)' 'Liest max. 30 App-Fehler der letzten 7 Tage.' 'Get-WinEvent -FilterHashtable ...'
Add-Task 'sys-info'       'Diagnose' 'Systeminformationen' 'Version, Build, RAM, CPU und Rechnername im Log; sensible Daten beachten.' 'Get-ComputerInfo'
Add-Task 'reliability-ui' 'Diagnose' 'Zuverlaessigkeitsverlauf oeffnen' 'Oeffnet die grafische Fehlerchronik.' 'perfmon /rel'
Add-Task 'memory-ui'      'Diagnose' 'RAM-Diagnose oeffnen' 'Oeffnet die Speicherdiagnose mit moeglicher Neustart-Abfrage.' 'mdsched.exe' 'Rueckfrage'

Add-Task 'def-status'     'Sicherheit' 'Defender-Status' 'Zeigt Echtzeitschutz-, Scan- und Signaturstatus.' 'Get-MpComputerStatus'
Add-Task 'def-update'     'Sicherheit' 'Defender-Signaturen aktualisieren' 'Laedt Signaturaktualisierungen, falls Defender aktiv.' 'Update-MpSignature' 'Standard'
Add-Task 'def-quick'      'Sicherheit' 'Defender Schnellscan' 'Fuehrt eine schnelle Malwareueberpruefung durch.' 'Start-MpScan -ScanType QuickScan' 'Standard'
Add-Task 'def-full'       'Sicherheit' 'Defender Vollscan' 'Kann sehr lange dauern und das System belasten.' 'Start-MpScan -ScanType FullScan' 'Rueckfrage'
Add-Task 'def-threats'    'Sicherheit' 'Defender-Funde' 'Zeigt bekannte Defender-Funde.' 'Get-MpThreat'

Add-Task 'wmi-check'      'WMI' 'WMI-Konsistenz pruefen' 'Ueberprueft das WMI-Repository.' 'winmgmt /verifyrepository'
Add-Task 'wmi-salvage'    'WMI' 'WMI reparieren' 'Nur nach diagnostizierter Inkonsistenz; versucht Repository-Reparatur.' 'winmgmt /salvagerepository' 'Rueckfrage'

Add-Task 'winre-info'     'Wiederherstellung / Boot' 'WinRE-Status' 'Zeigt, ob die Windows-Wiederherstellungsumgebung aktiv ist.' 'reagentc /info'
Add-Task 'winre-enable'   'Wiederherstellung / Boot' 'WinRE aktivieren' 'Versucht WinRE mit vorhandener Wiederherstellungsumgebung zu aktivieren.' 'reagentc /enable' 'Rueckfrage'
Add-Task 'restore-list'   'Wiederherstellung / Boot' 'Wiederherstellungspunkte' 'Zeigt vorhandene Systemwiederherstellungspunkte.' 'Get-ComputerRestorePoint'
Add-Task 'restore-create' 'Wiederherstellung / Boot' 'Wiederherstellungspunkt anlegen' 'Erfordert aktiven Systemschutz; kann am Tageslimit scheitern.' 'Checkpoint-Computer' 'Standard'
Add-Task 'restore-ui'     'Wiederherstellung / Boot' 'Systemwiederherstellung oeffnen' 'Oeffnet den Assistenten; keine automatische Ruecksetzung.' 'rstrui.exe' 'Rueckfrage'
Add-Task 'bcd-read'       'Wiederherstellung / Boot' 'Boot-Eintraege anzeigen' 'Nur lesender Einblick in die BCD-Konfiguration.' 'bcdedit /enum all'

# Die neun Presets sind klar definiert. Rueckfrage-Schritte werden nur nach Zustimmung ausgefuehrt.
Add-Preset '1' 'Windows-Grundreparatur' 'DISM und SFC in sinnvoller Reihenfolge.' @('dism-check','dism-repair','sfc-repair')
Add-Preset '2' 'Dateisystem und Datentraeger' 'Online-Scan, Datentraegerstatus und Verschleisswerte.' @('disk-scan','disk-health','disk-reliable')
Add-Preset '3' 'Windows Update' 'Dienste pruefen, ETL-Log erzeugen, Cache-Reset nur nach Rueckfrage.' @('upd-services','upd-log','upd-cache')
Add-Preset '4' 'Netzwerk' 'Adapter, DNS, HTTPS, DNS-Cache und optionale Stack-Resets.' @('net-adapters','net-dns','net-test','net-proxy','net-flush','net-winsock','net-ipreset')
Add-Preset '5' 'Microsoft Store' 'Store-Paket und Cache, optionale erneute Registrierung.' @('store-status','store-wsreset','store-log','store-register')
Add-Preset '6' 'Treiber und Fehleranalyse' 'System-/Anwendungsereignisse, Treiber, Dienste und WMI-Pruefung.' @('sys-info','driver-problems','driver-list','service-state','event-errors','event-apps','wmi-check')
Add-Preset '7' 'Sicherheit' 'Defender-Zustand, Signaturen und Schnellscan.' @('def-status','def-update','def-quick')
Add-Preset '8' 'Systemwartung' 'Komponentenspeicher analysieren, optionale Bereinigung.' @('dism-analyze','dism-clean')
Add-Preset '9' 'Wiederherstellungsstatus' 'WinRE, Wiederherstellungspunkte und Boot-Konfiguration lesend pruefen.' @('winre-info','restore-list','bcd-read')

function Get-EventList {
    param([string]$LogName, [int]$Count)
    try {
        $events = @(Get-WinEvent -FilterHashtable @{
            LogName = $LogName; Level = 2; StartTime = (Get-Date).AddDays(-7)
        } -MaxEvents $Count -ErrorAction Stop)
        if ($events.Count -eq 0) { Write-Log 'Keine entsprechenden Fehler gefunden.'; return }
        foreach ($ev in $events) {
            $msg = ([string]$ev.Message -replace '\r?\n',' ')
            if ($msg.Length -gt 340) { $msg = $msg.Substring(0,340) + ' ...' }
            Write-Log ('{0} | ID {1} | {2} | {3}' -f $ev.TimeCreated,$ev.Id,$ev.ProviderName,$msg) 'OUT'
        }
    } catch {
        if ($_.FullyQualifiedErrorId -match 'NoMatchingEventsFound') {
            Write-Log 'Keine entsprechenden Fehler gefunden.'
        } else { throw }
    }
}

function Reset-UpdateCaches {
    Write-Log 'Es werden SoftwareDistribution und catroot2 UMBENANNT, nicht geloescht.' 'WARN'
    $names = @('bits','wuauserv','cryptsvc')
    $stopped = [System.Collections.Generic.List[string]]::new()
    $successful = 0
    try {
        foreach ($name in $names) {
            try {
                $svc = Get-Service -Name $name -ErrorAction Stop
                if ($svc.Status -ne 'Stopped') {
                    Write-Log "Stoppe Dienst $name ..."
                    Stop-Service -Name $name -Force -ErrorAction Stop
                    (Get-Service -Name $name).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(25))
                    $stopped.Add($name)
                }
            } catch { Write-Log ("Dienst $name konnte nicht gestoppt werden: $($_.Exception.Message)") 'WARN' }
        }
        $suffix = (Get-Date).ToString('yyyyMMdd-HHmmss')
        foreach ($rel in @('SoftwareDistribution','System32\catroot2')) {
            $source = Join-Path $env:windir $rel
            if (Test-Path -LiteralPath $source) {
                try {
                    $name = Split-Path -Leaf $source
                    $newName = '{0}.WindowsRepair-{1}' -f $name,$suffix
                    Rename-Item -LiteralPath $source -NewName $newName -ErrorAction Stop
                    Write-Log ("Umbenannt: {0} -> {1}" -f $source,$newName) 'OK'
                    $successful++
                } catch {
                    Write-Log ("Umbenennung fehlgeschlagen: {0}: {1}" -f $source,$_.Exception.Message) 'ERROR'
                }
            } else { Write-Log "Ordner nicht gefunden: $source" 'WARN' }
        }
    } finally {
        foreach ($name in $names) {
            try {
                $s = Get-Service -Name $name -ErrorAction Stop
                if ($s.Status -ne 'Running') {
                    Start-Service -Name $name -ErrorAction Stop
                    Write-Log "Dienst $name gestartet." 'OK'
                }
            } catch { Write-Log ("Dienst $name konnte nicht gestartet werden: $($_.Exception.Message)") 'WARN' }
        }
    }
    if ($successful -lt 2) { throw "Nur $successful von 2 Cache-Verzeichnissen umbenannt. Protokoll pruefen." }
    Write-Log 'Windows erstellt die Verzeichnisse bei Bedarf neu. Update-Downloads ggf. wiederholen.' 'WARN'
}

function Invoke-TaskBody {
    param([string]$Id)
    switch ($Id) {
        'dism-check'    { Invoke-External 'dism.exe' @('/Online','/Cleanup-Image','/CheckHealth'); break }
        'dism-scan'     { Invoke-External 'dism.exe' @('/Online','/Cleanup-Image','/ScanHealth'); break }
        'dism-repair'   { Invoke-External 'dism.exe' @('/Online','/Cleanup-Image','/RestoreHealth'); break }
        'sfc-verify'    { Invoke-External 'sfc.exe' @('/verifyonly'); break }
        'sfc-repair'    { Invoke-External 'sfc.exe' @('/scannow'); break }
        'sfc-cbs'       {
            $source = Join-Path $env:windir 'Logs\CBS\CBS.log'
            $target = Join-Path $script:SessionDir 'SFC-CBS-Auszug.txt'
            if (-not (Test-Path -LiteralPath $source)) { throw "CBS.log nicht gefunden: $source" }
            $matches = @(Select-String -LiteralPath $source -Pattern '\[SR\]' -ErrorAction Stop)
            $matches | ForEach-Object Line | Set-Content -LiteralPath $target -Encoding UTF8
            Write-Log ("{0} SFC-Zeilen in {1}" -f $matches.Count,$target) 'OK'
            break
        }
        'dism-analyze'  { Invoke-External 'dism.exe' @('/Online','/Cleanup-Image','/AnalyzeComponentStore'); break }
        'dism-clean'    { Invoke-External 'dism.exe' @('/Online','/Cleanup-Image','/StartComponentCleanup'); break }
        'dism-source'   {
            $path = (Read-Host 'Voller Pfad zu install.wim oder install.esd').Trim().Trim('"')
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'Quelldatei existiert nicht.' }
            $extension = [IO.Path]::GetExtension($path).ToLowerInvariant()
            if ($extension -notin @('.wim','.esd')) { throw 'Nur WIM oder ESD als Quelle erlaubt.' }
            Invoke-External 'dism.exe' @('/Get-WimInfo',"/WimFile:$path")
            $indexInput = Read-Host 'Image-Index der passenden Windows-Edition aus obiger Liste'
            $index = 0
            if (-not [int]::TryParse($indexInput, [ref]$index) -or $index -le 0) { throw 'Ungueltiger Image-Index.' }
            $kind = $extension.TrimStart('.').ToUpperInvariant()
            $src = '/Source:{0}:{1}:{2}' -f $kind,$path,$index
            Invoke-External 'dism.exe' @('/Online','/Cleanup-Image','/RestoreHealth',$src,'/LimitAccess')
            break
        }
        'disk-scan'     { Invoke-External 'chkdsk.exe' @($script:SystemDrive,'/scan') -AllowNonZero; break }
        'disk-spotfix'  { Invoke-External 'chkdsk.exe' @($script:SystemDrive,'/spotfix') -AllowNonZero; break }
        'disk-fix'      { Invoke-External 'chkdsk.exe' @($script:SystemDrive,'/f') -AllowNonZero; break }
        'disk-r'        { Invoke-External 'chkdsk.exe' @($script:SystemDrive,'/r') -AllowNonZero; break }
        'disk-health'   {
            $disks = @(Get-PhysicalDisk -ErrorAction Stop)
            Show-TextResult ($disks | Select-Object FriendlyName,DeviceId,MediaType,HealthStatus,OperationalStatus,Size | Format-Table -AutoSize)
            break
        }
        'disk-reliable' {
            $disks = @(Get-PhysicalDisk -ErrorAction Stop)
            foreach ($disk in $disks) {
                Write-Log ("Datentraeger: {0}" -f $disk.FriendlyName)
                try {
                    $values = $disk | Get-StorageReliabilityCounter -ErrorAction Stop
                    Show-TextResult ($values | Select-Object DeviceId,Temperature,Wear,ReadErrorsTotal,WriteErrorsTotal | Format-List)
                } catch { Write-Log "Keine Zuverlaessigkeitswerte: $($_.Exception.Message)" 'WARN' }
            }
            break
        }
        'upd-services'  { Show-TextResult (Get-Service -Name wuauserv,bits,cryptsvc | Format-Table -AutoSize); break }
        'upd-start'     {
            foreach ($name in @('wuauserv','bits','cryptsvc')) {
                $s = Get-Service -Name $name -ErrorAction Stop
                if ($s.Status -ne 'Running') { Start-Service -Name $name -ErrorAction Stop; Write-Log "$name gestartet" 'OK' }
                else { Write-Log "$name bereits aktiv" }
            }
            break
        }
        'upd-log'       {
            $target = Join-Path $script:SessionDir 'WindowsUpdate.log'
            Get-WindowsUpdateLog -LogPath $target -ErrorAction Stop | Out-Null
            Write-Log "Windows-Update-Protokoll erzeugt: $target" 'OK'
            break
        }
        'upd-cache'     { Reset-UpdateCaches; break }
        'net-adapters'  { Show-TextResult (Get-NetAdapter | Format-Table -AutoSize Name,InterfaceDescription,Status,LinkSpeed); break }
        'net-dns'       { Show-TextResult (Get-DnsClientServerAddress | Format-Table -AutoSize InterfaceAlias,AddressFamily,ServerAddresses); break }
        'net-test'      { Show-TextResult (Test-NetConnection -ComputerName 'microsoft.com' -Port 443 -InformationLevel Detailed | Format-List); break }
        'net-flush'     { Clear-DnsClientCache -ErrorAction Stop; Write-Log 'DNS-Cache geleert.' 'OK'; break }
        'net-register'  { Invoke-External 'ipconfig.exe' @('/registerdns'); break }
        'net-proxy'     { Invoke-External 'netsh.exe' @('winhttp','show','proxy'); break }
        'net-winsock'   { Invoke-External 'netsh.exe' @('winsock','reset'); Write-Log 'Neustart empfohlen.' 'WARN'; break }
        'net-ipreset'   { Invoke-External 'netsh.exe' @('int','ip','reset'); Write-Log 'Neustart empfohlen.' 'WARN'; break }
        'net-proxyreset'{ Invoke-External 'netsh.exe' @('winhttp','reset','proxy'); break }
        'net-renew'     { Invoke-External 'ipconfig.exe' @('/release'); Invoke-External 'ipconfig.exe' @('/renew'); break }
        'store-status'  {
            $pkg = Get-AppxPackage -Name 'Microsoft.WindowsStore' -ErrorAction Stop
            if (-not $pkg) { throw 'Microsoft Store beim aktuellen Benutzer nicht vorhanden.' }
            Show-TextResult ($pkg | Select-Object Name,PackageFullName,Status,InstallLocation | Format-List)
            break
        }
        'store-wsreset' { Invoke-External 'wsreset.exe' @(); break }
        'store-register'{
            $pkg = Get-AppxPackage -Name 'Microsoft.WindowsStore' -ErrorAction Stop | Select-Object -First 1
            if (-not $pkg) { throw 'Store nicht gefunden. Erneute Registrierung unmoeglich.' }
            $manifest = Join-Path $pkg.InstallLocation 'AppxManifest.xml'
            if (-not (Test-Path -LiteralPath $manifest)) { throw 'AppxManifest.xml fehlt.' }
            Add-AppxPackage -DisableDevelopmentMode -Register $manifest -ErrorAction Stop
            Write-Log 'Store-Registrierung angestossen.' 'OK'
            break
        }
        'store-reset'   {
            $pkg = Get-AppxPackage -Name 'Microsoft.WindowsStore' -ErrorAction Stop | Select-Object -First 1
            if (-not $pkg) { throw 'Store nicht gefunden.' }
            if (-not (Get-Command 'Reset-AppxPackage' -ErrorAction SilentlyContinue)) { throw 'Reset-AppxPackage in dieser Windows-Version nicht verfuegbar.' }
            Reset-AppxPackage -Package $pkg.PackageFullName -ErrorAction Stop
            Write-Log 'Store-App zurueckgesetzt.' 'OK'
            break
        }
        'store-log'     { Show-TextResult (Get-AppxLog -ErrorAction Stop | Select-Object -First 15 TimeCreated,Id,Message | Format-List); break }
        'driver-problems'{ Invoke-External 'pnputil.exe' @('/enum-devices','/problem'); break }
        'driver-list'   { Invoke-External 'pnputil.exe' @('/enum-drivers'); break }
        'driver-rescan' { Invoke-External 'pnputil.exe' @('/scan-devices'); break }
        'service-state' { Show-TextResult (Get-Service -Name wuauserv,bits,cryptsvc,WSearch,Spooler | Format-Table -AutoSize); break }
        'spooler-restart'{ Restart-Service -Name Spooler -ErrorAction Stop; Write-Log 'Druckwarteschlange neu gestartet.' 'OK'; break }
        'search-restart'{ Restart-Service -Name WSearch -ErrorAction Stop; Write-Log 'Suchdienst neu gestartet.' 'OK'; break }
        'event-errors'  { Get-EventList -LogName 'System' -Count 40; break }
        'event-apps'    { Get-EventList -LogName 'Application' -Count 30; break }
        'sys-info'      {
            $sys = Get-ComputerInfo -ErrorAction Stop | Select-Object CsName,WindowsProductName,WindowsVersion,OsBuildNumber,OsArchitecture,CsTotalPhysicalMemory,CsProcessors
            Show-TextResult ($sys | Format-List)
            break
        }
        'reliability-ui'{ Start-Process 'perfmon.exe' -ArgumentList '/rel' -ErrorAction Stop; Write-Log 'Zuverlaessigkeitsverlauf geoeffnet.'; break }
        'memory-ui'    { Start-Process 'mdsched.exe' -ErrorAction Stop; Write-Log 'RAM-Diagnose-Assistent gestartet; moeglicher Neustart.' 'WARN'; break }
        'def-status'    {
            Show-TextResult (Get-MpComputerStatus -ErrorAction Stop | Select-Object AMServiceEnabled,AntivirusEnabled,RealTimeProtectionEnabled,AntivirusSignatureLastUpdated,QuickScanEndTime,FullScanEndTime | Format-List)
            break
        }
        'def-update'    { Update-MpSignature -ErrorAction Stop; Write-Log 'Signaturupdate angestossen/abgeschlossen.' 'OK'; break }
        'def-quick'     { Start-MpScan -ScanType QuickScan -ErrorAction Stop; Write-Log 'Schnellscan abgeschlossen/angestossen (Defender-Status nachpruefen).' 'OK'; break }
        'def-full'      { Start-MpScan -ScanType FullScan -ErrorAction Stop; Write-Log 'Vollscan abgeschlossen/angestossen (Defender-Status nachpruefen).' 'OK'; break }
        'def-threats'   { Show-TextResult (Get-MpThreat -ErrorAction Stop | Select-Object -First 30 | Format-List); break }
        'wmi-check'     { Invoke-External 'winmgmt.exe' @('/verifyrepository'); break }
        'wmi-salvage'   { Invoke-External 'winmgmt.exe' @('/salvagerepository'); break }
        'winre-info'    { Invoke-External 'reagentc.exe' @('/info'); break }
        'winre-enable'  { Invoke-External 'reagentc.exe' @('/enable'); break }
        'restore-list'  {
            try {
                $points = @(Get-ComputerRestorePoint -ErrorAction Stop)
                if ($points.Count -eq 0) { Write-Log 'Keine Wiederherstellungspunkte verfuegbar.' 'WARN' }
                else { Show-TextResult ($points | Select-Object SequenceNumber,Description,CreationTime | Format-Table -AutoSize) }
            } catch { Write-Log "Systemschutz nicht verfuegbar oder ohne Punkte: $($_.Exception.Message)" 'WARN' }
            break
        }
        'restore-create'{
            Checkpoint-Computer -Description ('WindowsRepair ' + (Get-Date -Format 'yyyy-MM-dd HH:mm')) -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
            Write-Log 'Systemwiederherstellungspunkt angefordert.' 'OK'
            break
        }
        'restore-ui'    { Start-Process 'rstrui.exe' -ErrorAction Stop; Write-Log 'Systemwiederherstellungsassistent gestartet.'; break }
        'bcd-read'      { Invoke-External 'bcdedit.exe' @('/enum','all'); break }
        default         { throw "Unbekannte Aktion: $Id" }
    }
}

function Get-RiskMessage {
    param([string]$Id)
    switch ($Id) {
        'upd-cache'      { return 'Kann Update-Historie und heruntergeladene Updates beeinflussen. Nicht waehrend laufender Updates ausfuehren.' }
        'net-winsock'    { return 'Aendert Netzwerkstack; VPNs, Netzwerktreiber und Einstellungen koennen betroffen sein. Neustart noetig.' }
        'net-ipreset'    { return 'Setzt wichtige IP-Einstellungen zurueck. Statische Adressen, benutzerdefinierte DNS/VPNs pruefen; Neustart noetig.' }
        'net-renew'      { return 'Unterbricht die aktuelle DHCP-Netzwerkverbindung, ggf. auch eine Remote-Sitzung.' }
        'net-proxyreset' { return 'Entfernt einen ggf. absichtlich gesetzten WinHTTP-Proxy.' }
        'disk-r'         { return 'Kann sehr lange dauern. Bei Hardwaredefekt zuerst Daten sichern. Nicht fuer Routinediagnose.' }
        'disk-fix'       { return 'Kann Dateisystem aendern und einen Boot-Scan planen. Backup empfohlen.' }
        'disk-spotfix'   { return 'Repariert NTFS-Metadaten, ggf. mit Offline-Zeit. Backup empfohlen.' }
        'store-reset'    { return 'App-Daten und lokale Store-Einstellungen koennen verloren gehen.' }
        'store-register' { return 'Aendert die Paketregistrierung fuer den aktuellen Benutzer.' }
        'dism-clean'     { return 'Entfernt ersetzte Komponenten; kann die Deinstallation aelterer Updates beeinflussen.' }
        'dism-source'    { return 'Quelle muss exakt zum Windows-Komponentenstand passen; nur mit bekannter ISO verwenden.' }
        'wmi-salvage'    { return 'Nur nach inkonsistentem WMI-Repository nutzen. WMI abhaengige Programme koennen betroffen sein.' }
        'def-full'       { return 'Erhoehte Systemlast und unter Umstaenden stundenlange Laufzeit.' }
        'memory-ui'      { return 'Windows kann einen Neustart zur Speicherdiagnose anbieten.' }
        'restore-ui'     { return 'Eine im Assistenten bestaetigte Wiederherstellung kann Apps und Systemkonfiguration aendern.' }
        default          { return 'Dieser Schritt veraendert die Systemkonfiguration. Nur bei passendem Fehlerbild ausfuehren.' }
    }
}

function Invoke-OneTask {
    param([string]$Id)
    $task = $script:Tasks[$Id]
    if ($null -eq $task) { Write-Log "Ungueltige Task-ID: $Id" 'ERROR'; return }
    if ($task.Risk -eq 'Rueckfrage') {
        Write-Host ''
        Write-Host ('ACHTUNG: {0}' -f $task.Name) -ForegroundColor Yellow
        Write-Host (Get-RiskMessage -Id $Id) -ForegroundColor Yellow
        if (-not (Ask-YesNo 'Diesen Schritt wirklich ausfuehren?')) {
            Write-Log ("Uebersprungen (nicht bestaetigt): {0}" -f $task.Name) 'WARN'
            $script:History.Add([pscustomobject]@{
                Zeit = Get-Date; Id = $Id; Name = $task.Name; Status = 'Uebersprungen'; Sekunden = 0; Fehler = ''
            })
            return
        }
    }
    Write-Host ''
    Write-Log ("START: {0} [{1}]" -f $task.Name,$task.Command) 'RUN'
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $script:StepWarning = $false
    $status = 'OK'; $errorMessage = ''
    try {
        Invoke-TaskBody -Id $Id
        if ($script:StepWarning) { $status = 'Warnung' }
        if ($Id -in @('net-winsock','net-ipreset','upd-cache','disk-fix','disk-r','disk-spotfix')) {
            $script:RestartRecommended = $true
        }
        Write-Log ("BEENDET: {0} (Exitcode allein garantiert keine erfolgreiche Reparatur.)" -f $task.Name) 'OK'
    } catch {
        $status = 'Fehler'
        $errorMessage = $_.Exception.Message
        Write-Log ("FEHLER bei {0}: {1}" -f $task.Name,$errorMessage) 'ERROR'
    } finally {
        $watch.Stop()
        $script:History.Add([pscustomobject]@{
            Zeit = Get-Date; Id = $Id; Name = $task.Name; Status = $status;
            Sekunden = [math]::Round($watch.Elapsed.TotalSeconds, 1); Fehler = $errorMessage
        })
    }
}

function Invoke-Tasks {
    param([string[]]$Ids, [string]$BatchName)
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $unique = [System.Collections.Generic.List[string]]::new()
    foreach ($id in $Ids) {
        if ($script:Tasks.Contains($id) -and $seen.Add($id)) { $unique.Add($id) }
    }
    if ($unique.Count -eq 0) { Write-Host 'Keine gueltigen Schritte ausgewaehlt.' -ForegroundColor Yellow; return }
    # Im Komplettdurchlauf Netzwerk-/Update-Resets erst zum Schluss,
    # damit vorherige Diagnosen/Signaturupdates nicht gestoert werden.
    if ($BatchName -eq 'ALLE PRESETS') {
        $deferred = @('upd-cache','net-winsock','net-ipreset')
        $sorted = [System.Collections.Generic.List[string]]::new()
        foreach ($id in $unique) { if ($id -notin $deferred) { $sorted.Add($id) } }
        foreach ($id in $deferred) { if ($seen.Contains($id)) { $sorted.Add($id) } }
        $unique = $sorted
    }
    Write-Host ''
    Write-Host ('Auswahl: {0} | {1} unterschiedliche Schritte' -f $BatchName,$unique.Count) -ForegroundColor Cyan
    foreach ($id in $unique) {
        $task = $script:Tasks[$id]
        $note = if ($task.Risk -eq 'Rueckfrage') { ' [RUECKFRAGE]' } else { '' }
        Write-Host ('  - {0}{1}' -f $task.Name,$note)
    }
    Write-Host 'Es werden keine Neustarts automatisch ausgefuehrt.' -ForegroundColor Yellow
    if (-not (Ask-YesNo 'Diese Auswahl starten?')) { Write-Log "Abgebrochen: $BatchName" 'WARN'; return }

    $repairs = @('dism-repair','sfc-repair','upd-cache','net-winsock','net-ipreset','store-register','dism-clean')
    $hasRepair = @($unique | Where-Object { $_ -in $repairs }).Count -gt 0
    if ($hasRepair -and (Ask-YesNo 'Vorher einen Systemwiederherstellungspunkt versuchen? (Systemschutz muss aktiv sein)')) {
        Invoke-OneTask -Id 'restore-create'
    }

    Write-Log ("====== BEGINN: {0} ======" -f $BatchName) 'RUN'
    foreach ($id in $unique) { Invoke-OneTask -Id $id }
    Write-Log ("====== ENDE: {0} ======" -f $BatchName) 'OK'
    Show-RunSummary
}

function Show-RunSummary {
    Write-Host ''
    Write-Host '==== BISHERIGE ERGEBNISSE DIESER SITZUNG ====' -ForegroundColor Cyan
    if ($script:History.Count -eq 0) { Write-Host 'Noch keine Schritte ausgefuehrt.'; return }
    $ok = @($script:History | Where-Object Status -eq 'OK').Count
    $bad = @($script:History | Where-Object Status -eq 'Fehler').Count
    $skipped = @($script:History | Where-Object Status -eq 'Uebersprungen').Count
    $warn = @($script:History | Where-Object Status -eq 'Warnung').Count
    Write-Host ("OK: {0} | Warnungen: {1} | Fehler: {2} | Uebersprungen: {3}" -f $ok,$warn,$bad,$skipped)
    foreach ($row in $script:History) {
        $color = if ($row.Status -eq 'OK') { 'Green' } elseif ($row.Status -eq 'Fehler') { 'Red' } else { 'Yellow' }
        Write-Host ('{0,-13} {1,-40} {2,7}s' -f $row.Status,$row.Name,$row.Sekunden) -ForegroundColor $color
    }
    Write-Host 'Wichtig: OK bedeutet: Befehl ohne gemeldeten Fehler abgeschlossen, nicht zwingend: Problem behoben.' -ForegroundColor Yellow
    if ($script:RestartRecommended) { Write-Host 'Nach den ausgefuehrten Systemeingriffen ist ein Neustart empfehlenswert.' -ForegroundColor Yellow }
}

function Export-Session {
    if ($script:History.Count -eq 0) {
        Write-Host 'Noch keine Befehle ausgefuehrt. Bisher nur ein leeres Sitzungslog.' -ForegroundColor Yellow
    }
    $desktop = [Environment]::GetFolderPath('Desktop')
    if ([string]::IsNullOrWhiteSpace($desktop)) { $desktop = $env:USERPROFILE }
    $base = Read-Host "Log-Ordner (Enter = Desktop: $desktop)"
    if ([string]::IsNullOrWhiteSpace($base)) { $base = $desktop }
    $base = [Environment]::ExpandEnvironmentVariables($base.Trim().Trim('"'))
    try {
        if (-not (Test-Path -LiteralPath $base -PathType Container)) {
            New-Item -ItemType Directory -Path $base -Force -ErrorAction Stop | Out-Null
        }
        $dest = Join-Path $base ('WindowsRepair-Bericht-' + $script:Stamp)
        if (Test-Path -LiteralPath $dest) { $dest += '-' + [Guid]::NewGuid().ToString('N').Substring(0,8) }
        New-Item -ItemType Directory -Path $dest -ErrorAction Stop | Out-Null

        $summary = [System.Collections.Generic.List[string]]::new()
        $summary.Add('WindowsRepair ' + $script:Version)
        $summary.Add('Sitzungsbeginn: ' + $script:StartedAt)
        $summary.Add('Exportiert: ' + (Get-Date))
        $summary.Add('PC: ' + $env:COMPUTERNAME)
        $summary.Add('Windows: ' + [Environment]::OSVersion.VersionString)
        $summary.Add('')
        $summary.Add('Status OK bedeutet nur: keine gemeldete Ausnahme/kein unerwarteter Exitcode.')
        $summary.Add('Ein repariertes Betriebssystem kann daraus nicht garantiert werden.')
        $summary.Add('')
        foreach ($item in $script:History) {
            $summary.Add(('{0} | {1,-13} | {2} | {3}s' -f $item.Zeit,$item.Status,$item.Name,$item.Sekunden))
            if ($item.Fehler) { $summary.Add('  Fehler: ' + $item.Fehler) }
        }
        $summary | Set-Content -LiteralPath (Join-Path $script:SessionDir 'Zusammenfassung.txt') -Encoding UTF8
        ConvertTo-Json -InputObject @($script:History.ToArray()) -Depth 5 | Set-Content -LiteralPath (Join-Path $script:SessionDir 'Ergebnisse.json') -Encoding UTF8
        Write-Log "Logexport angefordert: $dest" 'INFO'
        Copy-Item -Path (Join-Path $script:SessionDir '*') -Destination $dest -Recurse -Force -ErrorAction Stop
        $script:ExportedPaths.Add($dest)
        Write-Host ('Bericht gespeichert: {0}' -f $dest) -ForegroundColor Green
        Write-Host 'Enthaelt ggf. Rechnernamen, IP-Adressen, Dateipfade und Fehlermeldungen. Nicht ungeprueft oeffentlich teilen.' -ForegroundColor Yellow
        return $true
    } catch {
        Write-Host ('Export fehlgeschlagen: {0}' -f $_.Exception.Message) -ForegroundColor Red
        return $false
    }
}

function Show-Presets {
    Write-Host ''
    Write-Host '=== REPARATUR-PRESETS ===' -ForegroundColor Cyan
    foreach ($preset in $script:Presets.Values) {
        Write-Host (' [{0}] {1}' -f $preset.Number,$preset.Name) -ForegroundColor White
        Write-Host ('     {0}' -f $preset.Explanation) -ForegroundColor Gray
    }
    Write-Host ' [A] ALLE Presets (einmal je Befehl, mit Rueckfragen bei Eingriffen)' -ForegroundColor Yellow
    Write-Host ' [M] Mehrere Presets waehlen (z.B. 1,3,6)'
    Write-Host ' [0] Zurueck'
    $choice = (Read-Host 'Auswahl').Trim().ToLowerInvariant()
    if ($choice -eq '0' -or -not $choice) { return }
    if ($choice -eq 'a') {
        Write-Host 'ALLE bedeutet: alle 9 Standard-Presets. Besonders riskante Einzelbefehle sind nur manuell verfuegbar.' -ForegroundColor Yellow
        $allIds = [System.Collections.Generic.List[string]]::new()
        foreach ($preset in $script:Presets.Values) { foreach ($id in $preset.Ids) { $allIds.Add($id) } }
        Invoke-Tasks -Ids $allIds.ToArray() -BatchName 'ALLE PRESETS'
        return
    }
    if ($choice -eq 'm') { $choice = Read-Host 'Preset-Nummern kommagetrennt (z.B. 1,3,6)' }
    $picked = [System.Collections.Generic.List[string]]::new()
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($num in ($choice -split '[,; ]+' | Where-Object { $_ })) {
        if ($script:Presets.Contains($num)) {
            $names.Add($script:Presets[$num].Name)
            foreach ($id in $script:Presets[$num].Ids) { $picked.Add($id) }
        } else { Write-Host ("Unbekanntes Preset: {0}" -f $num) -ForegroundColor Yellow }
    }
    if ($picked.Count -gt 0) { Invoke-Tasks -Ids $picked.ToArray() -BatchName ($names -join ' + ') }
}

function Show-IndividualTasks {
    Write-Host ''
    Write-Host '=== EINZELBEFEHLE / FREIE MEHRFACHAUSWAHL ===' -ForegroundColor Cyan
    Write-Host 'Eine Nummer oder mehrere durch Komma getrennt eingeben. [!] = Rueckfrage.'
    $index = @{}
    $n = 0
    $lastCategory = ''
    foreach ($task in $script:Tasks.Values) {
        if ($task.Category -ne $lastCategory) {
            Write-Host ("-- {0} --" -f $task.Category) -ForegroundColor Cyan
            $lastCategory = $task.Category
        }
        $n++
        $index[$n.ToString()] = $task.Id
        $warning = if ($task.Risk -eq 'Rueckfrage') { ' [!]' } else { '' }
        Write-Host (' {0,2}. {1}{2}' -f $n,$task.Name,$warning)
    }
    Write-Host '  0. Zurueck'
    $choice = (Read-Host 'Befehlsnummern, z.B. 2,5,18').Trim()
    if ($choice -eq '0' -or -not $choice) { return }
    $picked = [System.Collections.Generic.List[string]]::new()
    foreach ($num in ($choice -split '[,; ]+' | Where-Object { $_ })) {
        if ($index.ContainsKey($num)) { $picked.Add($index[$num]) }
        else { Write-Host ("Ungueltige Nummer: {0}" -f $num) -ForegroundColor Yellow }
    }
    if ($picked.Count -gt 0) {
        foreach ($id in $picked) {
            $task = $script:Tasks[$id]
            Write-Host ("{0}: {1}" -f $task.Name,$task.Explanation) -ForegroundColor Gray
        }
        Invoke-Tasks -Ids $picked.ToArray() -BatchName 'FREIE AUSWAHL'
    }
}

function Show-OfflineHelp {
    Write-Host ''
    Write-Host '=== STARTPROBLEME / WINRE (NUR ANLEITUNG) ===' -ForegroundColor Cyan
    Write-Host 'Kein automatisches Bootrec, BCDBoot oder DISM RevertPendingActions auf laufendem Windows.'
    Write-Host 'In WinRE zunaechst Windows-Laufwerk und EFI-Partition eindeutig identifizieren:'
    Write-Host '  diskpart' -ForegroundColor Yellow
    Write-Host '  list disk' -ForegroundColor Yellow
    Write-Host '  list volume' -ForegroundColor Yellow
    Write-Host '  exit' -ForegroundColor Yellow
    Write-Host 'UEFI-Beispiel (Laufwerke sind NUR PLATZHALTER!):' -ForegroundColor Yellow
    Write-Host '  bcdboot D:\Windows /s S: /f UEFI'
    Write-Host 'Bei ausstehenden Updateaktionen auf einem OFFLINE-Windows:' -ForegroundColor Yellow
    Write-Host '  DISM /Image:D:\ /Cleanup-Image /RevertPendingActions'
    Write-Host 'Offline-Systemdateien (Bootpartition kann von Windows-Partition abweichen):'
    Write-Host '  sfc /scannow /offbootdir=D:\ /offwindir=D:\Windows'
    Write-Host 'Bei BitLocker erst Wiederherstellungsschluessel sicherstellen.' -ForegroundColor Red
    Write-Host 'Quelle: https://learn.microsoft.com/windows-hardware/manufacture/desktop/bcdboot-command-line-options-techref-di'
    Write-Host 'NIEMALS beispielhafte Laufwerksbuchstaben unkontrolliert uebernehmen.' -ForegroundColor Red
}

function Show-MainMenu {
    do {
        Write-Host ''
        Write-Host '============================================================' -ForegroundColor Cyan
        Write-Host (' WindowsRepair {0} | Windows 10/11 | Admin' -f $script:Version) -ForegroundColor Cyan
        Write-Host '============================================================' -ForegroundColor Cyan
        Write-Host ' [1] Presets ausfuehren (inklusive ALLE)'
        Write-Host ' [2] Einzelbefehle / eigene Befehlskombination'
        Write-Host ' [3] Bisherige Ergebnisse anzeigen'
        Write-Host ' [4] Log und Debug-Bericht jetzt exportieren'
        Write-Host ' [5] WinRE / Bootreparatur-Hilfe (nur Anleitung)'
        Write-Host ' [0] Beenden (fragt nach Log-Export)'
        $inputValue = (Read-Host 'Auswahl').Trim().ToLowerInvariant()
        switch ($inputValue) {
            '1' { Show-Presets; Read-Host 'Enter fuer Hauptmenue' | Out-Null }
            '2' { Show-IndividualTasks; Read-Host 'Enter fuer Hauptmenue' | Out-Null }
            '3' { Show-RunSummary; Read-Host 'Enter fuer Hauptmenue' | Out-Null }
            '4' { [void](Export-Session); Read-Host 'Enter fuer Hauptmenue' | Out-Null }
            '5' { Show-OfflineHelp; Read-Host 'Enter fuer Hauptmenue' | Out-Null }
            '0' { return }
            default { Write-Host 'Ungueltige Auswahl.' -ForegroundColor Yellow }
        }
    } while ($true)
}

try {
    Write-Log ("WindowsRepair $script:Version gestartet | Benutzer: $env:USERNAME | PC: $env:COMPUTERNAME")
    Write-Log ("Windows: {0} | PowerShell: {1} | Sitzung: {2}" -f [Environment]::OSVersion.VersionString,$PSVersionTable.PSVersion,$script:SessionDir)
    Write-Host 'Hinweis: Bitte vor tiefgreifenden Reparaturen wichtige Daten sichern.' -ForegroundColor Yellow
    Write-Host 'Das Tool wird lokal ausgefuehrt und laedt keine fremden Skripte nach.'
    Show-MainMenu
} catch {
    Write-Log ("UNERWARTETER FEHLER: {0}" -f $_.Exception.ToString()) 'ERROR'
} finally {
    Write-Host ''
    Write-Host '=== SITZUNGSENDE ===' -ForegroundColor Cyan
    try { Show-RunSummary } catch {}
    $keep = $false
    try {
        if (Ask-YesNo 'Gesamtes Sitzungslog inklusive Debug-Bericht speichern?') {
            $keep = Export-Session
        }
    } catch { Write-Host ("Log-Abfrage gescheitert: {0}" -f $_.Exception.Message) -ForegroundColor Red; $keep = $true }
    try {
        Write-Log 'WindowsRepair wird beendet.'
        $script:LogWriter.Dispose()
        Remove-Item -LiteralPath $script:SessionDir -Recurse -Force -ErrorAction Stop
        if ($keep -or $script:ExportedPaths.Count -gt 0) {
            Write-Host 'Gespeicherte Berichte liegen am ausgewaehlten Exportort.' -ForegroundColor Green
        } else {
            Write-Host 'Temporaere Sitzungsdaten entfernt. Keine dauerhaften Logs gespeichert.'
        }
    } catch {
        Write-Host ("Temporaere Daten ggf. erhalten unter: {0}" -f $script:SessionDir) -ForegroundColor Yellow
    }
}
