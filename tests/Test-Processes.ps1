#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\Repair.Engine.ps1')
$checks = 0
function Assert { param([bool]$Condition, [string]$Message); if (-not $Condition) { throw "ASSERTION FAILED: $Message" }; $script:checks++; Write-Host "PASS: $Message" }

# Check the real limited-query API against this test process; no memory reads,
# termination, or live repair. The rest of the process fixtures are synthetic.
$actual = Get-LimitedProcessImagePath $PID
Assert ($actual -and (Split-Path -Leaf $actual) -match '^(powershell|pwsh)\.exe$') 'Native limited image query resolves the test PowerShell process'
$script:fallbackCalls = 0
function Get-LimitedProcessImagePath {
    param([int]$ProcessId)
    $script:fallbackCalls++
    switch ($ProcessId) {
        1 { return 'C:\Users\example\AppData\Roaming\Elgato\StreamDeck\NodeJS\20.20.0\node.exe' }
        2 { return 'C:\fixture\runtimes\cua_node\hash\bin\node.exe' }
        3 { return $null }
    }
}
function Get-Process {
    param($Name, $ErrorAction)
    return @(
        [pscustomobject]@{ Id = 1; ProcessName = 'node'; Path = $null },
        [pscustomobject]@{ Id = 2; ProcessName = 'node'; Path = $null },
        [pscustomobject]@{ Id = 3; ProcessName = 'node'; Path = $null },
        [pscustomobject]@{ Id = 4; ProcessName = 'node'; Path = 'C:\Program Files\nodejs\node.exe' },
        [pscustomobject]@{ Id = 5; ProcessName = 'node_repl'; Path = 'C:\fixture\runtimes\cua_node\hash\bin\node_repl.exe' },
        [pscustomobject]@{ Id = 6; ProcessName = 'ChatGPT'; Path = 'C:\fixture\app\ChatGPT.exe' },
        [pscustomobject]@{ Id = 7; ProcessName = 'node'; Path = 'C:\fixture\computer-use-repair\chrome-resources\view\cua_node\bin\node.exe' },
        [pscustomobject]@{ Id = 8; ProcessName = 'extension-host'; Path = 'C:\fixture\.codex\plugins\cache\openai-bundled\chrome\1.0.0\extension-host\windows\x64\extension-host.exe' },
        [pscustomobject]@{ Id = 9; ProcessName = 'extension-host'; Path = 'C:\unrelated\extension-host.exe' }
    )
}
$blocking = @(Get-RepairProcesses 'C:/fixture/runtimes/cua_node')
Assert (1 -notin $blocking.Id) 'Stream Deck Node with a null Get-Process.Path is not misclassified'
Assert (2 -in $blocking.Id) 'A real Codex Node found through the fallback still blocks repair'
Assert (3 -in $blocking.Id -and ($blocking | Where-Object Id -eq 3).Reason -like '*unavailable*') 'Truly unreadable process paths still fail safely with a reason'
Assert (4 -notin $blocking.Id) 'An unrelated readable Node executable is ignored'
Assert (5 -in $blocking.Id -and 6 -in $blocking.Id) 'Node REPL and ChatGPT continue to block replacement'
Assert ($script:fallbackCalls -eq 3) 'Limited native queries are only used for unreadable paths'
Assert ((Format-RepairProcesses $blocking).Contains('node (PID 2)')) 'User-facing diagnostics include names and process IDs'
Assert (7 -in $blocking.Id) 'Node using the decrypted initialization view blocks replacement'
Assert (8 -in $blocking.Id) 'An active Chrome plugin bridge blocks replacement'
Assert (9 -notin $blocking.Id) 'Unrelated extension-host processes are excluded'
Write-Host "Passed $checks process assertions."
