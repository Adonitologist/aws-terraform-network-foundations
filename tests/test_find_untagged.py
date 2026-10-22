import os
import sys

import boto3
import pytest
from moto import mock_aws

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))
import find_untagged  # noqa: E402

REGION = "us-east-1"


@pytest.fixture(autouse=True)
def fake_credentials(monkeypatch):
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "testing")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "testing")
    monkeypatch.setenv("AWS_DEFAULT_REGION", REGION)


def run_instance(ec2, tags):
    ami = ec2.describe_images()["Images"][0]["ImageId"]
    kwargs = {"ImageId": ami, "MinCount": 1, "MaxCount": 1}
    if tags:
        kwargs["TagSpecifications"] = [{
            "ResourceType": "instance",
            "Tags": [{"Key": k, "Value": "x"} for k in tags],
        }]
    return ec2.run_instances(**kwargs)["Instances"][0]["InstanceId"]


@mock_aws
def test_untagged_resources_are_reported_with_exit_code_1(capsys):
    ec2 = boto3.client("ec2", region_name=REGION)
    iid = run_instance(ec2, tags=[])
    vol = ec2.create_volume(AvailabilityZone=REGION + "a", Size=1)["VolumeId"]

    code = find_untagged.main(["--region", REGION])

    out = capsys.readouterr().out
    assert code == 1
    assert "instance %s missing: Project,Environment" % iid in out
    assert "volume %s missing: Project,Environment" % vol in out


@mock_aws
def test_fully_tagged_instance_gives_exit_code_0(capsys):
    ec2 = boto3.client("ec2", region_name=REGION)
    run_instance(ec2, tags=["Project", "Environment"])
    for vol in ec2.describe_volumes()["Volumes"]:
        ec2.create_tags(Resources=[vol["VolumeId"]], Tags=[
            {"Key": "Project", "Value": "x"},
            {"Key": "Environment", "Value": "x"},
        ])

    code = find_untagged.main(["--region", REGION])

    assert code == 0
    assert "No findings" in capsys.readouterr().out


@mock_aws
def test_partial_tags_report_only_the_missing_key(capsys):
    ec2 = boto3.client("ec2", region_name=REGION)
    iid = run_instance(ec2, tags=["Project"])

    find_untagged.main(["--region", REGION, "--required-tags", "Project,Environment"])

    assert "instance %s missing: Environment" % iid in capsys.readouterr().out
