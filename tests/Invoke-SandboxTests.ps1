#requires -Version 5.1
param([string]$TaskId, [switch]$ChecksOnly, [switch]$Resume)

$ErrorActionPreference = 'Stop'
# Never run repair commands on the host. This suite requires these explicit mappings
# and the disposable Windows Sandbox account, even when invoked accidentally.
if ($env:USERNAME -ne 'WDAGUtilityAccount' -or
    -not (Test-Path 'C:\Input\WindowsRepair.ps1') -or
    -not (Test-Path 'C:\TestResults')) {
    throw 'Run only inside Windows Sandbox as WDAGUtilityAccount with C:\Input and C:\TestResults mapped.'
}
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Sandbox test account must be elevated.'
}
$source = 'C:\Input\WindowsRepair.ps1'
function Write-ResultFile {
    param([string]$Path, [string]$Text)
    # The host may briefly hold a shared result file open while polling it.
    for ($attempt = 0; $attempt -lt 10; $attempt++) {
        try { [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($true)); return }
        catch [IO.IOException] { if ($attempt -eq 9) { throw }; Start-Sleep -Milliseconds 200 }
    }
}
$text = Get-Content -LiteralPath $source -Raw
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }

# Load original functions/catalogs without running the interactive entry point.
# This also leaves the original file intact for the separate startup smoke test.
$start = $text.IndexOf('$script:StartedAt =')
$end = $text.IndexOf('function Write-Log')
. ([scriptblock]::Create($text.Substring($start, $end - $start)))
$script:Version = '1.0.1'
foreach ($statement in $ast.EndBlock.Statements) {
    if ($statement -is [System.Management.Automation.Language.FunctionDefinitionAst] -or
        $statement.Extent.Text -match '^Add-(Task|Preset) ') {
        . ([scriptblock]::Create($statement.Extent.Text))
    }
}

if ($TaskId) {
    # Yes at the application's confirmation prompt; do not schedule a boot scan
    # through native stdin. A real, matching ISO is deliberately not fabricated.
    function Read-Host {
        param([string]$Prompt)
        if ($Prompt -like '*install.wim*') { return 'C:\missing-test-source.wim' }
        return 'j'
    }
    try {
        Invoke-OneTask -Id $TaskId
        $script:History | ConvertTo-Json -Depth 5 | Set-Content "C:\TestResults\$TaskId.json" -Encoding UTF8
    } finally {
        $script:LogWriter.Dispose()
        Copy-Item $script:LogFile "C:\TestResults\$TaskId.log"
    }
    exit
}

$transcript = if ($ChecksOnly) { 'C:\TestResults\checks-only.log' } elseif ($Resume) { 'C:\TestResults\resume.log' } else { 'C:\TestResults\suite.log' }
Start-Transcript -Path $transcript -Force | Out-Null
$checks = [System.Collections.Generic.List[object]]::new()
function Check {
    param([string]$Name, [scriptblock]$Body)
    try { & $Body; $checks.Add([pscustomobject]@{Name=$Name; Status='PASS'; Detail=''}) }
    catch { $checks.Add([pscustomobject]@{Name=$Name; Status='FAIL'; Detail=$_.Exception.Message}) }
    Write-ResultFile C:\TestResults\checks.json ($checks | ConvertTo-Json -Depth 5)
}
function Assert { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }
$script:Answers = [System.Collections.Generic.Queue[string]]::new()
function Read-Host {
    param([string]$Prompt)
    if ($script:Answers.Count -eq 0) { throw "Unexpected prompt: $Prompt" }
    return $script:Answers.Dequeue()
}
function Answers { param([string[]]$Values) $script:Answers.Clear(); foreach ($value in $Values) { $script:Answers.Enqueue($value) } }

if (-not $Resume) {
Check 'Catalog: 58 unique actions, 9 valid presets, all dispatch cases present' {
    Assert ($script:Tasks.Count -eq 58) 'Wrong task count'
    Assert ($script:Presets.Count -eq 9) 'Wrong preset count'
    $dispatch = (Get-Command Invoke-TaskBody).ScriptBlock.ToString()
    foreach ($id in $script:Tasks.Keys) { Assert ($dispatch.Contains("'$id'")) "Missing dispatch: $id" }
}
Check 'Yes/no: empty defaults, German/English, whitespace, invalid answer' {
    foreach ($case in @(@('', $false, $false), @('', $true, $true), @(' j ', $false, $true), @('JA', $false, $true), @('yes', $false, $true), @('n', $true, $false), @('invalid', $true, $false))) {
        Answers @($case[0]); Assert ((Ask-YesNo 'test' $case[1]) -eq $case[2]) 'Wrong confirmation result'
    }
}
Check 'Task and preset registration reject duplicates and unknown references' {
    $rejected = $false; try { Add-Task 'dism-check' 'x' 'x' 'x' 'x' } catch { $rejected = $true }
    Assert $rejected 'Duplicate accepted'
    $rejected = $false; try { Add-Preset 'test' 'x' 'x' @('missing') } catch { $rejected = $true }
    Assert $rejected 'Unknown task accepted'
}
Check 'Every risky task can be declined without executing its body' {
    function Invoke-TaskBody { throw 'Body must not run' }
    $script:History.Clear()
    foreach ($task in $script:Tasks.Values) {
        if ($task.Risk -eq 'Rueckfrage') {
            Answers @('n'); Invoke-OneTask $task.Id
            Assert ($script:History[-1].Status -eq 'Uebersprungen') "Not skipped: $($task.Id)"
            Assert (-not [string]::IsNullOrWhiteSpace((Get-RiskMessage $task.Id))) 'Missing risk warning'
        }
    }
}
Check 'Task errors are recorded, subsequent task continues, warning status survives' {
    function Invoke-TaskBody { param($Id) if ($Id -eq 'dism-check') { throw 'injected failure' }; $script:StepWarning = $true }
    $script:History.Clear(); Invoke-OneTask 'dism-check'; Invoke-OneTask 'dism-scan'
    Assert ($script:History[0].Status -eq 'Fehler') 'Failure swallowed'
    Assert ($script:History[1].Status -eq 'Warnung') 'Continuation/warning lost'
}
Check 'Batch deduplication, unknown IDs, and cancellation' {
    $script:Seen = [System.Collections.Generic.List[string]]::new()
    function Invoke-OneTask { param($Id) $script:Seen.Add($Id) }
    Answers @('j'); Invoke-Tasks @('dism-check','dism-check','missing','dism-scan') 'test'
    Assert (($script:Seen -join ',') -eq 'dism-check,dism-scan') 'Deduplication failed'
    $script:Seen.Clear(); Answers @('n'); Invoke-Tasks @('dism-check') 'cancel'
    Assert ($script:Seen.Count -eq 0) 'Canceled batch executed'
}
Check 'All presets defer network/update resets and deduplicate; multi-select works' {
    $script:Seen = [System.Collections.Generic.List[string]]::new()
    function Invoke-OneTask { param($Id) $script:Seen.Add($Id) }
    Answers @('a','j','n'); Show-Presets
    Assert (($script:Seen | Select-Object -Last 3) -join ',' -eq 'upd-cache,net-winsock,net-ipreset') 'Reset order wrong'
    Assert ($script:Seen.Count -eq @($script:Seen | Select-Object -Unique).Count) 'Duplicate action'
    $script:Seen.Clear(); Answers @('m','1,1,2','j','n'); Show-Presets
    Assert ($script:Seen.Count -eq 6) 'Preset multi-select wrong'
}
Check 'Individual selection and main menu: results, export, help, invalid input, exit' {
    $script:Seen = [System.Collections.Generic.List[string]]::new()
    function Invoke-OneTask { param($Id) $script:Seen.Add($Id) }
    Answers @('1,2,999','j'); Show-IndividualTasks
    Assert (($script:Seen -join ',') -eq 'dism-check,dism-scan') 'Individual selection wrong'
    $script:ExportCalled = $false
    function Export-Session { $script:ExportCalled = $true; return $true }
    Answers @('invalid','1','0','','2','0','','3','','4','','5','','0'); Show-MainMenu
    Assert $script:ExportCalled 'Export menu not reached'
    Assert ($script:Answers.Count -eq 0) 'Menu inputs unused'
}
Check 'External stdout/stderr, failing exit code, allowed nonzero exit and missing executable' {
    Invoke-External 'cmd.exe' @('/d','/c','echo stdout & echo stderr 1>&2 & exit /b 0')
    $rejected = $false; try { Invoke-External 'cmd.exe' @('/d','/c','exit /b 7') } catch { $rejected = $true }
    Assert $rejected 'Nonzero exit swallowed'
    $script:StepWarning = $false; Invoke-External 'cmd.exe' @('/d','/c','exit /b 7') -AllowNonZero
    Assert $script:StepWarning 'Nonzero warning missing'
    $rejected = $false; try { Invoke-External 'WindowsRepair-missing.exe' } catch { $rejected = $true }
    Assert $rejected 'Missing executable accepted'
}
Check 'UTF-16 native output is decoded without embedded NUL characters' {
    $before = [Console]::OutputEncoding.CodePage
    Invoke-External 'cmd.exe' @('/d','/u','/c','echo WindowsRepairUnicodeProbe')
    $sample = 'Gr' + [char]0x00fc + [char]0x00df + 'e ' + [char]0x4e2d
    Invoke-External 'cmd.exe' @('/d','/u','/c', "echo $sample & echo STDERR-$sample 1>&2")
    Assert ([Console]::OutputEncoding.CodePage -eq $before) 'Console encoding was not restored'
    try { Invoke-External 'cmd.exe' @('/d','/u','/c','exit /b 9') } catch {}
    Assert ([Console]::OutputEncoding.CodePage -eq $before) 'Console encoding changed after failure'
    $stream = [IO.File]::Open($script:LogFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    $reader = [IO.StreamReader]::new($stream)
    try { $log = $reader.ReadToEnd() } finally { $reader.Dispose() }
    Assert (-not $log.Contains([string][char]0)) 'UTF-16 native output was logged with embedded NUL characters'
    Assert ($log.Contains('[OUT] WindowsRepairUnicodeProbe')) 'Native Unicode output line was not decoded correctly'
    Assert ($log.Contains('[OUT] ' + $sample)) 'Non-ASCII Unicode output was corrupted'
    Assert ($log.Contains('[OUT] STDERR-' + $sample)) 'Non-ASCII Unicode stderr was corrupted'
}
Check 'Real SFC help and console-encoded command output remain readable' {
    # SFC returns 1 even when it successfully prints its help.
    Invoke-External 'sfc.exe' @('/?') -AllowNonZero
    $sample = 'OEM-Gr' + [char]0x00fc + [char]0x00df + 'e'
    Invoke-External 'cmd.exe' @('/d','/c', "echo $sample")
    $stream = [IO.File]::Open($script:LogFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    $reader = [IO.StreamReader]::new($stream)
    try { $log = $reader.ReadToEnd() } finally { $reader.Dispose() }
    Assert (-not $log.Contains([string][char]0)) 'SFC output contains embedded NUL characters'
    Assert ($log -match '\[OUT\].*SCANNOW') 'SFC help was not decoded'
    Assert ($log.Contains('[OUT] ' + $sample)) 'Console-encoded umlauts were corrupted'
}
Check 'Native argument quoting, inherited stdin and large stderr do not lose data or deadlock' {
    $fixture = @'
using System;
public class NativeProbe {
    public static void Main(string[] args) {
        foreach (string arg in args)
            Console.WriteLine("ARG=" + Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes(arg)));
        Console.Error.WriteLine(new string('x', 100000));
        Console.Error.WriteLine("STDERR-END");
        Console.WriteLine("INPUT=" + Console.ReadLine());
    }
}
'@
    $probe = 'C:\NativeProbe-' + [guid]::NewGuid().ToString('N') + '.exe'
    Add-Type -TypeDefinition $fixture -OutputAssembly $probe -OutputType ConsoleApplication
    $arguments = @('', 'C:\path with spaces\', 'embedded"quote', 'slashes\\"quote', '/Source:WIM:C:\image folder\install.wim:1')
    $driver = "function Write-Log { param([string]`$Text, [string]`$Level) Add-Content C:\TestResults\native-probe.log `$Text }`r`n" +
        'function Invoke-External {' + (Get-Command Invoke-External).ScriptBlock.ToString() + "}`r`n" +
        "Invoke-External '$probe' @(" + (($arguments | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }) -join ',') + ')'
    Set-Content C:\native-probe.ps1 $driver -Encoding UTF8
    Set-Content C:\TestResults\native-probe.log '' -Encoding UTF8
    Set-Content C:\native-probe-input.txt 'inherited-input' -Encoding ASCII
    $p = Start-Process powershell.exe -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File C:\native-probe.ps1' -RedirectStandardInput C:\native-probe-input.txt -RedirectStandardOutput C:\TestResults\native-probe.stdout.txt -RedirectStandardError C:\TestResults\native-probe.stderr.txt -PassThru -WindowStyle Hidden
    $null = $p.Handle
    if (-not $p.WaitForExit(30000)) { & taskkill.exe /PID $p.Id /T /F | Out-Null; throw 'Native IO deadlocked' }
    Assert ($p.ExitCode -eq 0) 'Native driver failed'
    $lines = @(Get-Content C:\TestResults\native-probe.log)
    foreach ($argument in $arguments) {
        Assert ($lines -contains ('ARG=' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($argument)))) "Argument corrupted: $argument"
    }
    Assert ($lines -contains 'STDERR-END') 'stderr was truncated'
    Assert ($lines -contains 'INPUT=inherited-input') 'Native stdin was not inherited'
}
Check 'Windows diagnostic tools preserve localized help text' {
    $script:NativeHelp = [System.Collections.Generic.List[string]]::new()
    function Write-Log { param($Text,$Level) if ($Level -eq 'OUT') { $script:NativeHelp.Add($Text) } }
    foreach ($exe in @('dism.exe','chkdsk.exe','netsh.exe','ipconfig.exe','pnputil.exe','reagentc.exe','bcdedit.exe')) {
        $script:NativeHelp.Clear()
        Invoke-External $exe @('/?') -AllowNonZero
        $help = $script:NativeHelp -join "`n"
        Assert ($help.Length -gt 100) "Missing help: $exe"
        Assert (-not $help.Contains([string][char]0xfffd) -and -not $help.Contains([string][char]0)) "Invalid encoding: $exe"
        if ([Globalization.CultureInfo]::CurrentUICulture.Name -eq 'de-DE') {
            $expected = switch ($exe) {
                'dism.exe' { 'f' + [char]0xfc + 'r die Bereitstellung' }
                'chkdsk.exe' { [string][char]0xdc + 'berpr' + [char]0xfc + 'ft' }
                'netsh.exe' { 'Dom' + [char]0xe4 + 'nenname' }
                'ipconfig.exe' { 'zul' + [char]0xe4 + 'ssig' }
                'pnputil.exe' { 'F' + [char]0xfc + 'gt dem Treiberspeicher' }
                'reagentc.exe' { 'Systemr' + [char]0xfc + 'cksetzung' }
                'bcdedit.exe' { 'Editor f' + [char]0xfc + 'r' }
            }
            Assert ($help.Contains($expected)) "Localized text corrupted: $exe"
        }
        $help | Set-Content "C:\TestResults\$exe-help.txt" -Encoding UTF8
    }
}
Check 'Report exports contain log, summary and valid result JSON' {
    Answers @('C:\TestResults\exports'); Assert (Export-Session) 'Export failed'
    $export = Get-Item -LiteralPath $script:ExportedPaths[$script:ExportedPaths.Count - 1]
    foreach ($name in @('WindowsRepair.log','Zusammenfassung.txt','Ergebnisse.json')) { Assert (Test-Path (Join-Path $export.FullName $name)) "Missing $name" }
    $data = Get-Content (Join-Path $export.FullName 'Ergebnisse.json') -Raw | ConvertFrom-Json
    Assert (@($data).Count -eq $script:History.Count) 'Wrong export count'
}
Check 'ISO source validation: missing file, wrong extension, invalid index, WIM and ESD arguments' {
    $script:Calls = [System.Collections.Generic.List[object]]::new()
    function Invoke-External { param($File, $Arguments) $script:Calls.Add(@($File) + @($Arguments)) }
    New-Item C:\Sources -ItemType Directory -Force | Out-Null
    foreach ($name in @('install.wim','install.esd','invalid.txt')) { Set-Content "C:\Sources\$name" 'test fixture, not an image' }
    foreach ($case in @(@('C:\missing.wim'), @('C:\Sources\invalid.txt'), @('C:\Sources\install.wim','0'), @('C:\Sources\install.wim','invalid'))) {
        Answers $case
        $rejected = $false; try { Invoke-TaskBody 'dism-source' } catch { $rejected = $true }
        Assert $rejected 'Bad source accepted'
    }
    foreach ($ext in @('wim','esd')) {
        $script:Calls.Clear(); Answers @("C:\Sources\install.$ext", '1'); Invoke-TaskBody 'dism-source'
        Assert ($script:Calls.Count -eq 2) 'Expected Get-WimInfo and repair calls'
        Assert ($script:Calls[1] -contains '/LimitAccess') 'Missing LimitAccess'
        Assert ($script:Calls[1] -contains ('/Source:{0}:C:\Sources\install.{1}:1' -f $ext.ToUpperInvariant(),$ext)) 'Wrong source argument'
    }
}
Check 'Empty result formatting, empty history export, export failure, unknown task' {
    Show-TextResult $null; Show-TextResult ([pscustomobject]@{Value='test'})
    $script:History.Clear(); Show-RunSummary
    Invoke-OneTask 'unknown-task'; Assert ($script:History.Count -eq 0) 'Unknown task added to history'
    Answers @('C:\TestResults\empty-export'); Assert (Export-Session) 'Empty export failed'
    Set-Content C:\not-a-directory.txt 'fixture'
    Answers @('C:\not-a-directory.txt\child'); Assert (-not (Export-Session)) 'Invalid export accepted'
    $rejected = $false; try { Invoke-TaskBody 'unknown-task' } catch { $rejected = $true }
    Assert $rejected 'Unknown dispatch accepted'
}
Check 'Unmodified CMD entry point: start, menu, exit and log export' {
    New-Item C:\Smoke -ItemType Directory -Force | Out-Null
    Copy-Item C:\Input\WindowsRepair.ps1,C:\Input\WindowsRepair-Starten.cmd C:\Smoke
    "3`r`n`r`n0`r`nj`r`nC:\TestResults\smoke-export" | Set-Content C:\Smoke\stdin.txt -Encoding ASCII
    $p = Start-Process cmd.exe -ArgumentList '/d /c C:\Smoke\WindowsRepair-Starten.cmd' -RedirectStandardInput C:\Smoke\stdin.txt -RedirectStandardOutput C:\TestResults\smoke.stdout.txt -RedirectStandardError C:\TestResults\smoke.stderr.txt -PassThru -WindowStyle Hidden
    $null = $p.Handle
    if (-not $p.WaitForExit(60000)) { & taskkill.exe /PID $p.Id /T /F | Out-Null; throw 'Entry point timed out' }
    Assert ($p.ExitCode -eq 0) "CMD exit: $($p.ExitCode)"
    Assert (Test-Path C:\TestResults\smoke-export) 'No smoke export'
    $output = Get-Content C:\TestResults\smoke.stdout.txt -Raw
    Assert ($output -match 'Sitzung: ([^\r\n]+)') 'Missing session path'
    Assert (-not (Test-Path -LiteralPath $Matches[1].Trim())) 'Successful export left temporary session behind'
}
Check 'Unmodified CMD: select real adapter diagnostic and verify exported result' {
    $number = [array]::IndexOf(@($script:Tasks.Keys), 'net-adapters') + 1
    "2`r`n$number`r`nj`r`n`r`n0`r`nj`r`nC:\TestResults\menu-export" | Set-Content C:\Smoke\menu-input.txt -Encoding ASCII
    $p = Start-Process cmd.exe -ArgumentList '/d /c C:\Smoke\WindowsRepair-Starten.cmd' -RedirectStandardInput C:\Smoke\menu-input.txt -RedirectStandardOutput C:\TestResults\menu.stdout.txt -RedirectStandardError C:\TestResults\menu.stderr.txt -PassThru -WindowStyle Hidden
    $null = $p.Handle
    if (-not $p.WaitForExit(60000)) { & taskkill.exe /PID $p.Id /T /F | Out-Null; throw 'Menu diagnostic timed out' }
    Assert ($p.ExitCode -eq 0) 'Menu process failed'
    $file = Get-ChildItem C:\TestResults\menu-export -Filter Ergebnisse.json -Recurse | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $result = @(Get-Content $file.FullName -Raw | ConvertFrom-Json)
    Assert ($result.Count -eq 1 -and $result[0].Id -eq 'net-adapters' -and $result[0].Status -eq 'OK') 'Wrong diagnostic result'
}
Check 'Failed final export preserves the requested session log for recovery' {
    "0`r`nj`r`nC:\not-a-directory.txt\child" | Set-Content C:\Smoke\failed-export-input.txt -Encoding ASCII
    $p = Start-Process cmd.exe -ArgumentList '/d /c C:\Smoke\WindowsRepair-Starten.cmd' -RedirectStandardInput C:\Smoke\failed-export-input.txt -RedirectStandardOutput C:\TestResults\failed-export.stdout.txt -RedirectStandardError C:\TestResults\failed-export.stderr.txt -PassThru -WindowStyle Hidden
    $null = $p.Handle
    if (-not $p.WaitForExit(60000)) { & taskkill.exe /PID $p.Id /T /F | Out-Null; throw 'Failed-export test timed out' }
    $output = Get-Content C:\TestResults\failed-export.stdout.txt -Raw
    Assert ($output -match 'Export fehlgeschlagen:') 'Export failure was not exercised'
    Assert ($output -match 'Sitzung: ([^\r\n]+)') 'Session directory not found in output'
    $session = $Matches[1].Trim()
    Assert (Test-Path -LiteralPath (Join-Path $session 'WindowsRepair.log')) 'Requested export failed and original session log was deleted'
    Assert ($output.Contains("Sitzungsdaten erhalten unter: $session")) 'Recovery path not shown'
}
Check 'Declining final export removes temporary session data' {
    "0`r`nn" | Set-Content C:\Smoke\decline-input.txt -Encoding ASCII
    $p = Start-Process cmd.exe -ArgumentList '/d /c C:\Smoke\WindowsRepair-Starten.cmd' -RedirectStandardInput C:\Smoke\decline-input.txt -RedirectStandardOutput C:\TestResults\decline.stdout.txt -RedirectStandardError C:\TestResults\decline.stderr.txt -PassThru -WindowStyle Hidden
    $null = $p.Handle
    if (-not $p.WaitForExit(60000)) { & taskkill.exe /PID $p.Id /T /F | Out-Null; throw 'Decline test timed out' }
    $output = Get-Content C:\TestResults\decline.stdout.txt -Raw
    Assert ($output -match 'Sitzung: ([^\r\n]+)') 'Missing session path'
    Assert (-not (Test-Path -LiteralPath $Matches[1].Trim())) 'Declined export left temporary session behind'
}
Check 'An exception in the final save prompt preserves the session log' {
    $original = "Ask-YesNo 'Gesamtes Sitzungslog inklusive Debug-Bericht speichern?'"
    Assert ($text.Contains($original)) 'Final prompt injection point missing'
    $text.Replace($original, "& { throw 'injected prompt failure' }") | Set-Content C:\Smoke\prompt-failure.ps1 -Encoding UTF8
    '0' | Set-Content C:\Smoke\prompt-input.txt -Encoding ASCII
    $p = Start-Process powershell.exe -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File C:\Smoke\prompt-failure.ps1' -RedirectStandardInput C:\Smoke\prompt-input.txt -RedirectStandardOutput C:\TestResults\prompt.stdout.txt -RedirectStandardError C:\TestResults\prompt.stderr.txt -PassThru -WindowStyle Hidden
    $null = $p.Handle
    if (-not $p.WaitForExit(60000)) { & taskkill.exe /PID $p.Id /T /F | Out-Null; throw 'Prompt failure test timed out' }
    $output = Get-Content C:\TestResults\prompt.stdout.txt -Raw
    Assert ($output -match 'Log-Abfrage gescheitert: injected prompt failure') 'Exception path not reached'
    Assert ($output -match 'Sitzung: ([^\r\n]+)') 'Missing session path'
    Assert (Test-Path -LiteralPath (Join-Path $Matches[1].Trim() 'WindowsRepair.log')) 'Prompt failure deleted original log'
}

} else {
    $previousEnvironment = Get-Content C:\TestResults\environment.json -Raw | ConvertFrom-Json
    if ($previousEnvironment.SourceSHA256 -ne (Get-FileHash $source -Algorithm SHA256).Hash) { throw 'Cannot resume results for a different source version.' }
    foreach ($check in (Get-Content C:\TestResults\checks.json -Raw | ConvertFrom-Json)) { $checks.Add($check) }
}

if ($ChecksOnly) {
    $script:LogWriter.Dispose()
    Stop-Transcript | Out-Null
    if (@($checks | Where-Object Status -eq 'FAIL').Count) { exit 1 }
    exit 0
}

# Execute the real task implementations, one child process each. Results are
# persisted immediately so unsupported commands or a timeout cannot hide coverage.
$environmentFile = if ($Resume) { 'C:\TestResults\environment-resume.json' } else { 'C:\TestResults\environment.json' }
@{Computer=$env:COMPUTERNAME; User=$env:USERNAME; PS=$PSVersionTable.PSVersion.ToString(); OS=[Environment]::OSVersion.VersionString; SourceSHA256=(Get-FileHash $source -Algorithm SHA256).Hash} | ConvertTo-Json | Set-Content $environmentFile -Encoding UTF8
$runs = [System.Collections.Generic.List[object]]::new()
if ($Resume) { foreach ($run in (Get-Content C:\TestResults\actions.json -Raw | ConvertFrom-Json)) { $runs.Add($run) } }
'n' | Set-Content C:\native-input.txt -Encoding ASCII
$deferred = @('upd-cache','net-winsock','net-ipreset','net-proxyreset','net-renew','sfc-verify','sfc-repair','sfc-cbs','dism-scan','dism-repair','dism-analyze','dism-clean')
$ids = @($script:Tasks.Keys | Where-Object { $_ -notin $deferred }) + $deferred
foreach ($id in $ids) {
    if ($id -in @($runs | ForEach-Object Id)) { continue }
    Write-ResultFile C:\TestResults\current-task.txt $id
    $limit = if ($id -match '^(dism|sfc)-') { 600 } else { 180 }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File C:\Input\tests\Invoke-SandboxTests.ps1 -TaskId $id" -RedirectStandardInput C:\native-input.txt -RedirectStandardOutput "C:\TestResults\$id.stdout.txt" -RedirectStandardError "C:\TestResults\$id.stderr.txt" -PassThru -WindowStyle Hidden
    $null = $p.Handle
    $finished = $p.WaitForExit($limit * 1000)
    if (-not $finished) { & taskkill.exe /PID $p.Id /T /F | Out-Null }
    $result = if (Test-Path "C:\TestResults\$id.json") { Get-Content "C:\TestResults\$id.json" -Raw | ConvertFrom-Json } else { $null }
    $runs.Add([pscustomobject]@{Id=$id; Finished=$finished; Seconds=[math]::Round($timer.Elapsed.TotalSeconds,1); ExitCode=$(if ($finished) {$p.ExitCode} else {$null}); Result=$result})
    Write-ResultFile C:\TestResults\actions.json ($runs | ConvertTo-Json -Depth 7)
}
$script:LogWriter.Dispose()
'Complete' | Set-Content C:\TestResults\complete.txt
Stop-Transcript | Out-Null
if (@($checks | Where-Object Status -eq 'FAIL').Count) { exit 1 }
