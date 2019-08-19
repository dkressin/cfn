function global:Invoke-RetryCommand {
    Param(
        [Parameter(Mandatory=$true)]
        [string]
        $Command,

        [Parameter(Mandatory=$false)]
        $ArgList = @{},

        [Parameter(Mandatory=$false)]
        [string]
        $CheckExpression = '$? -and $Return.Result',

        [Parameter(Mandatory=$false)]
        [int]
        $Tries = 5,

        [Parameter(Mandatory=$false)]
        [int]
        $InitialDelay = 2,  # in seconds

        [Parameter(Mandatory=$false)]
        [int]
        $MaxDelay = 32  # in seconds
    )
    Begin {
        $TryCount = 0
        $Delay = $InitialDelay
        $Completed = $false
        $MsgFailed = "Command FAILED: {0}" -f $Command
        $MsgSucceeded = "Command SUCCEEDED: {0}" -f $Command
        $ArgString = if ($ArgList -is [Hashtable]) { $ArgList | Select-Object -Property * | Out-String } else { $ArgList -join " "}
        $Return = @{Result=$Null}

        Write-Verbose ("Tries: {0}" -f $Tries)
        Write-Verbose ("Command: {0}" -f $Command)
        Write-Verbose ("ArgList: {0}" -f $ArgString)
    }
    Process {
        while (-not $Completed)
        {
            try
            {
                $Return.Result = & $Command @ArgList
                if (-not (Invoke-Expression $CheckExpression))
                {
                    throw $MsgFailed
                }
                else
                {
                    Write-Verbose $MsgSucceeded
                    Write-Output $Return.Result
                    $Completed = $true
                }
            }
            catch
            {
                $TryCount++
                if ($TryCount -ge $Tries)
                {
                    $Completed = $true
                    Write-Output $Return.Result
                    Write-Warning ($PSItem | Select-Object -Property * | Out-String)
                    Write-Warning ("Command failed the maximum number of {0} time(s)." -f $Tries)
                    $PSCmdlet.ThrowTerminatingError($PSItem)
                }
                else
                {
                    $Msg = $PSItem.ToString()
                    if ($Msg -ne $MsgFailed) { Write-Warning $Msg }
                    Write-Warning ("Command failed. Retrying in {0} second(s)." -f $Delay)
                    Start-Sleep $Delay
                    $Delay *= 2
                    $Delay = [Math]::Min($MaxDelay, $Delay)
                }
            }
        }
    }
    End {}
}

function global:Test-RetryNetConnection {
    Param(
        [Parameter(Mandatory=$true, ValueFromPipeLine=$true)]
        [string[]]
        $ComputerName,

        [Parameter(Mandatory=$false)]
        [string]
        $CheckExpression = '$? -and $Return.Result.TcpTestSucceeded',

        [Parameter(Mandatory=$false)]
        [int]
        $Tries = 5,

        [Parameter(Mandatory=$false)]
        [int]
        $InitialDelay = 2,  # in seconds

        [Parameter(Mandatory=$false)]
        [int]
        $MaxDelay = 32  # in seconds
    )
    BEGIN {
        $ValidComputers = @()
        $StaleComputers = @()
    }
    PROCESS {
        ForEach ($computer in $ComputerName)
        {
            Write-Verbose ("Testing connectivity to server: {0}" -f $computer)
            try
            {
                $null = Invoke-RetryCommand -Command Test-NetConnection -ArgList @{ComputerName=$computer; CommonTCPPort="RDP"} -CheckExpression $CheckExpression -Tries $Tries
                Write-Verbose ("Successfully connected to server: {0}" -f $computer)
                Write-Output @{ ValidComputers = $computer }
                $ValidComputers += $computer
            }
            catch
            {
                Write-Verbose ("Server is not available, marked as stale: {0}" -f $computer)
                Write-Output @{ StaleComputers = $computer }
                $StaleComputers += $computer
            }
        }
    }
    END {
        Write-Verbose "Valid Computers:"
        $ValidComputers | ForEach-Object { Write-Verbose "*    $_" }
        Write-Verbose "Stale Computers:"
        $StaleComputers | ForEach-Object { Write-Verbose "*    $_" }
    }
}

function global:Edit-AclIdentityReference {
    Param(
        [Parameter(Mandatory=$true)]
        [System.Security.AccessControl.DirectorySecurity]
        $Acl,

        [Parameter(Mandatory=$false)]
        [string[]]
        $IdentityReference,

        [Parameter(Mandatory=$false)]
        [string]
        $IdentityFilter = "(?i).*\\.*[$]$",

        [Parameter(Mandatory=$false)]
        [string]
        $FileSystemRights = "FullControl",

        [Parameter(Mandatory=$false)]
        [string]
        $InheritanceFlags = "ContainerInherit, ObjectInherit",

        [Parameter(Mandatory=$false)]
        [string]
        $PropagationFlags = "None",

        [Parameter(Mandatory=$false)]
        [string]
        $AccessControlType = "Allow"
    )
    BEGIN {
        $AclIdentities = @($Acl.Access.IdentityReference.Value) | Where-Object { $_ -match $IdentityFilter }

        # Test if ACL contains only matching identity references
        $DiffIdentities = Compare-Object $IdentityReference $AclIdentities

        # Skip further processing if there are no differences
        if (-not $DiffIdentities)
        {
            Write-Verbose "ACL contains only matching identities, no changes needed..."
            return
        }

        # Identity in ACL but not in $IdentityReference; need to remove
        $RemoveIdentities = $DiffIdentities | Where-Object { $_.SideIndicator -eq "=>" } | ForEach-Object { $_.InputObject }

        # Identity in $IdentityReference but not in ACL; need to add
        $AddIdentities = $DiffIdentities | Where-Object { $_.SideIndicator -eq "<=" } | ForEach-Object { $_.InputObject }

        # Remove rules for identity references not present in $IdentityReference
        foreach ($Rule in $Acl.Access)
        {
            $Identity = $Rule.IdentityReference.Value

            if ($Identity -in $RemoveIdentities)
            {
                Write-Verbose "Identity is NOT VALID, removing rule:"
                Write-Verbose "*    Rule Identity: $Identity"
                $Acl.RemoveAccessRule($Rule)
            }
        }

        # Add rules for identity references in $IdentityReference that are missing from the ACL
        foreach ($Identity in $AddIdentities)
        {
            Write-Verbose "Adding missing access rule to ACL:"
            Write-Verbose "*    Rule Identity: $Identity"
            $Acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                $Identity,
                $FileSystemRights,
                $InheritanceFlags,
                $PropagationFlags,
                $AccessControlType
            )))
        }

        # Output the new ACL
        Write-Verbose ($Acl.Access | Out-String)
        Write-Output $Acl
    }
}
