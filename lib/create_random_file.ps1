$path = "D:\Daten\VSC\zufallsdatei\nd_mm.qgap"
$size = 5MB

if (!(Test-Path (Split-Path $path))) {
    Write-Host "Ordner existiert nicht: $(Split-Path $path)"
    exit
}

try {
    $bytes = New-Object byte[] $size
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    [System.IO.File]::WriteAllBytes($path, $bytes)
    Write-Host "Datei '$path' mit $size Zufallsdaten wurde erzeugt."
} catch {
    Write-Host "Fehler: $_"
}