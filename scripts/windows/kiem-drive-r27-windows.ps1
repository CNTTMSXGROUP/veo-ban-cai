param([Parameter(Mandatory)][string]$Install, [Parameter(Mandatory)][string]$Qa)
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or !$Qa.StartsWith($env:RUNNER_TEMP, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Chỉ thao tác cửa sổ trên máy Windows thử.'
}
$AppFile = Join-Path $Install 'msx-phong-dung.exe'
$Data = Join-Path $env:APPDATA 'vn.msxgroup.phongdung'
$Proof = Join-Path $Qa 'minh-chung'
New-Item -ItemType Directory -Path $Proof -Force | Out-Null
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class VeoQaWindow {
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int L,T,R,B; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out Rect r);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, int x, int y, uint data, UIntPtr extra);
    [DllImport("user32.dll")] public static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);
}
'@

function Wait-Moc([scriptblock]$Predicate, [int]$Seconds, [string]$Message) {
    $Until = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        $Value = & $Predicate
        if ($Value) { return $Value }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $Until)
    throw $Message
}
function Find-Ui([string]$Name, [switch]$ButtonPrefix, [switch]$Focusable) {
    $App.Refresh()
    if ($App.HasExited -or $App.MainWindowHandle -eq [IntPtr]::Zero) { return }
    try {
        $Window = [System.Windows.Automation.AutomationElement]::FromHandle($App.MainWindowHandle)
        $Condition = if ($ButtonPrefix) {
            [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
        } else {
            [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty, $Name)
        }
        $Items = $Window.FindAll([System.Windows.Automation.TreeScope]::Descendants, $Condition)
        foreach ($Item in $Items) {
            if ($ButtonPrefix -and !([string]$Item.Current.Name).StartsWith($Name)) { continue }
            if ($Focusable -and !$Item.Current.IsKeyboardFocusable) { continue }
            if ($Item.Current.IsEnabled -and !$Item.Current.IsOffscreen) { return $Item }
        }
        foreach ($Item in $Items) {
            if ($ButtonPrefix -and !([string]$Item.Current.Name).StartsWith($Name)) { continue }
            if ($Focusable -and !$Item.Current.IsKeyboardFocusable) { continue }
            if ($Item.Current.IsEnabled) { return $Item }
        }
    } catch [System.Windows.Automation.ElementNotAvailableException] { return }
    catch {
        if ($_.Exception.ToString() -match '0x80010012') { return }
        throw
    }
}
function Ui([string]$Name) { Wait-Moc { Find-Ui $Name } 15 "Không thấy điều khiển '$Name'." }
function Keys([string]$Key) { [System.Windows.Forms.SendKeys]::SendWait($Key) }
function Click-Ui($Item) {
    $Item.SetFocus()
    Start-Sleep -Milliseconds 220
    Mouse-Ui $Item
}
function Mouse-Ui($Item, [double]$X=.5) {
    $Rect = $Item.Current.BoundingRectangle
    if ($Rect.Width -le 0 -or $Rect.Height -le 0) { throw 'Điều khiển không nằm trên cửa sổ.' }
    if (![VeoQaWindow]::SetCursorPos([int]($Rect.X + $Rect.Width*$X), [int]($Rect.Y + $Rect.Height / 2))) { throw 'Không đặt được con trỏ trên máy thử.' }
    [VeoQaWindow]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
    [VeoQaWindow]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
}
function Anh([string]$Name) {
    $App.Refresh()
    $Rect = [VeoQaWindow+Rect]::new()
    if (![VeoQaWindow]::GetWindowRect($App.MainWindowHandle, [ref]$Rect)) { return $false }
    $Image = [System.Drawing.Bitmap]::new(($Rect.R - $Rect.L), ($Rect.B - $Rect.T))
    $Graphics = [System.Drawing.Graphics]::FromImage($Image)
    try {
        $Dc = $Graphics.GetHdc()
        try { $Ok = [VeoQaWindow]::PrintWindow($App.MainWindowHandle, $Dc, 2) }
        finally { $Graphics.ReleaseHdc($Dc) }
        if (!$Ok -or $Image.GetPixel([int]($Image.Width / 2), 75).ToArgb() -eq 0) { return $false }
        $Image.Save((Join-Path $Proof "$Name.png"), [System.Drawing.Imaging.ImageFormat]::Png)
        return $true
    } finally { $Graphics.Dispose(); $Image.Dispose() }
}

function Choose-Drive([string]$Path) {
    $Dialog = Wait-Moc {
        $Root = [System.Windows.Automation.AutomationElement]::RootElement
        $Filter = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty, 'Chọn thư mục lưu')
        $Window = $Root.FindFirst([System.Windows.Automation.TreeScope]::Children, $Filter)
        if ($Window -and $Window.Current.ProcessId -eq $App.Id) { $Window }
    } 20 'Không thấy hộp chọn thư mục của Vèo.'
    Keys '%d'
    Keys $Path
    Keys '{ENTER}'
    $Select = Wait-Moc {
        $Filter = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
        $Dialog.FindAll([System.Windows.Automation.TreeScope]::Descendants, $Filter) |
            Where-Object { $_.Current.AutomationId -eq '1' -or $_.Current.Name -eq 'Select Folder' } | Select-Object -First 1
    } 15 'Không thấy nút xác nhận thư mục.'
    Mouse-Ui $Select
}

function Read-Color([string]$Path, [double]$X, [double]$Y) {
    $Image = [System.Drawing.Bitmap]::new($Path)
    try {
        $Cx = [int]($Image.Width*$X)
        $Cy = [int]($Image.Height*$Y)
        $Totals = @(0,0,0)
        for ($dy=-4; $dy -le 4; $dy++) {
            for ($dx=-4; $dx -le 4; $dx++) {
                $c = $Image.GetPixel($Cx+$dx,$Cy+$dy)
                $Totals[0]+=$c.R; $Totals[1]+=$c.G; $Totals[2]+=$c.B
            }
        }
        return $Totals | ForEach-Object { [int][Math]::Round($_/81) }
    } finally { $Image.Dispose() }
}
function Compare-Color($A, $B) {
    $Worst = 0
    for ($I=0; $I -lt 3; $I++) { $Worst=[Math]::Max($Worst,[Math]::Abs($A[$I]-$B[$I])) }
    return $Worst
}
$Firewall = "Veo-QA-WebView2-$env:GITHUB_RUN_ID"
$env:WEBVIEW2_USER_DATA_FOLDER = Join-Path $Qa 'webview2'
$Shell = New-Object -ComObject WScript.Shell
$App = $null
try {
    $App = Start-Process $AppFile -WorkingDirectory $Install -PassThru
    $null = Wait-Moc { Find-Ui 'Tiếp tục với Google' } 45 'Bộ cài chưa mở màn đăng nhập.'
    $Browser = Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" |
        Where-Object ParentProcessId -eq $App.Id | Select-Object -First 1
    if (!$Browser.ExecutablePath -or @((Get-NetFirewallProfile) | Where-Object Enabled -ne 'True').Count) {
        throw 'Chưa xác định được luật tường lửa cho WebView2 thử.'
    }
    # Chặn kết nối Internet trước khi tạo phiên tổng hợp. Phần dựng dùng 127.0.0.1.
    $Ranges = @('1.0.0.0-126.255.255.255','128.0.0.0-255.255.255.255','2000::/3')
    New-NetFirewallRule -Name $Firewall -DisplayName $Firewall -Enabled True -Direction Outbound -Action Block -Program $Browser.ExecutablePath -RemoteAddress $Ranges | Out-Null
    if (!(Get-NetFirewallRule -Name $Firewall -PolicyStore ActiveStore -ErrorAction SilentlyContinue)) {
        throw 'Luật ngoại tuyến chưa có hiệu lực.'
    }
    $PreviousWorker = Get-CimInstance Win32_Process -Filter "Name='node.exe'" |
        Where-Object ParentProcessId -eq $App.Id | Select-Object -First 1
    if (!$App.CloseMainWindow() -or !$App.WaitForExit(10000)) {
        Stop-Process -Id $App.Id
        $App.WaitForExit()
    }
    if ($PreviousWorker) {
        $null = Wait-Moc {
            !(Get-Process -Id $PreviousWorker.ProcessId -ErrorAction SilentlyContinue)
        } 15 'Phần dựng từ lượt mở đầu chưa dừng.'
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
    if (!$Shell.AppActivate($App.Id)) { throw 'Không lấy được tiêu điểm cửa sổ thử.' }
    if ($Skip = Find-Ui 'Dùng ngay') { Click-Ui $Skip }
    Write-Host 'Đã vào Danh sách làm việc trong kho thử.'
    $null = Ui 'Vèo 0.3.24'




    $FFmpeg = Join-Path $Install 'ffmpeg.exe'
    $Probe = Join-Path $Install 'ffprobe.exe'
    $Transfer = Join-Path $Qa 'may-gui'
    $Sync = Join-Path $Transfer 'drive'
    $IndexFile = @(Get-ChildItem -LiteralPath $Sync -Recurse -File -Filter 'veo.json')
    if ($IndexFile.Count -ne 1) { throw 'Máy gửi phải để lại đúng một bản Drive.' }
    $Index = Get-Content -LiteralPath $IndexFile[0].FullName -Raw -Encoding utf8 | ConvertFrom-Json -Depth 100
    $Original = $Index.plan.sources[0].original
    if ($Original -notmatch '^tep/[0-9]+\.(mp4|mov)$' -or $Original -eq $Index.plan.sources[0].path) {
        throw 'Bản gửi chưa có clip gốc riêng.'
    }
    $OriginalFile = Join-Path $IndexFile[0].DirectoryName $Original
    $Entry = $Index.files | Where-Object path -eq $Original
    $OriginalSha = (Get-FileHash -LiteralPath $OriginalFile).Hash.ToLowerInvariant()
    if ($OriginalSha -ne $Entry.sha -or $OriginalSha -ne (Get-FileHash (Join-Path $Transfer 'nguon-ngang.mp4')).Hash) {
        throw 'Clip gốc trong bản gửi khác tư liệu Mac.'
    }
    $Hold = Join-Path $Qa 'clip-nguon-dang-thu.mp4'
    Move-Item -LiteralPath $OriginalFile -Destination $Hold

    Click-Ui (Ui 'Chỗ lưu')
    Click-Ui (Ui 'Chọn thư mục Drive…')
    Choose-Drive $Sync
    Click-Ui (Ui 'Kiểm tra tư liệu')
    $null = Ui '1 tệp cần xử lý'
    $null = Ui $Entry.name
    $null = Ui "Thiếu tệp · $Original"
    $null = Wait-Moc { Anh '01-thieu-clip-goc' } 12 'Chưa chụp được thông báo thiếu nguồn.'
    $Bytes = [System.IO.File]::ReadAllBytes($Hold)
    $Mid = [int]($Bytes.Length / 2)
    $Bytes[$Mid] = $Bytes[$Mid] -bxor 1
    [System.IO.File]::WriteAllBytes($OriginalFile, $Bytes)
    if ((Get-Item -LiteralPath $OriginalFile).Length -ne $Entry.bytes) { throw 'Ca tệp sai phải giữ nguyên kích thước.' }
    Click-Ui (Ui 'Kiểm lại')
    $null = Ui "Tệp khác bản đã lưu · $Original"
    $null = Wait-Moc { Anh '02-clip-goc-khac-ma-bam' } 12 'Chưa chụp được thông báo sai mã băm.'
    Copy-Item -LiteralPath $Hold -Destination $OriginalFile -Force
    Click-Ui (Ui 'Kiểm lại')
    $null = Ui "Đủ $($Index.files.Count) tệp trên máy này"
    $Offline = Join-Path $Qa 'drive-da-ngat'
    Move-Item -LiteralPath $Sync -Destination $Offline
    Click-Ui (Ui 'Làm mới')
    $null = Ui 'Không mở được thư mục Drive. Kiểm tra Google Drive cho máy tính rồi bấm Làm mới.'
    $null = Wait-Moc { Anh '03-kiem-du-roi-ngat-drive' } 12 'Chưa chụp được bản đã kiểm khi ngắt Drive.'
    Click-Ui (Ui 'Mở bản sao')
    $null = Ui 'Đã tạo dự án từ Drive trong danh sách Đang làm.'
    Keys '{ESC}'
    $null = Ui "$($Index.name) (Drive)"
    Click-Ui (Ui 'Sửa tay')
    Click-Ui (Ui 'Khung bìa')
    $Picker = Wait-Moc { Find-Ui 'Tỷ lệ khung dự án' -Focusable } 18 'Không đổi được khung từ clip quay gốc.'
    $Picker.SetFocus()
    Keys '{DOWN}'
    $null = Ui 'Ngang 16:9'
    Keys '{END}{ENTER}'
    $null = Wait-Moc { Find-Ui 'Tỷ lệ khung dự án' -Focusable } 120 'Đổi sang khung ngang chưa xong.'
    $null = Wait-Moc { Anh '04-khung-ngang-tu-clip-goc' } 12 'Chưa chụp được khung ngang.'
    Mouse-Ui (Ui 'Tự động')
    Mouse-Ui (Ui 'Xuất video')
    Click-Ui (Ui '720p')
    Click-Ui (Ui 'Tuỳ chọn xuất thêm')
    Click-Ui (Ui 'Dự án dựng')
    Click-Ui (Ui 'Xuất 2 tệp')
    $null = Wait-Moc { Find-Ui 'Thành phẩm' } 180 'Chưa thấy MP4 sau khi khôi phục.'

    $Outputs = @{}
    foreach ($Ext in @('mp4','fcpxml')) {
        $Found = @(Get-ChildItem -LiteralPath (Join-Path $Data 'du-an') -Directory | ForEach-Object {
            Get-ChildItem -LiteralPath (Join-Path $_.FullName 'xuat') -File -Filter "*.$Ext" -ErrorAction SilentlyContinue
        })
        if ($Found.Count -ne 1 -or !$Found[0].Length) { throw "Thiếu tệp $Ext hoặc xuất trùng." }
        $Outputs[$Ext] = $Found[0]
        Copy-Item -LiteralPath $Found[0].FullName -Destination (Join-Path $Proof "khoi-phuc.$Ext")
    }
    $Streams = (& $Probe -v error -show_entries 'stream=codec_name,width,height,nb_frames,avg_frame_rate' -of json $Outputs.mp4.FullName | ConvertFrom-Json).streams
    $Video = $Streams | Where-Object codec_name -eq h264
    if ($LASTEXITCODE -ne 0 -or $Video.width -ne 1280 -or $Video.height -ne 720 -or $Video.avg_frame_rate -ne '30/1' -or $Video.nb_frames -ne '120' -or 'aac' -notin $Streams.codec_name) {
        throw ('Sai thông số MP4: ' + ($Streams | ConvertTo-Json -Compress))
    }
    $Decoded = Join-Path $Proof '05-khung-tu-mp4.png'
    & $FFmpeg -v error -ss 1 -i $Outputs.mp4.FullName -frames:v 1 -threads 1 $Decoded
    if ($LASTEXITCODE -ne 0) { throw 'Không giải mã được khung MP4.' }
    $Left = @(Read-Color $Decoded .06 .50)
    $Right = @(Read-Color $Decoded .94 .50)
    if ((Compare-Color $Left @(255,0,0)) -gt 25 -or (Compare-Color $Right @(0,0,255)) -gt 25) {
        throw "Khung ngang không giữ được hai mép của clip gốc: $Left / $Right"
    }
    [xml]$Xml = Get-Content -LiteralPath $Outputs.fcpxml.FullName -Raw -Encoding utf8
    $Refs = @($Xml.SelectNodes('//media-rep') | ForEach-Object { ([uri]$_.GetAttribute('src')).LocalPath })
    $Matching = @($Refs | Where-Object {
        (Test-Path -LiteralPath $_ -PathType Leaf) -and (Get-FileHash -LiteralPath $_).Hash -eq $OriginalSha
    })
    if ($Xml.fcpxml.version -ne '1.10' -or !$Matching.Count -or @($Matching | Where-Object { !$_.StartsWith($Data, [StringComparison]::OrdinalIgnoreCase) }).Count) {
        throw 'FCPXML không trỏ tới clip quay gốc trong kho máy nhận.'
    }

    $Next = Join-Path $Qa 'Drive Win gui lai'
    New-Item -ItemType Directory -Path $Next | Out-Null
    Click-Ui (Ui 'Chỗ lưu')
    Click-Ui (Ui 'Đổi thư mục…')
    Choose-Drive $Next
    $Picker = Wait-Moc { Find-Ui 'Video đưa lên Drive' -Focusable } 20 'Chưa chọn được dự án để lưu lại.'
    $Picker.SetFocus()
    Keys '{DOWN}'
    Keys '{END}{ENTER}'
    Click-Ui (Ui 'Đưa bản dựng lên Drive')
    $null = Ui 'Đã lưu vào thư mục Drive. Google Drive cho máy tính sẽ tải bản lên.'
    $null = Wait-Moc { Anh '06-luu-ban-sao-tu-windows' } 12 'Chưa chụp được lần lưu lại.'
    $NewIndex = @(Get-ChildItem -LiteralPath $Next -Recurse -File -Filter 'veo.json')
    if ($NewIndex.Count -ne 1) { throw 'Máy nhận chưa ghi đúng một bản để gửi lại.' }
    $SentAgain = Get-Content -LiteralPath $NewIndex[0].FullName -Raw -Encoding utf8 | ConvertFrom-Json -Depth 100
    $AgainOriginal = $SentAgain.plan.sources[0].original
    if ($AgainOriginal -notmatch '^tep/[0-9]+\.(mp4|mov)$' -or $SentAgain.plan.canvas -ne 'ngang') { throw 'Bản gửi lại sai canvas hoặc sai đường dẫn nguồn.' }
    if ((Get-FileHash -LiteralPath (Join-Path $NewIndex[0].DirectoryName $AgainOriginal)).Hash -ne $OriginalSha) {
        throw 'Gửi lại trên Windows đã làm đổi clip quay gốc.'
    }
    Copy-Item -LiteralPath $NewIndex[0].FullName -Destination (Join-Path $Proof 'veo-win-gui-lai.json')
    Click-Ui (Ui 'Ngắt kết nối')
    Keys '{ESC}'
    $Hash = (Get-FileHash -LiteralPath $Outputs.mp4.FullName).Hash.ToLowerInvariant()
    Keys '%{F4}'
    if (!$App.WaitForExit(15000)) { throw 'Vèo chưa đóng.' }
    $App = Start-Process $AppFile -WorkingDirectory $Install -PassThru
    $null = Wait-Moc { Find-Ui 'Thành phẩm' } 70 'Vèo mở lại chưa thấy thành phẩm.'
    if (!$Shell.AppActivate($App.Id)) { throw 'Không lấy được tiêu điểm sau khi mở lại.' }
    Mouse-Ui (Ui 'Tua video') .25
    Mouse-Ui (Ui 'Phát')
    $null = Wait-Moc { Find-Ui 'Dừng' } 8 'Không phát được MP4 khôi phục sau khi mở lại.'
    $null = Wait-Moc { Anh '07-phat-sau-khi-mo-lai' } 12 'Chưa chụp được khung phát lại.'
    if ((Get-FileHash -LiteralPath $Outputs.mp4.FullName).Hash -ne $Hash) { throw 'Mở lại làm đổi MP4.' }
    $Report = [ordered]@{
        source=$env:VEO_QA_SOURCE
        workerSha256=$env:VEO_QA_WORKER_SHA
        system=$env:VEO_QA_OS
        sourceClipSha256=$OriginalSha
        mediaCount=$Index.files.Count
        missingDetected=$true
        sameSizeChangeDetected=$true
        restoredOffline=$true
        video=$Video
        sampleLeft=$Left
        sampleRight=$Right
        outputSha256=$Hash
        fcpxmlRefersOriginal=$true
        originalUnchangedWhenRepublished=$true
        reopenedAndPlayed=$true
    }
    $Report | ConvertTo-Json -Depth 7 | Set-Content -Encoding utf8 -LiteralPath (Join-Path $Proof 'ket-qua.json')
    Write-Host ($Report | ConvertTo-Json -Depth 7 -Compress)


} catch {
    if ($App -and !$App.HasExited) {
        $null = Anh 'loi'
        try {
            $Win = [System.Windows.Automation.AutomationElement]::FromHandle($App.MainWindowHandle)
            $Nodes = $Win.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
            $Nodes | Where-Object { $_.Current.Name -and $_.Current.IsKeyboardFocusable } |
                ForEach-Object { $_.Current.Name } | Sort-Object -Unique |
                Set-Content -Encoding utf8 -LiteralPath (Join-Path $Proof 'dieu-khien-khi-loi.txt')
        } catch { Write-Host 'Không đọc được danh sách điều khiển khi dừng ca.' }
    }
    $Roots = @($Data, (Join-Path $env:LOCALAPPDATA 'vn.msxgroup.phongdung'))
    $Log = Get-ChildItem -LiteralPath $Roots -Recurse -File -Filter 'phan-dung.log' -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($Log) { Copy-Item -LiteralPath $Log.FullName -Destination (Join-Path $Proof 'phan-dung.log') }
    throw
} finally {
    if ($App -and !$App.HasExited) { Stop-Process -Id $App.Id }
    Remove-NetFirewallRule -Name $Firewall -ErrorAction SilentlyContinue
}
