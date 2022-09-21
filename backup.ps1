#
# Restic Windows Backup Script
#

# =========== start configuration =========== # 

# set restic configuration parmeters (destination, passwords, etc.)
$SecretsScript = Join-Path $PSScriptRoot "secrets.ps1"

# backup configuration variables
$ConfigScript = Join-Path $PSScriptRoot "config.ps1"

# =========== end configuration =========== #

# globals for state storage
$Script:ResticStateRepositoryInitialized = $null
$Script:ResticStateLastMaintenance = $null
$Script:ResticStateLastDeepMaintenance = $null
$Script:ResticStateMaintenanceCounter = $null
 
# Returns all drive letters which exactly match the serial number, drive label, or drive name of 
# the input parameter. Returns all drives if no input parameter is provided.
# inspiration: https://stackoverflow.com/questions/31088930/combine-get-disk-info-and-logicaldisk-info-in-powershell
function Get-Drives {
    Param($ID)

    foreach($disk in Get-CimInstance Win32_Diskdrive) {
        $diskMetadata = Get-Disk | Where-Object { $_.Number -eq $disk.Index } | Select-Object -First 1
        $partitions = Get-CimAssociatedInstance -ResultClassName Win32_DiskPartition -InputObject $disk

        foreach($partition in $partitions) {

            $drives = Get-CimAssociatedInstance -ResultClassName Win32_LogicalDisk -InputObject $partition

            foreach($drive in $drives) {
                    
                $volume = Get-Volume |
                          Where-Object { $_.DriveLetter -eq $drive.DeviceID.Trim(":") } |
                          Select-Object -First 1

                if(($diskMetadata.SerialNumber.trim() -eq $ID) -or 
                    ($disk.Caption -eq $ID) -or
                    ($volume.FileSystemLabel  -eq $ID) -or
                    ($null -eq $ID)) {
    
                    [PSCustomObject] @{
                        DriveLetter   = $drive.DeviceID
                        Number        = $disk.Index
                        Label         = $volume.FileSystemLabel
                        Manufacturer  = $diskMetadata.Manufacturer
                        Model         = $diskMetadata.Model
                        SerialNumber  = $diskMetadata.SerialNumber.trim()
                        Name          = $disk.Caption
                        FileSystem    = $volume.FileSystem
                        PartitionKind = $diskMetadata.PartitionStyle
                        Drive         = $drive
                        Partition     = $partition
                        Disk          = $disk
                    }
                }
            }
        }
    }
}

# restore backup state from disk
function Get-BackupState {
    if(Test-Path $StateFile) {
        Import-Clixml $StateFile | ForEach-Object{ Set-Variable -Scope Script $_.Name $_.Value }
    }
}
function Set-BackupState {
    Get-Variable ResticState* | Export-Clixml $StateFile
}

# unlock the repository if need be
function Invoke-Unlock {
    Param($SuccessLog, $ErrorLog)

    $locks = & $ResticExe list locks --no-lock -q 3>&1 2>> $ErrorLog
    if($locks.Length -gt 0) {
        # unlock the repository (assumes this machine is the only one that will ever use it)
        & $ResticExe unlock 3>&1 2>> $ErrorLog | Tee-Object -Append $SuccessLog
        Write-Output "[[Unlock]] Repository was locked. Unlocking. Past script failure?" | Tee-Object -Append $ErrorLog | Tee-Object -Append $SuccessLog
        Start-Sleep 120 
    }
}

# run maintenance on the backup set
function Invoke-Maintenance {
    Param($SuccessLog, $ErrorLog)
    
    # skip maintenance if disabled
    if($SnapshotMaintenanceEnabled -eq $false) {
        Write-Output "[[Maintenance]] Skipped - maintenance disabled" | Tee-Object -Append $SuccessLog
        return
    }

    # skip maintenance if it's been done recently
    if(($null -ne $ResticStateLastMaintenance) -and ($null -ne $ResticStateMaintenanceCounter)) {
        $Script:ResticStateMaintenanceCounter += 1
        $delta = New-TimeSpan -Start $ResticStateLastMaintenance -End $(Get-Date)
        if(($delta.Days -lt $SnapshotMaintenanceDays) -and ($ResticStateMaintenanceCounter -lt $SnapshotMaintenanceInterval)) {
            Write-Output "[[Maintenance]] Skipped - last maintenance $ResticStateLastMaintenance ($($delta.Days) days, $ResticStateMaintenanceCounter backups ago)" | Tee-Object -Append $SuccessLog
            return
        }
    }

    Write-Output "[[Maintenance]] Start $(Get-Date)" | Tee-Object -Append $SuccessLog
    $maintenance_success = $true
    Start-Sleep 120

    # forget snapshots based upon the retention policy
    Write-Output "[[Maintenance]] Start forgetting..." | Tee-Object -Append $SuccessLog
    & $ResticExe forget $SnapshotRetentionPolicy 3>&1 2>> $ErrorLog | Tee-Object -Append $SuccessLog
    if(-not $?) {
        Write-Output "[[Maintenance]] Forget operation completed with errors" | Tee-Object -Append $ErrorLog | Tee-Object -Append $SuccessLog
        $maintenance_success = $false
    }

    # prune (remove) data from the backup step. Running this separate from `forget` because
    #   `forget` only prunes when it detects removed snapshots upon invocation, not previously removed
    Write-Output "[[Maintenance]] Start pruning..." | Tee-Object -Append $SuccessLog
    & $ResticExe prune $SnapshotPrunePolicy 3>&1 2>> $ErrorLog | Tee-Object -Append $SuccessLog
    if(-not $?) {
        Write-Output "[[Maintenance]] Prune operation completed with errors" | Tee-Object -Append $ErrorLog | Tee-Object -Append $SuccessLog
        $maintenance_success = $false
    }

    # check data to ensure consistency
    Write-Output "[[Maintenance]] Start checking..." | Tee-Object -Append $SuccessLog

    # check to determine if we want to do a full data check or not
    $data_check = @()
    if($null -ne $ResticStateLastDeepMaintenance) {
        $delta = New-TimeSpan -Start $ResticStateLastDeepMaintenance -End $(Get-Date)
        if($delta.Days -ge $SnapshotDeepMaintenanceDays) {
            Write-Output "[[Maintenance]] Performing full data check - deep '--read-data' check last ran $ResticStateLastDeepMaintenance ($($delta.Days) days ago)" | Tee-Object -Append $SuccessLog
            $data_check = @("--read-data")
            $Script:ResticStateLastDeepMaintenance = Get-Date
        }
        else {
            Write-Output "[[Maintenance]] Performing fast data check - deep '--read-data' check last ran $ResticStateLastDeepMaintenance ($($delta.Days) days ago)" | Tee-Object -Append $SuccessLog
        }
    }
    else {
        # set the date, but don't do a deep check if we've never done a full data read
        $Script:ResticStateLastDeepMaintenance = Get-Date
    }

    & $ResticExe check @data_check 3>&1 2>> $ErrorLog | Tee-Object -Append $SuccessLog
    if(-not $?) {
        Write-Output "[[Maintenance]] Check completed with errors" | Tee-Object -Append $ErrorLog | Tee-Object -Append $SuccessLog
        $maintenance_success = $false
    }

    Write-Output "[[Maintenance]] End $(Get-Date)" | Tee-Object -Append $SuccessLog
    
    if($maintenance_success -eq $true) {
        $Script:ResticStateLastMaintenance = Get-Date
        $Script:ResticStateMaintenanceCounter = 0
    }
}

# Run restic backup 
function Invoke-Backup {
    Param($SuccessLog, $ErrorLog)

    Write-Output "[[Backup]] Start $(Get-Date)" | Tee-Object -Append $SuccessLog
    $return_value = $true
    $starting_location = Get-Location
    ForEach ($item in $BackupSources.GetEnumerator()) {

        # Get the source drive letter or identifier and set as the root path
        $root_path = $item.Key
        $tag = $item.Key

        $vss_option = "--use-fs-snapshot"

        # Test if root path is a valid path, if not assume it is an external drive identifier
        if(-not (Test-Path $root_path)) {
            # attempt to find a drive letter associated with the identifier provided
            $drives = Get-Drives $root_path
            if($drives.Count -gt 1) {
                Write-Output "[[Backup]] Fatal error - external drives with more than one partition are not currently supported." | Tee-Object -Append $SuccessLog | Tee-Object -Append $ErrorLog
                return $false
            }
            elseif ($drives.Count -eq 0) {
                $ignore_error = ($null -ne $IgnoreMissingBackupSources) -and $IgnoreMissingBackupSources
                $warning_message = {Write-Output "[[Backup]] Warning - backup path $root_path not found."}
                if($ignore_error) {
                    & $warning_message | Tee-Object -Append $SuccessLog                    
                }
                else {
                    & $warning_message | Tee-Object -Append $SuccessLog | Tee-Object -Append $ErrorLog
                    $return_value = $false
                }
                continue
            }
            
            $root_path = Join-Path $drives[0].DriveLetter ""
            
            # disable VSS / file system snapshot for external drives
            # TODO: would be best to just test for VSS compatibility on the drive, rather than assume it won't work
            $vss_option = $null
        }

        Write-Output "[[Backup]] Start $(Get-Date) [$tag]" | Tee-Object -Append $SuccessLog
        
        # build the list of folders to backup
        $folder_list = New-Object System.Collections.Generic.List[System.Object]
        if ($item.Value.Count -eq 0) {
            # backup everything in the root if no folders are provided
            $folder_list.Add($root_path)
        }
        else {
            # Build the list of folders from settings
            ForEach ($path in $item.Value) {
                $p = '"{0}"' -f ((Join-Path $root_path $path) -replace "\\$")
                
                if(Test-Path ($p -replace '"')) {
                    # add the folder if it exists
                    $folder_list.Add($p)
                }
                else {
                    # if the folder doesn't exist, log a warning/error
                    $ignore_error = ($null -ne $IgnoreMissingBackupSources) -and $IgnoreMissingBackupSources
                    $warning_message = {Write-Output "[[Backup]] Warning - backup path $p not found."}
                    if($ignore_error) {
                        & $warning_message | Tee-Object -Append $SuccessLog
                    }
                    else {
                        & $warning_message | Tee-Object -Append $SuccessLog | Tee-Object -Append $ErrorLog
                        $return_value = $false
                    }
                }
            }

        }
        
        if(-not $folder_list) {
            # there are no folders to backup
            $ignore_error = ($null -ne $IgnoreMissingBackupSources) -and $IgnoreMissingBackupSources
            $warning_message = {Write-Output "[[Backup]] Warning - no folders to back up!"}
            if($ignore_error) {
                & $warning_message | Tee-Object -Append $SuccessLog
            }
            else {
                & $warning_message | Tee-Object -Append $SuccessLog | Tee-Object -Append $ErrorLog
                $return_value = $false
            }
        }
        else {
            # Launch Restic
            & $ResticExe backup $folder_list $vss_option --tag "$tag" --exclude-file=$WindowsExcludeFile --exclude-file=$LocalExcludeFile 3>&1 2>> $ErrorLog | Tee-Object -Append $SuccessLog
            if(-not $?) {
                Write-Output "[[Backup]] Completed with errors" | Tee-Object -Append $ErrorLog | Tee-Object -Append $SuccessLog
                $return_value = $false
            }
        }

        Write-Output "[[Backup]] End $(Get-Date) [$tag]" | Tee-Object -Append $SuccessLog
    }
    
    Set-Location $starting_location
    Write-Output "[[Backup]] End $(Get-Date)" | Tee-Object -Append $SuccessLog

    return $return_value
}

function Send-Healthcheck-Start {
    Invoke-RestMethod $HealthcheckUrl/start
}

function Send-Healthcheck-End {
    Param($SuccessLog, $ErrorLog)

    $postfix = "" # Success
    $body = ""
    if (($null -ne $SuccessLog) -and (Test-Path $SuccessLog) -and (Get-Item $SuccessLog).Length -gt 0) {
        $body = $(Get-Content -Raw $SuccessLog)
    }
    else {
        $body = "Crtical Error! Restic backup log is empty or missing. Check log file path."
        $status = "/fail"
    }
    $attachments = @{}
    if (($null -ne $ErrorLog) -and (Test-Path $ErrorLog) -and (Get-Item $ErrorLog).Length -gt 0) {
        $body = $(Get-Content -Raw $SuccessLog) $(Get-Content -Raw $ErrorLog) | Select -Last 1000
        $status = "/fail"
    }

    Invoke-RestMethod -Uri $HealthcheckUrl$postfix -Method Post -Body $body
}

function Invoke-ConnectivityCheck {
    Param($SuccessLog, $ErrorLog)
    
    if($InternetTestAttempts -le 0) {
        Write-Output "[[Internet]] Internet connectivity check disabled. Skipping." | Tee-Object -Append $SuccessLog    
        return $true
    }

    # skip the internet connectivity check for local repos
    if(Test-Path $env:RESTIC_REPOSITORY) {
        Write-Output "[[Internet]] Local repository. Skipping internet connectivity check." | Tee-Object -Append $SuccessLog    
        return $true
    }

    $repository_host = ''

    # use generic internet service for non-specific repo types (e.g. swift:, rclone:, etc. )
    if(($env:RESTIC_REPOSITORY -match "^swift:") -or 
        ($env:RESTIC_REPOSITORY -match "^rclone:")) {
        $repository_host = "cloudflare.com"
    }
    elseif($env:RESTIC_REPOSITORY -match "^b2:") {
        $repository_host = "api.backblazeb2.com"
    }
    elseif($env:RESTIC_REPOSITORY -match "^azure:") {
        $repository_host = "azure.microsoft.com"
    }
    elseif($env:RESTIC_REPOSITORY -match "^gs:") {
        $repository_host = "storage.googleapis.com"
    }
    else {
        # parse connection string for hostname
        # Uri parser doesn't handle leading connection type info (s3:, sftp:, rest:)
        $connection_string = $env:RESTIC_REPOSITORY -replace "^s3:" -replace "^sftp:" -replace "^rest:"
        if(-not ($connection_string -match "://")) {
            # Uri parser expects to have a protocol. Add 'https://' to make it parse correctly.
            $connection_string = "https://" + $connection_string
        }
        $repository_host = ([System.Uri]$connection_string).DnsSafeHost
    }

    if([string]::IsNullOrEmpty($repository_host)) {
        Write-Output "[[Internet]] Repository string could not be parsed." | Tee-Object -Append $SuccessLog | Tee-Object -Append $ErrorLog
        return $false
    }

    # test for internet connectivity
    $connections = 0
    $sleep_count = $InternetTestAttempts
    while($true) {
        $connections = Get-NetRoute | Where-Object DestinationPrefix -eq '0.0.0.0/0' | Get-NetIPInterface | Where-Object ConnectionState -eq 'Connected' | Measure-Object | ForEach-Object{$_.Count}
        if($sleep_count -le 0) {
            Write-Output "[[Internet]] Connection to repository ($repository_host) could not be established." | Tee-Object -Append $SuccessLog | Tee-Object -Append $ErrorLog
            return $false
        }
        if(($null -eq $connections) -or ($connections -eq 0)) {
            Write-Output "[[Internet]] Waiting for internet connectivity... $sleep_count" | Tee-Object -Append $SuccessLog
            Start-Sleep 30
        }
        elseif(!(Test-Connection -ComputerName $repository_host -Quiet)) {
            Write-Output "[[Internet]] Waiting for connection to repository ($repository_host)... $sleep_count" | Tee-Object -Append $SuccessLog
            Start-Sleep 30
        }
        else {
            return $true
        }
        $sleep_count--
    }
}

# check previous logs
function Invoke-HistoryCheck {
    Param($SuccessLog, $ErrorLog)
    $logs = Get-ChildItem $LogPath -Filter '*err.txt' | ForEach-Object{$_.Length -gt 0}
    $logs_with_success = ($logs | Where-Object {($_ -eq $false)}).Count
    if($logs.Count -gt 0) {
        Write-Output "[[History]] Backup success rate: $logs_with_success / $($logs.Count) ($(($logs_with_success / $logs.Count).tostring("P")))" | Tee-Object -Append $SuccessLog
    }
}

# main function
function Invoke-Main {
    
    # check for elevation, required for creation of shadow copy (VSS)
    if (-not (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
    {
        Write-Error "[[Backup]] Elevation required (run as administrator). Exiting."
        exit
    }

    # initialize secrets
    . $SecretsScript
    
    # initialize config
    . $ConfigScript

    Send-Healthcheck-Start
    
    Get-BackupState

    if(!(Test-Path $LogPath)) {
        Write-Error "[[Backup]] Log file directory $LogPath does not exist. Exiting."
        Send-Healthcheck-End
        exit
    }

    $error_count = 0;
    $attempt_count = $GlobalRetryAttempts
    while ($attempt_count -gt 0) {
        # setup logfiles
        $timestamp = Get-Date -Format FileDateTime
        $success_log = Join-Path $LogPath ($timestamp + ".log.txt")
        $error_log = Join-Path $LogPath ($timestamp + ".err.txt")
        
        $internet_available = Invoke-ConnectivityCheck $success_log $error_log
        if($internet_available -eq $true) { 
            Invoke-Unlock $success_log $error_log
            $backup_success = Invoke-Backup $success_log $error_log
            if($backup_success) {
                Invoke-Maintenance $success_log $error_log
            }

            if (!(Test-Path $error_log) -or ((Get-Item $error_log).Length -eq 0)) {
                # successful with no errors; end
                $total_attempts = $GlobalRetryAttempts - $attempt_count + 1
                Write-Output "Succeeded after $total_attempts attempt(s)" | Tee-Object -Append $success_log
                Invoke-HistoryCheck $success_log $error_log
                Send-Healthcheck-End $success_log $error_log
                break;
            }
        }

        Write-Output "[[General]] Errors found. Log: $error_log" | Tee-Object -Append $success_log | Tee-Object -Append $error_log
        $error_count++
        
        $attempt_count--
        if($attempt_count -gt 0) {
            Write-Output "[[Retry]] Sleeping for 15 min and then retrying..." | Tee-Object -Append $success_log
        }
        else {
            Write-Output "[[Retry]] Retry limit has been reached. No more attempts to backup will be made." | Tee-Object -Append $success_log
        }
        if($internet_available -eq $true) {
            Invoke-HistoryCheck $success_log $error_log
            Send-Healthcheck-End $success_log $error_log
        }
        if($attempt_count -gt 0) {
            Start-Sleep (15*60)
        }
    }    

    Set-BackupState

    # cleanup older log files
    Get-ChildItem $LogPath | Where-Object {$_.CreationTime -lt $(Get-Date).AddDays(-$LogRetentionDays)} | Remove-Item

    exit $error_count
}

Invoke-Main
