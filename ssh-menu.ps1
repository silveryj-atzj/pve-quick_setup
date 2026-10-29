# PowerShell TUI SSH Menu
$ConfigFile = Join-Path $PSScriptRoot "networks.json"

if (-not (Test-Path $ConfigFile)) { throw "Config file not found: $ConfigFile" }

$nodes = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
$selectedIndex = 0

function Get-PveContainers {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Pve
    )

    Write-Host "正在从 $Pve 获取 LXC 列表..." -ForegroundColor DarkCyan
    $json = & ssh $Pve "pvesh get /cluster/resources --type vm --output-format json" 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "无法从 $Pve 获取 LXC 列表: $($json -join ' ')"
    }

    try {
        $containers = ($json -join "`n") | ConvertFrom-Json
    } catch {
        throw "PVE 返回的数据不是有效 JSON: $($_.Exception.Message)"
    }

    @($containers |
        Where-Object { $_.type -eq "lxc" -and $_.template -ne 1 } |
        Sort-Object { [int]$_.vmid } |
        ForEach-Object {
            [PSCustomObject]@{
                name = if ([string]::IsNullOrWhiteSpace($_.name)) { "LXC-$($_.vmid)" } else { $_.name }
                type = "pve_pct"
                pve = $Pve
                ctid = [string]$_.vmid
            }
        })
}

function Resolve-Nodes {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$ConfiguredNodes
    )

    $resolvedNodes = @()
    foreach ($node in $ConfiguredNodes) {
        if ($node.type -eq "pve_cts") {
            try {
                $resolvedNodes += Get-PveContainers -Pve $node.pve
            } catch {
                Write-Host "警告: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        } else {
            $resolvedNodes += $node
        }
    }

    if ($resolvedNodes.Count -eq 0) {
        throw "没有可用的节点。请检查 networks.json 或 PVE 连接。"
    }

    return $resolvedNodes
}

function Draw-Menu {
    Clear-Host
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "         快捷 SSH / PVE 节点选择器        " -ForegroundColor Yellow
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host " [↑/↓] 选择节点 | [Enter] 连接 | [Q] 退出`n" -ForegroundColor DarkGray

    for ($i = 0; $i -lt $nodes.Count; $i++) {
        $node = $nodes[$i]
        $typeLabel = if ($node.type -eq "direct") { "[直连]" } else { "[LXC-pct]" }
        
        if ($i -eq $selectedIndex) {
            Write-Host " > $($node.name) $typeLabel" -ForegroundColor Black -BackgroundColor White
        } else {
            Write-Host "   $($node.name) $typeLabel" -ForegroundColor Gray
        }
    }
}

$nodes = Resolve-Nodes -ConfiguredNodes @($nodes)

# 主循环捕获按键
while ($true) {
    Draw-Menu
    $key = [System.Console]::ReadKey($true)

    if ($key.Key -eq [ConsoleKey]::UpArrow) {
        if ($selectedIndex -gt 0) { $selectedIndex-- }
    }
    elseif ($key.Key -eq [ConsoleKey]::DownArrow) {
        if ($selectedIndex -lt ($nodes.Count - 1)) { $selectedIndex++ }
    }
    elseif ($key.Key -eq [ConsoleKey]::Enter) {
        Clear-Host
        $targetNode = $nodes[$selectedIndex]
        try {
            if ($targetNode.type -eq "direct") {
                Write-Host "正在直连 $($targetNode.name)..." -ForegroundColor Green
                & ssh $targetNode.target
            } elseif ($targetNode.type -eq "pve_pct") {
                Write-Host "正在通过 $($targetNode.pve) 进入 LXC $($targetNode.ctid)..." -ForegroundColor Green
                & ssh -t $targetNode.pve "pct enter $($targetNode.ctid)"
            }

            if ($LASTEXITCODE -ne 0) {
                throw "SSH 连接失败，退出代码: $LASTEXITCODE"
            }
        } catch {
            Write-Host "`n错误: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "按任意键返回节点列表..." -ForegroundColor Yellow
            [System.Console]::ReadKey($true) | Out-Null
        }
    }
    elseif ($key.Key -eq [ConsoleKey]::Q) {
        Clear-Host
        break
    }
}