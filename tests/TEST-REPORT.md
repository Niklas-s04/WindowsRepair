# Sandbox-Testbericht

Dieser Bericht hält den Test von Version 1.0.0 fest. Die beiden hier beschriebenen Programmfehler wurden anschließend in Version 1.0.1 behoben; Ergebnisse und Umfang der Nachprüfung stehen in [FIX-VERIFICATION.md](FIX-VERIFICATION.md).

Testzeitraum: 14. bis 16. Oktober 2026. Getestet wird der unveränderte Stand `df53c50` von WindowsRepair 1.0.0. Die Programmdatei hat den SHA-256-Hash `5475A1573A7FE8EE658FD2D07FB62213BC657D43ACB35CEB5597AF86C17A58A9`.

Die Tests laufen in Windows Sandbox unter Windows PowerShell 5.1.26100.9549. DISM meldet für das Gastabbild Build 26100.9550. Nach dem Ende der ersten Sandbox wurde der Lauf am 15. Oktober in einer neuen Instanz fortgesetzt; bereits erfasste Ergebnisse wurden übernommen. Der Projektordner ist nur lesbar eingebunden; ein eigener Ausgabeordner nimmt die Ergebnisse auf. Auf dem Host werden keine Reparaturbefehle ausgeführt.

## Bestätigter Fehler: Protokollverlust bei fehlgeschlagenem Export

Beim Beenden fragt das Programm, ob die Sitzung gespeichert werden soll. Scheitert der gewünschte Export, löscht die abschließende Bereinigung trotzdem den temporären Sitzungsordner. Damit geht das ursprüngliche Protokoll verloren.

Reproduktion mit der unveränderten CMD-Datei:

1. Eine Datei `C:\not-a-directory.txt` anlegen.
2. WindowsRepair starten und im Hauptmenü `0` wählen.
3. Den Berichtsexport mit `j` bestätigen.
4. Als Ziel `C:\not-a-directory.txt\child` eingeben.
5. Das Programm meldet zuerst „Export fehlgeschlagen“ und danach „Temporaere Sitzungsdaten entfernt. Keine dauerhaften Logs gespeichert.“ Der ursprüngliche Sitzungsordner existiert anschließend nicht mehr.

`Export-Session` liefert bei einem Exportfehler `$false` zurück. Im abschließenden `finally`-Block wird der Sitzungsordner dennoch bedingungslos mit `Remove-Item` gelöscht (`WindowsRepair.ps1`, Zeile 746). Auch `$keep = $true` im Fehlerpfad der Log-Abfrage verhindert diese Löschung nicht.

Der Regressionstest `Failed final export preserves the requested session log for recovery` schlägt deshalb fehl. Erwartetes Verhalten: Bei einem angeforderten, aber fehlgeschlagenen Export bleibt das ursprüngliche Protokoll erhalten; das Programm nennt seinen Pfad oder bietet einen erneuten Export an.

## Bestätigter Fehler: UTF-16-Ausgaben enthalten Nullzeichen

Beim echten SFC-Aufruf enthalten die protokollierten Fortschrittszeilen zwischen den Buchstaben Nullzeichen. Die Ausgabe wird in `Invoke-External` über die native PowerShell-Pipeline eingelesen und anschließend unverändert in das UTF-8-Protokoll geschrieben. UTF-16-Ausgaben werden dabei nicht korrekt dekodiert.

Der Fehler lässt sich ohne langen SFC-Lauf mit `Invoke-External 'cmd.exe' @('/d','/u','/c','echo WindowsRepairUnicodeProbe')` reproduzieren. Der Test liest das Sitzungsprotokoll und findet darin eingebettete NUL-Zeichen. Der Regressionstest `UTF-16 native output is decoded without embedded NUL characters` schlägt fehl.

Erwartetes Verhalten: Native Ausgaben werden mit ihrer jeweiligen Kodierung eingelesen, sodass SFC-Text im Protokoll lesbar bleibt. Eine pauschale Umstellung aller Programme auf UTF-16 wäre nicht ausreichend, da andere Windows-Werkzeuge andere Kodierungen liefern. Im Test waren auch einzelne Umlaute von CHKDSK und netsh verstümmelt; deren interaktive Darstellung wurde nicht gesondert geprüft.

## Umfang und Grenzen

Der Testtreiber lädt die Originalfunktionen und den Aktionskatalog über den PowerShell-Parser. Menüauswahl, Bestätigungen, Fehlerfortsetzung, ungültige Eingaben und Exportpfade werden mit gezielten Assertions geprüft. Für Ablaufprüfungen werden einzelne Systemaufrufe simuliert. Zusätzlich starten Integrationstests die unveränderte CMD-Datei, einschließlich einer echten Adapterdiagnose und des Exportfehlerfalls.

Die 58 Aktionen werden anschließend einzeln mit echten Windows-Befehlen aufgerufen. Ein gemeldeter Status „OK“ belegt dabei nicht, dass ein zuvor beschädigtes Windows repariert wurde: Das Testabbild wurde nicht absichtlich beschädigt. Dialoge, Boot-Prüfungen, fehlende Komponenten und eine fehlende passende Windows-ISO begrenzen die Aussagekraft. CHKDSK erhält auf native Rückfragen `n`.

DISM- und SFC-Aufrufe haben jeweils zehn Minuten Zeit, andere Aktionen drei Minuten. Ein Timeout ist ein unvollständiger Test und kein Beleg für einen Programmfehler. Windows-Servicing kann nach dem Beenden eines DISM-Prozesses noch im Hintergrund arbeiten; nachfolgende Servicing-Aufrufe in derselben Sandbox sind deshalb nicht vollständig unabhängig.

Testtreiber und Anleitung: [Invoke-SandboxTests.ps1](Invoke-SandboxTests.ps1), [README.md](README.md).

## Ergebnisse

Alle 58 registrierten Aktionspfade wurden aufgerufen und einzeln erfasst. 37 lieferten den Programmstatus `OK`, zwölf `Fehler` und drei `Warnung`. Fünf Aufrufe erreichten das Zeitlimit. Die DISM-Analyse wurde nach der Sitzungsunterbrechung bei weiterhin angezeigten 16,5 Prozent manuell beendet. Damit bleiben sechs Langläufe ohne abschließendes Programmergebnis.

Von 16 gezielten Prüfgruppen bestehen 14. Zwei Regressionstests schlagen wegen der oben beschriebenen Programmfehler fehl. Ein `OK` in der folgenden Tabelle bedeutet nur den vom Programm gemeldeten Abschluss; die Einordnung beschreibt die tatsächliche Testgrenze.

| Aktion | Befehl laut Katalog | Erfasst | Einordnung |
| --- | --- | --- | --- |
| `dism-check` | `DISM /Online /Cleanup-Image /CheckHealth` | OK | CheckHealth beendet, Exitcode 0. |
| `dism-scan` | `DISM /Online /Cleanup-Image /ScanHealth` | Timeout | Nach zehn Minuten beendet; kein vollständiger Scan-Nachweis. |
| `dism-repair` | `DISM /Online /Cleanup-Image /RestoreHealth` | Timeout | 100-Prozent-Anzeige erreicht, aber kein Abschluss innerhalb von zehn Minuten. |
| `sfc-verify` | `sfc /verifyonly` | Timeout | Zeitlimit von zehn Minuten erreicht; kein abschließendes Programmergebnis. |
| `sfc-repair` | `sfc /scannow` | Timeout | Zeitlimit von zehn Minuten erreicht; kein abschließendes Programmergebnis. |
| `sfc-cbs` | `Select-String CBS.log [SR]` | OK | Aufruf ohne gemeldeten Fehler abgeschlossen. |
| `dism-analyze` | `DISM /Online /Cleanup-Image /AnalyzeComponentStore` | Abbruch | Nach Sitzungsunterbrechung bei 16,5 % manuell beendet; kein abschließendes Programmergebnis. |
| `dism-clean` | `DISM /Online /Cleanup-Image /StartComponentCleanup` | Timeout | Zeitlimit von zehn Minuten erreicht; kein abschließendes Programmergebnis. |
| `dism-source` | `DISM /Online /Cleanup-Image /RestoreHealth /Source:... /LimitAccess` | Fehler | Negativtest: fehlende Quelle korrekt abgewiesen. WIM-/ESD-Argumente separat simuliert geprüft; echte ISO-Reparatur offen. |
| `disk-scan` | `chkdsk C: /scan` | OK | Online-Dateisystemprüfung beendet. |
| `disk-spotfix` | `chkdsk C: /spotfix` | Warnung | Volume nicht sperrbar; Boot-Prüfung mit n abgelehnt. Keine Offline-Reparatur verifiziert. |
| `disk-fix` | `chkdsk C: /f` | Warnung | Volume nicht sperrbar; Boot-Prüfung mit n abgelehnt. Keine Offline-Reparatur verifiziert. |
| `disk-r` | `chkdsk C: /r` | Warnung | Volume nicht sperrbar; Boot-Prüfung mit n abgelehnt. Kein vollständiger Sektorscan. |
| `disk-health` | `Get-PhysicalDisk` | OK | Abfrage beendet, aber keine physischen Datenträger in der Sandbox geliefert. |
| `disk-reliable` | `Get-StorageReliabilityCounter` | OK | Keine physischen Datenträger geliefert; daher keine Hardware-Zuverlässigkeitswerte geprüft. |
| `upd-services` | `Get-Service wuauserv,bits,cryptsvc` | OK | Aufruf ohne gemeldeten Fehler abgeschlossen. |
| `upd-start` | `Start-Service wuauserv,bits,cryptsvc` | OK | Aufruf ohne gemeldeten Fehler abgeschlossen. |
| `upd-log` | `Get-WindowsUpdateLog` | OK | Aufruf ohne gemeldeten Fehler abgeschlossen. |
| `upd-cache` | `SoftwareDistribution/catroot2 umbenennen` | OK | Beide Cache-Verzeichnisse umbenannt; BITS, Windows Update und CryptSvc wieder gestartet. |
| `net-adapters` | `Get-NetAdapter` | OK | Aufruf ohne gemeldeten Fehler abgeschlossen. |
| `net-dns` | `Get-DnsClientServerAddress` | OK | Aufruf ohne gemeldeten Fehler abgeschlossen. |
| `net-test` | `Test-NetConnection microsoft.com -Port 443` | OK | DNS-Auflösung und TCP 443 erfolgreich (TcpTestSucceeded=True). |
| `net-flush` | `Clear-DnsClientCache` | OK | Aufruf ohne gemeldeten Fehler abgeschlossen. |
| `net-register` | `ipconfig /registerdns` | OK | Aufruf ohne gemeldeten Fehler abgeschlossen. |
| `net-proxy` | `netsh winhttp show proxy` | OK | Aufruf ohne gemeldeten Fehler abgeschlossen. |
| `net-winsock` | `netsh winsock reset` | OK | Reset beendet; Wirksamkeit nach Neustart nicht geprüft. |
| `net-ipreset` | `netsh int ip reset` | Fehler | Teilweise ausgeführt; mindestens ein Teilschritt mit Zugriff verweigert, Exitcode 1. |
| `net-proxyreset` | `netsh winhttp reset proxy` | OK | WinHTTP-Proxy zurückgesetzt. |
| `net-renew` | `ipconfig /release und /renew` | OK | DHCP-Freigabe und Erneuerung beendet. |
| `store-status` | `Get-AppxPackage -Name Microsoft.WindowsStore` | Fehler | Microsoft Store für den Sandbox-Benutzer nicht installiert. |
| `store-wsreset` | `wsreset.exe` | OK | Prozess liefert Exitcode 0; ohne Store-Installation keine Cache-Reparaturwirkung belegt. |
| `store-register` | `Add-AppxPackage -Register AppxManifest.xml` | Fehler | Store nicht installiert; Fehlerpfad geprüft. |
| `store-reset` | `Reset-AppxPackage Microsoft.WindowsStore` | Fehler | Store nicht installiert; Fehlerpfad geprüft. |
| `store-log` | `Get-AppxLog` | OK | Aufruf ohne gemeldeten Fehler abgeschlossen. |
| `driver-problems` | `pnputil /enum-devices /problem` | OK | Aufruf ohne gemeldeten Fehler abgeschlossen. |
| `driver-list` | `pnputil /enum-drivers` | OK | Aufruf ohne gemeldeten Fehler abgeschlossen. |
| `driver-rescan` | `pnputil /scan-devices` | OK | Aufruf ohne gemeldeten Fehler abgeschlossen. |
| `service-state` | `Get-Service wuauserv,bits,cryptsvc,WSearch,Spooler` | OK | Aufruf ohne gemeldeten Fehler abgeschlossen. |
| `spooler-restart` | `Restart-Service Spooler` | OK | Aufruf ohne gemeldeten Fehler abgeschlossen. |
| `search-restart` | `Restart-Service WSearch` | Fehler | WSearch ist in der Sandbox deaktiviert und lässt sich nicht starten. |
| `event-errors` | `Get-WinEvent -FilterHashtable ...` | OK | Aufruf ohne gemeldeten Fehler abgeschlossen. |
| `event-apps` | `Get-WinEvent -FilterHashtable ...` | OK | Aufruf ohne gemeldeten Fehler abgeschlossen. |
| `sys-info` | `Get-ComputerInfo` | OK | Aufruf ohne gemeldeten Fehler abgeschlossen. |
| `reliability-ui` | `perfmon /rel` | OK | Assistent aufgerufen; Oberfläche und weitere Interaktion nicht automatisiert geprüft. |
| `memory-ui` | `mdsched.exe` | OK | Assistent aufgerufen; keine RAM-Prüfung nach Neustart durchgeführt. |
| `def-status` | `Get-MpComputerStatus` | OK | Status lesbar; Defender, Virenschutz und Echtzeitschutz deaktiviert. |
| `def-update` | `Update-MpSignature` | Fehler | WinDefend deaktiviert; Signaturupdate meldet Fehler. |
| `def-quick` | `Start-MpScan -ScanType QuickScan` | Fehler | WinDefend deaktiviert; kein erfolgreicher Schnellscan. |
| `def-full` | `Start-MpScan -ScanType FullScan` | Fehler | WinDefend deaktiviert; kein erfolgreicher Vollscan. |
| `def-threats` | `Get-MpThreat` | OK | Abfrage beendet; kein Nachweis funktionierender Erkennung oder Bereinigung. |
| `wmi-check` | `winmgmt /verifyrepository` | OK | Aufruf ohne gemeldeten Fehler abgeschlossen. |
| `wmi-salvage` | `winmgmt /salvagerepository` | OK | Befehl beendet; keine absichtlich beschädigte WMI-Datenbank als Testfall. |
| `winre-info` | `reagentc /info` | OK | Status lesbar: WinRE deaktiviert, kein Wiederherstellungsimage registriert. |
| `winre-enable` | `reagentc /enable` | Fehler | Windows-RE-Image fehlt; Exitcode 1614. |
| `restore-list` | `Get-ComputerRestorePoint` | OK | Keine Wiederherstellungspunkte vorhanden; Warnung im Log, Programmstatus OK. |
| `restore-create` | `Checkpoint-Computer` | Fehler | Anlegen scheitert an einem deaktivierten bzw. nicht verfügbaren Dienst. |
| `restore-ui` | `rstrui.exe` | OK | Assistent aufgerufen; keine Systemwiederherstellung durchgeführt. |
| `bcd-read` | `bcdedit /enum all` | Fehler | Boot-Konfigurationsspeicher nicht zugreifbar; Systemgerät nicht gefunden, Exitcode 1. |

## Nachvollziehbarkeit

Die Rohdaten liegen lokal unter `sandbox-results/2026-10-14-to16/` und sind über `.gitignore` von Git ausgeschlossen. `actions.json` enthält alle 58 Aktionsdatensätze, `checks.json` die 16 Prüfgruppen und `test-interruptions.json` den manuellen Abbruch. Die Programme und Befehle wurden ausschließlich in der Sandbox ausgeführt. Die beiden Programmdateien wurden für diese ursprüngliche Prüfung nicht geändert; die Fehlerbehebung erfolgte im Anschluss.

Die Sandbox wurde nach dem Sichern der Ergebnisse beendet. Dieser Lauf bestätigt weder die Reparatur einer absichtlich beschädigten Windows-Installation noch die Funktion der fehlenden bzw. deaktivierten Komponenten auf einer vollständigen Windows-Installation.
