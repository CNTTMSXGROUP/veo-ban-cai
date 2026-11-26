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
if ((Test-Path -LiteralPath $Data) -or (Test-Path -LiteralPath $Install)) { throw 'Máy thử đã có app hoặc kho Vèo.' }

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
}

function Click-Ui($Item) {
  $Item.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
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

$OpenSsl = (Get-Command openssl.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if (!$OpenSsl) { $OpenSsl = Join-Path $env:ProgramFiles 'Git/usr/bin/openssl.exe' }
Push-Location $Qa
$Cert = $null
$Server = $null
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
  Write-Host "Vèo 0.3.23 từ chối gói thử $Phase qua HTTPS và giữ nguyên app."
  if ($Custom) {
    if (!$App.CloseMainWindow() -or !$App.WaitForExit(25000)) { throw 'Vèo không thoát sau lượt gói sai.' }
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
  Write-Host 'Vèo đã xác minh và lưu gói 0.3.24 hợp lệ.'
  $NextCache = Join-Path $Cache 'ban-0.3.25.bin'
  Set-Content -LiteralPath $NextCache -Value 'Tệp thử để kiểm phạm vi dọn' -Encoding utf8
  $NextHash = (Get-FileHash -LiteralPath $NextCache).Hash

  # Bản thử 0.3.24 mở màn đăng nhập thật. Xóa phiên giả trên máy thử trước khi chạy bản đó.
  Remove-Item -LiteralPath $Session
  if ($Custom) {
    if (!$App.CloseMainWindow()) { throw 'Không gửi được lệnh đóng cửa sổ.' }
  } else {
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
  $null = Wait-Moc { Find-Ui $NewApp 'Tiếp tục với Google' } 60 'Bản 0.3.24 chưa mở màn đăng nhập.'
  $Expected = @{
    'worker/dung-app.mjs' = '9580b15420f5a580f181fc23228d7d35269c7ced1b1a6a3a37583d4fc57eb0d7'
    'licenses/LIBVPX-LICENSE.txt' = '8267348d5af1262c11d1a08de2f5afc77457755f1ac658627dd9acf71011d615'
    'licenses/LIBVPX-PATENTS.txt' = 'cc3273e0694ea5896145e0677699b53471b03ea43021ddc50e7923fbb9f5023c'
  }
  foreach ($Asset in $Expected.Keys) {
    if ((Get-FileHash -LiteralPath (Join-Path $Install $Asset) -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Expected[$Asset]) { throw "Sai tệp trong gói cập nhật: $Asset" }
  }
  $null = Wait-Moc { !(Test-Path -LiteralPath $Ready) } 10 'Bản mới chưa dọn bộ cài đã dùng.'
  if ((Get-FileHash -LiteralPath $NextCache).Hash -ne $NextHash) { throw 'Bản mới đã đổi bộ đệm của phiên bản khác.' }
  Write-Host "Bản mới dọn bộ cài đã dùng $((Get-Item -LiteralPath $New).Length) byte và giữ bộ đệm của phiên bản khác."
  if (!$NewApp.CloseMainWindow() -or !$NewApp.WaitForExit(25000)) { throw 'Không đóng được bản đã nâng để kiểm kho.' }
  & (Join-Path $Install 'node.exe') $Seed 'sau' $Install $Qa
  if ($LASTEXITCODE -ne 0) { throw 'Kho cũ không qua kiểm tra sau cập nhật.' }
} finally {
  if ($Server -and !$Server.HasExited) { $Server.Kill($true); $Server.WaitForExit() }
  if ($Cert.Thumbprint) { Remove-Item -LiteralPath "Cert:\LocalMachine\Root\$($Cert.Thumbprint)" }
  Pop-Location
}
