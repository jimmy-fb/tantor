# ─── Tantor Server Security Group ───

resource "aws_security_group" "tantor_server" {
  name_prefix = "${var.name_prefix}-tantor-"
  description = "Tantor Kafka Manager server"
  vpc_id      = aws_vpc.main.id

  # SSH access
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Web UI
  ingress {
    description = "Tantor UI (HTTP)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # All outbound
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.name_prefix}-tantor-sg"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ─── Kafka Nodes Security Group ───

resource "aws_security_group" "kafka_nodes" {
  name_prefix = "${var.name_prefix}-kafka-"
  description = "Kafka cluster nodes"
  vpc_id      = aws_vpc.main.id

  # SSH from Tantor server (for Ansible deployment)
  ingress {
    description     = "SSH from Tantor"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.tantor_server.id]
  }

  # SSH from anywhere (for debugging — remove in production)
  ingress {
    description = "SSH debug"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Kafka broker + controller ports (inter-node)
  ingress {
    description = "Kafka inter-broker and controller"
    from_port   = 9092
    to_port     = 9093
    protocol    = "tcp"
    self        = true
  }

  # Kafka broker port from Tantor (health checks)
  ingress {
    description     = "Kafka from Tantor"
    from_port       = 9092
    to_port         = 9093
    protocol        = "tcp"
    security_groups = [aws_security_group.tantor_server.id]
  }

  # All outbound
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.name_prefix}-kafka-sg"
  }

  lifecycle {
    create_before_destroy = true
  }
}
