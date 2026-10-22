# Read-only leftover check. Uses describe/list calls only and prints ids or names only.
# Usage: .\scripts\check-leftovers.ps1 [-Region us-east-1] [-Projects ssm-private-ec2,alb-asg]
# Exit codes: 0 = nothing left, 1 = leftovers found, 2 = check incomplete (an AWS call failed).
# A failed call is reported as ERROR and never as "none".
param(
    [string]$Region = "us-east-1",
    [string[]]$Projects = @("ssm-private-ec2", "alb-asg")
)

$found = 0
$errors = 0

function Show([string]$label, $out) {
    if ($LASTEXITCODE -ne 0) {
        $script:errors += 1
        Write-Output ("{0}: ERROR (aws call failed)" -f $label)
        return
    }
    $items = @($out -split "\s+" | Where-Object { $_ -and $_ -ne "None" })
    if ($items.Count -gt 0) {
        $script:found += $items.Count
        Write-Output ("{0}: {1}" -f $label, ($items -join " "))
    } else {
        Write-Output ("{0}: none" -f $label)
    }
}

if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
    Write-Output "RESULT: check incomplete, aws CLI not found"
    exit 2
}

foreach ($p in $Projects) {
    Write-Output "--- project $p"
    $tag = "Name=tag:Project,Values=$p"

    Show "vpcs" (aws ec2 describe-vpcs --region $Region --filters $tag --query "Vpcs[].VpcId" --output text)
    Show "nat-gateways" (aws ec2 describe-nat-gateways --region $Region --filter $tag --query "NatGateways[?State!='deleted'].NatGatewayId" --output text)
    Show "elastic-ips" (aws ec2 describe-addresses --region $Region --filters $tag --query "Addresses[].AllocationId" --output text)
    Show "load-balancers" (aws elbv2 describe-load-balancers --region $Region --query "LoadBalancers[?starts_with(LoadBalancerName, '$p-')].LoadBalancerName" --output text)
    Show "target-groups" (aws elbv2 describe-target-groups --region $Region --query "TargetGroups[?starts_with(TargetGroupName, '$p-')].TargetGroupName" --output text)
    Show "autoscaling-groups" (aws autoscaling describe-auto-scaling-groups --region $Region --query "AutoScalingGroups[?starts_with(AutoScalingGroupName, '$p-')].AutoScalingGroupName" --output text)
    Show "launch-templates" (aws ec2 describe-launch-templates --region $Region --query "LaunchTemplates[?starts_with(LaunchTemplateName, '$p-')].LaunchTemplateId" --output text)
    Show "instances" (aws ec2 describe-instances --region $Region --filters $tag "Name=instance-state-name,Values=pending,running,stopping,stopped" --query "Reservations[].Instances[].InstanceId" --output text)
    Show "volumes" (aws ec2 describe-volumes --region $Region --filters $tag --query "Volumes[].VolumeId" --output text)
    Show "log-groups" (aws logs describe-log-groups --region $Region --log-group-name-prefix "/aws/vpc/$p-" --query "logGroups[].logGroupName" --output text)
    Show "iam-roles" (aws iam list-roles --query "Roles[?starts_with(RoleName, '$p-')].RoleName" --output text)
    Show "instance-profiles" (aws iam list-instance-profiles --query "InstanceProfiles[?starts_with(InstanceProfileName, '$p-')].InstanceProfileName" --output text)
}

if ($found -gt 0) {
    Write-Output "RESULT: $found leftover item(s) found"
    exit 1
}
if ($errors -gt 0) {
    Write-Output "RESULT: check incomplete, $errors call(s) failed"
    exit 2
}
Write-Output "RESULT: nothing left"
exit 0
