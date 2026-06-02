#!/bin/bash
# Week 5 — AWS Resource Inventory Script
# Run this before destroying to see everything that exists
# Region: us-east-1 | Account: 432500708329

set -euo pipefail
REGION="us-east-1"
echo "=========================================="
echo " AWS RESOURCE INVENTORY — Week 5"
echo " Region: $REGION"
echo " $(date)"
echo "=========================================="

echo ""
echo "--- ECS ---"
echo "Clusters:"
aws ecs list-clusters --region $REGION --query 'clusterArns[]' --output table

echo "Services:"
aws ecs list-services \
  --cluster wordpress-ecs-ha-dev-cluster \
  --region $REGION \
  --query 'serviceArns[]' \
  --output table 2>/dev/null || echo "Cluster not found or no services"

echo "Running Tasks:"
aws ecs list-tasks \
  --cluster wordpress-ecs-ha-dev-cluster \
  --region $REGION \
  --query 'taskArns[]' \
  --output table 2>/dev/null || echo "No tasks"

echo ""
echo "--- EC2 ---"
echo "Instances:"
aws ec2 describe-instances \
  --region $REGION \
  --filters "Name=instance-state-name,Values=running,stopped,stopping" \
  --query 'Reservations[].Instances[].[InstanceId,InstanceType,State.Name,Tags[?Key==`Name`].Value|[0],PublicIpAddress]' \
  --output table

echo "Auto Scaling Groups:"
aws autoscaling describe-auto-scaling-groups \
  --region $REGION \
  --query 'AutoScalingGroups[].[AutoScalingGroupName,DesiredCapacity,MinSize,MaxSize]' \
  --output table

echo "Launch Templates:"
aws ec2 describe-launch-templates \
  --region $REGION \
  --query 'LaunchTemplates[].[LaunchTemplateName,LatestVersionNumber]' \
  --output table

echo ""
echo "--- LOAD BALANCER ---"
echo "ALBs:"
aws elbv2 describe-load-balancers \
  --region $REGION \
  --query 'LoadBalancers[].[LoadBalancerName,State.Code,DNSName]' \
  --output table

echo "Target Groups:"
aws elbv2 describe-target-groups \
  --region $REGION \
  --query 'TargetGroups[].[TargetGroupName,Protocol,Port]' \
  --output table

echo ""
echo "--- RDS ---"
echo "DB Instances:"
aws rds describe-db-instances \
  --region $REGION \
  --query 'DBInstances[].[DBInstanceIdentifier,DBInstanceClass,DBInstanceStatus,Engine]' \
  --output table

echo "DB Snapshots (manual):"
aws rds describe-db-snapshots \
  --region $REGION \
  --snapshot-type manual \
  --query 'DBSnapshots[].[DBSnapshotIdentifier,Status,SnapshotCreateTime]' \
  --output table

echo ""
echo "--- EFS ---"
echo "File Systems:"
aws efs describe-file-systems \
  --region $REGION \
  --query 'FileSystems[].[FileSystemId,Name,LifeCycleState,SizeInBytes.Value]' \
  --output table

echo "Mount Targets:"
aws efs describe-mount-targets \
  --region $REGION \
  --query 'MountTargets[].[MountTargetId,FileSystemId,LifeCycleState,IpAddress]' \
  --output table 2>/dev/null || echo "No mount targets"

echo ""
echo "--- NETWORKING ---"
echo "VPCs:"
aws ec2 describe-vpcs \
  --region $REGION \
  --filters "Name=tag:Project,Values=wordpress-ecs-ha" \
  --query 'Vpcs[].[VpcId,CidrBlock,State]' \
  --output table

echo "Subnets:"
aws ec2 describe-subnets \
  --region $REGION \
  --filters "Name=tag:Project,Values=wordpress-ecs-ha" \
  --query 'Subnets[].[SubnetId,CidrBlock,AvailabilityZone,MapPublicIpOnLaunch]' \
  --output table

echo "Security Groups:"
aws ec2 describe-security-groups \
  --region $REGION \
  --filters "Name=tag:Project,Values=wordpress-ecs-ha" \
  --query 'SecurityGroups[].[GroupId,GroupName]' \
  --output table

echo "NAT Gateways:"
aws ec2 describe-nat-gateways \
  --region $REGION \
  --filter "Name=state,Values=available,pending" \
  --query 'NatGateways[].[NatGatewayId,State,SubnetId]' \
  --output table

echo "Internet Gateways:"
aws ec2 describe-internet-gateways \
  --region $REGION \
  --filters "Name=tag:Project,Values=wordpress-ecs-ha" \
  --query 'InternetGateways[].[InternetGatewayId,Attachments[0].State]' \
  --output table

echo ""
echo "--- SECRETS & ENCRYPTION ---"
echo "Secrets Manager:"
aws secretsmanager list-secrets \
  --region $REGION \
  --query 'SecretList[].[Name,LastChangedDate]' \
  --output table

echo "KMS Keys (customer managed):"
aws kms list-keys \
  --region $REGION \
  --query 'Keys[].[KeyId]' \
  --output table

echo "KMS Aliases:"
aws kms list-aliases \
  --region $REGION \
  --query 'Aliases[?starts_with(AliasName,`alias/wordpress`)].AliasName' \
  --output table

echo ""
echo "--- MONITORING ---"
echo "CloudWatch Alarms:"
aws cloudwatch describe-alarms \
  --region $REGION \
  --query 'MetricAlarms[].[AlarmName,StateValue]' \
  --output table

echo "Composite Alarms:"
aws cloudwatch describe-alarms \
  --alarm-types CompositeAlarm \
  --region $REGION \
  --query 'CompositeAlarms[].[AlarmName,StateValue]' \
  --output table

echo "CloudWatch Dashboards:"
aws cloudwatch list-dashboards \
  --region $REGION \
  --query 'DashboardEntries[].[DashboardName]' \
  --output table

echo "CloudWatch Log Groups:"
aws logs describe-log-groups \
  --region $REGION \
  --log-group-name-prefix "/ecs/wordpress" \
  --query 'logGroups[].[logGroupName,retentionInDays]' \
  --output table

echo ""
echo "--- SNS ---"
echo "Topics:"
aws sns list-topics \
  --region $REGION \
  --query 'Topics[].[TopicArn]' \
  --output table

echo "Subscriptions:"
aws sns list-subscriptions \
  --region $REGION \
  --query 'Subscriptions[].[TopicArn,Protocol,Endpoint,SubscriptionArn]' \
  --output table

echo ""
echo "--- IAM ---"
echo "Roles (project specific):"
aws iam list-roles \
  --query 'Roles[?contains(RoleName,`wordpress-ecs-ha`)].RoleName' \
  --output table

echo "Instance Profiles:"
aws iam list-instance-profiles \
  --query 'InstanceProfiles[?contains(InstanceProfileName,`wordpress-ecs-ha`)].InstanceProfileName' \
  --output table

echo "Policies (customer managed):"
aws iam list-policies \
  --scope Local \
  --query 'Policies[?contains(PolicyName,`wordpress-ecs-ha`)].PolicyName' \
  --output table

echo ""
echo "--- S3 STATE ---"
echo "Terraform State Bucket:"
aws s3 ls s3://wordpress-ecs-tfstate-xgrid-1779080592 --recursive 2>/dev/null || echo "Bucket not found"

echo ""
echo "=========================================="
echo " COST-INCURRING RESOURCES SUMMARY"
echo " (These charge money every hour)"
echo "=========================================="
echo ""
echo "NAT Gateway   — ~\$0.045/hour (~\$32/month)"
aws ec2 describe-nat-gateways \
  --region $REGION \
  --filter "Name=state,Values=available" \
  --query 'NatGateways[].[NatGatewayId,State]' \
  --output table

echo ""
echo "EC2 Instances — ~\$0.0116/hour each (t2.micro)"
aws ec2 describe-instances \
  --region $REGION \
  --filters "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].[InstanceId,InstanceType,Tags[?Key==`Name`].Value|[0]]' \
  --output table

echo ""
echo "RDS Instance  — ~\$0.017/hour (db.t3.micro)"
aws rds describe-db-instances \
  --region $REGION \
  --query 'DBInstances[?DBInstanceStatus==`available`].[DBInstanceIdentifier,DBInstanceStatus]' \
  --output table

echo ""
echo "ALB           — ~\$0.008/hour"
aws elbv2 describe-load-balancers \
  --region $REGION \
  --query 'LoadBalancers[?State.Code==`active`].[LoadBalancerName,State.Code]' \
  --output table

echo ""
echo "=========================================="
echo " TO DESTROY EVERYTHING RUN:"
echo "=========================================="
echo ""
echo "  cd 'week 5/environments/dev'"
echo "  terraform destroy -var 'grafana_admin_password=YOUR_PASSWORD'"
echo ""
echo "  After destroy, manually delete:"
echo "  1. S3 state bucket (terraform does not delete this)"
echo "  aws s3 rm s3://wordpress-ecs-tfstate-xgrid-1779080592 --recursive"
echo "  aws s3 rb s3://wordpress-ecs-tfstate-xgrid-1779080592"
echo ""
echo "  2. CloudWatch Log Groups (may persist after destroy)"
echo "  aws logs delete-log-group --log-group-name /ecs/wordpress-ecs-ha/dev/wordpress --region us-east-1"
echo ""
echo "  3. Any manual RDS snapshots"
echo "  aws rds describe-db-snapshots --snapshot-type manual --region us-east-1"
echo ""
echo "=========================================="
echo " INVENTORY COMPLETE"
echo "=========================================="
