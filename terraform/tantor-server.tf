# ─── Tantor Server (Native Install) ───

resource "aws_instance" "tantor_server" {
  ami                    = local.ami_id
  instance_type          = var.tantor_instance_type
  key_name               = aws_key_pair.tantor.key_name
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.tantor_server.id]

  associate_public_ip_address = true

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }

  user_data = templatefile("${path.module}/user-data/tantor-server.sh.tpl", {
    os_variant    = var.os_variant
    github_repo   = var.github_repo
    github_token  = var.github_token
    kafka_version = var.kafka_version
  })

  tags = {
    Name     = "${var.name_prefix}-tantor-server"
    Role     = "tantor-manager"
    OS       = var.os_variant
  }
}
