# Deploys aws/index.mjs to the binderbooks-sync Lambda (us-west-2).
#   .\deploy.ps1                     # update code only
#   .\deploy.ps1 -PptKey "ppt_..."   # also set the pokemonpricetracker.com
#                                    # API key the /graded route needs
param([string]$PptKey)
$ErrorActionPreference = "Stop"
$fn = "binderbooks-sync"; $region = "us-west-2"
Set-Location $PSScriptRoot

Compress-Archive -Force -Path index.mjs -DestinationPath lambda.zip
aws lambda update-function-code --function-name $fn --region $region --zip-file fileb://lambda.zip | Out-Null
Remove-Item lambda.zip
Write-Host "code deployed"

if ($PptKey) {
  # update-function-configuration replaces the whole environment, so merge
  # the new key into whatever is already there (TABLE_NAME, SYNC_TOKEN)
  $cfg = aws lambda get-function-configuration --function-name $fn --region $region | ConvertFrom-Json
  $vars = @{}
  if ($cfg.Environment -and $cfg.Environment.Variables) {
    $cfg.Environment.Variables.PSObject.Properties | ForEach-Object { $vars[$_.Name] = $_.Value }
  }
  $vars["PPT_KEY"] = $PptKey
  $envFile = Join-Path $PSScriptRoot "env.json"
  @{ Variables = $vars } | ConvertTo-Json -Compress | Out-File -Encoding ascii $envFile
  aws lambda wait function-updated --function-name $fn --region $region
  aws lambda update-function-configuration --function-name $fn --region $region --environment file://env.json | Out-Null
  Remove-Item $envFile
  Write-Host "PPT_KEY set"
}
