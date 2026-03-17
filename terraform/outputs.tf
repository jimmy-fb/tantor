# ─── Tantor Server ───

output "tantor_public_ip" {
  description = "Public IP of the Tantor server"
  value       = aws_instance.tantor_server.public_ip
}

output "tantor_private_ip" {
  description = "Private IP of the Tantor server"
  value       = aws_instance.tantor_server.private_ip
}

output "tantor_url" {
  description = "Tantor UI URL"
  value       = "http://${aws_instance.tantor_server.public_ip}"
}

# ─── Kafka Nodes ───

output "kafka_private_ips" {
  description = "Private IPs of Kafka nodes (used by Tantor for SSH deployment)"
  value       = aws_instance.kafka_node[*].private_ip
}

output "kafka_public_ips" {
  description = "Public IPs of Kafka nodes (for debug SSH access)"
  value       = aws_instance.kafka_node[*].public_ip
}

# ─── SSH ───

output "private_key_pem" {
  description = "SSH private key for all EC2 instances"
  value       = tls_private_key.tantor.private_key_pem
  sensitive   = true
}

output "ssh_user" {
  description = "SSH username for EC2 instances"
  value       = local.ssh_user
}

output "os_variant" {
  description = "OS variant used for this deployment"
  value       = var.os_variant
}

# ─── SSH Commands (for convenience) ───

output "ssh_tantor" {
  description = "SSH command to connect to Tantor server"
  value       = "ssh -i tantor-key.pem ${local.ssh_user}@${aws_instance.tantor_server.public_ip}"
}

output "ssh_kafka_nodes" {
  description = "SSH commands to connect to Kafka nodes"
  value = [
    for i, instance in aws_instance.kafka_node :
    "ssh -i tantor-key.pem ${local.ssh_user}@${instance.public_ip}  # kafka-${i + 1}"
  ]
}
