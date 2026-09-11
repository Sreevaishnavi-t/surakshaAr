$ErrorActionPreference = "Stop"
$dir = $PSScriptRoot
$pptPath = Join-Path $dir "SurakshaAR-SIH2026-Idea.pptx"
$outDir  = Join-Path $dir "render"
if (Test-Path $outDir) { Remove-Item $outDir -Recurse -Force }
New-Item -ItemType Directory -Path $outDir | Out-Null

$app = New-Object -ComObject PowerPoint.Application
try {
    $deck = $app.Presentations.Open($pptPath, $true, $false, $false)
    # 1600x900 keeps text legible when inspected.
    $deck.SaveCopyAs((Join-Path $outDir "deck.pdf"), 32)
    for ($i = 1; $i -le $deck.Slides.Count; $i++) {
        $target = Join-Path $outDir ("slide-{0}.png" -f $i)
        $deck.Slides.Item($i).Export($target, "PNG", 1600, 900)
    }
    Write-Output ("exported {0} slides" -f $deck.Slides.Count)
    $deck.Close()
} finally {
    $app.Quit()
}
