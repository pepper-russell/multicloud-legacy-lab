# Workload 1 — 3-tier legacy application, AWS leg of the mesh (10.10.0.0/16).
#
# Reality, stated once and plainly:
# - Windows Server 2008 is end-of-life (extended security ended Jan 2023).
#   No cloud sells a WS2008 image anymore. You bring your own: import the
#   VHD with VM Import/Export (aws ec2 import-image) or restore from your
#   own media, ONCE, into a private AMI. That AMI id is `var.ws2008_ami`.
# - Classic VB (VB6) runtime ships inside that image. The app is what it is.
# - dBase is a FILE-based database. There is no server, no transactions,
#   no clustering. "HA for the data layer" = the .DBF/.DBT/.MDX files live
#   on shared storage (FSx for Windows) mounted by every app node, with
#   file-level replication + scheduled snapshots. Record locking is the
#   application's problem, exactly as it was in 1997. The migration plan
#   out of dBase is in ../../migration-plans/dbase-to-sql.md — read it
#   before you fall in love with this design.
# - Because WS2008 cannot be patched, this VPC segment is a quarantine:
#   no internet egress, no inbound except the ALB, all traffic inspected,
#   and it talks to the other clouds only over the VPN mesh.

terraform {
  required_providers { aws = { source = "hashicorp/aws", version = "~> 5.0" } }
}

variable "vpc_id" { type = string }         # from ../network (hub-aws)
variable "ws2008_ami" { type = string }      # your imported WS2008 AMI
variable "dbase_bucket_prefix" { default = "legacy-dbase" }

provider "aws" { region = "us-east-1" }

# ---------- Tier 0: network quarantine ----------
resource "aws_subnet" "web" {
  vpc_id = var.vpc_id
  cidr_block = "10.10.11.0/24"
  availability_zone = "us-east-1a"
}
resource "aws_subnet" "web_b" {
  vpc_id = var.vpc_id
  cidr_block = "10.10.12.0/24"
  availability_zone = "us-east-1b"
}
resource "aws_subnet" "app" {
  vpc_id = var.vpc_id
  cidr_block = "10.10.21.0/24"
  availability_zone = "us-east-1a"
}
resource "aws_subnet" "app_b" {
  vpc_id = var.vpc_id
  cidr_block = "10.10.22.0/24"
  availability_zone = "us-east-1b"
}
resource "aws_subnet" "data" {
  vpc_id = var.vpc_id
  cidr_block = "10.10.31.0/24"
  availability_zone = "us-east-1a"
}

resource "aws_security_group" "alb" {
  name = "w1-alb"
  vpc_id = var.vpc_id
  ingress { from_port = 443, to_port = 443, protocol = "tcp", cidr_blocks = ["0.0.0.0/0"] }
  egress { from_port = 0, to_port = 0, protocol = "-1", cidr_blocks = ["10.10.0.0/16"] }
}

resource "aws_security_group" "tier" {
  name = "w1-tier"
  vpc_id = var.vpc_id
  # Only the ALB may speak to the web tier; only the mesh may reach the app tier.
  ingress { from_port = 80, to_port = 80, protocol = "tcp", security_groups = [aws_security_group.alb.id] }
  ingress { from_port = 3389, to_port = 3389, protocol = "tcp", cidr_blocks = ["10.20.0.0/16", "10.30.0.0/16"] } # RDP over VPN only, from the other clouds' admin ranges
  egress { from_port = 0, to_port = 0, protocol = "-1", cidr_blocks = ["10.10.0.0/16"] } # no internet egress. none.
}

# ---------- Tier 1+2: web + app (same legacy image, role by user-data) ----------
# WS2008 + VB6 in an Auto Scaling group is an act of will: the ASG gives you
# instance replacement and count scaling; the application itself is stateless
# only because the dBase files are on FSx, not the local disk.
resource "aws_launch_template" "legacy" {
  name_prefix = "w1-legacy-"
  image_id = var.ws2008_ami
  instance_type = "m5.large" # WS2008-era drivers behave on Nitro with the ENA/NVMe caveat checked at import time
  vpc_security_group_ids = [aws_security_group.tier.id]
  user_data = base64encode(<<-EOT
    <powershell>
    # Role assignment + dBase share mount happen here at first boot.
    New-PSDrive -Name "D" -PSProvider FileSystem -Root "\\${aws_fsx_windows_file_system.dbase.dns_name}\share" -Persist
    Set-Service -Name "W3SVC" -StartupType Automatic
    </powershell>
  EOT
  )
}

resource "aws_autoscaling_group" "web" {
  name = "w1-web-asg"
  vpc_zone_identifier = [aws_subnet.web.id, aws_subnet.web_b.id]
  min_size = 2
  max_size = 6
  desired_capacity = 2
  health_check_type = "ELB"
  launch_template { id = aws_launch_template.legacy.id, version = "$Latest" }
}

resource "aws_autoscaling_group" "app" {
  name = "w1-app-asg"
  vpc_zone_identifier = [aws_subnet.app.id, aws_subnet.app_b.id]
  min_size = 2
  max_size = 6
  desired_capacity = 2
  health_check_type = "EC2"
  launch_template { id = aws_launch_template.legacy.id, version = "$Latest" }
}

# Autoscaling policies for every service, as ordered.
resource "aws_autoscaling_policy" "web_cpu" {
  name = "w1-web-cpu"
  autoscaling_group_name = aws_autoscaling_group.web.name
  policy_type = "TargetTrackingScaling"
  target_tracking_configuration {
    predefined_metric_specification { predefined_metric_type = "ASGAverageCPUUtilization" }
    target_value = 55.0
  }
}
resource "aws_autoscaling_policy" "app_cpu" {
  name = "w1-app-cpu"
  autoscaling_group_name = aws_autoscaling_group.app.name
  policy_type = "TargetTrackingScaling"
  target_tracking_configuration {
    predefined_metric_specification { predefined_metric_type = "ASGAverageCPUUtilization" }
    target_value = 55.0
  }
}

resource "aws_lb" "front" {
  name = "w1-alb"
  load_balancer_type = "application"
  security_groups = [aws_security_group.alb.id]
  subnets = [aws_subnet.web.id, aws_subnet.web_b.id]
}
resource "aws_lb_target_group" "web" {
  name = "w1-web-tg"
  port = 80
  protocol = "HTTP"
  vpc_id = var.vpc_id
  health_check { path = "/health.htm", matcher = "200" }
}
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.front.arn
  port = 443
  protocol = "HTTPS"
  ssl_policy = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn = var.acm_cert_arn
  default_action { type = "forward", target_group_arn = aws_lb_target_group.web.arn }
}
resource "aws_autoscaling_attachment" "web" {
  autoscaling_group_name = aws_autoscaling_group.web.name
  lb_target_group_arn = aws_lb_target_group.web.arn
}

variable "acm_cert_arn" { type = string }

# ---------- Tier 3: the dBase layer ----------
# FSx for Windows = the shared disk the .DBF files live on. Multi-AZ,
# automatic backups on. This is as HA as dBase honestly gets.
resource "aws_fsx_windows_file_system" "dbase" {
  storage_capacity = 100
  subnet_ids = [aws_subnet.data.id]
  throughput_capacity = 32
  deployment_type = "SINGLE_AZ_2"
  backup_id = null
  automatic_backup_retention_days = 14
  tags = { Name = "w1-dbase-files" }
}

# Versioned cold copy of the data files, for the migration plan and for
# the day someone deletes the wrong .DBF.
resource "aws_s3_bucket" "dbase_vault" {
  bucket = "${var.dbase_bucket_prefix}-vault"
}
resource "aws_s3_bucket_versioning" "dbase_vault" {
  bucket = aws_s3_bucket.dbase_vault.id
  versioning_configuration { status = "Enabled" }
}

output "alb_dns" { value = aws_lb.front.dns_name }
output "dbase_share" { value = aws_fsx_windows_file_system.dbase.dns_name }
