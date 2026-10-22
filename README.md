# AWS Batch ETL Pipeline Infrastructure

A production-grade Terraform configuration for deploying an AWS Batch-based ETL pipeline with Redshift Serverless integration.

## Architecture Overview

This infrastructure provisions a fully managed batch processing environment on AWS, featuring:

- **AWS Batch** compute environment running on Fargate
- **Amazon Redshift Serverless** for data warehousing
- **Amazon ECR** for Docker image management
- **AWS Secrets Manager** for secure credential storage
- **HashiCorp Vault** integration for secret management
- **VPC networking** with public subnets and security groups
- **CloudWatch Logs** for monitoring and troubleshooting

## Prerequisites

- [Terraform](https://www.terraform.io/downloads.html) >= 1.0
- [AWS CLI](https://aws.amazon.com/cli/) configured with appropriate credentials
- [Docker](https://www.docker.com/get-started) for building container images
- [HashiCorp Vault](https://www.vaultproject.io/) server with Redshift credentials stored at `secret/redshift`
- AWS account with necessary permissions

## Required IAM Permissions

Your AWS credentials must have permissions to create and manage:
- VPC resources (VPCs, subnets, security groups, internet gateways)
- IAM roles and policies
- AWS Batch resources (compute environments, job definitions, job queues)
- ECR repositories
- Secrets Manager secrets
- Redshift Serverless resources
- CloudWatch Log Groups

## Project Structure

```
.
├── main.tf                    # Main Terraform configuration
├── variables.tf               # Input variables
├── outputs.tf                 # Output values
├── terraform.tfvars           # Variable values (not committed)
├── modules/
│   ├── vpc/                   # VPC module
│   ├── ecr/                   # ECR module
│   ├── secrets-manager/       # Secrets Manager module
│   └── redshift/              # Redshift Serverless module
└── src/
    ├── artifact_push.sh       # ECR image push script
    └── Dockerfile             # Container image definition
```

## Configuration

### 1. Vault Setup

Ensure Redshift credentials are stored in Vault:

```bash
vault kv put secret/redshift username=admin password=SecurePassword123!
```

### 2. Terraform Variables

Create a `terraform.tfvars` file:

```hcl
region          = "us-east-1"
azs             = ["us-east-1a", "us-east-1b"]
public_subnets  = ["10.0.1.0/24", "10.0.2.0/24"]
private_subnets = ["10.0.10.0/24", "10.0.20.0/24"]
```

### 3. Environment Variables

Export required environment variables:

```bash
export VAULT_ADDR="https://your-vault-server:8200"
export VAULT_TOKEN="your-vault-token"
export AWS_REGION="us-east-1"
```

## Deployment

### Step 1: Initialize Terraform

```bash
terraform init
```

### Step 2: Review the Plan

```bash
terraform plan
```

### Step 3: Apply Configuration

```bash
terraform apply
```

### Step 4: Build and Push Container Image

The ECR module automatically triggers the artifact push script, but you can manually push updates:

```bash
cd src
./artifact_push.sh us-east-1
```

## Usage

### Submitting a Batch Job

Using AWS CLI:

```bash
aws batch submit-job \
  --job-name my-etl-job \
  --job-queue batch-job-queue \
  --job-definition batch-job-definition
```

Using AWS Console:
1. Navigate to AWS Batch
2. Select "Jobs" → "Submit new job"
3. Choose the job queue: `batch-job-queue`
4. Choose the job definition: `batch-job-definition`
5. Submit

### Monitoring Jobs

View logs in CloudWatch:

```bash
aws logs tail /aws/batch/job --follow
```

Or access through the AWS Console:
- CloudWatch → Log groups → `/aws/batch/job`

## Security Considerations

### Current Configuration
- ⚠️ **Security groups allow traffic from 0.0.0.0/0** - Restrict to specific IP ranges in production
- ⚠️ **Redshift is publicly accessible** - Consider using private subnets with VPN/Direct Connect
- ✅ Credentials stored in Secrets Manager with encryption at rest
- ✅ IAM roles follow principle of least privilege
- ✅ ECR images set to IMMUTABLE for auditability

### Recommended Hardening

1. **Network Security**
   ```hcl
   ingress {
     from_port   = 5439
     to_port     = 5439
     protocol    = "tcp"
     cidr_blocks = ["10.0.0.0/16"]  # VPC CIDR only
   }
   ```

2. **Redshift Access**
   ```hcl
   publicly_accessible = false
   subnet_ids          = module.private_subnets.subnets[*].id
   ```

3. **Enable NAT Gateway** for private subnet internet access:
   ```hcl
   enable_nat_gateway = true
   single_nat_gateway = true
   ```

4. **Secrets Rotation**
   - Enable automatic rotation for Secrets Manager secrets
   - Set appropriate `recovery_window_in_days` (currently set to 0)

5. **Enable VPC Flow Logs** for network traffic analysis

## Resource Specifications

### Batch Compute Environment
- **Type**: Fargate (serverless)
- **Max vCPUs**: 16
- **Scaling**: Automatic based on job queue

### Container Resources
- **vCPU**: 0.25
- **Memory**: 512 MB
- **Platform**: Fargate LATEST

### Redshift Serverless
- **Base Capacity**: 128 RPUs
- **Database**: records
- **Namespace**: batch-namespace

## Cost Optimization

- Fargate Spot pricing can reduce costs by up to 70% for fault-tolerant workloads
- Redshift Serverless charges only for actual usage
- CloudWatch Logs retention set to 7 days to manage storage costs
- Consider using lifecycle policies for ECR images

## Troubleshooting

### Common Issues

**Job fails to start:**
- Check IAM role permissions
- Verify ECR image exists and is accessible
- Review security group rules

**Cannot connect to Redshift:**
- Verify security group allows traffic from Batch subnets
- Check Redshift endpoint is correct
- Ensure credentials in Secrets Manager are valid

**Container logs not appearing:**
- Verify CloudWatch Logs permissions on execution role
- Check log group exists: `/aws/batch/job`
- Review log configuration in job definition

### Debug Commands

```bash
# Check Batch job status
aws batch describe-jobs --jobs <job-id>

# View CloudWatch logs
aws logs get-log-events \
  --log-group-name /aws/batch/job \
  --log-stream-name <stream-name>

# Test Redshift connectivity
psql -h <redshift-endpoint> -U admin -d records -p 5439
```

## Cleanup

To destroy all resources:

```bash
terraform destroy
```

**Warning**: This will permanently delete all resources including Redshift data. Ensure you have backups before proceeding.

## Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Support

For issues and questions:
- Create an issue in the GitHub repository
- Contact the infrastructure team at infrastructure@yourcompany.com

## References

- [AWS Batch Documentation](https://docs.aws.amazon.com/batch/)
- [Redshift Serverless Documentation](https://docs.aws.amazon.com/redshift/latest/mgmt/serverless-console.html)
- [Terraform AWS Provider](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)
- [HashiCorp Vault Documentation](https://www.vaultproject.io/docs)
