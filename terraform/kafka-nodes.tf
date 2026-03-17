# ─── Kafka Cluster Nodes ───

resource "aws_instance" "kafka_node" {
  count = var.kafka_node_count

  ami                    = local.ami_id
  instance_type          = var.kafka_instance_type
  key_name               = aws_key_pair.tantor.key_name
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.kafka_nodes.id]

  associate_public_ip_address = true

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }

  user_data = templatefile("${path.module}/user-data/kafka-node.sh.tpl", {
    os_variant = var.os_variant
    ssh_user   = local.ssh_user
  })

  tags = {
    Name     = "${var.name_prefix}-kafka-${count.index + 1}"
    Role     = "kafka-broker"
    OS       = var.os_variant
    NodeId   = count.index + 1
  }
}
