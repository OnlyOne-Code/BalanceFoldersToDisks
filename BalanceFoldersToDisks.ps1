# === Конфигурация ===
$folders = @(
    "J:\Folder01", "J:\Folder02", "J:\Folder03", "J:\Folder04", "J:\Folder05",
    "J:\Folder06", "J:\Folder07", "J:\Folder08", "J:\Folder09", "J:\Folder10",
    "I:\Folder11", "I:\Folder12", "I:\Folder13", "F:\", "G:\", "H:\"
)

# Папки, которые будут расти — добавим буфер
$growingFolders = @(
    "J:\Folder01",
    "I:\Folder11",
    "J:\Folder07",
    "J:\Folder08"
)
$bufferSizeGB = 100  # Буфер для растущих папок

$diskCount = 5
$diskSize = 4000
$maxOptRounds = 5

# === 1. Сбор реальных размеров ===
Write-Host "ВЫЧИСЛЕНИЕ РЕАЛЬНЫХ РАЗМЕРОВ..." -ForegroundColor Yellow
Write-Host "=================================" -ForegroundColor Yellow

$folderData = @()
$totalReal = 0

foreach ($folder in $folders) {
    if (Test-Path $folder) {
        $sizeBytes = (Get-ChildItem $folder -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        $sizeGB = if ($null -eq $sizeBytes) { 0 } else { [math]::Round($sizeBytes / 1GB, 1) }
        $folderData += [PSCustomObject]@{
            Path = $folder
            RealSize = $sizeGB
        }
        $totalReal += $sizeGB
        Write-Host "✓ $folder - $sizeGB GB" -ForegroundColor Green
    } else {
        Write-Host "✗ $folder - НЕ НАЙДЕН" -ForegroundColor Red
    }
}

# === 2. Добавление буфера роста ===
$workingData = $folderData | ForEach-Object {
    $buffer = if ($growingFolders -contains $_.Path) { $bufferSizeGB } else { 0 }
    [PSCustomObject]@{
        Path          = $_.Path
        RealSize      = $_.RealSize
        SizeWithBuffer = $_.RealSize + $buffer
    }
}

$totalWithBuffer = ($workingData | Measure-Object -Property SizeWithBuffer -Sum).Sum
Write-Host "---------------------------------" -ForegroundColor Yellow
Write-Host "ОБЩИЙ РЕАЛЬНЫЙ ОБЪЁМ: $totalReal GB" -ForegroundColor Cyan
Write-Host "ОБЪЁМ С БУФЕРОМ (+$bufferSizeGB ГБ на растущие): $totalWithBuffer GB" -ForegroundColor Magenta
Write-Host "СРЕДНИЙ С БУФЕРОМ: $([math]::Round($totalWithBuffer / $diskCount, 1)) GB/диск" -ForegroundColor Cyan
Write-Host "=================================" -ForegroundColor Yellow

# === 3. Распределение по дискам (с учётом буфера) ===
Write-Host "`nРАСПРЕДЕЛЕНИЕ ПО ДИСКАМ (с буфером роста)..." -ForegroundColor Yellow

$sortedFolders = $workingData | Sort-Object SizeWithBuffer -Descending
$disks = @()
for ($i = 0; $i -lt $diskCount; $i++) {
    $disks += [PSCustomObject]@{
        UsedBuffered = 0
        Folders      = @()
    }
}

foreach ($folder in $sortedFolders) {
    $bestDisk = -1
    $maxFreeSpace = -1

    for ($i = 0; $i -lt $diskCount; $i++) {
        $free = $diskSize - $disks[$i].UsedBuffered
        if ($free -ge $folder.SizeWithBuffer -and $free -gt $maxFreeSpace) {
            $maxFreeSpace = $free
            $bestDisk = $i
        }
    }

    if ($bestDisk -ge 0) {
        $disks[$bestDisk].UsedBuffered += $folder.SizeWithBuffer
        $disks[$bestDisk].Folders += $folder
    } else {
        Write-Host "ОШИБКА: не удалось разместить $($folder.Path) (буфер: $($folder.SizeWithBuffer) GB)" -ForegroundColor Red
    }
}

# === 4. Пост-оптимизация (только мелкие, без буфера) ===
Write-Host "`nПОСТ-ОПТИМИЗАЦИЯ (осторожно)..." -ForegroundColor Yellow

for ($round = 1; $round -le $maxOptRounds; $round++) {
    $used = $disks | ForEach-Object { $_.UsedBuffered }
    $maxIdx = 0..($diskCount-1) | Sort-Object { $used[$_] } -Descending | Select-Object -First 1
    $minIdx = 0..($diskCount-1) | Sort-Object { $used[$_] } | Select-Object -First 1

    $diffBefore = $used[$maxIdx] - $used[$minIdx]
    if ($diffBefore -le 10) { break }

    $improved = $false
    # Перемещаем только мелкие папки БЕЗ буфера (те, у кого RealSize < 100 и нет буфера)
    $smallCandidates = $disks[$maxIdx].Folders | Where-Object {
        $_.RealSize -lt 100 -and ($growingFolders -notcontains $_.Path)
    } | Sort-Object RealSize

    foreach ($folder in $smallCandidates) {
        $newMaxUsed = $disks[$maxIdx].UsedBuffered - $folder.SizeWithBuffer
        $newMinUsed = $disks[$minIdx].UsedBuffered + $folder.SizeWithBuffer

        if ($newMinUsed -le $diskSize) {
            $diffAfter = $newMaxUsed - $newMinUsed
            if ($diffAfter -lt $diffBefore) {
                # Перемещаем
                $disks[$maxIdx].UsedBuffered = $newMaxUsed
                $disks[$minIdx].UsedBuffered = $newMinUsed
                $disks[$maxIdx].Folders = $disks[$maxIdx].Folders | Where-Object { $_.Path -ne $folder.Path }
                $disks[$minIdx].Folders += $folder
                $improved = $true
                break
            }
        }
    }

    if (-not $improved) { break }
}

# === 5. Вывод результата ===
Write-Host "`nФИНАЛЬНОЕ РАСПРЕДЕЛЕНИЕ:" -ForegroundColor Green
Write-Host "========================" -ForegroundColor Green

for ($i = 0; $i -lt $diskCount; $i++) {
    $disk = $disks[$i]
    $free = $diskSize - $disk.UsedBuffered
    $currentReal = ($disk.Folders | Measure-Object -Property RealSize -Sum).Sum
    Write-Host "`nДИСК $($i+1): $($disk.UsedBuffered)/$diskSize GB (прогноз)" -ForegroundColor White
    Write-Host "    (сейчас: $currentReal GB)" -ForegroundColor DarkGray
    foreach ($f in $disk.Folders) {
        $mark = if ($growingFolders -contains $f.Path) { " [+буфер]" } else { "" }
        Write-Host "  $($f.RealSize) GB - $($f.Path)$mark" -ForegroundColor Gray
    }
}

$usedFinal = $disks | ForEach-Object { $_.UsedBuffered }
$range = ($usedFinal | Measure-Object -Maximum).Maximum - ($usedFinal | Measure-Object -Minimum).Minimum
$rangeRounded = [math]::Round($range, 1)
Write-Host "`nБАЛАНСИРОВКА (с буфером): разброс $rangeRounded GB" -ForegroundColor Cyan
Write-Host "`n========================" -ForegroundColor Green

pause
