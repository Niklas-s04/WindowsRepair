# Nachprüfung der Fehlerbehebung

Am 16. Oktober 2026 wurde WindowsRepair 1.0.1 in einer neuen Windows Sandbox unter Windows PowerShell 5.1 geprüft. Der Projektordner war nur lesbar eingebunden. Auf dem Host liefen keine Reparaturbefehle.

SHA-256 von `WindowsRepair.ps1`: `7051FE01BBEA0A03FCDF8DFB87234337F663F1D37D24044842928867ABB2F929`.

## Korrekturen

Bei einem fehlgeschlagenen abschließenden Export bleiben die ursprünglichen Sitzungsdaten erhalten. Das gilt auch, wenn die Speicherabfrage eine Ausnahme auslöst. Das Programm nennt den Pfad zur Wiederherstellung. Nach erfolgreichem Export oder ausdrücklichem Ablehnen werden temporäre Daten wie bisher entfernt.

Native Ausgaben werden direkt am Kindprozess mit der passenden Codierung gelesen. SFC und `cmd /u` verwenden UTF-16, CHKDSK und PnPUtil die Windows-ANSI-Codierung, DISM, ipconfig und REAgentC die OEM-Codepage der Windows-Systemsprache. Die übrigen Aufrufe verwenden die Konsolencodierung. Die globale Konsole wird dabei nicht umgestellt. Standardfehler wird parallel eingelesen und nach Standardausgabe protokolliert; die zeitliche Reihenfolge zwischen beiden Kanälen ist daher nicht garantiert.

## Ergebnis

`Invoke-SandboxTests.ps1 -ChecksOnly`: **21 Prüfgruppen bestanden, keine fehlgeschlagen**. Enthalten sind die bisherigen Menü-, Auswahl-, Bestätigungs-, Fehlerfortsetzungs- und Exportprüfungen sowie:

- beide zuvor fehlgeschlagenen Regressionstests;
- UTF-16 mit Umlauten und chinesischem Zeichen, Standardausgabe und Standardfehler;
- echte SFC-Hilfe und lokalisierte Hilfe von DISM, CHKDSK, netsh, ipconfig, PnPUtil, REAgentC und BCDEdit;
- native Argumente mit Leerzeichen, leeres Argument, Anführungszeichen und abschließende Backslashes;
- geerbte Standardeingabe und 100.000 Zeichen Fehlerausgabe ohne blockierte Pipes;
- Exitcodes, erlaubte Nicht-Null-Exitcodes und unveränderte Konsolencodierung;
- Start über die CMD-Datei, echte Adapterdiagnose und Berichtsexport;
- Erhalt der Logs nach Exportfehler und injiziertem Fehler der Speicherabfrage, Bereinigung nach erfolgreichem oder abgelehntem Export.

SFC gibt bei `/?` auch nach erfolgreicher Hilfeausgabe Exitcode 1 zurück. Der Test erlaubt diesen ausdrücklich und prüft zusätzlich den ausgegebenen Inhalt. Eine ergänzende echte WMI-Repositoryprüfung meldete ein konsistentes Repository.

## Grenzen und Nachvollziehbarkeit

Die 58 vollständigen Aktionsläufe aus dem [ursprünglichen Bericht](TEST-REPORT.md) wurden nicht wiederholt. Lange Reparaturläufe, Neustarts, eine Reparatur mit passender ISO und in der Sandbox fehlende Windows-Komponenten bleiben außerhalb dieser Nachprüfung. Deren ursprüngliche Fehler oder Zeitüberschreitungen sind damit nicht als behoben nachgewiesen.

Die Rohdaten der Nachprüfung liegen lokal unter `sandbox-results/fix-2026-10-16/` und werden nicht in Git aufgenommen. `checks.json` enthält die einzelnen Ergebnisse; die Hilfeausgaben und Exportproben liegen daneben. PowerShell-Syntaxprüfung und `git diff --check` wurden zusätzlich ausgeführt. Die Sandbox wurde nach Sicherung der Ergebnisse beendet.
