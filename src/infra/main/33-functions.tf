##
## SNS topic and lambda for email and Slack notifications
##

resource "aws_sns_topic" "notifications" {
  name = "ca-eng-pagopa-it-notifications-topic"
}

resource "aws_sns_topic_subscription" "notifications" {
  topic_arn = aws_sns_topic.notifications.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.notifications_handler.arn
}

##
## Zip lambdas
##

data "archive_file" "notifications_handler_zip" {
  type        = "zip"
  source_dir  = "${local.relative_path_app}/notifications-handler/"
  output_path = "${local.full_path_root_project}/notifications_handler.zip"
}

data "archive_file" "expiring_cert_checker_zip" {
  type        = "zip"
  source_dir  = "${local.relative_path_app}/expiring-cert-checker/"
  output_path = "${local.full_path_root_project}/expiring_cert_checker.zip"
}

##
## Lambda functions
##

resource "aws_lambda_function" "notifications_handler" {
  depends_on       = [data.archive_file.notifications_handler_zip]
  runtime          = "python${local.python_version}"
  function_name    = "notifications_handler"
  role             = aws_iam_role.notifications_handler.arn
  filename         = data.archive_file.notifications_handler_zip.output_path
  source_code_hash = data.archive_file.notifications_handler_zip.output_base64sha256
  handler          = "main.handler"
  timeout          = 6 # we have 3s for SMTP connection
  environment {
    variables = {
      "ENV"                = upper("${var.environment}")
      "SLACK_CHANNEL"      = var.slack_channel_name
      "SLACK_USERNAME"     = "Internal CA Notifier"
      "SLACK_WEBHOOK"      = data.aws_ssm_parameter.slack_webhook.value
      "SMTP_HOST"          = "smtp.gmail.com"
      "SMTP_PORT"          = "587"
      "SMTP_USERNAME"      = var.environment == "prod" ? data.aws_ssm_parameter.smtp_username[0].value : "dummy"
      "SMTP_PASSWORD"      = var.environment == "prod" ? data.aws_ssm_parameter.smtp_password[0].value : "dummy"
      "AWS_DYNAMODB_TABLE" = aws_dynamodb_table.certificate_information.name
    }
  }
}

resource "aws_lambda_function" "expiring_cert_checker" {
  depends_on       = [data.archive_file.expiring_cert_checker_zip]
  runtime          = "python${local.python_version}"
  function_name    = "expiring_cert_checker"
  role             = aws_iam_role.expiring_cert_checker.arn
  filename         = data.archive_file.expiring_cert_checker_zip.output_path
  source_code_hash = data.archive_file.expiring_cert_checker_zip.output_base64sha256
  handler          = "main.handler"
  timeout          = 6 # we have 3s for DynamoDB and SNS connections
  environment {
    variables = {
      "AWS_SNS_TOPIC"                      = aws_sns_topic.notifications.arn
      "AWS_DYNAMODB_TABLE"                 = aws_dynamodb_table.certificate_information.name
      "AWS_DYNAMODB_TABLE_SECONDARY_INDEX" = aws_dynamodb_table.certificate_information.global_secondary_index.*.name[0]
    }
  }
}





##
## Roles and policies
##

resource "aws_iam_role" "expiring_cert_checker" {
  name               = "expiring_cert_checker"
  assume_role_policy = data.aws_iam_policy_document.expiring_cert_checker.json
  tags               = var.tags
}

data "aws_iam_policy_document" "expiring_cert_checker" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "allow_publish_sns_expiring_cert_checker" {
  name   = "allow_publish_sns_expiring_cert_checker"
  policy = data.aws_iam_policy_document.allow_publish_sns_expiring_cert_checker.json
  role   = aws_iam_role.expiring_cert_checker.id
}

data "aws_iam_policy_document" "allow_publish_sns_expiring_cert_checker" {
  statement {
    effect = "Allow"
    actions = [
      "SNS:Publish"
    ]
    resources = [
      "${aws_sns_topic.notifications.arn}"
    ]
  }
}

resource "aws_iam_role_policy" "cw_logs_expiring_cert_checker" {
  name   = "cw_logs_expiring_cert_checker"
  policy = data.aws_iam_policy_document.cw_logs_expiring_cert_checker.json
  role   = aws_iam_role.expiring_cert_checker.name
}

data "aws_iam_policy_document" "cw_logs_expiring_cert_checker" {
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
      "logs:PutLogEvents",
      "logs:GetLogEvents",
      "logs:FilterLogEvents"
    ]
    resources = [
      "${aws_cloudwatch_log_group.functions_expiring_cert_checker.arn}:*"
    ]
  }
}

resource "aws_iam_role" "notifications_handler" {
  name               = "notifications_handler"
  assume_role_policy = data.aws_iam_policy_document.notifications_handler.json
  tags               = var.tags
}

data "aws_iam_policy_document" "notifications_handler" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "cw_logs_notifications_handler" {
  name   = "cw_logs_notifications_handler"
  policy = data.aws_iam_policy_document.cw_logs_notifications_handler.json
  role   = aws_iam_role.notifications_handler.name
}

data "aws_iam_policy_document" "cw_logs_notifications_handler" {
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
      "logs:PutLogEvents",
      "logs:GetLogEvents",
      "logs:FilterLogEvents"
    ]
    resources = [
      "${aws_cloudwatch_log_group.functions_notifications_handler.arn}:*"
    ]
  }
}

resource "aws_iam_role_policy" "dynamodb_table_write" {
  name   = "dynamodb_table_write"
  policy = data.aws_iam_policy_document.dynamodb_table_write.json
  role   = aws_iam_role.notifications_handler.name
}

data "aws_iam_policy_document" "dynamodb_table_write" {
  statement {
    effect = "Allow"
    actions = [
      "dynamodb:PutItem",
      "dynamodb:DeleteItem"
    ]
    resources = [
      "${aws_dynamodb_table.certificate_information.arn}",
    ]
  }
}

resource "aws_iam_role_policy" "dynamodb_table_read_scan" {
  name   = "dynamodb_table_read_scan"
  policy = data.aws_iam_policy_document.dynamodb_table_read_scan.json
  role   = aws_iam_role.expiring_cert_checker.name
}

data "aws_iam_policy_document" "dynamodb_table_read_scan" {
  statement {
    effect = "Allow"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:Scan",
      "dynamodb:Query"
    ]
    resources = [
      "${aws_dynamodb_table.certificate_information.arn}/index/${aws_dynamodb_table.certificate_information.global_secondary_index.*.name[0]}"
    ]
  }
}

##
## Trigger lambda from SNS
##
resource "aws_lambda_permission" "sns" {
  statement_id  = "AllowExecutionFromSNS"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.notifications_handler.arn
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.notifications.arn
}

##
## Trigger lambda from Event Bridge hourly
##

resource "aws_cloudwatch_event_rule" "hourly_event" {
  name                = "hourly_event"
  schedule_expression = "rate(1 hour)"
}

resource "aws_cloudwatch_event_target" "invoke_expiring_cert_checker" {
  rule      = aws_cloudwatch_event_rule.hourly_event.name
  target_id = "expiring_cert_checker"
  arn       = aws_lambda_function.expiring_cert_checker.arn
}

resource "aws_lambda_permission" "event_bridge" {
  statement_id  = "AllowExecutionFromCloudwatch"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.expiring_cert_checker.arn
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.hourly_event.arn
}

##
## Cloudwatch log groups (each lambda function will create a log stream on update)
##

resource "aws_cloudwatch_log_group" "functions_expiring_cert_checker" {
  name              = "/lambda/${aws_lambda_function.expiring_cert_checker.function_name}"
  retention_in_days = 90
}

resource "aws_cloudwatch_log_group" "functions_notifications_handler" {
  name              = "/lambda/${aws_lambda_function.notifications_handler.function_name}"
  retention_in_days = 90
}
