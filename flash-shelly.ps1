$ErrorActionPreference = "Stop"

$DiskNumber = 1
$TargetSerial = "SN253408929355"
$Image = Join-Path $PSScriptRoot "shellyforever.img"

Write-Host ""
Write-Host "=== ShellyForever SSD Flasher ===" -ForegroundColor Cyan
Write-Host ""

# Check image
if (-not (Test-Path $Image)) {
    Write-Host "ERROR: shellyforever.img not found." -ForegroundColor Red
    exit 1
}

$imageSize = (Get-Item $Image).Length

# Check Windows disk
$disk = Get-Disk -Number $DiskNumber

Write-Host "Image: $Image"
Write-Host "Image size: $imageSize bytes"
Write-Host ""

Write-Host "Target disk:"
Write-Host "  Disk   : $($disk.Number)"
Write-Host "  Model  : $($disk.FriendlyName)"
Write-Host "  Serial : $($disk.SerialNumber)"
Write-Host "  Size   : $([math]::Round($disk.Size / 1GB, 2)) GB"
Write-Host "  Bus    : $($disk.BusType)"
Write-Host ""

if ($disk.SerialNumber.Trim() -ne $TargetSerial) {
    Write-Host "ERROR: WRONG DISK SERIAL!" -ForegroundColor Red
    exit 1
}

if ($disk.IsSystem -or $disk.IsBoot) {
    Write-Host "ERROR: Disk is a system/boot disk!" -ForegroundColor Red
    exit 1
}

Write-Host "TARGET VERIFIED." -ForegroundColor Green
Write-Host ""

Write-Host "WARNING: DISK $DiskNumber WILL BE OVERWRITTEN." -ForegroundColor Yellow
$confirm = Read-Host "Type YES to continue"

if ($confirm -cne "YES") {
    Write-Host "Cancelled."
    exit 0
}

# Mount
Write-Host ""
Write-Host "Mounting physical disk into WSL..." -ForegroundColor Cyan

wsl --shutdown
wsl --mount "\\.\PHYSICALDRIVE$DiskNumber" --bare

if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Could not mount disk." -ForegroundColor Red
    exit 1
}

Write-Host "Disk mounted." -ForegroundColor Green
Write-Host ""

# Get Linux device using lsblk JSON
$lsblk = wsl -d Ubuntu -- lsblk -J -o NAME,SIZE,MODEL,SERIAL,TYPE

if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: lsblk failed." -ForegroundColor Red
    wsl --shutdown
    exit 1
}

$data = $lsblk | ConvertFrom-Json

$target = $data.blockdevices |
    Where-Object {
        $_.serial -and
        $_.serial.Trim() -eq $TargetSerial -and
        $_.type -eq "disk"
    }

if (-not $target) {
    Write-Host "ERROR: Target SSD was NOT found in WSL." -ForegroundColor Red
    Write-Host ""
    Write-Host $lsblk
    wsl --shutdown
    exit 1
}

$device = "/dev/$($target.name)"

Write-Host "TARGET FOUND IN WSL:" -ForegroundColor Green
Write-Host "  Device : $device"
Write-Host "  Size   : $($target.size)"
Write-Host "  Model  : $($target.model)"
Write-Host "  Serial : $($target.serial)"
Write-Host ""

$wslImage = "/mnt/c/Users/RICK/Downloads/ShellyForever/shellyforever.img"

Write-Host "Writing image to $device..." -ForegroundColor Cyan
Write-Host ""

wsl -d Ubuntu -- sudo dd "if=$wslImage" "of=$device" bs=4M status=progress conv=fsync

if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "ERROR: dd FAILED." -ForegroundColor Red
    wsl --shutdown
    exit 1
}

Write-Host ""
Write-Host "Flushing writes..." -ForegroundColor Cyan

wsl -d Ubuntu -- sync

Write-Host "Shutting down WSL..." -ForegroundColor Cyan
wsl --shutdown

Write-Host "Detaching disk..." -ForegroundColor Cyan
wsl --unmount "\\.\PHYSICALDRIVE$DiskNumber" 2>$null

Write-Host ""
Write-Host "====================================" -ForegroundColor Green
Write-Host " ShellyForever flash completed!" -ForegroundColor Green
Write-Host "====================================" -ForegroundColor Green