provider "aws" {
  region = var.aws_region

  # Makes the AWS SDK retry transient network/API errors itself (the
  # "no such host" / dropped-connection errors you kept hitting) instead of
  # failing the whole apply/destroy on the first blip.
  retry_mode  = "adaptive"
  max_retries = 15

  default_tags {
    tags = {
      Project     = "NexOps Enterprise Platform"
      Environment = var.environment
      ManagedBy   = "Terraform"
      Owner       = "Nitesh"
    }
  }
}

