#Requires -Version 7.0
param(
  [string]$InstallDir,
  [string]$Version,
  [string]$ExFatRoot,
  [string]$EvidenceDir
)

$ErrorActionPreference = 'Stop'
$Rel = (Resolve-Path -LiteralPath $InstallDir).Path
$Worker = Join-Path $Rel 'worker'
$Node = Join-Path $Rel 'node.exe'
$Ffmpeg = Join-Path $Rel 'ffmpeg.exe'
$Ffprobe = Join-Path $Rel 'ffprobe.exe'
$Entry = Join-Path $Worker 'dung-app.mjs'
$AppFile = Join-Path $Rel 'msx-phong-dung.exe'
$LocalPath = "$env:SystemRoot\System32;$env:SystemRoot"
$WorkRoot = [IO.Path]::GetTempPath()
if ($ExFatRoot) {
  $WorkRoot = (Resolve-Path -LiteralPath $ExFatRoot).Path
  if ((Get-Volume -FilePath $WorkRoot).FileSystem -ne 'exFAT') { throw 'Kho thử cần nằm trên ổ exFAT.' }
}
$Temp = Join-Path $WorkRoot ("veo-smoke-" + [guid]::NewGuid().ToString('N'))
$Child = $null

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
  return $Video
}

foreach ($File in @($Node,$Ffmpeg,$Ffprobe,$Entry)) {
  if (!(Test-Path -LiteralPath $File -PathType Leaf)) { throw "Thiếu tệp đã đóng gói $(Split-Path -Leaf $File)" }
}
if ($Version) {
  $Installed = (Get-Item -LiteralPath $AppFile).VersionInfo.ProductVersion
  if ($Installed -notin @($Version,"$Version.0")) { throw "Sai bản Vèo $Installed" }
}
if ((Get-FileHash -LiteralPath $Entry -Algorithm SHA256).Hash -ne 'ef6a14085397580bb9d748fea6c4ed122e9b2b955c59f57172086b73e0be16b1') { throw 'Sai bản worker b0f4df2.' }
$OldPath = $env:PATH
try {
  $env:PATH = $LocalPath
  New-Item -ItemType Directory -Path $Temp | Out-Null
  if ((Invoke-Tool $Node @('-p','process.platform + "/" + process.arch')) -ne 'win32/x64') { throw 'Sai Node Windows x64' }
  $Start = [Diagnostics.ProcessStartInfo]::new($Node)
  $Start.ArgumentList.Add($Entry)
  $Start.WorkingDirectory = $Worker
  $Start.UseShellExecute = $false
  $Start.RedirectStandardOutput = $true
  $Start.RedirectStandardInput = $true
  $Start.Environment['DUNG_DATA'] = Join-Path $Temp "Kho dự án, [màu]; O'Brien"
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
  $Request = @{ stamp = $Project.stamp; requestId = 'kiem-exfat-hai-nguon-01'; shape = 'ngang'; fill = 'vua'; clips = @(
    @{ name = 'Đoạn đỏ'; fromFrame = 30; toFrame = 90 }, @{ name = 'Qua hai nguồn'; fromFrame = 90; toFrame = 150 },
    @{ name = 'Đoạn lam'; fromFrame = 150; toFrame = 210 }) }
  $Ids = (Send-Veo "projects/$Id/clip-ngan" $Request).ids
  $Again = (Send-Veo "projects/$Id/clip-ngan" $Request).ids
  if ($Ids.Count -ne 3 -or ($Ids -join ',') -ne ($Again -join ',')) { throw 'Lượt thử lại phải trả đúng ba clip đã tạo.' }
  $First = (Get-Veo "projects/$($Ids[0])").plan.sources
  $Across = (Get-Veo "projects/$($Ids[1])").plan.sources
  $Last = (Get-Veo "projects/$($Ids[2])").plan.sources
  $Shared = @($Across.path)
  if ($First.Count -ne 1 -or $Last.Count -ne 1 -or $Shared.Count -ne 2 -or
      $First[0].path -ne $Shared[0] -or $Last[0].path -ne $Shared[1] -or $Shared[0] -eq $Shared[1]) {
    throw 'Ba clip trên exFAT phải dùng đúng hai bản chuẩn.'
  }
  foreach ($File in $Shared) {
    if ($File -notmatch '[\\/]\.nguon-clip[\\/]' -or !(Test-Path -LiteralPath $File -PathType Leaf)) { throw 'Thiếu bản chuẩn dùng chung.' }
  }
  Write-Host 'Ba clip dùng đúng hai bản chuẩn trên exFAT.'
  $null = Invoke-RestMethod "$Base/api/projects/$Id" -Headers $Headers -Method Delete -TimeoutSec 30
  foreach ($File in $Project.plan.sources.path) {
    if (Test-Path -LiteralPath $File) { throw 'Tệp chuẩn của dự án nguồn chưa được xóa.' }
  }
  $Movie = Export-Veo $Ids[1] 'Xuất từ nguồn chung' 60
  $Drive = Join-Path $Temp 'Thư mục đồng bộ thử'
  New-Item -ItemType Directory -Path $Drive | Out-Null
  $null = Send-Veo 'google-drive' @{ folder = $Drive }
  $Snapshot = Send-Veo 'google-drive/publish' @{ id = $Ids[1] }
  $Index = Join-Path (Join-Path (Join-Path $Drive 'Bản đồng bộ Vèo') $Snapshot.id) 'veo.json'
  $Plan = Get-Content -LiteralPath $Index -Encoding UTF8 -Raw | ConvertFrom-Json
  if ($Plan.plan.sources.Count -ne 2 -or $Plan.files.Count -ne 2 -or !$Plan.plan.clipNgan) { throw 'Gói Drive không chứa clip và đúng hai nguồn.' }
  New-Item -ItemType Directory -Path $EvidenceDir | Out-Null
  $Archive = Join-Path $EvidenceDir 'goi-drive.tar.gz'
  tar.exe -czf $Archive -C $Drive .
  if ($LASTEXITCODE -ne 0 -or !(Test-Path -LiteralPath $Archive -PathType Leaf)) { throw 'Không gói được bản sao Drive.' }
  Copy-Item -LiteralPath $Movie -Destination (Join-Path $EvidenceDir 'Veo-Windows.mp4')
  @{
    source = 'Windows Server 2025 x64'; version = $Version; instance = $Snapshot.id
    files = $Plan.files.Count; frames = 60; volume = (Get-Volume -FilePath $ExFatRoot).FileSystem
    archiveSha256 = (Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash.ToLowerInvariant()
    workerSha256 = (Get-FileHash -LiteralPath $Entry -Algorithm SHA256).Hash.ToLowerInvariant()
  } | ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $EvidenceDir 'ket-qua-windows.json') -Encoding utf8
  Write-Host 'VEO_WINDOWS_DRIVE_OK: Gói Drive giữ hai nguồn và clip qua điểm nối.'
} finally {
  if ($Child -and !$Child.HasExited) {
    $Child.StandardInput.Close()
    if (!$Child.WaitForExit(8000)) { $Child.Kill($true); $Child.WaitForExit() }
  }
  $env:PATH = $OldPath
  if (Test-Path -LiteralPath $Temp) {
    try { [IO.Directory]::Delete($Temp, $true) }
    catch { Write-Warning "Chưa dọn được thư mục thử $Temp. $($_.Exception.Message)" }
  }
}
