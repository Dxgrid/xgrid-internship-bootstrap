# Map of activity env var name → service URL, e.g.
# { FRAUD_SERVICE_URL = "http://fraud.temporal-order-dev.local:8000", ... }
# Passed straight into the worker task definition environment.
output "service_urls" {
  description = "Env-var-name → Cloud Map URL for each dependency service, for the worker environment."
  value = {
    for name, env_var in local.services :
    env_var => "http://${name}.${var.cloudmap_namespace_name}:${var.container_port}"
  }
}
