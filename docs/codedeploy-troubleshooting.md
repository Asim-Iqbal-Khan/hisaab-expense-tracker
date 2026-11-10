# CodeDeploy blue/green deployment failure — investigation log

## Summary

The app pipeline's Deploy stage (CodeDeploy, blue/green, EC2/"Server" platform)
consistently fails, even after fixing every real IAM permission gap we could find.
Status as of this writing: **unresolved, still investigating.**

## What we were trying to do

Get `pipe-hisaab-app` to actually deploy the backend to EC2, so the ALB-native Cognito
auth flow (built earlier) becomes testable end-to-end. The pipeline's Source and Build
stages work fine; Deploy is where this is stuck.

## The error, and why it's misleading

CodeDeploy's blue/green mechanism for EC2 (`green_fleet_provisioning_option =
COPY_AUTO_SCALING_GROUP`) copies `asg-hisaab-blue` into a temporary "green" ASG per
deployment, then shifts traffic and tears down the old one. To do that, the
`role-codedeploy` service role needs a chain of AWS permissions. Every attempt failed
with one of two errors:

- `IAM_ROLE_PERMISSIONS`: *"does not give you permission to perform operations in
  AmazonAutoScaling"* — a generic, unhelpful message that turned out to mask several
  different underlying causes at different points in the investigation.
- `AUTOSCALING_VALIDATION_ERROR`: *"Target group not attached to the Auto Scaling
  group"* — reached only after the permission gaps below were fixed.

## Investigation timeline (abbreviated)

1. **First failure**: `codedeploy:GetDeploymentConfig` was scoped only to AWS's
   `:aws:` pseudo-account namespace, but the real API call resolves it under the
   actual account ID. **Fixed** — added both ARN forms.
2. **Second failure**: generic AutoScaling permission error. Verified the attached
   managed policy (`AWSCodeDeployRole`) already grants full `autoscaling:*`. Tried
   attaching `AutoScalingFullAccess` (broadest possible grant for that whole service)
   as a diagnostic test — **identical error**, proving policy *content* wasn't the
   cause on that axis.
3. Checked for a permissions boundary (none), inline deny policies (none), an
   AutoScaling service-linked role (exists, long-standing), and service quotas (way
   under limit). All clean.
4. Checked Control Tower's control catalog for AutoScaling-related guardrails —
   everything there is detective (Config/SecurityHub, reports only) or proactive via
   CloudFormation hooks (doesn't apply — this isn't provisioned through
   CloudFormation). No evidence of an SCP blocking this.
5. **Diagnostic test**: attached `AdministratorAccess` to `role-codedeploy`. The error
   changed — to the `AUTOSCALING_VALIDATION_ERROR` above. This proved a real
   permission gap existed *somewhere outside the autoscaling: namespace itself*.
6. Identified and fixed two genuinely missing, AWS-documented permissions that
   `AWSCodeDeployRole` deliberately omits (because they depend on project-specific
   resource IDs it can't know in advance):
   - `iam:PassRole` on the EC2 instance profile role, scoped + conditioned to
     `ec2.amazonaws.com`.
   - `ec2:DescribeLaunchTemplates` / `DescribeLaunchTemplateVersions` — our ASG uses a
     launch template, and the managed policy's only EC2 grants are
     `DescribeInstances`/`DescribeInstanceStatus`/`TerminateInstances`.
   - Retried after each — same generic error persisted both times, meaning neither was
     sufficient alone.
7. **Direct test (bypassing CodeDeploy's wrapper)**: temporarily granted our own
   identity permission to assume `role-codedeploy`, then called the actual AWS API
   (`autoscaling:CreateAutoScalingGroup`) ourselves, as that role. Got a much more
   specific raw error: *"You are not authorized to use launch template."* This is a
   distinct IAM check from merely being able to *read* a launch template.
8. Added the correct fix per AWS's documentation for this exact error:
   `ec2:RunInstances`, scoped across the multiple resources that action's
   authorization evaluates together (launch template, AMI, instance, network
   interface, subnet, volume, security group) — plus `ec2:CreateTags` (needed
   separately, since our ASG has `propagate_at_launch = true` tags). **Retried through
   the real pipeline — got past the generic error entirely**, landing on the same
   `AUTOSCALING_VALIDATION_ERROR` that `AdministratorAccess` reached in step 5.
9. **Re-ran the direct-assume-role test** against this specific validation error —
   manually replicated the exact operation CodeDeploy needs (attach a target group to
   an ASG, both as one call and as two separate calls). **Both succeeded, twice.** The
   permissions are demonstrably sufficient.
10. Yet the real, pipeline-driven deployment still fails in ~3 seconds — too fast to
    be a genuine attempt at the operation. CodeDeploy's own internal pre-flight check
    is reporting failure even though the actual operation, performed for real,
    provably works.

## Current best understanding (superseded — see below, kept for the record)

At one point we suspected an AWS-internal permission-simulation anomaly specific to
this account (motivated by `iam:simulate-principal-policy` separately giving a false
`implicitDeny` for an S3 write we'd watched succeed for real). That theory didn't hold
up once we looked at CloudTrail directly.

## What CloudTrail actually showed

Querying CloudTrail for the exact 3-second failure window of a specific deployment
attempt (rather than trusting CodeDeploy's summarized error) revealed the real
sequence:

1. `CreateAutoScalingGroup` for the green ASG (`CodeDeploy_dg-hisaab-api_d-<id>`)
   **succeeded, no error** — created with `minSize/desiredCapacity: 0` and
   `TargetGroupARNs: []` (CodeDeploy's normal pattern: create bare, attach and scale up
   in later steps).
2. **No `AttachLoadBalancerTargetGroups` or `UpdateAutoScalingGroup` call was ever
   made** in the following seconds — CodeDeploy never even attempted the next step.
3. The deployment group's `alarm_configuration` references a CloudWatch alarm
   (`alb-5xx-high`) that **doesn't exist** — `modules/observability` (phase 10) was
   never built, and this reference was believed to be harmlessly inert (per the
   variable's own original comment: "won't trigger anything until phase 10 creates
   it"). Confirmed via `aws cloudwatch describe-alarms` that it genuinely doesn't exist.

Disabling the alarm didn't fix it — same error, same signature (`CreateAutoScalingGroup`
succeeds, then nothing). Neither did temporarily stripping the ALB listener back to a
single plain `forward` action (ruling out the newly-added Cognito auth as a cause).

## Root cause, actually found

The error message includes a real AWS Request ID
(`Request ID: 33218ea9-4993-464d-b6a9-799ed38829b9`). Rather than guessing at event
names, searching CloudTrail for every event in the failure window and grepping for
that exact ID found the real match: **`PutScalingPolicy`**, not any target-group-attach
call.

The full sequence: CodeDeploy creates the bare green ASG (no target group yet, by
design — it plans to attach one later). It then immediately tries to replicate the
source ASG's scaling policy onto the copy. This project's ASG uses a target-tracking
policy on **`ALBRequestCountPerTarget`** (per spec §6.2) — a metric that's intrinsically
tied to a specific target group. AWS correctly rejects creating that policy on an ASG
that isn't attached to a target group yet, which the green copy deliberately isn't at
that point in CodeDeploy's own sequencing. That `ValidationError` is genuine and
accurate — it's just about a different, earlier API call than the summary message
implies, which is what made this so hard to pin down.

**This is a real, structural incompatibility**: `ALBRequestCountPerTarget`-based
scaling policies cannot coexist with CodeDeploy's blue/green
`COPY_AUTO_SCALING_GROUP` mechanism for the EC2/Server platform, because that
mechanism always creates the copy before attaching it to a load balancer, and this
specific metric type requires the attachment to exist first. None of the IAM
permission gaps found earlier were the actual cause of *this* specific failure — they
were real, correct fixes for what would have been the *next* problem, had this one not
blocked everything first.

## Where this leaves us

Two ways forward, given the spec (§6.2) explicitly calls for `ALBRequestCountPerTarget`:

1. **Switch to `IN_PLACE` CodeDeploy deployments.** No ASG copy happens at all, so this
   conflict never arises — the existing ASG (already correctly attached, scaling
   policy and all) just gets its instances updated directly. Real tradeoff: loses
   zero-downtime blue/green cutover, deviates from the decision log.
2. **Keep blue/green, change or drop the scaling policy metric.** Directly deviates
   from the spec's explicit §6.2 value.

Neither is a silent fix — both directly contradict something the spec states
explicitly, so this needs a decision, not just an implementation.

## Resolution

Switched to CPU-based scaling (`ASGAverageCPUUtilization`), keeping blue/green
deployments intact. That fixed the structural blocker, but revealed a chain of
further, genuinely separate issues once CodeDeploy could actually get past ASG
creation — each one only visible once the previous was fixed:

1. `codedeploy:GetDeploymentConfig` scoped to the wrong account namespace.
2. Missing `iam:PassRole` on the EC2 instance role (needed to launch instances into
   the copied ASG with the right instance profile).
3. Missing `ec2:DescribeLaunchTemplate*` (the ASG uses a launch template, not a launch
   configuration; `AWSCodeDeployRole` doesn't cover this).
4. Missing `ec2:RunInstances`, and specifically multi-resource-scoped (launch
   template, AMI, instance, network interface, subnet, volume, security group) —
   scoping it to just the launch template wasn't sufficient.
5. Missing `ec2:CreateTags` for the ASG's `propagate_at_launch` tags.
6. A stale `image_tag` Terraform variable (`asim-hisaab`, a placeholder from before
   any real image existed) baked into the launch template — cold-boot instances were
   trying to pull a nonexistent image.
7. Missing `ecr:GetDownloadUrlForLayer` / `ecr:BatchCheckLayerAvailability` on the EC2
   role — `ecr:BatchGetImage` alone resolves the manifest but can't fetch layers.
8. No SSL config on the `pg.Pool` in `backend/src/db.ts` — RDS rejects unencrypted
   connections outright (`no pg_hba.conf entry ... no encryption`).
9. Missing `s3:GetObject` on the EC2 role for the CodePipeline artifacts bucket —
   `DownloadBundle` (CodeDeploy's own deploy-time step) runs as the EC2 instance role,
   not `role-codedeploy`, and had never been granted read access to the revision
   bundle.
10. `scripts/start.sh` used a bare relative path (`cat image_tag.txt`) that didn't
    match CodeDeploy's actual working directory when running lifecycle hooks — fixed
    by resolving relative to the script's own location instead.
11. `scripts/start.sh` wasn't idempotent: `ApplicationStop` doesn't run before a
    CodeDeploy instance's *first* install (nothing of CodeDeploy's own to stop yet),
    but the cold-boot container from `user_data.sh.tpl` already occupies the
    `hisaab-api` container name — causing a `docker run` naming conflict. Fixed by
    removing any existing container defensively before starting the new one.

Diagnostic technique that mattered most: once CodeDeploy's summary error text proved
unreliable/misleading multiple times over, correlating the **exact Request ID** in the
error message against unfiltered CloudTrail events in the failure window (rather than
guessing likely event names) was what actually found the true failing API call each
time. Direct SSM access to the actual EC2 instances (`docker ps`, container logs,
`/var/log/cloud-init-output.log`, the CodeDeploy agent's own log and script logs) was
what found everything after the ASG-copy stage — CodeDeploy's pipeline-level error
reporting never became detailed enough on its own to diagnose issues 6 through 11.

**Final result**: `pipe-hisaab-app` deploys successfully end to end — Source, Build,
and Deploy all succeed, target group instances go healthy, and the ALB-native Cognito
auth flow built earlier is live and working against a real deployment.

## Real fixes made along the way (all still in place, all correct regardless of outcome)

- `codedeploy:GetDeploymentConfig` — corrected resource ARN scoping
- `iam:PassRole` on the EC2 instance role, scoped and conditioned
- `ec2:DescribeLaunchTemplates` / `DescribeLaunchTemplateVersions`
- `ec2:RunInstances`, properly multi-resource-scoped
- `ec2:CreateTags`, scoped to launch-time tag propagation only

All in `modules/security/iam.tf` and `modules/compute/main.tf`.

## Open question / next steps

Still trying to pin down the exact mechanism CodeDeploy uses for its internal
pre-check, and whether there's any way to work around it, before falling back to an
`IN_PLACE` deployment (which would sidestep this entirely by never copying an ASG).
