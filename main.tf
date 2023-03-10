provider "aws" {
  region = local.region1
}

provider "aws" {
  alias  = "region2"
  region = local.region2
}

data "aws_caller_identity" "current" {}

locals {
  name    = "rds-dms-demo"
  region1 = "eu-west-1"
  region2 = "eu-central-1"

  tags = {
    Name       = local.name
    Example    = local.name
    Repository = "https://github.com/terraform-aws-modules/terraform-aws-rds"
    Owner      = "jmoreno"
  }

  engine                = "postgres"
  engine_version        = "14"
  family                = "postgres14" # DB parameter group
  major_engine_version  = "14"         # DB option group
  instance_class        = "db.t4g.small"
  allocated_storage     = 10
  max_allocated_storage = 10
  port                  = 5432
}

################################################################################
# Main DB
################################################################################

module "main" {
  source  = "terraform-aws-modules/rds/aws"

  identifier = "${local.name}-main"

  engine               = local.engine
  engine_version       = local.engine_version
  family               = local.family
  major_engine_version = local.major_engine_version
  instance_class       = local.instance_class

  allocated_storage     = local.allocated_storage
  max_allocated_storage = local.max_allocated_storage

  db_name  = "demodb"
  username = "demouser"
  port     = local.port

  publicly_accessible = true

  multi_az               = false
  db_subnet_group_name   = module.vpc_region1.database_subnet_group_name
  vpc_security_group_ids = [module.security_group_region1.security_group_id]

  # Backups are required in order to create a replica
  backup_retention_period = 1
  skip_final_snapshot     = true
  deletion_protection     = false

  tags = local.tags
}

################################################################################
# Replica DB
################################################################################

module "kms" {
  source      = "terraform-aws-modules/kms/aws"
  version     = "~> 1.0"
  description = "KMS key for cross region replica DB"

  # Aliases
  aliases                 = [local.name]
  aliases_use_name_prefix = true

  key_owners = [data.aws_caller_identity.current.id]

  tags = local.tags

  providers = {
    aws = aws.region2
  }
}

module "replica" {
  source  = "terraform-aws-modules/rds/aws"

  providers = {
    aws = aws.region2
  }

  identifier = "${local.name}-replica"

  # Source database. For cross-region use db_instance_arn
  replicate_source_db    = module.main.db_instance_arn
  create_random_password = false

  engine               = local.engine
  engine_version       = local.engine_version
  family               = local.family
  major_engine_version = local.major_engine_version
  instance_class       = local.instance_class
  kms_key_id           = module.kms.key_arn

  allocated_storage     = local.allocated_storage
  max_allocated_storage = local.max_allocated_storage

  # Username and password should not be set for replicas
  username = null
  password = null
  port     = local.port

  publicly_accessible = true

  multi_az               = false
  vpc_security_group_ids = [module.security_group_region2.security_group_id]

  backup_retention_period = 0
  skip_final_snapshot     = true
  deletion_protection     = false

  # Specify a subnet group created in the replica region
  db_subnet_group_name = module.vpc_region2.database_subnet_group_name

  tags = local.tags
}

################################################################################
# Supporting Resources
################################################################################

module "vpc_region1" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 3.0"

  name = local.name
  cidr = "10.100.0.0/18"

  azs              = ["${local.region1}a", "${local.region1}b", "${local.region1}c"]
  public_subnets   = ["10.100.0.0/24", "10.100.1.0/24", "10.100.2.0/24"]
  private_subnets  = ["10.100.3.0/24", "10.100.4.0/24", "10.100.5.0/24"]
  database_subnets = ["10.100.7.0/24", "10.100.8.0/24", "10.100.9.0/24"]

  enable_dns_hostnames = true
  enable_dns_support = true
  
  create_database_subnet_group = true
  create_database_internet_gateway_route = true

  tags = local.tags
}

module "security_group_region1" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 4.0"

  name        = local.name
  description = "Replica PostgreSQL example security group"
  vpc_id      = module.vpc_region1.vpc_id

  # ingress
  ingress_with_cidr_blocks = [
    {
      from_port   = 5432
      to_port     = 5432
      protocol    = "tcp"
      description = "PostgreSQL access from within VPC"
      cidr_blocks = "0.0.0.0/0"
    }
  ]

  tags = local.tags
}

module "vpc_region2" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 3.0"

  providers = {
    aws = aws.region2
  }

  name = local.name
  cidr = "10.100.0.0/18"

  azs              = ["${local.region2}a", "${local.region2}b", "${local.region2}c"]
  public_subnets   = ["10.100.0.0/24", "10.100.1.0/24", "10.100.2.0/24"]
  private_subnets  = ["10.100.3.0/24", "10.100.4.0/24", "10.100.5.0/24"]
  database_subnets = ["10.100.7.0/24", "10.100.8.0/24", "10.100.9.0/24"]

  enable_dns_hostnames = true
  enable_dns_support = true

  create_database_subnet_group = true
  create_database_internet_gateway_route = true

  tags = local.tags
}

module "security_group_region2" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 4.0"

  providers = {
    aws = aws.region2
  }

  name        = local.name
  description = "Replica PostgreSQL example security group"
  vpc_id      = module.vpc_region2.vpc_id

  # ingress
  ingress_with_cidr_blocks = [
    {
      from_port   = 5432
      to_port     = 5432
      protocol    = "tcp"
      description = "PostgreSQL access from within VPC"
      cidr_blocks = "0.0.0.0/0"
    }
  ]

  tags = local.tags
}

resource "aws_route" "database_internet_gateway_1" {
  count = length(module.vpc_region1.database_route_table_ids)
  route_table_id         = module.vpc_region1.database_route_table_ids[count.index]
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = module.vpc_region1.igw_id
}

resource "aws_route" "database_internet_gateway_2" {
  count = length(module.vpc_region2.database_route_table_ids)
  route_table_id         = module.vpc_region2.database_route_table_ids[count.index]
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = module.vpc_region2.igw_id

  provider = aws.region2
}

