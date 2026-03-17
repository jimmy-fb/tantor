# Generate SSH key pair — lives in Terraform state (no manual key management)

resource "tls_private_key" "tantor" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "tantor" {
  key_name   = "${var.name_prefix}-${var.os_variant}-key"
  public_key = tls_private_key.tantor.public_key_openssh

  tags = {
    Name = "${var.name_prefix}-key"
  }
}
