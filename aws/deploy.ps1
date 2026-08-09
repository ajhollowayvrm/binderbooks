# Deploys aws/index.mjs to the binderbooks-sync Lambda (us-west-2).
#   .\deploy.ps1                             # update code only
#   .\deploy.ps1 -PptKey "ppt_..."           # also set the pokemonpricetracker.com
#                                            # API key the /graded route needs
#   .\deploy.ps1 -AnthropicKey "sk-ant-..."  # also set the Anthropic API key the
#                                            # /identify card scanner needs
# Both switches can be given at once; each merges into the existing environment.
param([string]$PptKey, [string]$AnthropicKey)
$ErrorActionPreference = "Stop"
$fn = "binderbooks-sync"; $region = "us-west-2"
Set-Location $PSScriptRoot

Compress-Archive -Force -Path index.mjs -DestinationPath lambda.zip
aws lambda update-function-code --function-name $fn --region $region --zip-file fileb://lambda.zip | Out-Null
Remove-Item lambda.zip
Write-Host "code deployed"

# update-function-configuration replaces the whole environment, so read what's
# already there (TABLE_NAME, SYNC_TOKEN, and any keys set on an earlier run)
# and merge into it — setting one key never drops another
function Set-LambdaEnv([hashtable]$new) {
  $cfg = aws lambda get-function-configuration --function-name $fn --region $region | ConvertFrom-Json
  $vars = @{}
  if ($cfg.Environment -and $cfg.Environment.Variables) {
    $cfg.Environment.Variables.PSObject.Properties | ForEach-Object { $vars[$_.Name] = $_.Value }
  }
  foreach ($k in $new.Keys) { $vars[$k] = $new[$k] }
  $envFile = Join-Path $PSScriptRoot "env.json"
  @{ Variables = $vars } | ConvertTo-Json -Compress | Out-File -Encoding ascii $envFile
  aws lambda wait function-updated --function-name $fn --region $region
  aws lambda update-function-configuration --function-name $fn --region $region --environment file://env.json | Out-Null
  Remove-Item $envFile
  Write-Host ("env set: " + ($new.Keys -join ", "))
}

$newVars = @{}
if ($PptKey)       { $newVars["PPT_KEY"] = $PptKey }
if ($AnthropicKey) { $newVars["ANTHROPIC_API_KEY"] = $AnthropicKey }
if ($newVars.Count) { Set-LambdaEnv $newVars }
