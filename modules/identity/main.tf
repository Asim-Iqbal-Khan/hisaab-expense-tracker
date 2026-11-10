data "aws_caller_identity" "current" {}

locals {
  # fn-post-confirmation doesn't exist until modules/messaging (phase 6).
  # Lambda ARNs are deterministic given account/region/function name, so the
  # trigger can be wired now — same trick used for ECR/SNS/S3 ARNs in
  # modules/security. modules/messaging must create the function under this
  # exact name, and grant Cognito invoke permission on it.
  post_confirmation_lambda_arn = "arn:aws:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:function:${var.post_confirmation_function_name}"
}

# ==========================================================================
# Cognito user pool — §9.1
# ==========================================================================

resource "aws_cognito_user_pool" "hisaab" {
  name = "hisaab-user-pool"

  alias_attributes         = ["email", "preferred_username"]
  auto_verified_attributes = ["email"]

  schema {
    name                     = "email"
    attribute_data_type      = "String"
    developer_only_attribute = false
    required                 = true
    mutable                  = true

    string_attribute_constraints {
      min_length = "0"
      max_length = "2048"
    }
  }

  # Not required: Cognito hard-blocks setting an alias-configured
  # preferred_username during sign-up itself ("Preferred username cannot
  # be provided for unconfirmed account") — confirmed the hard way via the
  # Hosted UI. Cognito's Hosted UI sign-up form only surfaces required
  # attributes, so leaving this optional stops it from being collected (and
  # rejected) at signup at all. fn-post-confirmation already tolerates a
  # missing preferred_username and derives a username from the email
  # instead; users can set their own later via UpdateUserAttributes, once
  # confirmed, from a profile screen (not yet built).
  schema {
    name                     = "preferred_username"
    attribute_data_type      = "String"
    developer_only_attribute = false
    required                 = false
    mutable                  = true

    string_attribute_constraints {
      min_length = "0"
      max_length = "2048"
    }
  }

  password_policy {
    minimum_length    = 8
    require_uppercase = true
    require_lowercase = true
    require_numbers   = true
    require_symbols   = false
  }

  mfa_configuration = "OPTIONAL"

  software_token_mfa_configuration {
    enabled = true
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  lambda_config {
    post_confirmation = local.post_confirmation_lambda_arn
  }

  tags = {
    Name    = "hisaab-user-pool"
    Project = "hisaab"
  }

  # Cognito flatly rejects any modification to schema attributes after
  # creation ("cannot modify or remove schema items") — confirmed the hard
  # way, including for changes that are purely cosmetic from Terraform's
  # side (e.g. re-declaring the same attributes after a pool recreation
  # produces a spurious diff, since AWS's actual response includes fields
  # like string_attribute_constraints that aren't fully representable back
  # in HCL). Since schema can only ever be set at creation regardless, and
  # any real change requires -replace on this whole resource anyway,
  # there's no reason to let Terraform keep re-litigating drift on it.
  lifecycle {
    ignore_changes = [schema]
  }
}

# ==========================================================================
# App client — §9.2
# ==========================================================================
# No Hosted UI domain and no OAuth-redirect config here (allowed_oauth_*,
# callback_urls, logout_urls, supported_identity_providers) — auth is
# frontend-driven: the SPA calls Cognito's InitiateAuth API directly with
# USER_PASSWORD_AUTH and sends the resulting ID token to the API as a
# Bearer header. explicit_auth_flows is what that direct-API flow actually
# needs; the OAuth/redirect attributes above were Hosted-UI-only and are
# unused now that nothing redirects through it.

resource "aws_cognito_user_pool_client" "web" {
  name         = "hisaab-web-client"
  user_pool_id = aws_cognito_user_pool.hisaab.id

  generate_secret = false # Public SPA client, no secret

  explicit_auth_flows = ["ALLOW_USER_PASSWORD_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"]

  prevent_user_existence_errors = "ENABLED"

  access_token_validity  = 1
  id_token_validity      = 1
  refresh_token_validity = 30

  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "days"
  }
}
