#!/usr/bin/env bash
# Usage: ssm-run.sh <instance-id> <command>
# Runs a shell command on an EC2 instance through SSM Run Command, waits for it, prints its output,
# and exits non-zero if it did not succeed. Used by the GitHub Actions deploy workflow.
set -euo pipefail

INSTANCE_ID="${1:?instance id required}"
COMMAND="${2:?command required}"

CMD_ID=$(aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --comment "GitHub deploy ${GITHUB_SHA:-manual}" \
  --parameters "$(jq -n --arg c "$COMMAND" '{commands: [$c], executionTimeout: ["900"]}')" \
  --query Command.CommandId --output text)
echo "SSM command $CMD_ID sent to $INSTANCE_ID"

STATUS=Pending
for _ in $(seq 1 180); do
  STATUS=$(aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
    --query Status --output text 2>/dev/null || echo Pending)
  case "$STATUS" in Success | Failed | Cancelled | TimedOut) break ;; esac
  sleep 5
done

echo "--- stdout ---"
aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
  --query StandardOutputContent --output text || true
echo "--- stderr ---"
aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
  --query StandardErrorContent --output text || true

echo "Final status: $STATUS"
[ "$STATUS" = "Success" ]
