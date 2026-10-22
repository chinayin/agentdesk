# Alibaba Cloud Native CLI Flow

Use `aliyun` and select the environment with an explicit `--profile "$PROFILE"` and the API's `--RegionId "$REGION"`. This branch documents the native flow but has not completed a real ECS POC; do not carry AWS results over to Alibaba Cloud.

1. Check `command -v aliyun`; if it is missing, give the [official install guide](https://www.alibabacloud.com/help/en/cli/installation-guide/) and let the user decide. Verify the identity with `aliyun sts GetCallerIdentity` without printing the credential config.
2. Query the required values with ECS `DescribeKeyPairs`, `DescribeInstanceTypes`, `DescribeImages`, `DescribeSecurityGroups` and VPC `DescribeVSwitches`. Check the image's actual distribution, version, architecture, SSH user and zone support; if no official image of the target exists, stop and say so instead of silently downgrading the OS.
3. Create a dedicated security group with source-limited SSH and the chosen RDP entry. Reusing an existing VPC/vSwitch does not mean you may modify its existing resources.
4. Check the parameters your local CLI/API version supports with `aliyun ecs RunInstances --help`, then build the native request with at least `RegionId`, `ImageId`, `InstanceType`, `SecurityGroupId`, `VSwitchId`, `KeyPairName`, `Amount`, `ClientToken`, the system disk category/size and the resource name. Choose `PostPaid` as needed. Set bandwidth and traffic billing when a public address is needed; request no public address in private-network mode.
5. Save the request and its ClientToken, then create. On a timeout, query `DescribeInstances` by the recorded instance ID or this run's unique name/tag first, and retry only with the same parameters and token; never generate a new token and add instances blindly.
6. Once the instance is running and has an address, check the SSH host key fingerprint in the official console/serial output, then follow the skill's deploy and verify flow. Never disable host key checking on first connect.
7. Keep or delete resources as the user authorized. Delete only this run's recorded instance and dedicated security group, and confirm the attached disks were released; never delete shared VPCs/vSwitches or key pairs.

Reference: [RunInstances API](https://www.alibabacloud.com/help/en/ecs/developer-reference/api-ecs-2014-05-26-runinstances). Whether the requested Ubuntu/Debian version, instance stock and billing options are available must be queried at run time.
