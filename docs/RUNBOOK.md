# Runbook

Commands for the operator, in PowerShell, run from the repository root. Apply and destroy
the two examples one at a time, never together. Region is us-east-1.

Rules for evidence:

- Raw command output is saved as `docs/evidence-raw/<name>.txt`. That folder is git-ignored
  and holds raw files only. Only `docs/evidence` is ever committed, and `git add` is never run
  on `docs/evidence-raw`.
- Never save `terraform apply` or `terraform plan` logs. Only the targeted outputs listed here.
- Section 5 builds the redacted copies in `docs/evidence` (same file names) from the raw files.

Setup. The virtual environment is git-ignored. The commands share variables (`$R`, `$py`,
`$iid`, ...), so in a new PowerShell window run this block again (venv creation is skipped if
`.venv` exists):

```powershell
New-Item -ItemType Directory -Force docs/evidence-raw, docs/evidence | Out-Null
$env:AWS_PAGER = ""
$R = "us-east-1"
if (-not (Test-Path .venv)) { python -m venv .venv }
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
$py = ".\.venv\Scripts\python.exe"
```

## 1. Example 1: ssm-private-ec2

### 1.1 Deploy

```powershell
cd examples/ssm-private-ec2
terraform init
terraform plan -out tfplan
terraform apply tfplan
$iid = terraform output -raw instance_id
$vpc = terraform output -raw vpc_id
$lg  = terraform output -raw flow_log_group_name
cd ../..
```

### 1.2 Verify

SSM registration. The agent can take a few minutes to register, so poll up to 15 times, 20
seconds apart, until `Online`. The last output is saved even if it never gets `Online`:

```powershell
$status = $null
for ($i = 1; $i -le 15; $i++) {
  $status = aws ssm describe-instance-information --region $R --filters "Key=InstanceIds,Values=$iid" `
    --query "InstanceInformationList[].{Instance:InstanceId,Ping:PingStatus,Platform:PlatformName}" --output json
  if (($status -join "`n") -match '"Ping": "Online"') { "online after $i attempt(s)"; break }
  if ($i -eq 15) { "stopped after 15 attempts, instance not Online" } else { Start-Sleep -Seconds 20 }
}
$status | Out-File -Encoding utf8 docs/evidence-raw/ex1-ssm-instance-info.txt
Get-Content docs/evidence-raw/ex1-ssm-instance-info.txt
```

No public IP, IMDSv2 required, encrypted gp3 root volume, no inbound rules:

```powershell
$out = @()
$out += aws ec2 describe-instances --region $R --instance-ids $iid `
  --query "Reservations[].Instances[].{Instance:InstanceId,Type:InstanceType,PublicIp:PublicIpAddress,HttpTokens:MetadataOptions.HttpTokens,Profile:IamInstanceProfile.Arn}" --output json
$out += aws ec2 describe-volumes --region $R --filters "Name=attachment.instance-id,Values=$iid" `
  --query "Volumes[].{Volume:VolumeId,Type:VolumeType,Encrypted:Encrypted}" --output json
$sg = aws ec2 describe-instances --region $R --instance-ids $iid --query "Reservations[0].Instances[0].SecurityGroups[0].GroupId" --output text
$out += aws ec2 describe-security-groups --region $R --group-ids $sg `
  --query "SecurityGroups[].{Group:GroupId,Inbound:IpPermissions,Outbound:IpPermissionsEgress[].{Proto:IpProtocol,From:FromPort,To:ToPort}}" --output json
$out | Out-File -Encoding utf8 docs/evidence-raw/ex1-instance-hardening.txt
Get-Content docs/evidence-raw/ex1-instance-hardening.txt
```

Expected: `PublicIp` is `null`, `HttpTokens` is `required`, `Encrypted` is `true`, `Type` is
`gp3`, `Inbound` is an empty list.

Run a command through SSM (this also generates outbound traffic through the NAT gateway for
the flow log check). The wait can fail on timeout or on a failed command; that does not stop
the runbook, and the next command records the real status:

```powershell
$cmd = aws ssm send-command --region $R --instance-ids $iid --document-name AWS-RunShellScript `
  --parameters "commands=curl -sS -o /dev/null https://aws.amazon.com && echo egress-ok" `
  --query "Command.CommandId" --output text
aws ssm wait command-executed --region $R --command-id $cmd --instance-id $iid
aws ssm get-command-invocation --region $R --command-id $cmd --instance-id $iid `
  --query "{Status:Status,Output:StandardOutputContent}" --output json |
  Out-File -Encoding utf8 docs/evidence-raw/ex1-ssm-command.txt
Get-Content docs/evidence-raw/ex1-ssm-command.txt
```

Flow log configuration:

```powershell
aws ec2 describe-flow-logs --region $R --filter "Name=resource-id,Values=$vpc" `
  --query "FlowLogs[].{Id:FlowLogId,Status:FlowLogStatus,Traffic:TrafficType,Destination:LogDestinationType,Group:LogGroupName,Delivery:DeliverLogsStatus}" `
  --output json | Out-File -Encoding utf8 docs/evidence-raw/ex1-flow-logs.txt
Get-Content docs/evidence-raw/ex1-flow-logs.txt
aws logs describe-log-groups --region $R --log-group-name-prefix $lg `
  --query "logGroups[].{Group:logGroupName,RetentionDays:retentionInDays}" --output json |
  Out-File -Encoding utf8 docs/evidence-raw/ex1-log-group-retention.txt
```

A flow log event, with a UTC timestamp on the first line. Delivery takes roughly 10 to 15
minutes after the traffic above; repeat until events appear:

```powershell
(Get-Date).ToUniversalTime().ToString("o") | Out-File -Encoding utf8 docs/evidence-raw/ex1-flow-log-event.txt
aws logs filter-log-events --region $R --log-group-name $lg --max-items 5 `
  --query "events[].message" --output json | Out-File -Append -Encoding utf8 docs/evidence-raw/ex1-flow-log-event.txt
Get-Content docs/evidence-raw/ex1-flow-log-event.txt
```

If the output after the timestamp is `[]`, wait a few minutes and repeat. Do not claim
delivery without events.

### 1.3 Tag audit (while the example is up)

The script scans the whole region, not only this example, so other instances and volumes in
the account can appear as findings. Save counts only (no ids) first:

```powershell
$ni = aws ec2 describe-instances --region $R --filters "Name=instance-state-name,Values=pending,running,stopping,stopped" `
  --query "length(Reservations[].Instances[])" --output text
$nv = aws ec2 describe-volumes --region $R --query "length(Volumes)" --output text
@("live instances in region: $ni", "volumes in region: $nv") | Out-File -Encoding utf8 docs/evidence-raw/ex1-region-resource-counts.txt
```

Then the two runs. The first is expected to exit 0 if all instances and volumes in the region
carry both tags. The second uses a tag key that does not exist (`CostCenter`) and must exit 1
with findings. If the first run reports findings, that is a real result; save it as is.

```powershell
$o = & $py scripts/find_untagged.py --required-tags Project,Environment --region $R 2>&1
$code = $LASTEXITCODE
(@($o) + "exit code: $code") | Out-File -Encoding utf8 docs/evidence-raw/ex1-find-untagged-ok.txt
$o = & $py scripts/find_untagged.py --required-tags Project,Environment,CostCenter --region $R 2>&1
$code = $LASTEXITCODE
(@($o) + "exit code: $code") | Out-File -Encoding utf8 docs/evidence-raw/ex1-find-untagged-finding.txt
Get-Content docs/evidence-raw/ex1-find-untagged-*.txt
```

### 1.4 Destroy and leftover checks

```powershell
cd examples/ssm-private-ec2
terraform destroy -auto-approve
cd ../..
(Get-Date).ToUniversalTime().ToString("o") | Out-File -Encoding utf8 docs/evidence-raw/ex1-leftovers-after-destroy.txt
.\scripts\check-leftovers.ps1 -Projects ssm-private-ec2 | Out-File -Append -Encoding utf8 docs/evidence-raw/ex1-leftovers-after-destroy.txt
Get-Content docs/evidence-raw/ex1-leftovers-after-destroy.txt
```

Post-destroy re-check of the flow log group after 3 minutes, each file starting with a UTC
timestamp:

```powershell
Start-Sleep -Seconds 180
(Get-Date).ToUniversalTime().ToString("o") | Out-File -Encoding utf8 docs/evidence-raw/ex1-log-group-after-3min.txt
aws logs describe-log-groups --region $R --log-group-name-prefix "/aws/vpc/ssm-private-ec2-" `
  --query "logGroups[].logGroupName" --output json | Out-File -Append -Encoding utf8 docs/evidence-raw/ex1-log-group-after-3min.txt
(Get-Date).ToUniversalTime().ToString("o") | Out-File -Encoding utf8 docs/evidence-raw/ex1-leftovers-after-3min.txt
.\scripts\check-leftovers.ps1 -Projects ssm-private-ec2 | Out-File -Append -Encoding utf8 docs/evidence-raw/ex1-leftovers-after-3min.txt
Get-Content docs/evidence-raw/ex1-log-group-after-3min.txt, docs/evidence-raw/ex1-leftovers-after-3min.txt
```

Expected: `[]` after the timestamp and `RESULT: nothing left`. A non-empty result means the log
group was recreated or something survived; save it as is. `RESULT: check incomplete` means an
AWS call failed; fix the cause and run it again.

## 2. Example 2: alb-asg

### 2.1 Deploy

Find your public IP (do not commit it) and create the local variables file:

```powershell
$myip = (Invoke-RestMethod https://checkip.amazonaws.com).Trim()
cd examples/alb-asg
"allowed_ingress_cidrs = [`"$myip/32`"]" | Out-File -Encoding ascii terraform.tfvars
terraform init
terraform plan -out tfplan
terraform apply tfplan
$alb = terraform output -raw alb_dns_name
$asg = terraform output -raw asg_name
$lg  = terraform output -raw flow_log_group_name
cd ../..
```

`terraform.tfvars` and `tfplan` are git-ignored. `apply` waits until two targets are healthy.

### 2.2 Verify

Group configuration:

```powershell
aws autoscaling describe-auto-scaling-groups --region $R --auto-scaling-group-names $asg `
  --query "AutoScalingGroups[].{Min:MinSize,Desired:DesiredCapacity,Max:MaxSize,Zones:AvailabilityZones,Instances:Instances[].{Id:InstanceId,Zone:AvailabilityZone,Health:HealthStatus,State:LifecycleState}}" `
  --output json | Out-File -Encoding utf8 docs/evidence-raw/ex2-asg-initial.txt
Get-Content docs/evidence-raw/ex2-asg-initial.txt
```

Ten requests to the ALB. If only one instance id appears, the output is saved as is and no
distribution is claimed:

```powershell
1..10 | ForEach-Object { curl.exe -sS --max-time 10 "http://$alb/" 2>&1 } | Out-File -Encoding utf8 docs/evidence-raw/ex2-curl-before.txt
Get-Content docs/evidence-raw/ex2-curl-before.txt
```

Terminate one instance, then wait for recovery (at most 30 checks, 20 seconds apart). The
group is recovered when two instances are healthy and in service and the terminated one is
gone from the group:

```powershell
$victim = aws autoscaling describe-auto-scaling-groups --region $R --auto-scaling-group-names $asg `
  --query "AutoScalingGroups[0].Instances[0].InstanceId" --output text
aws autoscaling terminate-instance-in-auto-scaling-group --region $R --instance-id $victim --no-should-decrement-desired-capacity
Start-Sleep -Seconds 30
for ($i = 1; $i -le 30; $i++) {
  $n = aws autoscaling describe-auto-scaling-groups --region $R --auto-scaling-group-names $asg `
    --query "length(AutoScalingGroups[0].Instances[?HealthStatus=='Healthy' && LifecycleState=='InService'])" --output text
  $gone = aws autoscaling describe-auto-scaling-groups --region $R --auto-scaling-group-names $asg `
    --query "length(AutoScalingGroups[0].Instances[?InstanceId=='$victim'])" --output text
  "check ${i}: healthy in service = $n, terminated instance still listed = $gone"
  if ($n -eq "2" -and $gone -eq "0") { "recovered after $i check(s)"; break }
  if ($i -eq 30) { "stopped waiting after 30 checks, group did not return to 2 healthy" } else { Start-Sleep -Seconds 20 }
}
```

Save the final state and the scaling activities (after the recovery loop), then repeat the
requests:

```powershell
aws autoscaling describe-auto-scaling-groups --region $R --auto-scaling-group-names $asg `
  --query "AutoScalingGroups[].{Desired:DesiredCapacity,Instances:Instances[].{Id:InstanceId,Zone:AvailabilityZone,Health:HealthStatus,State:LifecycleState}}" `
  --output json | Out-File -Encoding utf8 docs/evidence-raw/ex2-asg-recovered.txt
aws autoscaling describe-scaling-activities --region $R --auto-scaling-group-name $asg --max-items 10 `
  --query "Activities[].{Status:StatusCode,Description:Description,Cause:Cause}" --output json |
  Out-File -Encoding utf8 docs/evidence-raw/ex2-scaling-activities.txt
1..10 | ForEach-Object { curl.exe -sS --max-time 10 "http://$alb/" 2>&1 } | Out-File -Encoding utf8 docs/evidence-raw/ex2-curl-after.txt
Get-Content docs/evidence-raw/ex2-asg-recovered.txt, docs/evidence-raw/ex2-scaling-activities.txt, docs/evidence-raw/ex2-curl-after.txt
```

Instances have no public IP, and the flow log configuration:

```powershell
aws ec2 describe-instances --region $R --filters "Name=tag:Project,Values=alb-asg" "Name=instance-state-name,Values=running" `
  --query "Reservations[].Instances[].{Instance:InstanceId,PublicIp:PublicIpAddress,HttpTokens:MetadataOptions.HttpTokens}" `
  --output json | Out-File -Encoding utf8 docs/evidence-raw/ex2-instances.txt
$vpc = aws ec2 describe-vpcs --region $R --filters "Name=tag:Project,Values=alb-asg" --query "Vpcs[0].VpcId" --output text
aws ec2 describe-flow-logs --region $R --filter "Name=resource-id,Values=$vpc" `
  --query "FlowLogs[].{Id:FlowLogId,Status:FlowLogStatus,Traffic:TrafficType,Group:LogGroupName,Delivery:DeliverLogsStatus}" `
  --output json | Out-File -Encoding utf8 docs/evidence-raw/ex2-flow-logs.txt
Get-Content docs/evidence-raw/ex2-instances.txt, docs/evidence-raw/ex2-flow-logs.txt
```

Volumes and security groups:

```powershell
$out = @()
$out += aws ec2 describe-volumes --region $R --filters "Name=tag:Project,Values=alb-asg" `
  --query "Volumes[].{Volume:VolumeId,Type:VolumeType,Encrypted:Encrypted}" --output json
$out += aws ec2 describe-security-groups --region $R --filters "Name=group-name,Values=alb-asg-instance-sg,alb-asg-alb-sg" `
  --query "SecurityGroups[].{Name:GroupName,Inbound:IpPermissions[].{Proto:IpProtocol,From:FromPort,To:ToPort,Cidrs:IpRanges[].CidrIp,FromGroups:UserIdGroupPairs[].GroupId}}" --output json
$out | Out-File -Encoding utf8 docs/evidence-raw/ex2-instance-hardening.txt
Get-Content docs/evidence-raw/ex2-instance-hardening.txt
```

Expected: the volumes are `gp3` and encrypted; the instance security group admits port 80 only
from the load balancer security group; the load balancer security group admits port 80 only
from one `/32`.

### 2.3 Tag audit (while the example is up)

The script scans the whole region, not only this example. Save counts only (no ids) first:

```powershell
$ni = aws ec2 describe-instances --region $R --filters "Name=instance-state-name,Values=pending,running,stopping,stopped" `
  --query "length(Reservations[].Instances[])" --output text
$nv = aws ec2 describe-volumes --region $R --query "length(Volumes)" --output text
@("live instances in region: $ni", "volumes in region: $nv") | Out-File -Encoding utf8 docs/evidence-raw/ex2-region-resource-counts.txt
```

```powershell
$o = & $py scripts/find_untagged.py --required-tags Project,Environment --region $R 2>&1
$code = $LASTEXITCODE
(@($o) + "exit code: $code") | Out-File -Encoding utf8 docs/evidence-raw/ex2-find-untagged-ok.txt
$o = & $py scripts/find_untagged.py --required-tags Project,Environment,CostCenter --region $R 2>&1
$code = $LASTEXITCODE
(@($o) + "exit code: $code") | Out-File -Encoding utf8 docs/evidence-raw/ex2-find-untagged-finding.txt
Get-Content docs/evidence-raw/ex2-find-untagged-*.txt
```

### 2.4 Destroy and leftover checks

```powershell
cd examples/alb-asg
terraform destroy -auto-approve
cd ../..
(Get-Date).ToUniversalTime().ToString("o") | Out-File -Encoding utf8 docs/evidence-raw/ex2-leftovers-after-destroy.txt
.\scripts\check-leftovers.ps1 -Projects alb-asg | Out-File -Append -Encoding utf8 docs/evidence-raw/ex2-leftovers-after-destroy.txt
Start-Sleep -Seconds 180
(Get-Date).ToUniversalTime().ToString("o") | Out-File -Encoding utf8 docs/evidence-raw/ex2-log-group-after-3min.txt
aws logs describe-log-groups --region $R --log-group-name-prefix "/aws/vpc/alb-asg-" `
  --query "logGroups[].logGroupName" --output json | Out-File -Append -Encoding utf8 docs/evidence-raw/ex2-log-group-after-3min.txt
(Get-Date).ToUniversalTime().ToString("o") | Out-File -Encoding utf8 docs/evidence-raw/ex2-leftovers-after-3min.txt
.\scripts\check-leftovers.ps1 -Projects alb-asg | Out-File -Append -Encoding utf8 docs/evidence-raw/ex2-leftovers-after-3min.txt
Get-Content docs/evidence-raw/ex2-leftovers-after-destroy.txt, docs/evidence-raw/ex2-log-group-after-3min.txt, docs/evidence-raw/ex2-leftovers-after-3min.txt
```

## 3. Final leftover check for both projects

Run this last, after both examples are destroyed. It also serves as the later re-check of
example 1's log group; its timestamp on the first line shows how long after the destroy it ran.

```powershell
(Get-Date).ToUniversalTime().ToString("o") | Out-File -Encoding utf8 docs/evidence-raw/final-leftovers.txt
.\scripts\check-leftovers.ps1 | Out-File -Append -Encoding utf8 docs/evidence-raw/final-leftovers.txt
Get-Content docs/evidence-raw/final-leftovers.txt
```

## 4. If a step fails

Save the failing output too (for example `docs/evidence-raw/ex2-apply-error.txt`) and redact it.
If any step fails, still run `terraform destroy` for that example, then the leftover check.
Do not edit evidence by hand. A failed or empty check is a result, not something to hide.

## 5. Redaction

Raw files stay in `docs/evidence-raw` (git-ignored). The block below reads every file in
`docs/evidence-raw`, sorted by name, and writes the redacted copy to `docs/evidence` with the
same name. Run it after all raw files exist. It can be repeated at any time, because it always
rebuilds `docs/evidence` from `docs/evidence-raw`: files with the same name are overwritten and
nothing else in `docs/evidence` is deleted. Empty raw files are written as empty files, so a
missing result stays visible.

Order matters: the ALB hostname first, then resource ids, then account numbers, then local
user paths, then public IPv4 addresses. Private ranges (10., 172.16-31., 192.168.) and
0.0.0.0 are kept.

Each distinct id gets a stable pseudonym, the same in every file: the first distinct id of a
kind becomes `<kind>-REDACTED-1`, the next `-2`, and so on, with files processed in name
order. Instance profile ids (`AIPA...`) become `AIPA-REDACTED-N`. Numbering always starts at 1.

```powershell
$kinds = 'i','vol','vpc','subnet','sg','eni','eipalloc','nat','ami','lt','fl','igw','rtb','acl'
$map = @{}
$next = @{}
foreach ($k in $kinds + 'AIPA') { $next[$k] = 0 }
$files = Get-ChildItem docs/evidence-raw -File | Sort-Object Name

foreach ($f in $files) {
  $t = Get-Content $f.FullName -Raw
  if (-not $t) { $t = "" }
  $t = $t -replace '[A-Za-z0-9.-]+\.elb\.amazonaws\.com', 'alb-redacted.us-east-1.elb.amazonaws.com'
  foreach ($k in $kinds) {
    $kind = $k
    $t = [regex]::Replace($t, "\b$kind-[0-9a-f]{8,17}\b", [System.Text.RegularExpressions.MatchEvaluator]{
      param($m)
      if (-not $map.ContainsKey($m.Value)) { $next[$kind]++; $map[$m.Value] = "$kind-REDACTED-$($next[$kind])" }
      $map[$m.Value]
    })
  }
  $t = [regex]::Replace($t, 'AIPA[A-Z0-9]{12,}', [System.Text.RegularExpressions.MatchEvaluator]{
    param($m)
    if (-not $map.ContainsKey($m.Value)) { $next['AIPA']++; $map[$m.Value] = "AIPA-REDACTED-$($next['AIPA'])" }
    $map[$m.Value]
  })
  $t = $t -replace '(?<![0-9])[0-9]{12}(?![0-9])', '111111111111'
  $t = $t -replace '[A-Za-z]:\\Users\\[^\\\s"'']+', 'C:\Users\USER'
  $t = $t -replace '[A-Za-z]:\\\\Users\\\\[^\\\s"'']+', 'C:\\Users\\USER'
  $t = $t -replace '/home/[^/\s"'']+', '/home/USER'
  $t = $t -replace '(?<![0-9.])(?!(?:10\.|127\.|169\.254\.|192\.168\.|172\.(?:1[6-9]|2[0-9]|3[01])\.|0\.0\.0\.0(?![0-9])))(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9])', '203.0.113.1'
  Set-Content -Path (Join-Path "docs/evidence" $f.Name) -Value $t -NoNewline -Encoding utf8
}
```

Check that nothing is left. All checks run on `docs/evidence` only, print file names only
(never values), and all of them must print nothing:

```powershell
$idPattern = '\b(i|vol|vpc|subnet|sg|eni|eipalloc|nat|ami|lt|fl|igw|rtb|acl)-[0-9a-f]{8,17}\b'
Select-String -Path docs/evidence/* -Pattern $idPattern -List | ForEach-Object { $_.Path }
Select-String -Path docs/evidence/* -Pattern 'AIPA[A-Z0-9]{12,}' -List | ForEach-Object { $_.Path }
Select-String -Path docs/evidence/* -Pattern '(?<![0-9])[0-9]{12}(?![0-9])' -AllMatches |
  Where-Object { @($_.Matches | Where-Object { $_.Value -ne '111111111111' }).Count -gt 0 } |
  ForEach-Object { $_.Path } | Sort-Object -Unique
Select-String -Path docs/evidence/* -Pattern 'arn:aws:[a-z0-9-]*:[a-z0-9-]*:[0-9]{12}' -AllMatches |
  Where-Object { @($_.Matches | Where-Object { $_.Value -notmatch ':111111111111$' }).Count -gt 0 } |
  ForEach-Object { $_.Path } | Sort-Object -Unique
Select-String -Path docs/evidence/* -Pattern '(?<!alb-redacted)\.[a-z0-9-]+\.elb\.amazonaws\.com' -List | ForEach-Object { $_.Path }
Select-String -Path docs/evidence/* -Pattern '[A-Za-z]:\\Users\\(?!USER\b)|[A-Za-z]:\\\\Users\\\\(?!USER\b)|/home/(?!USER\b)' -List | ForEach-Object { $_.Path }
```

The substitute values (`111111111111`, `203.0.113.1`, `alb-redacted.us-east-1.elb.amazonaws.com`
and `<kind>-REDACTED-N`) are fictitious placeholders, not real resources.

Review the files in `docs/evidence` by eye once before committing. Only `docs/evidence` is
ever added to git.
