param(
  [Parameter(Mandatory)][string]$Qa,
  [Parameter(Mandatory)][ValidateSet('bam-cap-nhat','thoat-app')][string]$Ca
)

$ErrorActionPreference = 'Stop'
if (!$IsWindows -or $env:GITHUB_ACTIONS -ne 'true') { throw 'Chỉ dùng trên máy Windows thử của GitHub Actions.' }
$Qa = (Resolve-Path -LiteralPath $Qa).Path
if ((Split-Path -Path $Qa -Parent) -ne $env:RUNNER_TEMP) {
  throw 'Ca thử cần thư mục riêng trong RUNNER_TEMP.'
}

$Seed = Join-Path $PSScriptRoot 'kiem-kho-nang-cap.mjs'
$Feed = Join-Path $PSScriptRoot 'may-cap-nhat-thu.py'
$Old = Join-Path $Qa 'Veo-Windows-Signed-Flow-QA_0.3.23_x64-setup.exe'
$New = Join-Path $Qa 'Veo-Windows-Signed-Flow-QA_0.3.24_x64-setup.exe'
$Custom = $Ca -eq 'thoat-app'
$Install = if ($Custom) { Join-Path $Qa 'Bản cài Vèo tự chọn' } else { Join-Path $env:LOCALAPPDATA 'Vèo' }
$AppFile = Join-Path $Install 'msx-phong-dung.exe'
$Data = Join-Path $env:APPDATA 'vn.msxgroup.phongdung'
$Cache = Join-Path $env:LOCALAPPDATA 'vn.msxgroup.phongdung/cap-nhat'
$Key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Vèo'
$PhasePath = Join-Path $Qa 'cap-nhat.mode'
$FeedLog = Join-Path $Qa 'may-chu.log'
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
  if (!$Shell.AppActivate($App.Id)) { throw 'Không lấy được tiêu điểm cửa sổ thử.' }
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
  $null = Wait-Moc {
    $Skip = Find-Ui $App 'Dùng ngay'
    if ($Skip -and $Skip.Current.IsEnabled) { Click-Ui $Skip }
    Find-Ui $App 'Xem Kho cũ · Ba thẻ màu'
  } 65 'Chưa mở được dự án cũ trong Vèo 0.3.23.'
  return $App
}

function Set-Phase([string]$Phase) {
  $Temp = "$PhasePath.tmp"
  Set-Content -LiteralPath $Temp -Value $Phase -Encoding ascii
  [IO.File]::Move($Temp, $PhasePath, $true)
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
if (!$P.WaitForExit(240000)) { $P.Kill($true); throw 'Cài 0.3.23 quá thời gian.' }
if ($P.ExitCode -ne 0 -or (Get-AppFileVersion) -notmatch '^0\.3\.23(\.0)?$') { throw 'Sai phiên bản trước cập nhật.' }
$OldHash = (Get-FileHash -LiteralPath $AppFile).Hash
& (Join-Path $Install 'node.exe') $Seed 'truoc' $Install $Qa
if ($LASTEXITCODE -ne 0) { throw 'Không tạo được kho thử 0.3.23.' }

# Dữ liệu thử chỉ dùng ngoại tuyến. CSP của bộ cài 0.3.23 thử không cho gọi dịch vụ tài khoản.
$Session = Join-Path $Data 'dang-nhap.json'
@{ refresh='veo-qa-khong-phai-token'; id='00000000-0000-4000-8000-000000000026'; email='veo-qa@example.invalid'; ten='Kho thử Windows' } |
  ConvertTo-Json -Compress | Set-Content -LiteralPath $Session -Encoding utf8
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

$OpenSsl = (Get-Command openssl.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if (!$OpenSsl) { $OpenSsl = Join-Path $env:ProgramFiles 'Git/usr/bin/openssl.exe' }
Push-Location $Qa
$Cert = $null
$Server = $null
$Rule = $null
$App = $null
try {
  Set-Content -LiteralPath 'tls.ext' -Encoding ascii -Value @(
    'basicConstraints=critical,CA:FALSE','keyUsage=critical,digitalSignature,keyEncipherment',
    'extendedKeyUsage=serverAuth','subjectAltName=IP:127.0.0.1','authorityKeyIdentifier=keyid:always,issuer'
  )
  & $OpenSsl req -x509 -newkey rsa:2048 -nodes -sha256 -days 1 -subj '/CN=Veo CI Root' -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,keyCertSign,cRLSign' -addext 'subjectKeyIdentifier=hash' -keyout 'root.key' -out 'root.pem' 2>openssl-root.log
  if ($LASTEXITCODE -ne 0) { Get-Content openssl-root.log; throw 'Không tạo được CA thử.' }
  & $OpenSsl req -new -newkey rsa:2048 -nodes -subj '/CN=127.0.0.1' -keyout 'loopback.key' -out 'loopback.csr' 2>openssl-loopback.log
  if ($LASTEXITCODE -ne 0) { Get-Content openssl-loopback.log; throw 'Không tạo được yêu cầu chứng chỉ.' }
  & $OpenSsl x509 -req -sha256 -days 1 -in 'loopback.csr' -CA 'root.pem' -CAkey 'root.key' -CAcreateserial -extfile 'tls.ext' -out 'loopback.pem'
  if ($LASTEXITCODE -ne 0) { throw 'Không ký được chứng chỉ HTTPS thử.' }
  & $OpenSsl x509 -in 'root.pem' -outform DER -out 'root.cer'
  if ($LASTEXITCODE -ne 0) { throw 'Không tạo được tệp chứng chỉ CA.' }
  $Cert = Import-Certificate -FilePath (Join-Path $Qa 'root.cer') -CertStoreLocation 'Cert:\LocalMachine\Root'
  if (!$Cert.Thumbprint) { throw 'Không tin cậy được CA thử trên máy Windows.' }

  $Phase = if ($Custom) { 'wrong-version' } else { 'bad-bytes' }
  $WrongVersion = if ($Custom) { '0.3.25' } else { '0.3.24' }
  Set-Phase $Phase
  $Server = Start-Process python -ArgumentList ('"{0}" "{1}"' -f $Feed,$Qa) -RedirectStandardOutput $FeedLog -RedirectStandardError (Join-Path $Qa 'may-chu-loi.log') -PassThru
  $null = Wait-Moc {
    if ($Server.HasExited) { Get-Content (Join-Path $Qa 'may-chu-loi.log'); throw 'Máy chủ HTTPS thử đã thoát.' }
    try { (Invoke-RestMethod 'https://127.0.0.1:49324/health' -TimeoutSec 3).ready } catch { $false }
  } 20 'Windows không mở được máy chủ HTTPS thử.'
  $App = Open-KhoCu
  $null = Wait-Moc { Find-Ui $App "Có bản $WrongVersion · Sẽ thử tải lại" } 75 'Vèo chưa báo từ chối gói thử sai.'
  if (!(Select-String -LiteralPath $FeedLog -SimpleMatch "Da gui het goi $Phase," -Quiet)) { throw 'Máy chủ chưa giao đủ gói thử sai.' }
  if ((Test-Path -LiteralPath (Join-Path $Cache "ban-$WrongVersion.bin")) -or (Get-FileHash -LiteralPath $AppFile).Hash -ne $OldHash) {
    throw 'Gói thử sai đã vào đệm hoặc đổi bản đang cài.'
  }
  $null = Wait-Moc { Save-Ui $App '01-goi-sai-bi-tu-choi' } 12 'Không chụp được trạng thái gói sai.'
  Write-Host "Vèo 0.3.23 từ chối gói thử $Phase qua HTTPS và giữ nguyên app."
  if ($Custom) {
    Press-Ui $App '%{F4}'
    if (!$App.WaitForExit(25000)) { throw 'Vèo không thoát sau lượt gói sai.' }
    if ((Get-FileHash -LiteralPath $AppFile).Hash -ne $OldHash) { throw 'Vèo đổi phiên bản khi thoát dù số bản ký không khớp.' }
    Set-Phase 'valid'
    $App = Open-KhoCu
  } else {
    Set-Phase 'valid'
  }

  $Button = Wait-Moc {
    $Item = Find-Ui $App 'Cập nhật bản 0.3.24'
    if ($Item -and $Item.Current.IsEnabled) { $Item }
  } 110 'Thiếu nút cập nhật sau khi tải gói hợp lệ.'
  $Ready = Join-Path $Cache 'ban-0.3.24.bin'
  if ((Get-FileHash -LiteralPath $Ready).Hash -ne (Get-FileHash -LiteralPath $New).Hash) { throw 'Tệp cập nhật đã tải không khớp bộ cài ký.' }
  $null = Wait-Moc { Save-Ui $App '02-goi-r27-da-san-sang' } 12 'Không chụp được nút cập nhật.'
  Write-Host 'Vèo đã xác minh và lưu gói 0.3.24 hợp lệ.'
  $NextCache = Join-Path $Cache 'ban-0.3.25.bin'
  Set-Content -LiteralPath $NextCache -Value 'Tệp thử để kiểm phạm vi dọn' -Encoding utf8
  $NextHash = (Get-FileHash -LiteralPath $NextCache).Hash

  # Bản thử 0.3.24 mở màn đăng nhập thật. Xóa phiên giả trên máy thử trước khi chạy bản đó.
  $TestSession = Get-Content -LiteralPath $Session -Raw -Encoding utf8
  Remove-Item -LiteralPath $Session
  if ($Custom) {
    Press-Ui $App '%{F4}'
  } else {
    Focus-Ui $App
    Click-Ui $Button
  }
  if (!$App.WaitForExit(120000)) { throw 'Vèo 0.3.23 còn chạy sau lệnh cài.' }
  $null = Wait-Moc {
    (Get-AppFileVersion) -match '^0\.3\.24(\.0)?$' -and
      (Get-ItemPropertyValue -Path $Key -Name DisplayVersion -ErrorAction SilentlyContinue) -match '^0\.3\.24(\.0)?$'
  } 180 'Trình cài chưa hoàn tất nâng tại chỗ lên 0.3.24.'
  $Location = (Get-ItemPropertyValue -Path $Key -Name InstallLocation).Trim('"')
  if ($Location -ne $Install) { throw "Bộ cập nhật đã đổi thư mục cài: $Location" }
  if ($Custom) {
    Start-Sleep -Seconds 6
    if (Find-Veo) { throw 'Vèo không được tự mở khi cài lúc thoát.' }
    $NewApp = Start-Process $AppFile -WorkingDirectory $Install -PassThru
    Write-Host 'Đóng cửa sổ đã cài 0.3.24 vào thư mục tự chọn. Vèo ở trạng thái đã thoát.'
  } else {
    $NewApp = Wait-Moc { Find-Veo } 40 'Vèo chưa tự mở sau khi bấm Cập nhật.'
    Write-Host 'Bấm Cập nhật đã cài 0.3.24 vào thư mục mặc định và tự mở lại Vèo.'
  }
  $App = $NewApp
  $null = Wait-Moc { Find-Ui $App 'Tiếp tục với Google' } 60 'Bản 0.3.24 chưa mở màn đăng nhập.'
  $Expected = @{
    'worker/dung-app.mjs' = '2743e3bf2fe283e1c165ffda4e4abc1f96c51c3efc90c28a508cb81378736085'
    'licenses/LIBVPX-LICENSE.txt' = '8267348d5af1262c11d1a08de2f5afc77457755f1ac658627dd9acf71011d615'
    'licenses/LIBVPX-PATENTS.txt' = 'cc3273e0694ea5896145e0677699b53471b03ea43021ddc50e7923fbb9f5023c'
  }
  foreach ($Asset in $Expected.Keys) {
    if ((Get-FileHash -LiteralPath (Join-Path $Install $Asset) -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Expected[$Asset]) { throw "Sai tệp trong gói cập nhật: $Asset" }
  }
  $null = Wait-Moc { !(Test-Path -LiteralPath $Ready) } 10 'Bản mới chưa dọn bộ cài đã dùng.'
  if ((Get-FileHash -LiteralPath $NextCache).Hash -ne $NextHash) { throw 'Bản mới đã đổi bộ đệm của phiên bản khác.' }
  Write-Host "Bản mới dọn bộ cài đã dùng $((Get-Item -LiteralPath $New).Length) byte và giữ bộ đệm của phiên bản khác."
  # Cô lập WebView trên máy ảo trước khi mở kho bằng phiên tổng hợp.
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
  if (!$App.WaitForExit(25000)) { throw 'Không đóng được bản đã nâng để kiểm kho.' }
  Set-Content -Value $TestSession -LiteralPath $Session -Encoding utf8
  $App = Open-KhoCu
  Focus-Ui $App
  $null = Wait-Moc { Find-Ui $App 'Vèo 0.3.24' } 25 'Giao diện chưa báo 0.3.24.'
  $null = Wait-Moc { Save-Ui $App '03-kho-cu-sau-cap-nhat' } 12 'Không chụp được dự án cũ sau cập nhật.'
  $ProofOld = Get-Content -LiteralPath (Join-Path $Qa 'kho-0.3.23.json') -Raw -Encoding utf8 | ConvertFrom-Json
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
} catch {
  if ($App -and !$App.HasExited) { try { $null = Save-Ui $App '99-loi' } catch { Write-Host 'Không chụp được lỗi.' } }
  throw
} finally {
  if ($App -and !$App.HasExited) { Stop-Process -Id $App.Id }
  if ($Server -and !$Server.HasExited) { $Server.Kill($true); $Server.WaitForExit() }
  if ($Rule) { Remove-NetFirewallRule -Name $Firewall }
  if ($Cert.Thumbprint) { Remove-Item -LiteralPath "Cert:\LocalMachine\Root\$($Cert.Thumbprint)" }
  Pop-Location
}
