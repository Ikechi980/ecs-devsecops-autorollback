output "alb_url" {
  description = "Application URL."
  value       = "${local.https_enabled ? "https" : "http"}://${aws_lb.main.dns_name}"
}
