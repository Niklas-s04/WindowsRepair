# WindowsRepair

WindowsRepair bündelt Diagnose- und Reparaturbefehle für Windows 10 und 11 in einem interaktiven PowerShell-Menü. Du kannst ein Preset für ein bestimmtes Problem wählen oder einzelne Befehle kombinieren. Das Skript verwendet die Werkzeuge, die Windows mitbringt, darunter DISM, SFC und CHKDSK. Eine Installation oder zusätzliche PowerShell-Module brauchst du nicht.

Version 1.0.1 behebt die beim Sandbox-Test gefundenen Fehler beim Berichtsexport und bei der Zeichencodierung von Befehlsausgaben. Die [Nachprüfung](tests/FIX-VERIFICATION.md) dokumentiert die Regressionstests. Der [ursprüngliche Testbericht](tests/TEST-REPORT.md) enthält die Ergebnisse aller 58 Aktionen und die Grenzen der Sandbox-Prüfung. Probiere das Skript vor produktiver Nutzung zuerst auf einem Testsystem aus.

## Starten

1. [Projekt als ZIP herunterladen](https://github.com/Niklas-s04/WindowsRepair/archive/refs/heads/main.zip) und vollständig entpacken.
2. `WindowsRepair-Starten.cmd` doppelklicken und die Abfrage nach Administratorrechten bestätigen. Die Startdatei und `WindowsRepair.ps1` müssen im selben Ordner liegen.
3. Im Hauptmenü `1` für Presets oder `2` für einzelne Befehle wählen.
4. Die Auswahl prüfen und den Durchlauf bestätigen.

Im Preset-Menü kannst du mit `M` mehrere Presets auswählen, zum Beispiel `1,2,6`. Mit `A` startest du alle neun Presets. Aufgaben, die mehrfach vorkommen, werden pro Durchlauf nur einmal ausgeführt. Einige besonders eingreifende Befehle sind ausschließlich in der Einzelauswahl verfügbar.

Mit `3` siehst du die bisherigen Ergebnisse. Über `4` kannst du einen Bericht exportieren. Beim Beenden mit `0` fragt das Tool ebenfalls, ob du die Sitzung speichern möchtest. Unter `5` findest du Hinweise zu Startproblemen und WinRE.

Der Starter verwendet `-ExecutionPolicy Bypass` nur für den gestarteten Prozess. Die dauerhafte Ausführungsrichtlinie bleibt unverändert. Unternehmensrichtlinien oder fehlende Administratorrechte können den Start verhindern.

## Die Presets

| Nummer | Preset | Aufgaben |
| --- | --- | --- |
| 1 | Windows-Grundreparatur | DISM CheckHealth und RestoreHealth, anschließend SFC scannow |
| 2 | Dateisystem / Datenträger | CHKDSK Online-Scan, Datenträgerzustand und verfügbare Zuverlässigkeitswerte |
| 3 | Windows Update | Dienststatus, Update-Protokoll und optionales Umbenennen der Update-Caches |
| 4 | Netzwerk | Adapter, DNS, HTTPS-Verbindung, Proxy, DNS-Cache und optionale Winsock-/TCP-IP-Resets |
| 5 | Microsoft Store | Paketstatus, Cache, Deployment-Log und optionale Neuregistrierung |
| 6 | Treiber / Fehleranalyse | Systeminformationen, Gerätefehler, Treiber, Dienste, Ereignisprotokolle und WMI-Prüfung |
| 7 | Sicherheit | Defender-Status, Signaturupdate und Schnellscan |
| 8 | Systemwartung | WinSxS-Analyse und optionale Komponentenbereinigung |
| 9 | Wiederherstellungsstatus | WinRE, Wiederherstellungspunkte und BCD auslesen |

Die Einzelauswahl enthält insgesamt 58 Aktionen. Dazu gehören auch tiefere Scans, CHKDSK-Reparaturen, ein SFC-Protokollauszug, DISM mit einer ISO als Reparaturquelle, ein App-Reset, ein Defender-Vollscan und eine WMI-Reparatur.

## Vor einer Reparatur

Sichere wichtige Daten, bevor du Reparaturen ausführst. Bei einem vermuteten Hardwaredefekt sollte die Datenrettung vor einem CHKDSK-/r-Lauf stehen. DISM, SFC und CHKDSK beheben jeweils bestimmte Fehler; sie lösen nicht jedes Windows-Problem.

Das Skript fragt vor Eingriffen wie dem Zurücksetzen von Winsock, TCP/IP oder Update-Caches, einer Store-Neuregistrierung und Dateisystemreparaturen gesondert nach. Das gilt auch beim Ausführen aller Presets. Andere Aktionen, etwa SFC oder das Leeren des DNS-Caches, laufen nach der Bestätigung des Durchlaufs ohne weitere Einzelabfrage.

Vor ausgewählten Reparaturen bietet das Tool an, einen Wiederherstellungspunkt anzulegen. Dafür muss der Systemschutz aktiv sein. Das Anlegen kann trotzdem scheitern, etwa am Tageslimit. Schlägt ein Arbeitsschritt fehl, wird der Fehler protokolliert und der Durchlauf mit den übrigen Aufgaben fortgesetzt.

Neustarts werden nicht automatisch ausgeführt. Das Skript automatisiert auch keine Bootloader-Reparaturen oder Partitionseingriffe. `DISM /ResetBase`, `winmgmt /resetrepository`, `bootrec /fixmbr` und `bcdboot` werden nicht automatisch ausgeführt. Für Offline-Startprobleme gibt es eine Anleitung im Menü.

Ein Ergebnis mit dem Status „OK“ bedeutet, dass der Befehl ohne gemeldeten Fehler abgeschlossen wurde. Ob das ursprüngliche Problem behoben ist, musst du anschließend prüfen.

## Protokolle und Berichte

Während einer Sitzung schreibt das Skript seine Protokolle nach `%TEMP%\WindowsRepair-Sessions\...`. Beim Export kannst du einen Zielordner wählen; vorgeschlagen wird der Desktop.

Ein Bericht enthält:

- `WindowsRepair.log`: Ablaufprotokoll mit Befehlsausgaben
- `Zusammenfassung.txt`: Ergebnisse, Laufzeiten und Fehlermeldungen
- `Ergebnisse.json`: Ergebnisse zur maschinellen Weiterverarbeitung
- `WindowsUpdate.log` und `SFC-CBS-Auszug.txt`, sofern die jeweiligen Aktionen ausgeführt wurden

Nach einem erfolgreichen Export oder wenn du das Speichern ablehnst, versucht das Tool, den temporären Sitzungsordner zu löschen. Scheitert der gewünschte Export oder die abschließende Speicherabfrage, bleiben die Sitzungsdaten erhalten; das Programm zeigt ihren Pfad an. Exportierte Berichte bleiben erhalten. Nach einem Absturz oder abgebrochenen Lauf können ebenfalls temporäre Protokolle zurückbleiben.

Prüfe Berichte vor dem Teilen. Sie können Benutzernamen, Rechnernamen, installierte Programme, IP-Adressen und lokale Pfade enthalten. Die `.gitignore` schließt die vom Tool erzeugten Berichtsordner und Berichtsdateien aus, falls sie im Projektordner abgelegt werden.

## Voraussetzungen und Grenzen

Vorgesehen ist Windows 10 oder 11 mit Windows PowerShell 5.1 und Administratorrechten. Auf einem 64-Bit-Windows verlangt das Skript auch die 64-Bit-PowerShell.

Welche Befehle verfügbar sind, hängt von der Windows-Version, Edition und den aktivierten Komponenten ab. Das betrifft zum Beispiel Defender, WMI, Microsoft Store und den Systemschutz. Fehlende Komponenten werden als Fehler protokolliert.

DISM, CHKDSK und Defender-Vollscans können lange dauern. Unterbrich sie nicht ohne Grund. Das Skript lädt keine fremden Reparaturskripte nach; einzelne Windows-Werkzeuge können aber eine Internetverbindung nutzen, etwa für Reparaturdateien oder Defender-Signaturen.

## Fehler melden

Beschreibe in einem [Issue](https://github.com/Niklas-s04/WindowsRepair/issues), welche Windows-Version du nutzt, welche Aktion du gewählt hast und was passiert ist. Ein bereinigter Ausschnitt aus dem Protokoll hilft bei der Fehlersuche. Entferne persönliche Angaben vor dem Hochladen.

## Weiterführende Dokumentation

- [Microsoft: Windows-Image reparieren](https://learn.microsoft.com/de-de/windows-hardware/manufacture/desktop/repair-a-windows-image?view=windows-11)
- [Microsoft: Häufige Windows-Update-Fehler](https://learn.microsoft.com/de-de/troubleshoot/windows-client/installing-updates-features-roles/common-windows-update-errors)
- [Microsoft: CHKDSK](https://learn.microsoft.com/de-de/windows-server/administration/windows-commands/chkdsk)
- [Microsoft Support: Update-Probleme beheben](https://support.microsoft.com/de-de/windows/deployment/updates-lifecycle/troubleshoot-problems-updating-windows)
- [Microsoft Learn: Reset-AppxPackage](https://learn.microsoft.com/en-us/powershell/module/appx/reset-appxpackage)

Beide Skriptdateien liegen als lesbarer Quelltext vor und lassen sich vor dem Start in einem Editor prüfen und anpassen.
