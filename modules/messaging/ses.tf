# ==========================================================================
# SES sending identity — §10.1
# ==========================================================================
# Reuses the frontend's existing domain (hisaab.<parent_domain>) rather than
# minting a new subdomain just for mail — one less DNS surface to manage.
# Domain identity + DKIM, both verified via records Terraform writes into
# the existing shared hosted zone and waits on — same "create and validate
# via DNS, never by hand" pattern already used for the ACM certs
# (modules/network). Not automatable end-to-end, though: a fresh AWS
# account's SES is in sandbox mode and can only send to *verified
# recipient* addresses until AWS grants production access via a manual
# console/support-case request — nothing Terraform can do about that part.

resource "aws_ses_domain_identity" "hisaab" {
  domain = "hisaab.${var.parent_domain}"
}

resource "aws_route53_record" "ses_verification" {
  zone_id = var.hosted_zone_id
  name    = "_amazonses.hisaab.${var.parent_domain}"
  type    = "TXT"
  ttl     = 600
  records = [aws_ses_domain_identity.hisaab.verification_token]
}

resource "aws_ses_domain_identity_verification" "hisaab" {
  domain     = aws_ses_domain_identity.hisaab.id
  depends_on = [aws_route53_record.ses_verification]
}

resource "aws_ses_domain_dkim" "hisaab" {
  domain = aws_ses_domain_identity.hisaab.domain
}


# for_each can't iterate the dkim_tokens list directly — its values (though
# not its length) are only known after apply, and Terraform needs for_each
# keys known at plan time. SES always issues exactly 3 DKIM tokens per
# domain identity (stable, documented AWS behavior) — for_each over a
# static index set sidesteps the problem entirely.
resource "aws_route53_record" "ses_dkim" {
  for_each = toset(["0", "1", "2"])

  zone_id = var.hosted_zone_id
  name    = "${aws_ses_domain_dkim.hisaab.dkim_tokens[tonumber(each.value)]}._domainkey.hisaab.${var.parent_domain}"
  type    = "CNAME"
  ttl     = 600
  records = ["${aws_ses_domain_dkim.hisaab.dkim_tokens[tonumber(each.value)]}.dkim.amazonses.com"]
}

# ==========================================================================
# Per-user recipient verification — §10.1
# ==========================================================================
# The account's SES sending is in sandbox mode (verified the hard way: a
# real invite notification got AccessDenied, then — after fixing that IAM
# gap — MessageRejected: "Email address is not verified"). Sandbox mode
# only allows sending to individually-verified recipient addresses;
# requesting full production access is a manual AWS review outside
# Terraform's control. Rather than block on that, fn-post-confirmation
# verifies every new user's address at signup via ses:VerifyEmailIdentity
# (modules/messaging/src/post_confirmation/index.py) — the standard way to
# run indefinitely in sandbox mode without ever needing production access
# approved.
#
# A custom-branded verification template ("hisaab-verify-recipient") was
# built and is still live in the account via a one-time
# `aws ses create-custom-verification-email-template` CLI call (no
# Terraform resource for this API exists at all — confirmed directly
# against the installed provider's schema, hashicorp/aws 6.56.0), but it's
# NOT what the Lambda actually calls: SendCustomVerificationEmail itself
# turned out to require production access to use at all
# ("ProductionAccessNotGranted"), which defeats the entire point for a
# sandboxed account. The plain, unbranded VerifyEmailIdentity API is the
# one that genuinely works pre-production-access. The custom template is
# left in place, unused for now — worth switching back to once production
# access is actually granted, for a nicer-looking email.
#
# One content restriction confirmed the hard way while building that
# now-unused template, worth keeping in case it's revived later: this
# specific SES API rejects any <a> tag in the template body at all
# ("Disallowed tags: <{a}>") — content that was byte-for-byte identical
# minus the <a> tag succeeded instantly. The
# {{RegistrationConfirmationURL}} placeholder has to render as plain text;
# there's no clickable button, just a URL most email clients auto-link on
# their own.
