# The shared Postgres server for managed WebService databases. Each service
# gets its own database and login on it, created by Crossplane's provider-sql.
# Like Backstage's database, it is recreated with each EKS session.

resource "random_password" "shared_postgres" {
  count   = var.enable_eks ? 1 : 0
  length  = 32
  special = false
}

resource "aws_db_subnet_group" "shared_postgres" {
  count      = var.enable_eks ? 1 : 0
  name       = "${var.cluster_name}-shared-postgres"
  subnet_ids = module.vpc.private_subnets
}

resource "aws_security_group" "shared_postgres" {
  count       = var.enable_eks ? 1 : 0
  name        = "${var.cluster_name}-shared-postgres"
  description = "Shared Postgres for WebServices. Reachable from EKS pods and ECS tasks in the VPC."
  vpc_id      = module.vpc.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "shared_postgres" {
  count             = var.enable_eks ? 1 : 0
  security_group_id = aws_security_group.shared_postgres[0].id
  description       = "Postgres from inside the VPC"
  cidr_ipv4         = module.vpc.vpc_cidr_block
  from_port         = 5432
  to_port           = 5432
  ip_protocol       = "tcp"
}

resource "aws_db_instance" "shared_postgres" {
  count = var.enable_eks ? 1 : 0

  identifier     = "${var.cluster_name}-shared-postgres"
  engine         = "postgres"
  engine_version = "18"
  instance_class = "db.t4g.micro" # Free Tier-eligible

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  # The admin login provider-sql uses. Not a superuser on RDS.
  username = "idpadmin"
  password = random_password.shared_postgres[0].result

  db_subnet_group_name   = aws_db_subnet_group.shared_postgres[0].name
  vpc_security_group_ids = [aws_security_group.shared_postgres[0].id]
  publicly_accessible    = false
  multi_az               = false

  # Throwaway data: no snapshots or backups, and nothing blocks deletion.
  backup_retention_period = 0
  skip_final_snapshot     = true
  deletion_protection     = false
  apply_immediately       = true
}

# The admin login for External Secrets to hand to provider-sql, with the key
# names provider-sql expects. Deleted immediately on destroy.
resource "aws_secretsmanager_secret" "shared_postgres" {
  count                   = var.enable_eks ? 1 : 0
  name                    = "idp/platform/shared-postgres"
  description             = "Admin login for the shared Postgres server. Recreated every session."
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "shared_postgres" {
  count     = var.enable_eks ? 1 : 0
  secret_id = aws_secretsmanager_secret.shared_postgres[0].id
  secret_string = jsonencode({
    endpoint = aws_db_instance.shared_postgres[0].address
    port     = tostring(aws_db_instance.shared_postgres[0].port)
    username = aws_db_instance.shared_postgres[0].username
    password = random_password.shared_postgres[0].result
  })
}
