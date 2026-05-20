# ConfigDashboard.ps1
# ---------------------------------------------------------------------------
# Dashboard configuration variables.
# This script is dot-sourced by New-AzDashboardGenerator.ps1 so every
# variable defined here becomes available in the caller's scope.
#
# Usage:
#   . .\ConfigDashboard.ps1          (dot-source manually)
#   Handled automatically when running New-AzDashboardGenerator.ps1
# ---------------------------------------------------------------------------

# Display name embedded in the generated dashboard ARM template
$WORKBOOK_NAME = "DashboardMVP"

# Azure resource identifier used in the generated dashboard ARM template
$RESOURCE_NAME = "AZ_ID"
