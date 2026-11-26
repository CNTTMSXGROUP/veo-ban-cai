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
$ErrorActionPreference = 'Stop'
if (Test-Path $Data) { throw 'Cần kho Vèo trống.' }
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
function Find-Ui([string]$Name, [switch]$ButtonPrefix, [switch]$TextPrefix, [switch]$Focusable) {
    $App.Refresh()
    if ($App.HasExited -or $App.MainWindowHandle -eq [IntPtr]::Zero) { return }
    try {
        $Window = [System.Windows.Automation.AutomationElement]::FromHandle($App.MainWindowHandle)
        $Condition = if ($ButtonPrefix -or $TextPrefix) {
            $Type = if ($ButtonPrefix) { [System.Windows.Automation.ControlType]::Button } else { [System.Windows.Automation.ControlType]::Text }
            [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty, $Type)
        } else {
            [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty, $Name)
        }
        $Items = $Window.FindAll([System.Windows.Automation.TreeScope]::Descendants, $Condition)
        foreach ($Item in $Items) {
            if (($ButtonPrefix -or $TextPrefix) -and !([string]$Item.Current.Name).StartsWith($Name)) { continue }
            if ($Focusable -and !$Item.Current.IsKeyboardFocusable) { continue }
            if ($Item.Current.IsEnabled -and !$Item.Current.IsOffscreen) { return $Item }
        }
        foreach ($Item in $Items) {
            if (($ButtonPrefix -or $TextPrefix) -and !([string]$Item.Current.Name).StartsWith($Name)) { continue }
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

$Server = $null
$Port = 54325
$env:VEO_PHAN_CHAY_GOC = "http://127.0.0.1:$Port"
$Manifest = Join-Path $Install 'phan-do-hoa.json'
$Part = (Get-Content -LiteralPath $Manifest -Raw -Encoding utf8 | ConvertFrom-Json).items[0]
if ($Part.tep -notmatch '^render-hyperframes-win32-x64-[0-9a-f]{12}\.tar\.gz$') { throw 'Danh sách gói không đúng Windows x64.' }
$Archive = Join-Path $Qa $Part.tep
if ((Get-Item $Archive).Length -ne $Part.size -or (Get-FileHash -LiteralPath $Archive).Hash -ne $Part.sha256) {
    throw 'Tệp tải không khớp bộ cài Vèo.'
}
$Cache = Join-Path $Data "goi-do-hoa/$($Part.sha256)/render-hyperframes/render.mjs"
$Log = Join-Path $Proof 'may-chu-tai.log'
$Body = Join-Path $Qa 'goi'
New-Item -ItemType Directory -Path $Body | Out-Null
$Server = Start-Process (Get-Command python).Source -ArgumentList @('-m','http.server',$Port,'--bind','127.0.0.1','--directory',('"' + $Body + '"')) -RedirectStandardError $Log -RedirectStandardOutput (Join-Path $Qa 'may-chu.txt') -WindowStyle Hidden -PassThru
$null = Wait-Moc {
    curl.exe -fsI "$env:VEO_PHAN_CHAY_GOC/" 2>$null | Out-Null
    $LASTEXITCODE -eq 0
} 15 'Chưa mở được máy chủ gói trên máy thử.'
function Dien([string]$Name, [string]$Value) {
    $Field = Wait-Moc { Find-Ui $Name -Focusable } 15 "Không thấy ô nhập '$Name'."
    $Field.SetFocus()
    Keys '^a'
    [System.Windows.Forms.Clipboard]::SetText($Value)
    Keys '^v'
    Keys '{TAB}'
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





    if (Test-Path $Cache) { throw 'Kho thử đã cài sẵn bộ dựng.' }
    Click-Ui (Ui 'Tạo mới')
    Click-Ui (Ui 'Từ ý tưởng / Storyboard')
    Dien 'Tên video' 'Cảnh thử đồ họa'
    Dien 'Số giây cảnh 1' '4'
    Click-Ui (Ui 'Ngang 16:9')
    Click-Ui (Ui 'Tạo đồ họa')
    $Button = Wait-Moc { Find-Ui 'Tải bộ dựng' -ButtonPrefix } 25 'Không thấy nút tải bộ dựng.'
    $null = Anh '01-tai-bo-dung'
    Click-Ui $Button
    $Retry = Wait-Moc { Find-Ui 'Thử tải lại' -ButtonPrefix } 40 'Vèo chưa hiện thao tác thử tải lại.'
    if (Test-Path $Cache) { throw 'Máy chủ trả 404 mà app đã nhận gói.' }
    $null = Anh '02-thu-tai-lai'
    Copy-Item -LiteralPath $Archive -Destination (Join-Path $Body $Part.tep)
    Click-Ui $Retry
    $null = Wait-Moc { Test-Path $Cache } 80 'Gói đồ họa chưa cài.'
    Click-Ui (Ui 'Chữ động')
    Dien 'Dòng chữ' 'Góc đọc sách'
    Click-Ui (Ui 'Dựng bản xem')
    $null = Wait-Moc { Find-Ui 'Video xem thử đồ họa' } 140 'Chưa thấy bản xem chữ động.'
    $null = Anh '03-xem-chu-dong'
    Click-Ui (Ui 'Dùng đồ họa cho cảnh 1')
    $null = Ui 'Sửa đồ họa'
    $null = Anh '04-do-hoa-da-vao-canh'
    Click-Ui (Ui 'Dựng video')
    $null = Wait-Moc { Find-Ui 'Xuất video' } 140 'Storyboard chưa dựng xong.'
    Click-Ui (Ui 'Xuất video')
    Click-Ui (Ui '720p')
    Click-Ui (Ui 'Xuất 1 tệp')
    $null = Wait-Moc { Find-Ui 'Thành phẩm' } 140 'Chưa thấy video đã xuất.'
    $Outputs = @(Get-ChildItem -LiteralPath (Join-Path $Data 'du-an') -Directory | ForEach-Object {
        Get-ChildItem -LiteralPath (Join-Path $_.FullName 'xuat') -File -Filter '*.mp4' -ErrorAction SilentlyContinue
    })
    if ($Outputs.Count -ne 1 -or !$Outputs[0].Length) { throw 'Không thấy đúng một MP4 đã xuất.' }
    $Export = $Outputs[0].FullName
    Copy-Item -LiteralPath $Export -Destination (Join-Path $Proof 'Chuyen-dong-chu.mp4')
    $Hash = (Get-FileHash -LiteralPath $Export).Hash
    Keys '%{F4}'
    if (!$App.WaitForExit(15000)) { throw 'Vèo chưa đóng.' }
    $App = Start-Process $AppFile -WorkingDirectory $Install -PassThru
    $null = Wait-Moc { Find-Ui 'Thành phẩm' } 75 'Vèo mở lại chưa thấy thành phẩm.'
    if (!$Shell.AppActivate($App.Id)) { throw 'Không lấy được tiêu điểm sau khi mở lại.' }
    Mouse-Ui (Ui 'Tua video') .25
    Mouse-Ui (Ui 'Phát')
    $null = Wait-Moc { Find-Ui 'Dừng' } 8 'Không phát được MP4 sau khi mở lại.'
    $null = Wait-Moc { Anh '05-phat-sau-khi-mo-lai' } 12 'Chưa chụp được ảnh phát lại.'
    if ((Get-FileHash -LiteralPath $Export).Hash -ne $Hash) { throw 'Mở lại làm đổi MP4.' }
    python (Join-Path $Qa 'kiem-video-do-hoa.py') $Data $Install $Manifest $Proof $Log |
        Tee-Object -FilePath (Join-Path $Proof 'ket-qua.json')
    if ($LASTEXITCODE -ne 0) { throw 'Tệp đã xuất chưa đạt bài kiểm đồ họa.' }

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
    if ($Server -and !$Server.HasExited) { Stop-Process -Id $Server.Id }
    Remove-NetFirewallRule -Name $Firewall -ErrorAction SilentlyContinue
}
