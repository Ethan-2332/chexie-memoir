<#
一条命令完成发布：重新生成站点 → 提交 → 推送

用法（在任意位置）：
    powershell -ExecutionPolicy Bypass -File "C:\deepseek\Agent工作区\车协回忆录-网站\scripts\publish.ps1"
    powershell -ExecutionPolicy Bypass -File "...\publish.ps1" -Message "新增 3 张玄武湖照片"

说明：
  * 数据改了、照片加了，跑这个脚本就会自动更新到线上。
  * 本仓库已配置走本机代理（本机直连 github.com 不稳定）。如果代理软件关闭或换了端口，
    推送会失败，按提示改端口即可。
#>
param(
    [string]$Message = "更新投稿数据"
)

$ErrorActionPreference = "Stop"
$proj = Split-Path $PSScriptRoot -Parent
$gitDir = "C:\Program Files\Git\cmd"
if (Test-Path $gitDir) { $env:Path = "$gitDir;" + $env:Path }
$git = Join-Path $gitDir "git.exe"
if (-not (Test-Path $git)) { $git = "git" }

$py = "C:\Users\13338\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe"
if (-not (Test-Path $py)) { $py = "python" }

Write-Host "==> 项目目录: $proj" -ForegroundColor Cyan
Set-Location $proj

Write-Host "==> 1/4 重新生成站点" -ForegroundColor Cyan
& $py (Join-Path $PSScriptRoot "build_site.py")

Write-Host "==> 2/4 暂存改动" -ForegroundColor Cyan
& $git add -A
$staged = (& $git diff --cached --name-only | Measure-Object).Count
Write-Host "    暂存文件数: $staged"
if ($staged -eq 0) {
    Write-Host "    没有改动，无需发布。" -ForegroundColor Yellow
    exit 0
}

Write-Host "==> 3/4 提交" -ForegroundColor Cyan
& $git commit -m $Message

Write-Host "==> 4/4 推送到 GitHub" -ForegroundColor Cyan
& $git push
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "推送失败。常见原因与处理：" -ForegroundColor Yellow
    Write-Host "  1) 代理软件没开或换了端口 —— 查看系统代理端口后执行："
    Write-Host "     git config --local http.proxy http://127.0.0.1:<端口>"
    Write-Host "     git config --local https.proxy http://127.0.0.1:<端口>"
    Write-Host "  2) 未登录 GitHub —— 会弹出登录窗口，完成授权后重跑本脚本。"
    exit 1
}

Write-Host ""
Write-Host "发布完成。约 1 分钟后生效：" -ForegroundColor Green
Write-Host "    https://ethan-2332.github.io/chexie-memoir/" -ForegroundColor Green
