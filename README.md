# RDS DMS demo

This demo is based on https://github.com/terraform-aws-modules/terraform-aws-rds/tree/v5.6.0/examples/cross-region-replica-postgres.

Right now, it is a work in progress: main database and its read replica are created successfully in
public subnets, but DMS has not been integrated. Also, an EC2 with Postgres should be started to
act as the source of the data.