#Requires -Version 5.1
<#
.SYNOPSIS
  在本机限速（不改路由器）。默认 10 kbit/s = 10000 bit/s。

.DESCRIPTION
  Windows 自带 QoS 主要限制「本机发出」的流量（上传、以及本机主动发出的包）。
  下载（别人发给你的）系统无法像路由器那样精确限速，脚本会尽量启用 QoS 调度器并写明这一点。

  用法（右键 PowerShell「以管理员身份运行」，或本脚本会尝试提权）：
    .\limit-rate.ps1 apply          # 全机出口 10kbit
    .\limit-rate.ps1 apply 10       # 同上，可改数字（单位 kbit/s）
    .\limit-rate.ps1 status
    .\limit-rate.ps1 remove

.NOTES
  10kbit 极慢（约 1.25 KB/s），浏览器几乎打不开，仅适合测试。
#>
param(
    [Parameter(Position = 0)]
    [ValidateSet("apply", "remove", "status")]
    [string]$Action = "status",

    [Parameter(Position = 1)]
    [ValidateRange(8, 1000000)]
    [int]$RateKbit = 10,

    [string]$PolicyName = "LocalDeviceRateLimit"
)

$ErrorActionPreference = "Stop"
$BitsPerSecond = $RateKbit * 1000

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    if ($Action -eq "status") {
        Write-Host "未提权：只能尽量查看。apply/remove 必须管理员。" -ForegroundColor Yellow
    }
    else {
        Write-Host "需要管理员权限，正在重新启动本脚本…" -ForegroundColor Yellow
        $self = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
        $arg = "-NoProfile -ExecutionPolicy Bypass -File `"$self`" $Action $RateKbit"
        Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList $arg
        exit
    }
}

function Enable-QosScheduler {
    $bindings = Get-NetAdapterBinding -ComponentID ms_pacer -ErrorAction SilentlyContinue |
        Where-Object { $_.Enabled -eq $false }
    foreach ($b in $bindings) {
        try {
            Enable-NetAdapterBinding -Name $b.Name -ComponentID ms_pacer -ErrorAction Stop
            Write-Host "已启用网卡 QoS 调度器: $($b.Name)"
        }
        catch {
            Write-Host "无法启用 $($b.Name) 的 QoS 调度器: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

function Show-Status {
    Write-Host "==== 本机限速策略 ===="
    $policies = @(Get-NetQosPolicy -ErrorAction SilentlyContinue)
    if ($policies.Count -eq 0) {
        Write-Host "（用户策略存储里没有 QoS 策略）"
    }
    else {
        $policies | Format-Table Name, ThrottleRateActionBitsPerSecond, NetworkProfile, IPProtocol -AutoSize
    }
    Write-Host "==== 活动存储 ===="
    Get-NetQosPolicy -PolicyStore ActiveStore -ErrorAction SilentlyContinue |
        Format-Table Name, Owner, ThrottleRateActionBitsPerSecond -AutoSize
}

switch ($Action) {
    "status" { Show-Status }

    "remove" {
        $existing = Get-NetQosPolicy -Name $PolicyName -ErrorAction SilentlyContinue
        if ($existing) {
            Remove-NetQosPolicy -Name $PolicyName -Confirm:$false
            Write-Host "已删除策略 $PolicyName"
        }
        else {
            Write-Host "没有名为 $PolicyName 的策略"
        }
        Show-Status
    }

    "apply" {
        Enable-QosScheduler
        $existing = Get-NetQosPolicy -Name $PolicyName -ErrorAction SilentlyContinue
        if ($existing) {
            Remove-NetQosPolicy -Name $PolicyName -Confirm:$false
        }
        # -Default：匹配未命中其它策略的流量（接近「整机出口」）
        New-NetQosPolicy -Name $PolicyName -Default -ThrottleRateActionBitsPerSecond $BitsPerSecond | Out-Null
        Write-Host ""
        Write-Host "已限速: 出口 $RateKbit kbit/s  ($BitsPerSecond bit/s)" -ForegroundColor Green
        Write-Host "这主要限制本机「发出」的数据。网页下载往往仍较快。"
        Write-Host "取消:  .\limit-rate.ps1 remove"
        Write-Host ""
        Show-Status
    }
}
