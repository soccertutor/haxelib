resource "aws_db_instance" "haxe-org" {
  allocated_storage               = 20
  engine                          = "mysql"
  engine_version                  = "5.6.51"
  instance_class                  = "db.t2.micro"
  name                            = "ebdb"
  username                        = "Andy"
  parameter_group_name            = aws_db_parameter_group.default.name
  option_group_name               = aws_db_option_group.default.name
  enabled_cloudwatch_logs_exports = ["general", "slowquery", "error"]
  publicly_accessible             = true
  skip_final_snapshot             = true

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_db_parameter_group" "default" {
  name_prefix = "mysql56-default-upgrade-"
  family      = "mysql5.6"
  description = "Parameter group created for required database upgrade from RDS mysql 5.5.62 to 5.6.34 based on parameter group mysql55params"

  parameter {
    apply_method = "pending-reboot"
    name         = "max_allowed_packet"
    value        = "1073741824"
  }
  parameter {
    apply_method = "pending-reboot"
    name         = "max_connect_errors"
    value        = "1000"
  }
  parameter {
    name  = "general_log"
    value = "1"
  }
  parameter {
    name  = "slow_query_log"
    value = "1"
  }
  parameter {
    name  = "long_query_time"
    value = "1"
  }
  parameter {
    name  = "sort_buffer_size"
    value = "8388608"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_db_option_group" "default" {
  name_prefix              = "mysql56-default-upgrade-"
  option_group_description = "Option group created for required database upgrade from RDS mysql 5.5.62 to mysql 5.6.34."
  engine_name              = "mysql"
  major_engine_version     = "5.6"

  lifecycle {
    create_before_destroy = true
  }
}
