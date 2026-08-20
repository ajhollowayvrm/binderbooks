#!/usr/bin/env bash
# Deploys aws/index.mjs to the binderbooks-sync Lambda (us-west-2).
#   ./deploy.sh                        # update code only
#   ./deploy.sh --ppt-key "ppt_..."    # also set the pokemonpricetracker.com key
#                                      # every card-data route needs
#   ./deploy.sh --anthropic-key "sk-ant-..."  # also set the Anthropic key the
#                                             # /identify card scanner needs
# Both switches can be given at once; each merges into the existing environment.
#
# The macOS/Linux twin of deploy.ps1. It exists because deploy.ps1 only runs on
# Windows, and a fix that cannot be deployed from the machine it was written on
# is a fix that silently stays unshipped — which is exactly what happened to the
# "stop comping the wrong card" change.
set -euo pipefail

fn="binderbooks-sync"; region="us-west-2"
cd "$(dirname "$0")"

ppt_key=""; anthropic_key=""
while [ $# -gt 0 ]; do
  case "$1" in
    --ppt-key)       ppt_key="$2"; shift 2 ;;
    --anthropic-key) anthropic_key="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

zip -q -FS -j lambda.zip index.mjs
trap 'rm -f lambda.zip env.json' EXIT
aws lambda update-function-code --function-name "$fn" --region "$region" \
  --zip-file fileb://lambda.zip >/dev/null
echo "code deployed"

# update-function-configuration replaces the whole environment, so read what is
# already there (TABLE_NAME, SYNC_TOKEN, and any keys set on an earlier run) and
# merge into it — setting one key never drops another.
if [ -n "$ppt_key" ] || [ -n "$anthropic_key" ]; then
  aws lambda wait function-updated --function-name "$fn" --region "$region"
  PPT="$ppt_key" ANTHRO="$anthropic_key" \
    aws lambda get-function-configuration --function-name "$fn" --region "$region" \
    | python3 -c '
import json, os, sys
vars = json.load(sys.stdin).get("Environment", {}).get("Variables", {})
if os.environ.get("PPT"):    vars["PPT_KEY"] = os.environ["PPT"]
if os.environ.get("ANTHRO"): vars["ANTHROPIC_API_KEY"] = os.environ["ANTHRO"]
json.dump({"Variables": vars}, open("env.json", "w"))
print(" ".join(k for k in ("PPT_KEY" if os.environ.get("PPT") else "",
                           "ANTHROPIC_API_KEY" if os.environ.get("ANTHRO") else "") if k))
'
  aws lambda update-function-configuration --function-name "$fn" --region "$region" \
    --environment file://env.json >/dev/null
  echo "env set"
fi
