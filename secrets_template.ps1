# Template file for backup destination configuration and healthchecks url.
# Update this file to point to your restic repository and healthchecks url.
# Rename to `secrets.ps1`

# restic backup repository configuration
$Env:AWS_ACCESS_KEY_ID='<KEY>'
$Env:AWS_SECRET_ACCESS_KEY='<KEY>'
$Env:RESTIC_REPOSITORY='<REPO URL>'
$Env:RESTIC_PASSWORD='<BACKUP PASSWORD>'

# healtchecks configuration
$HealthcheckUrl=https://hc-ping.com/your-uuid-here
