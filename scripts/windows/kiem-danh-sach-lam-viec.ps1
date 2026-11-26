param([Parameter(Mandatory)][string]$Install, [Parameter(Mandatory)][string]$Qa)
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or !$Qa.StartsWith($env:RUNNER_TEMP, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Chỉ thao tác cửa sổ trên máy Windows thử.'
}
$AppFile = Join-Path $Install 'msx-phong-dung.exe'
$Data = Join-Path $env:APPDATA 'vn.msxgroup.phongdung'
$Proof = Join-Path $Qa 'minh-chung'
$Node = Join-Path $Install 'node.exe'
$ScriptPath = Join-Path $Qa 'kiem-danh-sach-lam-viec.mjs'
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
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out Rect r);
    [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int ht, bool paint);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, int x, int y, int wheel, UIntPtr info);
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
function Find-Ui([string]$Name) {
    $App.Refresh()
    if ($App.HasExited -or $App.MainWindowHandle -eq [IntPtr]::Zero) { return }
    try {
        $Window = [System.Windows.Automation.AutomationElement]::FromHandle($App.MainWindowHandle)
        $Condition = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty, $Name)
        $Items = $Window.FindAll([System.Windows.Automation.TreeScope]::Descendants, $Condition)
        foreach ($Item in $Items) {
            if ($Item.Current.IsEnabled -and !$Item.Current.IsOffscreen) { return $Item }
        }
        foreach ($Item in $Items) {
            if ($Item.Current.IsEnabled) { return $Item }
        }
    } catch [System.Windows.Automation.ElementNotAvailableException] { return }
}
function Ui([string]$Name) { Wait-Moc { Find-Ui $Name } 15 "Không thấy điều khiển '$Name'." }
function Keys([string]$Key) { [System.Windows.Forms.SendKeys]::SendWait($Key) }
function Click-Ui($Item) {
    $Pattern = $null
    if ($Item.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$Pattern)) { $Pattern.Invoke(); return }
    if ($Item.TryGetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern, [ref]$Pattern)) { $Pattern.Toggle(); return }
    $Item.SetFocus()
    Keys '{ENTER}'
}
function Search-Text {
    (Ui 'Tìm video').GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value
}
function Toggle-State([string]$Name) {
    (Ui $Name).GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Current.ToggleState.ToString()
}
function Doc-Kho([string]$Id) {
    $Rows = & $Node $ScriptPath doc-kho $Install $Qa $Id
    if ($LASTEXITCODE -ne 0) { throw 'Không đọc được kho Vèo.' }
    return ($Rows | ConvertFrom-Json)
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
function Viewport([int]$Width, [int]$Height) {
    $App.Refresh()
    $Window = [VeoQaWindow+Rect]::new()
    $Client = [VeoQaWindow+Rect]::new()
    $Hwnd = $App.MainWindowHandle
    $null = [VeoQaWindow]::GetWindowRect($Hwnd, [ref]$Window)
    $null = [VeoQaWindow]::GetClientRect($Hwnd, [ref]$Client)
    if (![VeoQaWindow]::MoveWindow($Hwnd, 0, 0, ($Width + $Window.R - $Window.L - $Client.R),
        ($Height + $Window.B - $Window.T - $Client.B), $true)) { throw 'Không đổi được kích cỡ cửa sổ thử.' }
    Start-Sleep -Milliseconds 350
    $null = [VeoQaWindow]::GetClientRect($Hwnd, [ref]$Client)
    if ($Client.R -ne $Width -or $Client.B -ne $Height) { throw "Sai kích thước vùng nội dung $($Client.R) × $($Client.B)." }
    $Search = (Ui 'Tìm video').Current.BoundingRectangle
    $Filter = (Ui 'Lọc trạng thái video').Current.BoundingRectangle
    if ($Search.IsEmpty -or $Filter.IsEmpty -or $Search.Right -gt $Filter.Left) { throw 'Ô tìm và bộ lọc đè lên nhau.' }
    return @{ width=$Client.R; height=$Client.B; searchWidth=$Search.Width; filterWidth=$Filter.Width; screenshot=(Anh ("veo-{0}x{1}" -f $Width,$Height)) }
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
    Stop-Process -Id $App.Id
    $App.WaitForExit()
    @{refresh='veo-qa-khong-phai-token'; id='00000000-0000-4000-8000-000000000026'; email='veo-qa@example.invalid'; ten='Kho thử Windows'} |
        ConvertTo-Json -Compress | Set-Content -Encoding utf8 -LiteralPath (Join-Path $Data 'dang-nhap.json')
    $App = Start-Process $AppFile -WorkingDirectory $Install -PassThru
    $null = Wait-Moc {
        $Skip = Find-Ui 'Dùng ngay'
        if ($Skip) { Click-Ui $Skip }
        Find-Ui 'Xem Mẫu cài đặt'
    } 65 'Không mở được kho thử trên Vèo.'
    if (!$Shell.AppActivate($App.Id)) { throw 'Không lấy được tiêu điểm cửa sổ thử.' }
    if ($Skip = Find-Ui 'Dùng ngay') { Click-Ui $Skip }
    $null = Ui 'Vèo 0.3.24'
    $TaiNguyen = Join-Path $Data 'tai-nguyen'
    $MusicWait = [Diagnostics.Stopwatch]::StartNew()
    $null = Wait-Moc {
        (Test-Path (Join-Path $TaiNguyen 'kho-nhac-xong')) -and
            !(Test-Path (Join-Path $TaiNguyen 'kho-tam')) -and
            !(Test-Path (Join-Path $TaiNguyen 'kho-nhac-co-san.tar'))
    } 210 'Kho nhạc tải sẵn chưa nạp xong hoặc còn tệp giải nén.'
    $MusicWait.Stop()
    Write-Host 'Đã tải và nạp kho nhạc ở lần mở đầu.'
    $V1440 = Viewport 1440 900
    $V1100 = Viewport 1100 700
    Write-Host 'Đã mở danh sách và đo hai kích thước cửa sổ.'
    Click-Ui (Ui 'Lọc trạng thái video')
    Click-Ui (Ui 'Lỗi')
    $null = Ui 'Xem Mẫu mất tệp nguồn'
    if (Find-Ui 'Xem Mẫu phỏng vấn') { throw 'Bộ lọc Lỗi vẫn hiện video đủ nguồn.' }
    Click-Ui (Ui 'Lọc trạng thái video')
    Click-Ui (Ui 'Sẵn sàng xuất')
    (Ui 'Tìm video').SetFocus()
    Keys 'Mau'
    $null = Wait-Moc { (Search-Text) -eq 'Mau' } 8 'Không điền được ô tìm.'
    Click-Ui (Ui 'Chọn nhiều')
    $SelectedNames = @('Mẫu phỏng vấn','Mẫu du lịch','Mẫu hướng dẫn')
    foreach ($Name in $SelectedNames) { Click-Ui (Ui "Chọn $Name") }
    $null = Ui 'Xuất 3 video đã chọn'
    Click-Ui (Ui 'Xem Mẫu hướng dẫn')
    $Anchor = Ui 'Xem Mẫu hướng dẫn'
    $RowY0 = $Anchor.Current.BoundingRectangle.Y
    $Point = $Anchor.GetClickablePoint()
    [System.Windows.Forms.Cursor]::Position = [System.Drawing.Point]::new([int]$Point.X, [int]$Point.Y)
    [VeoQaWindow]::mouse_event(0x0800, 0, 0, -480, [UIntPtr]::Zero)
    $RowY = Wait-Moc {
        $Y = (Ui 'Xem Mẫu hướng dẫn').Current.BoundingRectangle.Y
        if ([double]::IsFinite($Y) -and $Y -lt $RowY0) { $Y }
    } 5 'Chưa cuộn được danh sách thử.'
    Click-Ui (Ui 'Sửa tay')
    (Ui 'Phụ đề khi xem').SetFocus()
    Keys '{HOME}'
    Start-Sleep -Milliseconds 250
    Keys '+{RIGHT}'
    Start-Sleep -Milliseconds 350
    Keys '^b'
    $Split = Wait-Moc { $P = Doc-Kho 'p4'; if ($P.items -eq 2) { $P } } 20 'Ctrl+B chưa tách đoạn.'
    Keys '^z'
    $Undo = Wait-Moc { $P = Doc-Kho 'p4'; if ($P.head -eq 0 -and $P.items -eq 1) { $P } } 20 'Ctrl+Z chưa hoàn tác.'
    Keys '^y'
    $Redo = Wait-Moc { $P = Doc-Kho 'p4'; if ($P.head -eq $Split.head -and $P.items -eq 2) { $P } } 20 'Ctrl+Y chưa làm lại.'
    Click-Ui (Ui 'Tự động')
    $null = Ui 'Xuất 3 video đã chọn'
    $null = Ui 'Xem Mẫu hướng dẫn'
    if ((Search-Text) -ne 'Mau' -or (Find-Ui 'Xem Mẫu mất tệp nguồn')) { throw 'Danh sách mất từ tìm hoặc bộ lọc.' }
    $CurrentY = (Ui 'Xem Mẫu hướng dẫn').Current.BoundingRectangle.Y
    if ([Math]::Abs($CurrentY - $RowY) -gt 2) { throw "Danh sách đổi vị trí cuộn: $RowY → $CurrentY." }
    foreach ($Name in $SelectedNames) {
        if ((Toggle-State "Chọn $Name") -ne 'On') { throw "Mất lựa chọn $Name." }
    }
    $SelectionShot = Anh 'lua-chon-sau-sua-tay'
    (Ui 'Xuất 3 video đã chọn').SetFocus()
    Keys '{ENTER}'
    Click-Ui (Ui 'Video trong lô')
    foreach ($Name in $SelectedNames) { $null = Ui $Name }
    Click-Ui (Ui '720p')
    $Batch = [Diagnostics.Stopwatch]::StartNew()
    Click-Ui (Ui 'Xuất 3 tệp')
    $null = Wait-Moc {
        $All = @(Doc-Kho)
        $Exports = @($All | Where-Object { $_.job.kind -eq 'xuat' })
        if (@($Exports | Where-Object {$_.job.state -in 'loi','bi-ngat','da-huy'}).Count) { throw 'Có video xuất lỗi.' }
        if (@($Exports | Where-Object {$_.job.state -eq 'xong'}).Count -eq 3) { $true }
    } 150 'Quá giờ chờ 3 MP4.'
    $Batch.Stop()
    @{
        viewports=@($V1100,$V1440); search='Mau'; filter='Sẵn sàng xuất'; restoredSelection=$SelectedNames.Count;
        restoredScrollPx=($RowY0 - $RowY); screenshotAfter=$SelectionShot; batchMs=$Batch.ElapsedMilliseconds;
        musicWaitMs=$MusicWait.ElapsedMilliseconds;
        shortcuts=@('Ctrl+B','Ctrl+Z','Ctrl+Y'); revisions=@{split=$Split; undo=$Undo; redo=$Redo};
        webview2=([Diagnostics.FileVersionInfo]::GetVersionInfo($Browser.ExecutablePath)).ProductVersion
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $Proof 'giao-dien.json') -Encoding utf8
    & $Node $ScriptPath minh-chung $Install $Qa
    if ($LASTEXITCODE -ne 0) { throw 'Các tệp xuất chưa đạt kiểm tra.' }
} catch {
    if ($App -and !$App.HasExited) { $null = Anh 'loi' }
    throw
} finally {
    if ($App -and !$App.HasExited) { Stop-Process -Id $App.Id }
    Remove-NetFirewallRule -Name $Firewall -ErrorAction SilentlyContinue
}
