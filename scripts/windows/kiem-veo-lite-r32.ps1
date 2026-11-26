param([Parameter(Mandatory)][string]$Install, [Parameter(Mandatory)][string]$Qa)
. (Join-Path $Qa 'kiem-ai-truc-tiep-r27.ps1') -Install $Install -Qa $Qa -ChiNapHam

function Bam([string]$Ten, [switch]$Dau) {
    $Item = Wait-Moc { Find-Ui $Ten -Focusable -TextPrefix:$Dau } 25 "Không bấm được $Ten."
    $Item.SetFocus()
    Keys '{ENTER}'
}
function Thay([string[]]$Text) {
    $null = Wait-Moc {
        foreach ($Part in $Text) { $Item = Find-Ui $Part -TextPrefix; if ($Item) { return $Item } }
    } 28 "Không thấy $($Text -join ' hoặc ')."
}
function Nhap-Gia-Tri([string]$Value) {
    Keys '^a'
    [System.Windows.Forms.Clipboard]::SetText($Value)
    Keys '^v'
}
function Luu-Anh([string]$Name) { if (!(Anh $Name)) { throw "Không chụp được $Name." } }
function Mo-Veo {
    Bam 'Storyboard'
    Bam 'Tạo clip bằng AI'
    $null = Ui 'Model tạo clip'
}
function Cloud-Budget([string]$USD) {
    $Details = Wait-Moc { Find-Ui 'Kết nối Veo qua Google Cloud' -TextPrefix -Focusable } 15 'Không thấy mục kết nối Veo.'
    $Details.SetFocus()
    if (!(Find-Ui 'Dùng phiên Google Cloud')) { Keys '{ENTER}'; Thay 'Dùng phiên Google Cloud' }
    $R = $Details.Current.BoundingRectangle
    if (![VeoQaWindow]::SetCursorPos([int]($R.X + $R.Width / 2), [int]($R.Y + $R.Height / 2))) { throw 'Không đưa được chuột vào hộp Veo.' }
    [VeoQaWindow]::mouse_event(2048, 0, 0, [uint32]4294966936, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 350
    Mouse-Ui (Ui 'ID dự án Google Cloud')
    Nhap-Gia-Tri 'veo-lite-qa'
    Mouse-Ui (Ui 'Ngân sách ước tính mỗi ngày (USD)')
    Nhap-Gia-Tri $USD
    Mouse-Ui (Ui 'Dùng phiên Google Cloud')
    Thay @('Phiên Google Cloud creator@example.invalid', 'creator@example.invalid')
    Thay ("Kết nối Veo qua Google Cloud · còn " + $USD.Replace('.', ','))
    Write-Host "Đã lưu ngân sách thử $USD USD trong cửa sổ."
}
function Nhat-Ky {
    if (Test-Path -LiteralPath $CloudLog) { Get-Content -LiteralPath $CloudLog | ForEach-Object { ConvertFrom-Json $_ } }
}
function Restart-Veo {
    Keys '%{F4}'
    if (!$App.WaitForExit(15000)) { throw 'Vèo chưa đóng bằng Alt+F4.' }
    Start-Process $AppFile -WorkingDirectory $Install -PassThru
}

$App = $null
$Server = $null
$CloudHost = 'us-central1-aiplatform.googleapis.com'
$HostsPath = Join-Path $env:WINDIR 'System32/drivers/etc/hosts'
$HostsCopy = Join-Path $Qa 'hosts-goc'
$FirewallBrowser = "Veo-Lite-WebView2-$env:GITHUB_RUN_ID"
$FirewallNode = "Veo-Lite-Node-$env:GITHUB_RUN_ID"
$CloudLog = Join-Path $Proof 'luot-google-cloud.jsonl'
$Shell = New-Object -ComObject WScript.Shell
$Node = Join-Path $Install 'node.exe'
$FFmpeg = Join-Path $Install 'ffmpeg.exe'
$Probe = Join-Path $Install 'ffprobe.exe'
$env:NO_PROXY = "127.0.0.1,localhost,$CloudHost"
$env:WEBVIEW2_USER_DATA_FOLDER = Join-Path $Qa 'webview2'
$env:DUNG_GCLOUD = Join-Path $Qa 'gcloud.cmd'
$PictureA = Join-Path $Qa 'Anh A.png'
$PictureB = Join-Path $Qa 'Anh B.png'
if (Test-Path -LiteralPath $Data) { throw 'Cần một phiên Windows có kho Vèo trống.' }

try {
    $GitSsl = Join-Path $env:ProgramFiles 'Git/usr/bin/openssl.exe'
    if (!(Test-Path -LiteralPath $GitSsl)) { throw 'Máy thử thiếu OpenSSL của Git.' }
    $env:NODE_EXTRA_CA_CERTS = Join-Path $Qa 'cloud-cert.pem'
    & $GitSsl req -x509 -newkey rsa:2048 -sha256 -days 1 -nodes -subj "/CN=$CloudHost" -addext "subjectAltName=DNS:$CloudHost" -keyout (Join-Path $Qa 'cloud-key.pem') -out $env:NODE_EXTRA_CA_CERTS 2> (Join-Path $Qa 'cloud-tls.log')
    if ($LASTEXITCODE -ne 0) { throw 'Chưa tạo được chứng chỉ TLS của máy thử.' }
    @'
@echo off
if "%~1 %~2"=="auth list" (
  echo creator@example.invalid
  exit /b 0
)
if "%~1 %~2 %~3 %~4"=="auth print-access-token --account creator@example.invalid" (
  echo oauth-qa-veo-local-token
  exit /b 0
)
exit /b 1
'@ | Set-Content -LiteralPath $env:DUNG_GCLOUD -Encoding ascii
    Copy-Item -LiteralPath $HostsPath -Destination $HostsCopy
    Add-Content -LiteralPath $HostsPath -Encoding ascii -Value ("", "127.0.0.1 $CloudHost")
    Clear-DnsClientCache
    $Addresses = @([System.Net.Dns]::GetHostAddresses($CloudHost))
    if ($Addresses.Count -ne 1 -or $Addresses[0].IPAddressToString -ne '127.0.0.1') { throw 'Tên dịch vụ thử chưa trỏ riêng về loopback.' }

    & $FFmpeg -v error -f lavfi -i 'color=red:s=320x180' -frames:v 1 -threads 1 $PictureA
    if ($LASTEXITCODE -ne 0) { throw 'Chưa tạo ảnh mẫu A.' }
    & $FFmpeg -v error -f lavfi -i 'color=green:s=320x180' -frames:v 1 -threads 1 $PictureB
    if ($LASTEXITCODE -ne 0) { throw 'Chưa tạo ảnh mẫu B.' }
    & $FFmpeg -v error -f lavfi -i 'color=blue:s=640x360:r=30:d=4' -vf 'drawbox=x=10:y=10:w=70:h=40:color=red:t=fill:enable=gte(t\,2)' -an -c:v libx264 -threads 1 (Join-Path $Proof 'clip-cloud-thu.mp4')
    if ($LASTEXITCODE -ne 0) { throw 'Chưa tạo clip trả về của Cloud thử.' }
    $CloudScript = Join-Path $Qa 'veo-lite-cloud-thu.cjs'
    $Server = Start-Process -FilePath $Node -ArgumentList ('"{0}" "{1}" "{2}"' -f $CloudScript, $Qa, $Proof) -PassThru -WindowStyle Hidden -RedirectStandardError (Join-Path $Qa 'cloud-stderr.log') -RedirectStandardOutput (Join-Path $Qa 'cloud-stdout.log')
    $null = Wait-Moc { Test-Path -LiteralPath (Join-Path $Qa 'cloud-ready.txt') } 10 'Cloud TLS thử chưa nghe ở loopback.'

    $Ranges = @('1.0.0.0-126.255.255.255','128.0.0.0-255.255.255.255','2000::/3')
    New-NetFirewallRule -Name $FirewallNode -DisplayName $FirewallNode -Enabled True -Direction Outbound -Action Block -Program $Node -RemoteAddress $Ranges | Out-Null
    $App = Start-Process $AppFile -WorkingDirectory $Install -PassThru
    $null = Wait-Moc { Find-Ui 'Tiếp tục với Google' } 45 'Vèo chưa mở màn đăng nhập.'
    $Browser = Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" | Where-Object ParentProcessId -eq $App.Id | Select-Object -First 1
    if (!$Browser.ExecutablePath -or @((Get-NetFirewallProfile) | Where-Object Enabled -ne 'True').Count) { throw 'Chưa xác nhận máy thử ngoại tuyến.' }
    New-NetFirewallRule -Name $FirewallBrowser -DisplayName $FirewallBrowser -Enabled True -Direction Outbound -Action Block -Program $Browser.ExecutablePath -RemoteAddress $Ranges | Out-Null
    $PreviousWorker = Get-CimInstance Win32_Process -Filter "Name='node.exe'" | Where-Object ParentProcessId -eq $App.Id | Select-Object -First 1
    if (!$App.CloseMainWindow() -or !$App.WaitForExit(10000)) {
        Stop-Process -Id $App.Id
        $App.WaitForExit()
    }
    if ($PreviousWorker) {
        $null = Wait-Moc { !(Get-Process -Id $PreviousWorker.ProcessId -ErrorAction SilentlyContinue) } 15 'Phần dựng trước chưa dừng.'
    }
    New-Item -ItemType Directory -Path $Data -Force | Out-Null
    @{refresh='veo-qa-khong-phai-token'; id='00000000-0000-4000-8000-000000000026'; email='veo-qa@example.invalid'; ten='Kho thử Windows'} |
        ConvertTo-Json -Compress | Set-Content -Encoding utf8 -LiteralPath (Join-Path $Data 'dang-nhap.json')
    $App = Start-Process $AppFile -WorkingDirectory $Install -PassThru
    $null = Wait-Moc {
        $Skip = Find-Ui 'Dùng ngay'
        if ($Skip) { Click-Ui $Skip }
        Find-Ui 'Tạo mới'
    } 65 'Không mở được kho thử trên Vèo.'
    if (!$Shell.AppActivate($App.Id)) { throw 'Cửa sổ thử chưa nhận tiêu điểm.' }

    Click-Ui (Ui 'Tạo mới')
    Bam 'Từ ý tưởng / Storyboard'
    Dien 'Tên video' 'QA Veo Lite'
    Dien 'Chữ cảnh 1' 'Desk light'
    Dien 'Số giây cảnh 1' '4'
    Bam 'Dựng video'
    $null = Wait-Moc { Find-Ui 'Xuất video' -Focusable } 75 'Storyboard bốn giây chưa dựng xong.'
    Mo-Veo
    Chon 'Model tạo clip' 2 'Veo 3.1 Fast'
    foreach ($Picture in @($PictureA, $PictureB)) {
        Bam 'Nhập ảnh'
        Choose-File 'Chọn ảnh bìa' $Picture
        Thay ("Bỏ ảnh " + [IO.Path]::GetFileName($Picture))
    }
    Thay 'Ảnh tham chiếu'
    Chon 'Model tạo clip' 3 'Veo 3.1 Lite · Thử nghiệm'
    Thay 'Ảnh mở đầu'
    Thay 'Bỏ bớt ảnh để còn tối đa'
    Thay 'Bỏ ảnh Anh A.png'
    Thay 'Bỏ ảnh Anh B.png'
    Dien 'Mô tả hình ảnh và chuyển động' 'A slow camera move across the opening frame.'
    if (Find-Ui 'Xem trước và duyệt' -Focusable) { throw 'Lite cho duyệt hai ảnh mở đầu.' }
    Luu-Anh '01-hai-anh-giu-khi-doi-model'
    Chon 'Model tạo clip' 2 'Veo 3.1 Fast'
    Thay 'Ảnh tham chiếu'
    Thay 'Bỏ ảnh Anh A.png'
    Thay 'Bỏ ảnh Anh B.png'
    Bam 'Bỏ ảnh Anh B.png'
    Chon 'Model tạo clip' 3 'Veo 3.1 Lite · Thử nghiệm'
    Thay 'Ảnh mở đầu'
    Thay 'Bỏ ảnh Anh A.png'
    if (Find-Ui 'Bỏ ảnh Anh B.png') { throw 'Ảnh bỏ đi vẫn còn trong lượt duyệt.' }

    Cloud-Budget '0.11'
    Chon 'Độ phân giải clip' 1 '1080p'
    Bam 'Xem trước và duyệt'
    Thay @('Ước tính 0,32', '0,32')
    Thay 'Ảnh mở đầu sẽ gửi'
    Luu-Anh '02-lite-1080p-co-tieng'
    Bam 'Sửa yêu cầu'
    Chon 'Độ phân giải clip' 0 '720p'
    Bam 'Tạo tiếng cùng clip Veo'
    Bam 'Xem trước và duyệt'
    Thay @('Ước tính 0,12', '0,12')
    Thay 'Vượt ngân sách ước tính còn lại hôm nay.'
    if ((Find-Ui 'Gửi tạo cảnh' -Focusable) -or @(Nhat-Ky).Count -ne 0) { throw 'Không chặn đúng mức ngân sách 0,11 USD.' }
    Luu-Anh '03-chan-vuot-ngan-sach'

    Bam 'Sửa yêu cầu'
    Cloud-Budget '0.12'
    Bam 'Xem trước và duyệt'
    Thay @('Ước tính 0,12', '0,12')
    Bam 'Gửi tạo cảnh'
    Thay 'Có biên nhận, có thể tải lại'
    Luu-Anh '04-giu-ma-sau-loi-503'
    $Projects = @(Get-ChildItem -LiteralPath (Join-Path $Data 'du-an') -Directory)
    if ($Projects.Count -ne 1) { throw 'Kho thử cần đúng một dự án.' }
    $Photos = @(Get-ChildItem -LiteralPath (Join-Path $Projects[0].FullName 'xem') -File -Filter 'anh-gui-*.jpg')
    $Calls = @(Nhat-Ky)
    if ($Photos.Count -ne 1 -or $Calls.Count -ne 2 -or $Calls[0].action -ne 'submit' -or $Calls[1].status -ne 503 -or
        (Get-FileHash -LiteralPath $Photos[0].FullName).Hash -ne $Calls[0].imageSha256) { throw 'Ảnh duyệt hoặc biên nhận Cloud không khớp.' }

    $App = Restart-Veo
    $null = Wait-Moc { Find-Ui 'Xuất video' -Focusable } 75 'Vèo chưa mở lại dự án.'
    if (!$Shell.AppActivate($App.Id)) { throw 'Cửa sổ mở lại chưa nhận tiêu điểm.' }
    Mo-Veo
    Bam 'Tải lại clip đã tạo'
    Thay 'Đã vào kho tư liệu'
    Luu-Anh '05-tai-lai-va-giu-du-tru'
    Bam 'Dùng cho cảnh 1'
    $null = Ui 'Tạo bản dựng mới'
    Bam 'Tạo bản dựng mới'
    $null = Wait-Moc {
        if (!(Find-Ui 'Tên video' -Focusable) -and (Find-Ui 'Xuất video' -Focusable)) { return $true }
    } 75 'Chưa dựng lại từ clip đã tạo và đóng hộp storyboard.'
    $Output = Xuat 'QA Veo Lite Xuat' 120
    Kiem-Mau $Output '1.0' 2

    $App = Restart-Veo
    $null = Wait-Moc { Find-Ui 'Thành phẩm' } 75 'Vèo chưa mở lại thành phẩm.'
    if (!$Shell.AppActivate($App.Id)) { throw 'Cửa sổ mở lại chưa nhận tiêu điểm.' }
    Mouse-Ui (Ui 'Phát')
    $null = Wait-Moc { Find-Ui 'Dừng' } 10 'Thành phẩm không phát được.'
    Start-Sleep -Milliseconds 300
    Luu-Anh '06-phat-thanh-pham-sau-khi-mo-lai'
    $Final = @(Nhat-Ky)
    if ($Final.Count -ne 3 -or $Final[2].status -ne 200 -or $Final[2].operation -ne $Calls[1].operation -or
        (Get-FileHash -LiteralPath $Output.path).Hash -ne $Output.sha256) { throw 'Có gửi lại, đọc sai mã hoặc thành phẩm đổi sau khi mở.' }
    [ordered]@{
        source=$env:VEO_QA_SOURCE; workerSha256=$env:VEO_QA_WORKER_SHA; system=$env:VEO_QA_OS
        cloudFixture=$true; budgetBlocked=$true; blockedTwoImages=$true; restoredSameReceipt=$true; playedAfterRestart=$true
        quote720SilentCents=12; quote1080WithAudioCents=32; outputFrames=$Output.frames; outputSha256=$Output.sha256
        cloud=$Final
    } | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8 -LiteralPath (Join-Path $Proof 'ket-qua.json')
} catch {
    if ($App -and !$App.HasExited) {
        $null = Anh 'loi'
        $Root = [System.Windows.Automation.AutomationElement]::FromHandle($App.MainWindowHandle)
        if ($Root) {
            $Root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition) |
                Where-Object { $_.Current.Name } | ForEach-Object { $_.Current.Name } | Sort-Object -Unique |
                Set-Content -Encoding utf8 -LiteralPath (Join-Path $Proof 'dieu-khien-khi-loi.txt')
        }
    }
    $CloudError = Join-Path $Qa 'cloud-stderr.log'
    if (Test-Path -LiteralPath $CloudError) { Copy-Item -LiteralPath $CloudError -Destination $Proof }
    throw
} finally {
    if ($App -and !$App.HasExited) { Stop-Process -Id $App.Id }
    if ($Server -and !$Server.HasExited) { Stop-Process -Id $Server.Id }
    Remove-NetFirewallRule -Name $FirewallBrowser -ErrorAction SilentlyContinue
    Remove-NetFirewallRule -Name $FirewallNode -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $HostsCopy) {
        Copy-Item -Force -LiteralPath $HostsCopy -Destination $HostsPath
        Clear-DnsClientCache
    }
}
