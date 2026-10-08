# ============================================================
# rk-refine.ps1 - hand the picture we already have back to the model and ask for
# a light pass over it. ASCII only (PS 5.1 decodes a BOM-less .ps1 as ANSI).
#
# WHY THIS EXISTS. Everything else in this folder can change a colour, a
# rectangle or a size. None of it can change a DRAWING - it cannot put folds in
# a dress or sharpen an eye, because those are more information than the file
# contains. The obvious answer, "generate it again", has been the wrong one all
# along: a fresh txt2img with one word changed moves the pose, the hands and the
# face, and whatever already matched stops matching.
#
# img2img is the case that was missing. The existing picture goes in as the
# STARTING POINT rather than as a description of one, so at a low denoise the
# composition survives and only the surface is redrawn. That is exactly "tweak
# it a little and let the model tidy up", which is what a hand pass needs to be
# worth doing.
#
#   -Denoise  0.20  a polish. Lines get cleaner, nothing moves.
#             0.35  the default. Surfaces and detail are redrawn, pose holds.
#             0.55  the outfit and hair can change shape. Identity usually holds.
#             0.75+ a different picture. Use txt2img instead and be honest about it.
#
# -Mask makes it INPAINT: only the white part of the mask is redrawn, the rest is
# returned untouched. That is how a face gets sharpened without risking the pose,
# and how a hand-drawn correction gets blended in instead of pasted on.
#
#   powershell -File rk-refine.ps1 -In art\belka.png -Out belka_refined
#   powershell -File rk-refine.ps1 -In art\belka.png -Mask face.png -Denoise 0.5 -Out face_fix
#
# It waits for the file and prints where it landed. Nothing is imported: look
# first, then run build-belka.ps1 against the one you kept.
# ============================================================

param(
  [Parameter(Mandatory)][string]$In,
  [string]$Mask = '',
  [double]$Denoise = 0.35,
  [string]$Out = 'rk_refine',
  [string]$Prompt = '',
  [string]$Negative = '',
  [int]$Seed = 0,
  [int]$Steps = 28,
  [double]$Cfg = 6.0,
  [int]$TimeoutSec = 300
)

$ErrorActionPreference = 'Stop'
$API  = 'http://127.0.0.1:8188'
$CKPT = 'waiIllustriousSDXL_v170.safetensors'
$OUTDIR = (Join-Path $env:USERPROFILE 'Pictures\AIart\_inbox')

# The identity, and only the identity. Everything that must not drift between
# the two views lives here; clothes and pose are deliberately absent, because
# they differ on purpose (see DECISIONS.md [R-066]).
$IDENTITY = 'masterpiece, best quality, amazing quality, 1girl, solo, ' +
            'white hair, green eyes, gradient eyes, eyelashes, eyeliner, blunt bangs, ' +
            'medium hair, sidelocks, cel shading'
$NEG_DEFAULT = 'bad quality, worst quality, blurry, watermark, signature, artist name, ' +
               'shiny hair, glossy, latex, wet, text, english text, multiple views, ' +
               'chibi, extra limbs, bad hands, 2girls, multiple girls, ' +
               'nsfw, nude, topless, cleavage, revealing clothes'

if ($Denoise -le 0 -or $Denoise -ge 1) { throw '-Denoise must be between 0 and 1 (0.2 polish, 0.35 default, 0.55 loose)' }
if ($Prompt   -eq '') { $Prompt = $IDENTITY }
if ($Negative -eq '') { $Negative = $NEG_DEFAULT }
if ($Seed -eq 0) { $Seed = Get-Random -Minimum 1 -Maximum 2147483000 }

function Send-RkUpload([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) { throw ('no such image: ' + $path) }
  $full = (Resolve-Path -LiteralPath $path).Path
  $name = [System.IO.Path]::GetFileName($full)
  # Multipart by hand. PS 5.1 has no -Form, and the alternative - letting
  # ComfyUI read the path directly - does not exist: LoadImage only ever looks
  # in its own input folder.
  $bound = [System.Guid]::NewGuid().ToString()
  $enc   = [System.Text.Encoding]::GetEncoding('iso-8859-1')
  $bytes = [System.IO.File]::ReadAllBytes($full)
  $body  = (
    "--$bound`r`n" +
    "Content-Disposition: form-data; name=`"image`"; filename=`"$name`"`r`n" +
    "Content-Type: image/png`r`n`r`n" +
    $enc.GetString($bytes) +
    "`r`n--$bound`r`n" +
    "Content-Disposition: form-data; name=`"overwrite`"`r`n`r`ntrue`r`n" +
    "--$bound--`r`n")
  $r = Invoke-RestMethod -Uri ($API + '/upload/image') -Method Post `
        -ContentType ('multipart/form-data; boundary=' + $bound) `
        -Body $enc.GetBytes($body)
  Write-Host ('  uploaded ' + $r.name + $(if ($r.subfolder) { ' (' + $r.subfolder + ')' } else { '' }))
  return $r.name
}

# ---- refuse the small picture ----------------------------------------------
# The sprite in art\ is 249x320 or less. SDXL was trained near 1024 and produces
# mush below about 640 - and the sprite has an alpha channel, which arrives as
# black. Tried it once on belka.png (249x320): the pose survived and everything
# else fell apart. The input is the ORIGINAL generation, every time; the small
# picture is an OUTPUT of the pipeline, not a place to re-enter it.
Add-Type -AssemblyName System.Drawing
$probe = [System.Drawing.Image]::FromFile((Resolve-Path -LiteralPath $In).Path)
$long  = [math]::Max($probe.Width, $probe.Height)
$w0 = $probe.Width; $h0 = $probe.Height
$probe.Dispose()
if ($long -lt 640) {
  throw ('this is ' + $w0 + 'x' + $h0 + ', too small to refine. Give it the ORIGINAL generation ' +
         '(Pictures\AIart\_inbox\rk_*.png, around 900x1200), not the sprite in art\. ' +
         'The sprite is what comes OUT of the pipeline; refining it and importing again ' +
         'loses a step every time.')
}

Write-Host ('refine: ' + (Split-Path -Leaf $In) + '  ' + $w0 + 'x' + $h0 + '  denoise=' + $Denoise +
            $(if ($Mask) { '  mask=' + (Split-Path -Leaf $Mask) } else { '  (whole picture)' }))
$imgName = Send-RkUpload $In
$mskName = $(if ($Mask) { Send-RkUpload $Mask } else { '' })

# ---- the graph -------------------------------------------------------------
# LoadImage -> VAEEncode gives the sampler a starting point instead of noise.
# With a mask, SetLatentNoiseMask restricts where it is allowed to change
# anything - the untouched latent is decoded back exactly as it went in.
$g = [ordered]@{
  '4'  = @{ class_type = 'CheckpointLoaderSimple'; inputs = @{ ckpt_name = $CKPT } }
  '10' = @{ class_type = 'LoadImage';              inputs = @{ image = $imgName } }
  '11' = @{ class_type = 'VAEEncode';              inputs = @{ pixels = @('10', 0); vae = @('4', 2) } }
  '6'  = @{ class_type = 'CLIPTextEncode';         inputs = @{ text = $Prompt;   clip = @('4', 1) } }
  '7'  = @{ class_type = 'CLIPTextEncode';         inputs = @{ text = $Negative; clip = @('4', 1) } }
  '8'  = @{ class_type = 'VAEDecode';              inputs = @{ samples = @('3', 0); vae = @('4', 2) } }
  '9'  = @{ class_type = 'SaveImage';              inputs = @{ filename_prefix = $Out; images = @('8', 0) } }
}
$latent = @('11', 0)
if ($mskName) {
  $g['12'] = @{ class_type = 'LoadImageMask'; inputs = @{ image = $mskName; channel = 'red' } }
  $g['13'] = @{ class_type = 'SetLatentNoiseMask'; inputs = @{ samples = @('11', 0); mask = @('12', 0) } }
  $latent = @('13', 0)
}
$g['3'] = @{ class_type = 'KSampler'; inputs = @{
    seed = $Seed; steps = $Steps; cfg = $Cfg; sampler_name = 'euler_ancestral';
    scheduler = 'normal'; denoise = $Denoise;
    model = @('4', 0); positive = @('6', 0); negative = @('7', 0); latent_image = $latent } }

$before = @(Get-ChildItem $OUTDIR -Filter ($Out + '*.png') -ErrorAction SilentlyContinue).Count
$body = @{ prompt = $g } | ConvertTo-Json -Depth 12 -Compress
$r = Invoke-RestMethod -Uri ($API + '/prompt') -Method Post -Body $body -ContentType 'application/json'
Write-Host ('  queued ' + $r.prompt_id + '  seed=' + $Seed)

# ---- wait for the file, not for the queue ----------------------------------
# The queue empties the moment the node finishes; the PNG lands a beat later.
# Watching the folder is the thing that is actually true.
$deadline = (Get-Date).AddSeconds($TimeoutSec)
while ((Get-Date) -lt $deadline) {
  Start-Sleep -Seconds 3
  $now = @(Get-ChildItem $OUTDIR -Filter ($Out + '*.png') -ErrorAction SilentlyContinue)
  if ($now.Count -gt $before) {
    $newest = $now | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    Write-Host ''
    Write-Host ('  -> ' + $newest.FullName)
    Write-Host '     nothing was imported. Look at it first; then point build-belka.ps1 at the one you keep.'
    exit 0
  }
}
throw ('no output after ' + $TimeoutSec + 's. Is ComfyUI still running? ' + $API + '/queue')
