resource "aws_cloudwatch_metric_alarm" "alarm" {
  alarm_name          = var.alarm_name
  comparison_operator = var.comparison_operator
  evaluation_periods  = var.evaluation_periods
  metric_name         = var.metric_name
  namespace           = var.namespace
  period              = var.period
  statistic           = var.statistic != null && var.statistic != "" ? var.statistic : null
  extended_statistic  = var.extended_statistic != null && var.extended_statistic != "" ? var.extended_statistic : null
  threshold           = var.threshold
  alarm_description   = var.alarm_description
  alarm_actions       = var.alarm_actions
  ok_actions          = var.ok_actions
  dimensions          = var.dimensions
  treat_missing_data  = var.treat_missing_data

  tags = merge(
    {
      Name = var.alarm_name
    },
    var.tags
  )
}
