terraform {
  required_version = ">= 0.12.0"
  required_providers {
    aws    = ">= 2.48.0"
    random = ">= 2.2"
  }
}

data "aws_partition" "current" {}

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}


##########################################################################
#                                                                        #
#                               KMS Key                                  #
#                                                                        #
##########################################################################

resource "aws_kms_key" "marbot" {
  description         = "KMS CMK for ${var.module_name}"
  enable_key_rotation = true
  tags                = var.tags
}

resource "aws_kms_alias" "marbot" {
  name          = "alias/${var.module_name}"
  target_key_id = aws_kms_key.marbot.key_id
}


##########################################################################
#                                                                        #
#                                 TOPIC                                  #
#                                                                        #
##########################################################################

resource "aws_sns_topic" "marbot" {
  count = var.enabled ? 1 : 0

  name_prefix       = "marbot"
  kms_master_key_id = aws_kms_alias.marbot.arn
  tags              = var.tags
}

resource "aws_sns_topic_policy" "marbot" {
  count = var.enabled ? 1 : 0

  arn    = join("", aws_sns_topic.marbot.*.arn)
  policy = data.aws_iam_policy_document.topic_policy.json
}

data "aws_iam_policy_document" "topic_policy" {
  statement {
    sid       = "Sid1"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [join("", aws_sns_topic.marbot.*.arn)]

    principals {
      type = "Service"
      identifiers = [
        "events.amazonaws.com",
        "rds.amazonaws.com",
      ]
    }
  }

  statement {
    sid       = "Sid2"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [join("", aws_sns_topic.marbot.*.arn)]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceOwner"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_sns_topic_subscription" "marbot" {
  depends_on = [aws_sns_topic_policy.marbot]
  count      = var.enabled ? 1 : 0

  topic_arn              = join("", aws_sns_topic.marbot.*.arn)
  protocol               = "https"
  endpoint               = "https://api.marbot.io/${var.stage}/endpoint/${var.endpoint_id}"
  endpoint_auto_confirms = true
  delivery_policy        = <<JSON
{
  "healthyRetryPolicy": {
    "minDelayTarget": 1,
    "maxDelayTarget": 60,
    "numRetries": 100,
    "numNoDelayRetries": 0,
    "backoffFunction": "exponential"
  },
  "throttlePolicy": {
    "maxReceivesPerSecond": 1
  }
}
JSON
}

resource "aws_cloudwatch_event_rule" "monitoring_jump_start_connection" {
  depends_on = [aws_sns_topic_subscription.marbot]
  count      = var.enabled ? 1 : 0

  name                = "marbot-rds-cluster-connection-${random_id.id8.hex}"
  description         = "Monitoring Jump Start connection. (created by marbot)"
  schedule_expression = "rate(30 days)"
  tags                = var.tags
}

resource "aws_cloudwatch_event_target" "monitoring_jump_start_connection" {
  count = var.enabled ? 1 : 0

  rule      = join("", aws_cloudwatch_event_rule.monitoring_jump_start_connection.*.name)
  target_id = "marbot"
  arn       = join("", aws_sns_topic.marbot.*.arn)
  input     = <<JSON
{
  "Type": "monitoring-jump-start-tf-connection",
  "Module": "rds-cluster",
  "Version": "0.7.3",
  "Partition": "${data.aws_partition.current.partition}",
  "AccountId": "${data.aws_caller_identity.current.account_id}",
  "Region": "${data.aws_region.current.name}"
}
JSON
}

##########################################################################
#                                                                        #
#                                 ALARMS                                 #
#                                                                        #
##########################################################################

resource "random_id" "id8" {
  byte_length = 8
}

resource "aws_cloudwatch_metric_alarm" "cpu_utilization" {
  depends_on = [aws_sns_topic_subscription.marbot]
  count      = (var.cpu_utilization_threshold >= 0 && var.enabled) ? 1 : 0

  alarm_name          = "marbot-rds-cluster-cpu-utilization-${random_id.id8.hex}"
  alarm_description   = "Average database CPU utilization over last 10 minutes too high. (created by marbot)"
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 600
  evaluation_periods  = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.cpu_utilization_threshold
  alarm_actions       = [join("", aws_sns_topic.marbot.*.arn)]
  ok_actions          = [join("", aws_sns_topic.marbot.*.arn)]
  dimensions          = local.db-type["db-instance"]
  treat_missing_data  = var.treat_missing_data
  tags                = var.tags
}



resource "aws_cloudwatch_metric_alarm" "cpu_credit_balance" {
  depends_on = [aws_sns_topic_subscription.marbot]
  count      = (var.cpu_credit_balance_threshold >= 0 && var.burst_monitoring_enabled && var.enabled) ? 1 : 0

  alarm_name          = "marbot-rds-cluster-cpu-credit-balance-${random_id.id8.hex}"
  alarm_description   = "Average database CPU credit balance over last 10 minutes too low, expect a significant performance drop soon. (created by marbot)"
  namespace           = "AWS/RDS"
  metric_name         = "CPUCreditBalance"
  statistic           = "Average"
  period              = 600
  evaluation_periods  = 1
  comparison_operator = "LessThanThreshold"
  threshold           = var.cpu_credit_balance_threshold
  alarm_actions       = [join("", aws_sns_topic.marbot.*.arn)]
  ok_actions          = [join("", aws_sns_topic.marbot.*.arn)]
  dimensions          = local.db-type["db-instance"]
  treat_missing_data  = var.treat_missing_data
  tags                = var.tags
}

resource "aws_cloudwatch_metric_alarm" "free_storage_space" {
  depends_on = [aws_sns_topic_subscription.marbot]
  count      = (var.free_storage_space_threshold >= 0 && var.enabled) ? 1 : 0

  alarm_name          = "marbot-rds-cluster-free_storage_space-${random_id.id8.hex}"
  alarm_description   = "Average database free storage space over last 10 minutes too low, should be investigated as a priority. (created by marbot)"
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  statistic           = "Average"
  period              = 600
  evaluation_periods  = 1
  comparison_operator = "LessThanThreshold"
  threshold           = var.free_storage_space_threshold
  alarm_actions       = [join("", aws_sns_topic.marbot.*.arn)]
  ok_actions          = [join("", aws_sns_topic.marbot.*.arn)]
  dimensions          = local.db-type["db-instance"]
  treat_missing_data  = var.treat_missing_data
  tags                = var.tags
}

resource "aws_cloudwatch_metric_alarm" "freeable_memory" {
  depends_on = [aws_sns_topic_subscription.marbot]
  count      = (var.freeable_memory_threshold >= 0 && var.enabled) ? 1 : 0

  alarm_name          = "marbot-rds-cluster-freeable-memory-${random_id.id8.hex}"
  alarm_description   = "Average database freeable memory over last 10 minutes too low, performance may suffer. (created by marbot)"
  namespace           = "AWS/RDS"
  metric_name         = "FreeableMemory"
  statistic           = "Average"
  period              = 600
  evaluation_periods  = 1
  comparison_operator = "LessThanThreshold"
  threshold           = var.freeable_memory_threshold
  alarm_actions       = [join("", aws_sns_topic.marbot.*.arn)]
  ok_actions          = [join("", aws_sns_topic.marbot.*.arn)]
  dimensions          = local.db-type["db-instance"]
  treat_missing_data  = var.treat_missing_data
  tags                = var.tags
}

resource "aws_cloudwatch_metric_alarm" "db_connections" {
  depends_on = [aws_sns_topic_subscription.marbot]
  count      = (var.db_connection_threshold >= 0 && var.enabled) ? 1 : 0

  alarm_name          = "marbot-rds-cluster-db-connections-${random_id.id8.hex}"
  alarm_description   = "Less than usual connections, If a known outage or release is not taking place right now, there may be an issue with connectivity of the app to the RDS instance. (created by marbot)"
  namespace           = "AWS/RDS"
  metric_name         = "DatabaseConnections"
  statistic           = "Average"
  period              = 600
  evaluation_periods  = 1
  comparison_operator = "LessThanThreshold"
  threshold           = var.db_connection_threshold
  alarm_actions       = [join("", aws_sns_topic.marbot.*.arn)]
  ok_actions          = [join("", aws_sns_topic.marbot.*.arn)]
  dimensions          = local.db-type["db-instance"]
  treat_missing_data  = var.treat_missing_data
  tags                = var.tags
}

##########################################################################
#                                                                        #
#                                 EVENTS                                 #
#                                                                        #
##########################################################################

resource "aws_db_event_subscription" "rds_cluster_issue" {
  depends_on = [aws_sns_topic_subscription.marbot]
  count      = var.enabled ? 1 : 0

  sns_topic   = join("", aws_sns_topic.marbot.*.arn)
  source_type = var.deployment-type
  source_ids  = [var.db_cluster_identifier]
  tags        = var.tags
}
