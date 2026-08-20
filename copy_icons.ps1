# PowerShell Script to update QGap icon to all required locations and sizes
# Run this script whenever icon_logo_qgap.png is updated

$sourceLogo = "assets\images\icon_logo_qgap.png"
$basePath = "android\app\src\main\res"

Write-Host "Updating QGap icon in all Android locations..."
Write-Host "Source: $sourceLogo"

# Check if source file exists
if (-not (Test-Path $sourceLogo)) {
    Write-Error "Source file not found: $sourceLogo"
    exit 1
}

# Standard launcher icons for all densities
$iconPaths = @{
    "mipmap-mdpi\ic_launcher.png" = "48x48 (mdpi)"
    "mipmap-hdpi\ic_launcher.png" = "72x72 (hdpi)"  
    "mipmap-xhdpi\ic_launcher.png" = "96x96 (xhdpi)"
    "mipmap-xxhdpi\ic_launcher.png" = "144x144 (xxhdpi)"
    "mipmap-xxxhdpi\ic_launcher.png" = "192x192 (xxxhdpi)"
}

# Additional launcher icons (flutter_launcher_icons generated)
$additionalIcons = @{
    "mipmap-mdpi\launcher_icon.png" = "48x48 (mdpi) - additional"
    "mipmap-hdpi\launcher_icon.png" = "72x72 (hdpi) - additional"
    "mipmap-xhdpi\launcher_icon.png" = "96x96 (xhdpi) - additional"
    "mipmap-xxhdpi\launcher_icon.png" = "144x144 (xxhdpi) - additional"
    "mipmap-xxxhdpi\launcher_icon.png" = "192x192 (xxxhdpi) - additional"
}

# Adaptive icon foreground
$adaptiveIcon = @{
    "drawable\ic_launcher_foreground.png" = "Adaptive icon foreground"
}

Write-Host "`n=== Updating Standard Launcher Icons ==="
foreach ($iconPath in $iconPaths.Keys) {
    $targetPath = Join-Path $basePath $iconPath
    $description = $iconPaths[$iconPath]
    
    Write-Host "Copying to $iconPath ($description)"
    Copy-Item $sourceLogo $targetPath -Force
}

Write-Host "`n=== Updating Additional Launcher Icons ==="
foreach ($iconPath in $additionalIcons.Keys) {
    $targetPath = Join-Path $basePath $iconPath
    $description = $additionalIcons[$iconPath]
    
    if (Test-Path $targetPath) {
        Write-Host "Copying to $iconPath ($description)"
        Copy-Item $sourceLogo $targetPath -Force
    } else {
        Write-Host "Skipping $iconPath (file doesn't exist)"
    }
}

Write-Host "`n=== Updating Adaptive Icon ==="
foreach ($iconPath in $adaptiveIcon.Keys) {
    $targetPath = Join-Path $basePath $iconPath
    $description = $adaptiveIcon[$iconPath]
    
    Write-Host "Copying to $iconPath ($description)"
    Copy-Item $sourceLogo $targetPath -Force
}

Write-Host "`n=== Icon Update Completed! ==="
Write-Host "All QGap icons have been updated successfully."
Write-Host "Run 'flutter clean' and rebuild your app to see the changes."
