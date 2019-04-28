# Clean-up the screen before running... helps when debugging
Clear-Host
$InformationPreference = "Continue"
# Variables to be used throughout the script
$serverInstance = "localhost"                   # SQL Server instance name 
$sourceDatabaseName = "CMRamble_93"             # Name of database in SQL Server
$targetDatabaseName = "Restored_cmramble_93"    # Name to restore to in SQL Server
$backupFileName = "$($sourceDatabaseName).bak"  # File name for backup of database
$backupPath = "C:\\temp"                        # Folder to back-up into (relative to server)
$backupFilePath = [System.IO.Path]::Combine($backupPath, $backupFileName)   # Use .Net's path join which honors OS
$databaseFileGroup = "PRIMARY"                  # File group of database content, used when shrinking
$databaseFileName = "CMRamble_93"               # Filename within file group, used when shrinking
$sqlDataPath = "D:\Program Files\Microsoft SQL Server\MSSQL13.MSSQLSERVER\MSSQL\DATA"   # Path to data files, used in restore
$cmServiceName = "TRIMWorkgroup"                # Name of registered service in OS (not display name)
$recTypeUris = @( 3 )                           # Array of uri's for record types to be purged after restore

# Function to programmatically shrink, but in batches... stops process from seemingly hanging
function ShrinkDatabase 
{
    # Source: https://www.mssqltips.com/sqlservertip/3178/incrementally-shrinking-a-large-sql-server-data-file-using-powershell/
    param
    (
        [Parameter(Mandatory=$True)][string]$SQLInstanceName,
        [Parameter(Mandatory=$True)][string]$DatabaseName,
        [Parameter(Mandatory=$True)][string]$FileGroupName,
        [Parameter(Mandatory=$True)][string]$FileName,
        [Parameter(Mandatory=$True)][int]$ShrinkSizeMB,
        [Parameter(Mandatory=$False)][int]$ShrinkIncrementMB = 10
    )
    [system.Reflection.Assembly]::LoadWithPartialName("Microsoft.SQLServer.Smo") | Out-Null
    $server = New-Object Microsoft.SqlServer.Management.Smo.Server $SQLInstanceName
    $Database = $Server.Databases[$DatabaseName]
    $Filegroup = $Database.filegroups[$FileGroupName]
    $File = $Filegroup.Files[$FileName]
    $SizeMB = $File.Size/1024
    if($SizeMB - $file.AvailableSpace -le $ShrinkSizeMB)
    {
        while ($SizeMB -ge $ShrinkSizeMB)
        {
            $File.Shrink($SizeMB - $ShrinkIncrementMB, [Microsoft.SQLServer.Management.SMO.ShrinkMethod]::Default)
            $Server.Refresh()
            $Database.Refresh()
            $File.Refresh()
            $SizeMB = $File.Size/1024
        }
    }
}

# Function below is used so that we trap errors and shrink at certain times
function ExecuteSqlStatement 
{
    param([String]$Instance, [String]$Database, [String]$SqlStatement, [bool]$shrink = $false)
    $error = $false
    # Trap all errors
    try {
        # Execute the statement
        Write-Debug "Executing Statement on $($Instance) in DB $($Database): $($SqlStatement)"
        Invoke-Sqlcmd -ServerInstance $Instance -Database $Database -Query $SqlStatement | Out-Null
        Write-Debug "Statement executed with no exceptions"
    } catch [Exception] {
        Write-Error "Exception Executing Statement: $($_)"
        $error = $true
    } finally {
    }
    # When no error and parameter passed, shrink the DB (can slow process)
    if ( $error -eq $false -and $shrink -eq $true ) {
        ShrinkDatabase -SQLInstanceName $serverInstance -DatabaseName $Database -FileGroupName $databaseFileGroup -FileName $databaseFileName -ShrinkSizeMB 48000 -ShrinkIncrementMB 20
    }
}

# Remove previous backup, if it exists
if ( Test-Path $backupFilePath ) { 
    Write-Information "Removing Backup File"
    Remove-Item $backupFilePath
}

# Backup the source database to a new file
Write-Information "Backing Up $($sourceDatabaseName)"
Backup-SqlDatabase -ServerInstance $serverInstance -Database $sourceDatabaseName -BackupAction Database -CopyOnly -BackupFile $backupFilePath

# Restore the database by first getting an exclusive lock with single user access, enable multi-user when done
Write-Warning "Restoring database with exclusive use access"
$ExclusiveLock = "USE [master]; ALTER DATABASE [$($targetDatabaseName)] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;"
$RestoreDatabase = "RESTORE FILELISTONLY FROM disk = '$($backupFilePath)'; RESTORE DATABASE $($targetDatabaseName) FROM disk = '$($backupFilePath)' WITH replace, MOVE '$($sourceDatabaseName)' TO '$($sqlDataPath)\$($targetDatabaseName).mdf', MOVE '$($sourceDatabaseName)_log' TO '$($sqlDataPath)\$($targetDatabaseName)_log.ldf', stats = 5; ALTER DATABASE $($targetDatabaseName) SET MULTI_USER;"
ExecuteSqlStatement -Instance $serverInstance -Database $targetDatabaseName -SqlStatement ($ExclusiveLock+$RestoreDatabase)

# Change recovery mode to simple
Write-Information "Setting recovery mode to simple"
Invoke-Sqlcmd -ServerInstance $serverInstance -Database $targetDatabaseName -Query "ALTER DATABASE $($targetDatabaseName) SET RECOVERY SIMPLE"

# Purging content by record type uri
foreach ( $rtyUri in $recTypeUris ) 
{
    Write-Warning "Purging All Records & Supporting Objects for Record Type Uri $($rtyUri)"
    Write-Information " - Purging Workflow Document References"
    ExecuteSqlStatement -Instance $serverInstance -Database $targetDatabaseName -SqlStatement "delete from tswkdocusa where wduDocumentUri in (select uri from tswkdocume where wdcRecordUri in (select uri from tsrecord where rcRecTypeUri=$rtyUri))"
    Write-Information " - Purging Workflow Documents"
    ExecuteSqlStatement -Instance $serverInstance -Database $targetDatabaseName -SqlStatement "delete from tswkdocume where wdcRecordUri in (select uri from tsrecord where rcRecTypeUri=$rtyUri)"
    Write-Information " - Purging Workflow Activity Start Conditions"
    ExecuteSqlStatement -Instance $serverInstance -Database $targetDatabaseName -SqlStatement "delete from tswkstartc where wscActivityUri in (select uri from tswkactivi where wacWorkflowUri in (select uri from tswkworkfl where wrkInitiator in (select uri from tsrecord where rcRecTypeUri=$rtyUri)))"
    Write-Information " - Purging Workflow Activities"
    ExecuteSqlStatement -Instance $serverInstance -Database $targetDatabaseName -SqlStatement "delete from tswkactivi where wacWorkflowUri in (select uri from tswkworkfl where wrkInitiator in (select uri from tsrecord where rcRecTypeUri=$rtyUri))"
    Write-Information " - Purging Workflows"
    ExecuteSqlStatement -Instance $serverInstance -Database $targetDatabaseName -SqlStatement "delete from tswkworkfl where wrkInitiator in (select uri from tsrecord where rcRecTypeUri=$rtyUri)"
    Write-Information " - Purging Communications Detail Words"
    ExecuteSqlStatement -Instance $serverInstance -Database $targetDatabaseName -SqlStatement "delete from tstranswor where twdTransDetailUri in (select tstransdet.uri from tstransdet inner join tstransmit on tstransdet.tdTransUri = tstransmit.uri inner join tsrecord on tstransmit.trRecordUri = tsrecord.uri where tsrecord.rcRecTypeUri = $rtyUri);"
    Write-Information " - Purging Communications Details"
    ExecuteSqlStatement -Instance $serverInstance -Database $targetDatabaseName -SqlStatement "delete from tstransdet where tdTransUri in (select tstransmit.uri from tstransmit inner join tsrecord on tstransmit.trRecordUri = tsrecord.uri where rcRecTypeUri=$rtyUri);"
    Write-Information " - Purging Communications"
    ExecuteSqlStatement -Instance $serverInstance -Database $targetDatabaseName -SqlStatement "delete from tstransmit where trRecordUri in (select uri from tsrecord where rcRecTypeUri=$rtyUri);"
    Write-Information " - Purging Record Thesaurus Terms"
    ExecuteSqlStatement -Instance $serverInstance -Database $targetDatabaseName -SqlStatement "delete from tsrecterm where rtmRecordUri in (select uri from tsrecord where rcRecTypeUri=$rtyUri);"
    Write-Information " - Purging Record Relationships"
    ExecuteSqlStatement -Instance $serverInstance -Database $targetDatabaseName -SqlStatement "delete from tsreclink where rkRecUri1 in (select uri from tsrecord where rcRecTypeUri=$rtyUri) OR rkRecUri2 in (select uri from tsrecord where rcRecTypeUri=$rtyUri);"
    Write-Information " - Purging Record Actions"
    ExecuteSqlStatement -Instance $serverInstance -Database $targetDatabaseName -SqlStatement "delete from tsrecactst where raRecordUri in (select uri from tsrecord where rcRecTypeUri=$rtyUri);"
    Write-Information " - Purging Record Jurisdictions"
    ExecuteSqlStatement -Instance $serverInstance -Database $targetDatabaseName -SqlStatement "delete from tsrecjuris where rjRecordUri in (select uri from tsrecord where rcRecTypeUri=$rtyUri);"
    Write-Information " - Purging Record Requests"
    ExecuteSqlStatement -Instance $serverInstance -Database $targetDatabaseName -SqlStatement "delete from tsrecreque where rqRecordUri in (select uri from tsrecord where rcRecTypeUri=$rtyUri);"
    Write-Information " - Purging Record Rendition Queue"
    ExecuteSqlStatement -Instance $serverInstance -Database $targetDatabaseName -SqlStatement "delete from tsrendqueu where rnqRecUri in (select uri from tsrecord where rcRecTypeUri=$rtyUri);"
    Write-Information " - Purging Record Renditions"
    ExecuteSqlStatement -Instance $serverInstance -Database $targetDatabaseName -SqlStatement "delete from tsrenditio where rrRecordUri in (select uri from tsrecord where rcRecTypeUri=$rtyUri);"
    Write-Information " - Purging Record Revisions"
    ExecuteSqlStatement -Instance $serverInstance -Database $targetDatabaseName -SqlStatement "delete from tserecvsn where evRecElecUri in (select uri from tsrecord where rcRecTypeUri=$rtyUri);"
    Write-Information " - Purging Record Documents"
    ExecuteSqlStatement -Instance $serverInstance -Database $targetDatabaseName -SqlStatement "delete from tsrecelec where uri in (select uri from tsrecord where rcRecTypeUri=$rtyUri);"
    Write-Information " - Purging Record Holds"
    ExecuteSqlStatement -Instance $serverInstance -Database $targetDatabaseName -SqlStatement "delete from tscasereco where crRecordUri in (select uri from tsrecord where rcRecTypeUri=$rtyUri);"
    Write-Information " - Purging Record Locations"
    ExecuteSqlStatement -Instance $serverInstance -Database $targetDatabaseName -SqlStatement "delete from tsrecloc where rlRecUri in (select uri from tsrecord where rcRecTypeUri=$rtyUri);"
    Write-Information " - Purging Records (shrink after)"
    ExecuteSqlStatement -Instance $serverInstance -Database $targetDatabaseName -SqlStatement "delete from tsrecord where rcRecTypeUri = $rtyUri" -shrink $true
    Write-Information " - Purging Record Types"
    ExecuteSqlStatement -Instance $serverInstance -Database $targetDatabaseName -SqlStatement "delete from tsrectype where uri = $rtyUri"
}

# Change recovery mode to simple
Write-Information "Setting recovery mode to full"
Invoke-Sqlcmd -ServerInstance $serverInstance -Database $targetDatabaseName -Query "ALTER DATABASE $($targetDatabaseName) SET RECOVERY FULL"

# Restart CM
Write-Warning "Restarting Content Manager Service"
Restart-Service -Force -Name $cmServiceName
