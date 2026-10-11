<#
发布：把改动提交并推送到 GitHub。

注意：站点内容现在存在数据库（Supabase）里，
所以日常"改数据、传照片"不需要跑这个脚本；
只有改了网页代码（docs/ 下的 html/js/css）才需要。
#>
param([string]$Message = "更新站点")

$ErrorActionPreference = "Stop"
$proj = Split-Path $PSScriptRoot -Parent
$gitDir = "C:\Program Files\Git\cmd"
if (Test-Path $gitDir) { $env:Path = "$gitDir;" + $env:Path }
$git = Join-Path $gitDir "git.exe"
if (-not (Test-Path $git)) { $git = "git" }

Set-Location $proj

& $git add -A
$staged = (& $git diff --cached --name-only | Measure-Object).Count
if ($staged -eq 0) {
    Write-Host "没有改动，无需发布。" -ForegroundColor Yellow
    exit 0
}
Write-Host "暂存文件数: $staged" -ForegroundColor Cyan

& $git commit -m $Message
& $git push
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "推送失败。常见原因：" -ForegroundColor Yellow
    Write-Host "  1) 代理软件没开或换了端口 —— 查看系统代理端口后执行："
    Write-Host "     git config --local http.proxy http://127.0.0.1:<端口>"
    Write-Host "     git config --local https.proxy http://127.0.0.1:<端口>"
    Write-Host "  2) 未登录 GitHub —— 完成登录后重跑本脚本。"
    exit 1
}

Write-Host ""
Write-Host "发布完成，约 1 分钟后生效：" -ForegroundColor Green
Write-Host "    https://ethan-2332.github.io/chexie-memoir/" -ForegroundColor Green