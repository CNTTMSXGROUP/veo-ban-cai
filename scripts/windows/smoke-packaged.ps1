#Requires -Version 7.0
param(
  [string]$InstallDir,
  [string]$Version,
  [switch]$OpenApp
)

$ErrorActionPreference = 'Stop'
$Root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$Target = if ($env:CARGO_TARGET_DIR) { $env:CARGO_TARGET_DIR } else { Join-Path $Root 'target' }
$Rel = if ($InstallDir) { (Resolve-Path $InstallDir).Path } else { Join-Path $Target 'x86_64-pc-windows-msvc\release' }
$Worker = if ($InstallDir) { Join-Path $Rel 'worker' } else { Join-Path $Root 'src-tauri\resources\worker' }
$Node = Join-Path $Rel 'node.exe'
$Ffmpeg = Join-Path $Rel 'ffmpeg.exe'
$Ffprobe = Join-Path $Rel 'ffprobe.exe'
$Entry = Join-Path $Worker 'dung-app.mjs'
$AppFile = Join-Path $Rel 'msx-phong-dung.exe'
$LocalPath = "$env:SystemRoot\System32;$env:SystemRoot"
$Temp = Join-Path ([IO.Path]::GetTempPath()) ("veo-smoke-" + [guid]::NewGuid().ToString('N'))
$Child = $null
$App = $null

function Invoke-Tool([string]$Exe, [string[]]$Argv) {
  $output = & $Exe @Argv
  if ($LASTEXITCODE -ne 0) { throw "$(Split-Path -Leaf $Exe) thoát lỗi $LASTEXITCODE" }
  return $output
}
function Get-Veo([string]$Route) {
  Invoke-RestMethod "$Base/api/$Route" -Headers $Headers -TimeoutSec 60
}
function Send-Veo([string]$Route, [hashtable]$Body) {
  Invoke-RestMethod "$Base/api/$Route" -Method Post -Headers $Headers -ContentType 'application/json; charset=utf-8' `
    -Body ($Body | ConvertTo-Json -Depth 20 -Compress) -TimeoutSec 90
}
function Wait-VeoJob([string]$Id, [string]$Kind) {
  $Until = [DateTime]::UtcNow.AddSeconds(120)
  do {
    $Row = (Get-Veo 'state').projects | Where-Object id -eq $Id | Select-Object -First 1
    $Job = $Row.job
    if ($Job.kind -eq $Kind -and $Job.state -in @('loi','bi-ngat','da-huy')) {
      throw "Việc $Kind lỗi $($Job.error.message) $($Job.error.detail)"
    }
    if ($Job.kind -eq $Kind -and $Job.state -eq 'xong' -and !$Row.busy) { return $Job }
    Start-Sleep -Milliseconds 300
  } while ([DateTime]::UtcNow -lt $Until)
  throw "Việc $Kind chưa chạy xong."
}
function Get-Streams([string]$File) {
  $Json = Invoke-Tool $Ffprobe @('-v','error','-of','json','-show_entries','stream=codec_name,width,height,nb_frames,avg_frame_rate',$File)
  (($Json -join [Environment]::NewLine) | ConvertFrom-Json).streams
}
function Export-Veo([string]$Id, [string]$Name, [int]$Frames) {
  $null = Send-Veo "projects/$Id/export" @{ dir = $Temp; name = $Name; video = $true; check = $true; res = 720 }
  $Video = (Wait-VeoJob $Id 'xuat').files | Where-Object { $_.EndsWith('.mp4') } | Select-Object -First 1
  if (!$Video) { throw 'Không thấy MP4 trong kết quả xuất.' }
  $Streams = @(Get-Streams $Video)
  if ($Streams.Count -ne 2 -or $Streams[0].codec_name -ne 'h264' -or $Streams[1].codec_name -ne 'aac' -or
      $Streams[0].width -ne 1280 -or $Streams[0].height -ne 720 -or $Streams[0].avg_frame_rate -ne '30/1' -or
      [int]$Streams[0].nb_frames -ne $Frames) { throw "Sai định dạng MP4 $Name" }
}

foreach ($File in @($Node,$Ffmpeg,$Ffprobe,$Entry)) {
  if (!(Test-Path -LiteralPath $File -PathType Leaf)) { throw "Thiếu tệp đã đóng gói $(Split-Path -Leaf $File)" }
}
if ($Version) {
  $Installed = (Get-Item -LiteralPath $AppFile).VersionInfo.ProductVersion
  if ($Installed -notin @($Version,"$Version.0")) { throw "Sai bản Vèo $Installed" }
}
$OldPath = $env:PATH
try {
  $env:PATH = $LocalPath
  New-Item -ItemType Directory -Path $Temp | Out-Null
  if ((Invoke-Tool $Node @('-p','process.platform + "/" + process.arch')) -ne 'win32/x64') { throw 'Sai Node Windows x64' }
  if ($OpenApp) {
    $App = Start-Process -FilePath $AppFile -WorkingDirectory $Rel -PassThru
    Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes
    $Condition = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty,'Tiếp tục với Google')
    $Until = [DateTime]::UtcNow.AddSeconds(60)
    $Found = $null
    do {
      $App.Refresh()
      if ($App.HasExited) { throw 'Vèo thoát trước khi hiện màn đăng nhập.' }
      if ($App.MainWindowHandle -ne [IntPtr]::Zero) {
        $Window = [System.Windows.Automation.AutomationElement]::FromHandle($App.MainWindowHandle)
        $Found = $Window.FindFirst([System.Windows.Automation.TreeScope]::Descendants,$Condition)
      }
      if (!$Found) { Start-Sleep -Milliseconds 300 }
    } while (!$Found -and [DateTime]::UtcNow -lt $Until)
    if (!$Found) { throw 'Chưa thấy nút Tiếp tục với Google trong cửa sổ Vèo.' }
    Write-Host 'Đã mở màn đăng nhập của app Vèo.'
  }
  $Start = [Diagnostics.ProcessStartInfo]::new($Node)
  $Start.ArgumentList.Add($Entry)
  $Start.WorkingDirectory = $Worker
  $Start.UseShellExecute = $false
  $Start.RedirectStandardOutput = $true
  $Start.RedirectStandardInput = $true
  $Start.Environment['DUNG_DATA'] = Join-Path $Temp 'Kho dự án'
  $Start.Environment['DUNG_FFMPEG'] = $Ffmpeg
  $Start.Environment['DUNG_FFPROBE'] = $Ffprobe
  $Start.Environment['DUNG_FONTS'] = Join-Path $Worker 'fonts'
  $Start.Environment['DUNG_PORT'] = '0'
  foreach ($Key in @('DUNG_TOKEN','DUNG_GIU','DUNG_LOG','DUNG_KHO_NHAC')) { $null = $Start.Environment.Remove($Key) }
  $Child = [Diagnostics.Process]::Start($Start)
  $Read = $Child.StandardOutput.ReadLineAsync()
  if (!$Read.Wait(60000) -or !$Read.Result) { throw 'Không nhận được thông tin khởi động phần dựng.' }
  $Boot = $Read.Result | ConvertFrom-Json
  if (!$Boot.port -or !$Boot.token) { throw 'Thông tin khởi động phần dựng thiếu cổng hoặc mã phiên.' }
  $Base = "http://127.0.0.1:$($Boot.port)"
  $Headers = @{ 'x-dung-token' = $Boot.token }
  if ($null -eq (Get-Veo 'state').projects) { throw 'Phần dựng chưa trả danh sách dự án.' }
  if ((Get-Veo 'pixel').effects.Count -ne 244 -or (Get-Veo 'phong-cach/thu-vien').items.Count -lt 802) { throw 'Kho phong cách hoặc PixelFX thiếu nội dung đã đóng gói.' }
  $null = Send-Veo 'projects/khong-co/cancel' @{}

  $Sources = @(
    foreach ($Item in @(@{ Name='Nguồn đỏ'; Color='red'; Hz=440 },@{ Name='Nguồn lam'; Color='blue'; Hz=660 })) {
      $File = Join-Path $Temp ($Item.Name + '.mp4')
      $null = Invoke-Tool $Ffmpeg @('-v','error','-f','lavfi','-i',"color=$($Item.Color):s=640x360:r=30:d=4",
        '-f','lavfi','-i',"sine=frequency=$($Item.Hz):sample_rate=48000:duration=4",'-c:v','libx264','-threads','1','-c:a','aac','-y',$File)
      $File
    }
  )
  $Id = (Send-Veo 'projects' @{ clips = $Sources; canvas = 'ngang'; dungTheo = 'hinh'; autoExport = $false }).id
  $null = Wait-VeoJob $Id 'dung'
  $Project = Get-Veo "projects/$Id"
  if ($Project.plan.sources.Count -ne 2) { throw 'Dự án không giữ đủ hai nguồn.' }
  Export-Veo $Id 'Bản dựng thử' 240
  $Quote = Send-Veo "projects/$Id/canh-ai/duyet" @{ stamp = $Project.stamp; scene = -1; size = '360p'; prompt = 'Đổi ánh sáng của đoạn';
    timeline = @{ fromFrame = 114; toFrame = 204; coAm = $false } }
  $Clip = Join-Path $Temp 'Đoạn duyệt.mp4'
  $Video = $Quote.videoNguon
  Invoke-WebRequest "$Base/api/projects/$Id/canh-ai/video/$($Video.key)?h=$($Video.hash)" -Headers $Headers -OutFile $Clip -TimeoutSec 30
  $Streams = @(Get-Streams $Clip)
  if ((Get-FileHash -LiteralPath $Clip -Algorithm SHA256).Hash -ne $Video.hash -or $Streams.Count -ne 1 -or
      $Streams[0].codec_name -ne 'h264' -or $Streams[0].nb_frames -ne '90') { throw 'Đoạn duyệt qua hai nguồn không khớp.' }
  Write-Host 'Đã xuất 240 khung từ hai nguồn và duyệt đoạn 90 khung.'

  $Story = (Send-Veo 'tao-video' @{ version = 1; styleId = 'pixel'; canvas = 'ngang'; title = 'Thử tạo video';
    scenes = @(@{ text = 'Cảnh một'; seconds = 2 },@{ text = 'Cảnh hai'; seconds = 2 }) }).id
  $null = Wait-VeoJob $Story 'dung'
  Export-Veo $Story 'Video từ storyboard' 120
  Write-Host 'Đã dựng và xuất storyboard hai cảnh.'
  if ($env:DUNG_HYPERFRAMES_DIR) {
    $Status = Get-Veo 'do-hoa'
    if (!$Status.engine -or !$Status.browser -or !$Status.three -or !$Status.gsap) { throw 'Thiếu bộ dựng đồ họa hoặc trình duyệt.' }
    $Preview = Send-Veo 'do-hoa/xem' @{ canvas = 'ngang'; spec = @{ version = 1; id = 'chu-dong'; title = 'Đồ họa thử';
      subtitle = ''; accent = '#ffc16e'; seconds = 2; speed = 1; chuDong = @{ kieu = 'nay'; theo = 'tu'; treMs = 50; doNay = 1.8 } } }
    $File = Join-Path $Temp 'Chữ động.mp4'
    Invoke-WebRequest "$Base/api/do-hoa/xem/$($Preview.key)" -Headers $Headers -OutFile $File -TimeoutSec 30
    if ((Get-Streams $File | Select-Object -First 1).nb_frames -ne '60') { throw 'Thiếu khung hình chữ động.' }
    Write-Host 'Bộ dựng HyperFrames đã xuất 60 khung chữ động.'
  }
  Write-Host 'VEO_WINDOWS_SMOKE_OK'
} finally {
  if ($Child -and !$Child.HasExited) {
    $Child.StandardInput.Close()
    if (!$Child.WaitForExit(8000)) { $Child.Kill($true); $Child.WaitForExit() }
  }
  if ($App -and !$App.HasExited) { $App.Kill($true); $App.WaitForExit() }
  $env:PATH = $OldPath
  if (Test-Path -LiteralPath $Temp) { Remove-Item -LiteralPath $Temp -Recurse -Force }
}
