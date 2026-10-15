# Sandbox-Tests

`Invoke-SandboxTests.ps1` testet die Originalfunktionen aus `WindowsRepair.ps1` und startet die unveränderte CMD-Datei für Menütests. Der Testtreiber verändert die Programmdateien nicht. Er benötigt Windows PowerShell 5.1 in Windows Sandbox, den angemeldeten Benutzer `WDAGUtilityAccount` mit Administratorrechten sowie zwei Ordnerfreigaben:

- `C:\Input`: Projektordner, nur lesbar
- `C:\TestResults`: eigener Ergebnisordner, beschreibbar

Die Tests führen Reparaturbefehle wirklich aus. Der Testtreiber verweigert den Start außerhalb der vorgesehenen Umgebung. Starte ihn ausschließlich in einer entbehrlichen Windows Sandbox.

## Ausführen

Auf dem Host in PowerShell, mit installierter Windows-Sandbox-CLI `wsb`:

```powershell
$project = (Get-Location).Path
$output = Join-Path $env:LOCALAPPDATA ('WindowsRepair-SandboxTests\' + (Get-Date -Format yyyyMMdd-HHmmss))
New-Item -ItemType Directory -Path $output | Out-Null
$sandbox = wsb start --config '<Configuration><VGpu>Disable</VGpu><MemoryInMB>4096</MemoryInMB><ClipboardRedirection>Disable</ClipboardRedirection><Networking>Enable</Networking></Configuration>' --raw | ConvertFrom-Json
wsb share --id $sandbox.Id --host-path $project --sandbox-path C:\Input
wsb share --id $sandbox.Id --host-path $output --sandbox-path C:\TestResults --allow-write
wsb connect --id $sandbox.Id
# Warten, bis der Sandbox-Desktop angemeldet ist, dann:
wsb exec --id $sandbox.Id --run-as ExistingLogin --command 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Input\tests\Invoke-SandboxTests.ps1'
```

Die Prüfungen für Auswahl, Bestätigung, Fehlerfortsetzung und Eingabevalidierung verwenden gezielt simulierte Antworten bzw. Befehle. Anschließend ruft der Treiber jede der 58 Aktionen in einem eigenen PowerShell-Prozess mit echten Windows-Werkzeugen auf. Die gefährlicheren Netzwerk- und Update-Resets laufen am Ende. DISM- und SFC-Aktionen dürfen jeweils zehn Minuten laufen, die übrigen jeweils drei Minuten. Bei Überschreitung wird der Prozessbaum innerhalb der Sandbox beendet und der Lauf als unvollständig erfasst.

Mit `-ChecksOnly` laufen nur die Prüfgruppen einschließlich der CMD-Integrationstests. `-TaskId <ID>` führt eine einzelne echte Aktion aus. `-Resume` setzt einen unterbrochenen Lauf mit dem vorhandenen Ergebnisordner fort, sofern der Hash der Programmdatei übereinstimmt. Bereits erfasste Aktionen, auch solche mit Timeout, werden dabei übersprungen. Lange SFC-/DISM-Prüfungen laufen am Ende. Diese Optionen gelten nur für den Testtreiber.

## Ergebnisse lesen

`Finished=true` bestätigt nur das Ende des Kindprozesses. Fehlt dessen `Result`, ist die Aktion unvollständig, etwa nach einem externen Prozessabbruch. Ein solcher Datensatz darf nicht als bestandener Test gezählt werden.

`checks.json` enthält die Prüfgruppen und ihre Assertions. `actions.json` enthält Laufzeit, Abschlussstatus und das vom Programm gemeldete Ergebnis jeder Aktion. `current-task.txt` zeigt den laufenden Schritt; `complete.txt` markiert das Ende des gesamten Laufs. Abgeschlossene Aktionen liefern außerdem JSON-Ergebnis und Ablaufprotokoll. Bei einem Timeout bleiben die bis dahin geschriebenen Standard- und Fehlerausgaben erhalten; ein abschließendes Programmergebnis fehlt. `environment.json` enthält die Umgebung und den SHA-256-Hash der getesteten Programmdatei; `environment-resume.json` beschreibt die Umgebung eines fortgesetzten Laufs.

Ein erfolgreich gestarteter Assistent beweist nicht, dass eine Wiederherstellung oder RAM-Prüfung funktioniert. CHKDSK erhält auf native Rückfragen `n`, damit keine Boot-Prüfung geplant wird. Eine passende Windows-ISO wird nicht mitgeliefert: Der echte ISO-Reparaturlauf prüft deshalb nur den Fehlerfall einer fehlenden Quelle; Argumentbildung für WIM/ESD und ungültige Indizes werden separat mit simuliertem DISM geprüft. Fehlende Sandbox-Komponenten und Laufzeitüberschreitungen müssen im Bericht als Einschränkung stehen.

Die Ergebnisdateien können Rechnernamen, IP-Adressen und lokale Pfade enthalten. Verwende einen lokalen Ausgabeordner außerhalb von Nextcloud oder anderer Dateisynchronisation und veröffentliche nur bereinigte Berichte.

Nach der Auswertung lässt sich die eigens angelegte Sandbox verwerfen:

```powershell
wsb stop --id $sandbox.Id
```
