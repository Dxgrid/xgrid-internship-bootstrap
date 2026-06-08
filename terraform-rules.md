# Terraform IaC Rules for Claude Code

> These rules must be followed **strictly and without exception** when generating, modifying, or reviewing any Terraform Infrastructure as Code. No rule may be skipped unless explicitly overridden by the user in the current session.

---

## 1. FILE & MODULE STRUCTURE

- Always split configurations into distinct files per function:
  - `main.tf` → resource declarations and module calls
  - `variables.tf` → all variable declarations
  - `outputs.tf` → all output declarations
  - `providers.tf` → provider and version configuration
- Always create a separate directory per environment (`dev/`, `staging/`, `prod/`), each with its own `main.tf`, `variables.tf`, and backend config.
- Always encapsulate reusable infrastructure patterns into named modules (e.g., `modules/network/`, `modules/compute/`).
- Always use named arguments when calling modules. Never use positional arguments.

```hcl
# ✅ Correct
module "network" {
  source      = "./modules/network"
  vpc_cidr    = var.vpc_cidr
  environment = var.environment
}

# ❌ Wrong
module "network" {
  source = "./modules/network"
  "10.0.0.0/16"
  "dev"
}
```

---

## 2. NAMING CONVENTIONS

- Always use `snake_case` for all identifiers: filenames, resource names, variable names, output names, and module names.
- Always keep names descriptive but concise. Avoid verbose names.

```hcl
# ✅ Correct
resource "aws_security_group" "web_sg" {}

# ❌ Wrong
resource "aws_security_group" "SecurityGroupForWebServers" {}
```

- Always apply standard tags to every resource. At minimum include:

```hcl
tags = merge(
  local.default_tags,
  {
    Name        = "my-resource"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
)
```

---

## 3. VARIABLES & OUTPUTS

- Always declare an explicit `type` for every variable (`string`, `number`, `bool`, `list(string)`, `map(string)`, etc.).
- Always include a `description` for every variable and every output — no exceptions.
- Always add `validation` blocks to variables where the value must conform to a specific set or pattern.

```hcl
variable "instance_type" {
  type        = string
  description = "EC2 instance type. Only t2.micro and t2.small are permitted."
  validation {
    condition     = contains(["t2.micro", "t2.small"], var.instance_type)
    error_message = "Invalid instance type. Must be t2.micro or t2.small."
  }
}
```

- Only set `default` values for variables when a safe fallback genuinely exists. Never use defaults to mask required configuration.
- Always mark sensitive variables and outputs with `sensitive = true`.
- Never assume `sensitive = true` hides the value from the state file — treat state as potentially readable.

---

## 4. STATE MANAGEMENT

- Always use a remote backend (AWS S3 + DynamoDB, Terraform Cloud, Consul) — never rely on local state for shared or production infrastructure.
- Always enable state encryption at rest (e.g., `encrypt = true` with AWS KMS on S3 backends).
- Always enable state locking (e.g., DynamoDB table for S3 backend) to prevent concurrent modification corruption.
- Always enable versioning on the state storage backend (e.g., S3 bucket versioning) for rollback capability.
- Use Terraform workspaces or fully separate directories to isolate environments. Never share state across environments.
- Never manually edit `terraform.tfstate`. Always use CLI commands for state manipulation:
  - `terraform state mv`
  - `terraform state rm`
  - `terraform state list`
- Never run `terraform state push` unless absolutely necessary — it is a destructive, high-risk operation.

---

## 5. PROVIDERS & VERSIONS

- Always declare all required providers in a `required_providers` block with explicit version constraints.
- Always pin provider versions using the `~>` pessimistic constraint operator to allow patch updates but block breaking changes.

```hcl
terraform {
  required_version = "~> 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
```

- Never omit the `required_version` constraint for the Terraform CLI itself.
- Always commit the `.terraform.lock.hcl` file to version control to guarantee consistent provider versions across all runs.

---

## 6. RESOURCE DESIGN RULES

- Always declare required arguments before optional arguments within a resource block.
- Use `count` for simple conditional resource creation based on boolean flags or environment checks.

```hcl
resource "aws_instance" "bastion" {
  count = var.environment == "production" ? 1 : 0
  # ...
}
```

- Use `for_each` (not `count`) when creating multiple resources from a map or set, to avoid index-based state drift.

```hcl
resource "aws_iam_user" "team" {
  for_each = toset(var.team_members)
  name     = each.value
}
```

- Use `dynamic` blocks to generate repeated nested configuration blocks.
- Always prefer Terraform's implicit dependency graph over explicit `depends_on`.
- Only use `depends_on` when a dependency is invisible to Terraform (e.g., API readiness, cross-module ordering).
- Always use `data` sources to reference existing infrastructure instead of hardcoding resource IDs or ARNs.

---

## 7. SECURITY RULES

- Never hardcode secrets, passwords, API keys, tokens, or credentials anywhere in `.tf` files.
- Always inject secrets dynamically via a KMS or secrets manager:

```hcl
data "vault_generic_secret" "api_key" {
  path = "secret/myapp"
}
```

- Always follow least-privilege principles when defining IAM roles, policies, and security groups.
- Always implement Policy as Code (Sentinel or OPA) in pipelines to enforce security guardrails.
- Always mark sensitive input variables and outputs with `sensitive = true`.
- Never store secrets in `.tfvars` files committed to version control. Use environment variables or a secrets backend instead.

---

## 8. CI/CD & WORKFLOW RULES

- Always run these commands in order before any `apply`:
  1. `terraform fmt -recursive` — enforce formatting
  2. `terraform validate` — check syntax and schema
  3. `terraform plan` — review all changes before applying

- Always review the full `terraform plan` output. Treat any unintended resource **destruction** as a blocker — stop and investigate.
- Always integrate `terraform plan -refresh-only` into CI/CD pipelines to detect infrastructure drift and fail the build if drift is found.
- Only use `-target` for isolated debugging or emergency hotfixes. Never make `-target` part of standard deployment workflows — it causes state divergence.
- Never run `terraform apply` without a preceding reviewed plan in shared or production environments.

---

## 9. DOCUMENTATION RULES

- Always write inline comments (`#`) to explain **why** a decision was made, not what the code does (the code should speak for itself).
- Always include a `README.md` for every published or reusable module containing:
  - Purpose of the module
  - All input variables (name, type, description, required/optional)
  - All outputs (name, description)
  - Usage example
- Always document non-obvious `depends_on` usage with a comment explaining the invisible dependency.

---

## 10. ANTI-PATTERNS — NEVER DO THESE

| # | Anti-Pattern | Why It's Forbidden |
|---|---|---|
| 1 | Hardcoding secrets or credentials in `.tf` files | Security breach risk |
| 2 | Manually editing `terraform.tfstate` | Corrupts state irreversibly |
| 3 | Using positional arguments in module calls | Breaks readability and refactoring |
| 4 | Skipping `terraform plan` before `terraform apply` | Risk of accidental destruction |
| 5 | Assuming `sensitive = true` hides data from state | False security assumption |
| 6 | Using `terraform state push` routinely | Can overwrite and corrupt remote state |
| 7 | Hardcoding resource IDs or AMI IDs | Breaks portability; use `data` sources |
| 8 | Sharing state files across environments | Causes cross-environment blast radius |
| 9 | Using `count` for map-based resources | Use `for_each` to prevent index drift |
| 10 | Omitting version constraints on providers | Causes unpredictable, unreproducible builds |
| 11 | Committing `.tfvars` with secrets to version control | Exposes secrets in git history |
| 12 | Using `-target` as standard deployment practice | Causes state to diverge from real infra |

---

*Generated from HashiCorp Terraform exam study material. Last reviewed: 2026.*
