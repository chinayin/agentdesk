# AWS Native CLI Flow

Use `aws` and pass `--profile "$PROFILE" --region "$REGION" --no-cli-pager` on every command. The variables below come from the user's parameters or API queries; do not assume a personal environment.

1. Confirm the account with `aws sts get-caller-identity`; check the public key with `ec2 describe-key-pairs --key-names "$KEY_NAME" --include-public-key`. Query an existing machine's key pair, VPC and subnet read-only; reusing its key does not mean reusing its security group.
2. Confirm CPU, memory and architecture with `ec2 describe-instance-types`; confirm the subnet and its real public/private routing with `describe-subnets` and `describe-route-tables`.
3. Resolve the official Ubuntu image from the Canonical SSM parameter `/aws/service/canonical/ubuntu/server/$CODENAME/stable/current/amd64/hvm/ebs-gp3/ami-id`. Ubuntu 26.04 is `resolute`, 24.04 is `noble`. Then check owner, version, architecture, state and RootDeviceName with `describe-images`. For Debian use Debian's official image publication; do not reuse the Canonical path.
4. Create a dedicated security group tagged with this run's name and `ManagedBy=agentdesk`. Allow TCP 22 from the required source CIDR, plus the RDP port for direct access. Confirm the rules from the query result and keep the default egress for software downloads. Never open RDP to the whole internet.
5. Copy the [RunInstances JSON template](../assets/aws-run-instances.json) and fill it with a JSON library: the AMI's root device name, an encrypted gp3 disk, count, key, security group and subnet. The template is a T3 on-demand public example; for arm64 use an arm64 AMI with a Graviton type such as T4g. Remove `CreditSpecification` for non-burstable types and disable the public address for private-network mode. Keep IMDSv2 required.
6. Generate one ClientToken for this request and save the JSON. Run `aws ec2 run-instances --cli-input-json "file://$REQUEST" --dry-run` first; only `DryRunOperation` means the permission check passed, so resolve any other error first. Then create with the same JSON and save the response. A dry run does not guarantee capacity or quota.
7. On a create timeout, query `describe-instances --filters "Name=client-token,Values=$CLIENT_TOKEN"` first; retrying with the same parameters and token is idempotent. Never create a second copy with a new token.
8. Poll `describe-instance-status --include-all-instances` and `describe-instances`; record the instance ID, address and state. Get the host key fingerprints printed by cloud-init with `get-console-output --instance-id "$INSTANCE_ID" --latest`, compare them with `ssh-keyscan`, then connect.
9. Deploy and verify following the main skill flow; keep the native create/query responses and the result record.

The template uses standard CPU credits to avoid T3 unlimited surplus charges; the instance, disk and public IPv4 are still billed. Do not create a NAT gateway, load balancer or Elastic IP that the test does not need.

Delete resources only when the user authorizes it: `terminate-instances` by the recorded ID, confirm termination and the DeleteOnTermination disk deletion, then delete this run's dedicated security group. State clearly when cleanup is incomplete. Never delete shared networks or key pairs.

References: [RunInstances](https://docs.aws.amazon.com/cli/latest/reference/ec2/run-instances.html), [finding Ubuntu images](https://ubuntu.com/aws/docs/aws-how-to/instances/find-ubuntu-images/), [installing the AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html).
