# Postgres for Backstage, created with each EKS session. Backstage rebuilds its
# catalog from Git, so losing the data at the nightly destroy is fine.

resource "random_password" "backstage_db" {
  count   = var.enable_eks ? 1 : 0
  length  = 32
  special = false
}

resource "aws_db_subnet_group" "backstage" {
  count      = var.enable_eks ? 1 : 0
  name       = "${var.cluster_name}-backstage"
  subnet_ids = module.vpc.private_subnets
}

resource "aws_security_group" "backstage_db" {
  count       = var.enable_eks ? 1 : 0
  name        = "${var.cluster_name}-backstage-db"
  description = "Postgres for Backstage. Reachable only from the EKS nodes and pods."
  vpc_id      = module.vpc.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "backstage_db" {
  count                        = var.enable_eks ? 1 : 0
  security_group_id            = aws_security_group.backstage_db[0].id
  description                  = "Postgres from EKS nodes and pods"
  referenced_security_group_id = module.eks[0].node_security_group_id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

resource "aws_db_instance" "backstage" {
  count = var.enable_eks ? 1 : 0

  identifier     = "${var.cluster_name}-backstage"
  engine         = "postgres"
  engine_version = "18"
  instance_class = "db.t4g.micro" # Free Tier-eligible

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = "backstage"
  username = "backstage"
  password = random_password.backstage_db[0].result

  db_subnet_group_name   = aws_db_subnet_group.backstage[0].name
  vpc_security_group_ids = [aws_security_group.backstage_db[0].id]
  publicly_accessible    = false
  # A standby in another AZ that RDS fails over to, in the production profile.
  multi_az = local.high_availability

  # Throwaway data: no snapshots or backups, and nothing blocks deletion.
  backup_retention_period = 0
  skip_final_snapshot     = true
  deletion_protection     = false
  apply_immediately       = true
}

# Connection details for External Secrets to hand to Backstage. Deleted
# immediately on destroy, so the next session can reuse the name.
resource "aws_secretsmanager_secret" "backstage_db" {
  count                   = var.enable_eks ? 1 : 0
  name                    = "idp/backstage/database"
  description             = "Postgres connection for Backstage. Recreated every session."
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "backstage_db" {
  count     = var.enable_eks ? 1 : 0
  secret_id = aws_secretsmanager_secret.backstage_db[0].id
  secret_string = jsonencode({
    host     = aws_db_instance.backstage[0].address
    port     = tostring(aws_db_instance.backstage[0].port)
    user     = aws_db_instance.backstage[0].username
    password = random_password.backstage_db[0].result
  })
}
