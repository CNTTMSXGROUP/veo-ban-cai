param(
  [Parameter(Mandatory)][string]$Qa,
  [Parameter(Mandatory)][ValidateSet('mac-dinh','tu-chon')][string]$Ca,
  [Parameter(Mandatory)][ValidateSet('thay','that')][string]$CheDo
)

$ErrorActionPreference = 'Stop'
if (!$IsWindows -or $env:GITHUB_ACTIONS -ne 'true') { throw 'Chỉ dùng trên máy Windows thử của GitHub Actions.' }
$Qa = (Resolve-Path -LiteralPath $Qa).Path
if ((Split-Path -Path $Qa -Parent) -ne $env:RUNNER_TEMP) {
  throw 'Ca thử cần thư mục riêng trong RUNNER_TEMP.'
}

$Seed = Join-Path $PSScriptRoot 'kiem-kho-nang-cap.mjs'
$Old = Join-Path $Qa 'Veo_0.3.24_x64-setup.exe'
$New = Join-Path $Qa 'Veo_0.3.25_x64-setup.exe'
$Custom = $Ca -eq 'tu-chon'
$Install = if ($Custom) { Join-Path $Qa 'Bản cài Vèo tự chọn' } else { Join-Path $env:LOCALAPPDATA 'Vèo' }
$AppFile = Join-Path $Install 'msx-phong-dung.exe'
$Data = Join-Path $env:APPDATA 'vn.msxgroup.phongdung'
$Cache = Join-Path $env:LOCALAPPDATA 'vn.msxgroup.phongdung/cap-nhat'
$Key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Vèo'
$Proof = Join-Path $Qa 'minh-chung'
$Firewall = "Veo-QA-Update-$env:GITHUB_RUN_ID"
if ((Test-Path -LiteralPath $Data) -or (Test-Path -LiteralPath $Install)) { throw 'Máy thử đã có app hoặc kho Vèo.' }
New-Item -ItemType Directory -Path $Proof | Out-Null

function Wait-Moc([scriptblock]$Predicate, [int]$Seconds, [string]$Message) {
  $Until = [DateTime]::UtcNow.AddSeconds($Seconds)
  do {
    $Found = & $Predicate
    if ($Found) { return $Found }
    Start-Sleep -Milliseconds 300
  } while ([DateTime]::UtcNow -lt $Until)
  throw $Message
}

function Find-Ui([Diagnostics.Process]$App, [string]$Name) {
  $App.Refresh()
  if ($App.HasExited -or $App.MainWindowHandle -eq [IntPtr]::Zero) { return }
  try {
    $Window = [System.Windows.Automation.AutomationElement]::FromHandle($App.MainWindowHandle)
    $Condition = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty, $Name)
    return $Window.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $Condition)
  } catch [System.Windows.Automation.ElementNotAvailableException] { return }
  catch {
    if ($_.Exception.ToString() -match '0x80010012') { return }
    throw
  }
}

function Click-Ui($Item) {
  $Bounds = $Item.Current.BoundingRectangle
  if ($Bounds.IsEmpty -or ![VeoUpdateWindow]::SetCursorPos([int]($Bounds.X + $Bounds.Width / 2), [int]($Bounds.Y + $Bounds.Height / 2))) {
    throw 'Không đặt được con trỏ trên nút.'
  }
  [VeoUpdateWindow]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
  [VeoUpdateWindow]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
}

function Focus-Ui($App) {
  $null = Wait-Moc { $Shell.AppActivate($App.Id) } 20 'Không lấy được tiêu điểm cửa sổ thử.'
}

function Press-Ui($App, [string]$Key) {
  Focus-Ui $App
  [System.Windows.Forms.SendKeys]::SendWait($Key)
}

function Save-Ui($App, [string]$Name) {
  $App.Refresh()
  $Bounds = [VeoUpdateWindow+Rect]::new()
  if (![VeoUpdateWindow]::GetWindowRect($App.MainWindowHandle, [ref]$Bounds)) { return $false }
  $Image = [System.Drawing.Bitmap]::new(($Bounds.R - $Bounds.L), ($Bounds.B - $Bounds.T))
  $Graphics = [System.Drawing.Graphics]::FromImage($Image)
  try {
    $Dc = $Graphics.GetHdc()
    try { $Ok = [VeoUpdateWindow]::PrintWindow($App.MainWindowHandle, $Dc, 2) }
    finally { $Graphics.ReleaseHdc($Dc) }
    if (!$Ok -or $Image.GetPixel([int]($Image.Width / 2), 75).ToArgb() -eq 0) { return $false }
    $Image.Save((Join-Path $Proof "$Name.png"), [System.Drawing.Imaging.ImageFormat]::Png)
    return $true
  } finally { $Graphics.Dispose(); $Image.Dispose() }
}

function Open-KhoCu {
  $App = Start-Process $AppFile -WorkingDirectory $Install -PassThru
  Write-Host "VEO_QA_APP_PID=$($App.Id)"
  $null = Wait-Moc {
    $Skip = Find-Ui $App 'Dùng ngay'
    if ($Skip -and $Skip.Current.IsEnabled) { Click-Ui $Skip }
    Find-Ui $App 'Xem Kho cũ · Ba thẻ màu'
  } 65 'Chưa mở được dự án cũ trong Vèo 0.3.24.'
  return $App
}

function Get-AppFileVersion {
  if (!(Test-Path -LiteralPath $AppFile)) { return }
  (Get-Item -LiteralPath $AppFile).VersionInfo.ProductVersion
}

function Find-Veo {
  Get-Process msx-phong-dung -ErrorAction SilentlyContinue | Where-Object Path -eq $AppFile | Select-Object -First 1
}

$InstallArgs = if ($Custom) { @('/S',"/D=$Install") } else { @('/S') }
$P = Start-Process $Old -ArgumentList $InstallArgs -PassThru
Write-Host "VEO_QA_INSTALLER_PID=$($P.Id)"
if (!$P.WaitForExit(240000)) { $P.Kill($true); throw 'Cài 0.3.24 quá thời gian.' }
if ($P.ExitCode -ne 0 -or (Get-AppFileVersion) -notmatch '^0\.3\.24(\.0)?$') { throw 'Sai phiên bản trước cập nhật.' }
$OldHash = (Get-FileHash -LiteralPath $AppFile).Hash
& (Join-Path $Install 'node.exe') $Seed 'truoc' $Install $Qa
if ($LASTEXITCODE -ne 0) { throw 'Không tạo được kho thử 0.3.24.' }

$Session = Join-Path $Data 'dang-nhap.json'
$env:DUNG_CHEP_LOI = 'may'
$env:DUNG_WHISPER_MODEL = Join-Path $Qa 'ggml-base.en-q5_1.bin'
$env:NO_PROXY = '127.0.0.1,localhost'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class VeoUpdateWindow {
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int L,T,R,B; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out Rect r);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, int x, int y, uint data, UIntPtr extra);
}
'@
$Shell = New-Object -ComObject WScript.Shell

$App = $null
$Rule = $null
try {
  # Chặn WebView2 ra Internet trước khi tạo phiên tổng hợp.
  $App = Start-Process $AppFile -WorkingDirectory $Install -PassThru
  Write-Host "VEO_QA_APP_PID=$($App.Id)"
  $null = Wait-Moc { Find-Ui $App 'Tiếp tục với Google' } 60 'Bản 0.3.24 chưa mở màn đăng nhập.'
  $Browser = Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" |
    Where-Object ParentProcessId -eq $App.Id | Select-Object -First 1
  if (!$Browser.ExecutablePath -or @((Get-NetFirewallProfile) | Where-Object Enabled -ne 'True').Count) {
    throw 'Chưa xác định được luật tường lửa cho WebView2 thử.'
  }
  $Ranges = @('1.0.0.0-126.255.255.255','128.0.0.0-255.255.255.255','2000::/3')
  $Rule = New-NetFirewallRule -Name $Firewall -DisplayName $Firewall -Enabled True -Direction Outbound -Action Block -Program $Browser.ExecutablePath -RemoteAddress $Ranges
  if (!(Get-NetFirewallRule -Name $Firewall -PolicyStore ActiveStore -ErrorAction SilentlyContinue)) {
    throw 'Luật ngoại tuyến chưa có hiệu lực.'
  }
  Press-Ui $App '%{F4}'
  if (!$App.WaitForExit(25000)) { Stop-Process -Id $App.Id; $App.WaitForExit() }
  Start-Sleep -Seconds 5
  @{ refresh='veo-qa-khong-phai-token'; id='00000000-0000-4000-8000-000000000026'; email='veo-qa@example.invalid'; ten='Kho thử Windows' } |
    ConvertTo-Json -Compress | Set-Content -LiteralPath $Session -Encoding utf8
  $App = Open-KhoCu
  $KhongTuMo = $null
  $null = Wait-Moc { Save-Ui $App '01-kho-ban-cu' } 12 'Không chụp được kho bản cũ.'
  if ($CheDo -eq 'thay') {
    # Trước khi phát hành: chạy bộ cài mới đè lên bản đã phát hành, đúng tham số trình cập nhật dùng.
    Press-Ui $App '%{F4}'
    if (!$App.WaitForExit(25000)) { throw 'Không đóng được bản 0.3.24.' }
    $P = Start-Process $New -ArgumentList @('/P','/UPDATE') -PassThru
    Write-Host "VEO_QA_INSTALLER_PID=$($P.Id)"
    if (!$P.WaitForExit(240000)) { $P.Kill($true); throw 'Cài đè 0.3.25 quá thời gian.' }
    if ($P.ExitCode -ne 0) { throw "Bộ cài 0.3.25 trả mã $($P.ExitCode)." }
  } else {
    $Button = Wait-Moc {
      $Later = Find-Ui $App 'Để sau'
      if ($Later -and $Later.Current.IsEnabled) { Click-Ui $Later }
      $Item = Find-Ui $App 'Cập nhật bản 0.3.25'
      if ($Item -and $Item.Current.IsEnabled) { $Item }
    } 300 'Bản 0.3.24 chưa thấy bản 0.3.25 công khai.'
    $null = Wait-Moc { Save-Ui $App '02-goi-da-san-sang' } 12 'Không chụp được nút cập nhật.'
    if ($Custom) { Press-Ui $App '%{F4}' } else {
      # Bản 0.3.24: nút trên thanh công cụ chỉ mở hộp "có gì mới", cài bằng nút trong hộp.
      Focus-Ui $App; Click-Ui $Button
      Click-Ui (Wait-Moc { $N = Find-Ui $App 'Cập nhật ngay'; if ($N -and $N.Current.IsEnabled) { $N } } 20 'Không thấy nút Cập nhật ngay.')
    }
    if (!$App.WaitForExit(120000)) { throw 'Vèo 0.3.24 còn chạy sau lệnh cài.' }
  }
  $null = Wait-Moc {
    (Get-AppFileVersion) -match '^0\.3\.25(\.0)?$' -and
      (Get-ItemPropertyValue -Path $Key -Name DisplayVersion -ErrorAction SilentlyContinue) -match '^0\.3\.25(\.0)?$'
  } 180 'Trình cài chưa hoàn tất nâng tại chỗ lên 0.3.25.'
  $Location = (Get-ItemPropertyValue -Path $Key -Name InstallLocation).Trim('"')
  if ($Location -ne $Install) { throw "Bộ cài đã đổi thư mục cài: $Location" }
  if ($CheDo -eq 'that' -and !$Custom) {
    $Moc = [DateTime]::UtcNow
    try {
      # Chờ cả cửa sổ, không chỉ tiến trình vừa sinh ra.
      $App = Wait-Moc { $P = Find-Veo; if ($P) { $P.Refresh(); if ($P.MainWindowHandle -ne [IntPtr]::Zero) { $P } } } 120 'Vèo chưa tự mở sau khi bấm Cập nhật.'
      Write-Host "Bản 0.3.25 tự mở lại sau $([int]([DateTime]::UtcNow - $Moc).TotalSeconds) giây"
      Start-Sleep -Seconds 3
      try { $null = Save-Ui $App '02b-tu-mo-lai' } catch { Write-Host 'Không chụp được cửa sổ tự mở lại.' }
      $null = $App.CloseMainWindow()
      if (!$App.WaitForExit(25000)) { Stop-Process -Id $App.Id; $App.WaitForExit() }
    } catch {
      $KhongTuMo = $_.Exception.Message
      Write-Host "KHONG TU MO LAI: $KhongTuMo"
      Get-Process msx-phong-dung -ErrorAction SilentlyContinue | Stop-Process
    }
    Start-Sleep -Seconds 5
  }
  $Expected = @{
    'worker/dung-app.mjs' = $env:VEO_QA_WORKER_SHA
    'licenses/LIBVPX-LICENSE.txt' = '8267348d5af1262c11d1a08de2f5afc77457755f1ac658627dd9acf71011d615'
    'licenses/LIBVPX-PATENTS.txt' = 'cc3273e0694ea5896145e0677699b53471b03ea43021ddc50e7923fbb9f5023c'
  }
  foreach ($Asset in $Expected.Keys) {
    if ((Get-FileHash -LiteralPath (Join-Path $Install $Asset) -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Expected[$Asset]) { throw "Sai tệp trong bản đã cài: $Asset" }
  }
  $App = Open-KhoCu
  Focus-Ui $App
  $null = Wait-Moc { Find-Ui $App 'Vèo 0.3.25' } 25 'Giao diện chưa báo 0.3.25.'
  $null = Wait-Moc { Save-Ui $App '03-kho-cu-sau-cap-nhat' } 12 'Không chụp được dự án cũ sau cập nhật.'
  $ProofOld = Get-Content -LiteralPath (Join-Path $Qa 'kho-0.3.24.json') -Raw -Encoding utf8 | ConvertFrom-Json
  $Out = Join-Path $Data "du-an/$($ProofOld.id)/xuat"
  $OldFiles = @((Get-ChildItem -LiteralPath $Out -File -Filter '*.mp4').FullName)
  Click-Ui (Wait-Moc { Find-Ui $App 'Xuất lại' } 35 'Vèo chưa mở đúng dự án cũ đã xuất.')
  Click-Ui (Wait-Moc { Find-Ui $App '720p' } 15 'Không thấy lựa chọn 720p.')
  Click-Ui (Wait-Moc { Find-Ui $App 'Xuất 1 tệp' } 15 'Không thấy nút xuất MP4.')
  $null = Wait-Moc { Find-Ui $App 'Đã xuất xong 1 video' } 140 'Vèo chưa xuất được MP4 sau cập nhật.'
  $Output = @(Get-ChildItem -LiteralPath $Out -File -Filter '*.mp4' | Where-Object FullName -notin $OldFiles)
  if ($Output.Count -ne 1 -or !$Output[0].Length) { throw 'Không xác định được MP4 đã xuất từ giao diện.' }
  $env:VEO_QA_EXPORT = $Output[0].FullName
  $OutputHash = (Get-FileHash -LiteralPath $Output[0].FullName).Hash
  Press-Ui $App '%{F4}'
  if (!$App.WaitForExit(25000)) { throw 'Không đóng được Vèo sau khi xuất.' }
  $App = Open-KhoCu
  Focus-Ui $App
  $null = Wait-Moc { Find-Ui $App 'Thành phẩm' } 35 'Vèo chưa mở đúng tệp thành phẩm.'
  Click-Ui (Wait-Moc { Find-Ui $App 'Phát' } 15 'Không thấy nút phát MP4.')
  $null = Wait-Moc { Find-Ui $App 'Dừng' } 10 'MP4 chưa phát.'
  $null = Wait-Moc { Save-Ui $App '04-phat-mp4-sau-khi-mo-lai' } 12 'Không chụp được MP4 đang phát.'
  if ((Get-FileHash -LiteralPath $Output[0].FullName).Hash -ne $OutputHash) { throw 'Tệp mới đã thay đổi khi mở lại.' }
  Press-Ui $App '%{F4}'
  if (!$App.WaitForExit(25000)) { throw 'Không đóng được bản thử sau khi phát.' }
  & (Join-Path $Install 'node.exe') $Seed 'sau' $Install $Qa
  if ($LASTEXITCODE -ne 0) { throw 'Kho cũ không qua kiểm tra sau cập nhật.' }
  $Migration = Join-Path $Qa 'chuyen-kho'
  python (Join-Path $Qa 'kiem-chuyen-kho.py') $Migration $Install (Join-Path $Install 'worker/dung-app.mjs') (Join-Path $Install 'worker/fonts')
  if ($LASTEXITCODE -ne 0) { throw 'Kho thử không khôi phục sau khi dừng giữa giao dịch.' }
  Copy-Item -LiteralPath (Join-Path $Migration 'ket-qua.json') -Destination (Join-Path $Qa 'minh-chung/chuyen-kho.json')
  if ($KhongTuMo) { throw "Nâng cấp đạt nhưng không tự mở lại: $KhongTuMo" }
} catch {
  if ($App -and !$App.HasExited) { try { $null = Save-Ui $App '99-loi' } catch { Write-Host 'Không chụp được lỗi.' } }
  throw
} finally {
  Get-Process msx-phong-dung -ErrorAction SilentlyContinue | Where-Object Path -eq $AppFile | ForEach-Object {
    Write-Host "Đóng tiến trình thử $($_.Id) và các tiến trình con."
    cmd /c "taskkill /PID $($_.Id) /T /F"
  }
  if ((Find-Veo)) { throw 'Tiến trình Vèo thử vẫn còn chạy.' }
  if ($Rule) { Remove-NetFirewallRule -Name $Firewall }
}
