#!/usr/bin/env python3
"""List EC2 instances and EBS volumes that miss required tag keys.

Read-only. Prints resource ids and missing tag keys only.
Exit code 1 when findings exist, 0 when none, 2 on an AWS error.
"""
import argparse
import sys

import boto3
from botocore.exceptions import BotoCoreError, ClientError

LIVE_STATES = ["pending", "running", "stopping", "stopped"]


def missing_keys(tags, required):
    present = {t["Key"] for t in tags or []}
    return [k for k in required if k not in present]


def find_untagged(ec2, required):
    """Return a list of (kind, resource_id, missing_keys)."""
    findings = []

    pages = ec2.get_paginator("describe_instances").paginate(
        Filters=[{"Name": "instance-state-name", "Values": LIVE_STATES}]
    )
    for page in pages:
        for reservation in page["Reservations"]:
            for inst in reservation["Instances"]:
                missing = missing_keys(inst.get("Tags"), required)
                if missing:
                    findings.append(("instance", inst["InstanceId"], missing))

    for page in ec2.get_paginator("describe_volumes").paginate():
        for vol in page["Volumes"]:
            missing = missing_keys(vol.get("Tags"), required)
            if missing:
                findings.append(("volume", vol["VolumeId"], missing))

    return findings


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--required-tags", default="Project,Environment",
                        help="comma separated tag keys (default: %(default)s)")
    parser.add_argument("--region", default="us-east-1")
    args = parser.parse_args(argv)

    required = [k.strip() for k in args.required_tags.split(",") if k.strip()]
    try:
        ec2 = boto3.client("ec2", region_name=args.region)
        findings = find_untagged(ec2, required)
    except (BotoCoreError, ClientError) as exc:
        print("AWS error: " + type(exc).__name__, file=sys.stderr)
        return 2

    for kind, rid, missing in findings:
        print("%s %s missing: %s" % (kind, rid, ",".join(missing)))
    if not findings:
        print("No findings")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
