param(
    [Parameter(Mandatory=$true)][string]$ToolRoot,
    [Parameter(Mandatory=$true)][string]$SigningDirectory
)
# ToolRoot contains Android build tools, android.jar and the JDK. Signing files stay outside this repository.
$ErrorActionPreference = 'Stop'

$javaBin = (Get-ChildItem "$toolRoot\jdk" -Recurse -Filter javac.exe | Select-Object -First 1).Directory.FullName
$androidJar = (Get-ChildItem "$toolRoot\platform" -Recurse -Filter android.jar | Select-Object -First 1).FullName
$tools = (Get-ChildItem "$toolRoot\tools" -Recurse -Filter aapt.exe | Select-Object -First 1).Directory.FullName
$source = Join-Path $PSScriptRoot 'android'
$out = Join-Path $PSScriptRoot 'build'
New-Item -ItemType Directory -Force "$PSScriptRoot\lib" | Out-Null
$qr = Join-Path $PSScriptRoot 'lib\zxing-core.jar'
if (!(Test-Path $qr)) {
    Invoke-WebRequest 'https://repo.maven.apache.org/maven2/com/google/zxing/core/3.5.3/core-3.5.3.jar' -OutFile $qr
}
if ((Get-FileHash $qr -Algorithm SHA256).Hash -ne '8D8064C1636FDAEF7189DD9055C7D59950A8940A12F2293956446EC3C109FD82') {
    throw 'QR dependency checksum mismatch'
}
New-Item -ItemType Directory -Force "$out\classes", "$out\generated", "$out\dex" | Out-Null
& "$tools\aapt.exe" package -f -M "$source\AndroidManifest.xml" -S "$source\res" -I $androidJar -F "$out\resources.apk" -J "$out\generated"
if ($LASTEXITCODE) { throw 'Resource compilation failed' }
$files = Get-ChildItem "$source\src", "$out\generated" -Recurse -Filter *.java | ForEach-Object FullName
$qr = Join-Path $PSScriptRoot "lib\zxing-core.jar"
& "$javaBin\javac.exe" -encoding UTF-8 -source 8 -target 8 -classpath "$androidJar;$qr" -d "$out\classes" $files
if ($LASTEXITCODE) { throw 'Java compilation failed' }
& "$javaBin\jar.exe" cf "$out\classes.jar" -C "$out\classes" .
& "$javaBin\java.exe" -cp "$tools\lib\d8.jar" com.android.tools.r8.D8 --lib $androidJar --min-api 23 --output "$out\dex" "$out\classes.jar" $qr
if ($LASTEXITCODE) { throw 'DEX compilation failed' }
Copy-Item "$out\resources.apk" "$out\unaligned.apk" -Force
Push-Location "$out\dex"
try { & "$tools\aapt.exe" add "$out\unaligned.apk" classes.dex } finally { Pop-Location }
& "$tools\zipalign.exe" -f -p 4 "$out\unaligned.apk" "$out\Orbit-Phone-v35-unsigned.apk"
if ($LASTEXITCODE) { throw 'APK alignment failed' }
$signing = $SigningDirectory
& "$javaBin\java.exe" -jar "$tools\lib\apksigner.jar" sign --ks "$signing\jarvis-alerts-release.p12" --ks-key-alias jarvis-alerts-release --ks-pass "file:$signing\password.txt" --out "$out\Orbit-Phone-v35.apk" "$out\Orbit-Phone-v35-unsigned.apk"
if ($LASTEXITCODE) { throw 'Signing failed' }
& "$javaBin\java.exe" -jar "$tools\lib\apksigner.jar" verify --verbose --print-certs "$out\Orbit-Phone-v35.apk"
if ($LASTEXITCODE) { throw 'Signature verification failed' }
& "$tools\aapt.exe" dump badging "$out\Orbit-Phone-v35.apk" | Select-Object -First 5
