# Reports which revision of the monitoring-agent setup this computer runs, as InfluxDB line protocol for Telegraf's exec
# input. scripts/monitoring-autoupdate.sh compares it with this file in the repository and re-installs any computer that is
# behind. RAISE THE NUMBER whenever telegraf.conf.tmpl, a helper script or the installer changes in a way computers need.
# ASCII only: Windows PowerShell 5.1 mis-reads UTF-8 scripts that have no byte-order mark.
Write-Output 'agent_info rev=4i'
