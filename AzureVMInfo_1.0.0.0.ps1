#region Functions - Add your own functions here.  Leave AzureLogin as-is
####Functions#############################################################
function AzureLogin
{
    [cmdletbinding()]
    Param
    (
        [Parameter(Mandatory=$false)]
        [bool] $RunPasswordPrompt = $false,
        [Parameter(Mandatory=$false)]
        [string] $SecurePasswordLocation,
        [Parameter(Mandatory=$false)]
        [string] $LoginName,
        [Parameter(Mandatory=$false)]
        [bool] $AzureForGov = $false,
        [Parameter(Mandatory=$false)]
        [bool] $ConnectToAzureAd = $false
    )

    try 
    {
        $success = $false
        
        if(!($SecurePasswordLocation -match '(\w)[.](\w)') )
        {
            write-host "Encrypted password file ends in a directory, this needs to end in a filename.  Exiting..."
            return false # could make success false
        }
        if($RunPasswordPrompt)
        {
            #if fails return false
            Read-Host -Prompt "Enter your password for $($LoginName)" -assecurestring | convertfrom-securestring | out-file $SecurePasswordLocation
        }
        else 
        {
            #no prompt, does the password file exist
            if(!(Test-Path $SecurePasswordLocation))
            {
                write-host "There isn't a password file in the location you specified $($SecurePasswordLocation)."
                Read-host "Password file not found, Enter your password" -assecurestring | convertfrom-securestring | out-file $SecurePasswordLocation
                #return false if fail 
                if(!(Test-Path -Path $SecurePasswordLocation)){return Write-Host "Path doesn't exist: $($SecurePasswordLocation)"; $false}
            } 
        }
        try 
        {
            $password = Get-Content $SecurePasswordLocation | ConvertTo-SecureString
            $cred = new-object -typename System.Management.Automation.PSCredential -argumentlist $LoginName, $password 
            $success = $true
        }
        catch {$success = $false}
        try 
        {
            if($success)
            {
                #connect AD or Az
                if($ConnectToAzureAd)
                {
                    if($AzureForGov){Connect-AzureAD -Credential $cred -EnvironmentName AzureUSGovernment | Out-Null}
                    else{Connect-AzureAD -Credential $cred | Out-Null}
                    $context = Get-AzureADUser -Top 1
                    if($context){$success = $true}   
                    else{$success = $false}
                }
                else 
                {
                    if($AzureForGov){Connect-AzAccount -Credential $cred -EnvironmentName AzureUSGovernment | Out-Null}
                    else{Connect-AzAccount -Credential $cred | Out-Null}
                    $context = Get-AzContext
                    if($context.Subscription.Name){$success = $true}
                    else{$success = $false}
                }
                if(!($success))
                {
                  # error logging into account or user doesn't have subscription rights, exit
                  $success = $false
                  throw "Failed to login, exiting..."
                  #exit
                }   
            }
        }
        catch{$success = $false} 
    }
    catch {$success = $false}
    return $success
}

Function GetAzureIDValue
{
    [cmdletbinding()]
    Param (
    [string]$Name,
    [string]$IDPayload
    )
    $returnValue = ""
    $IDPayloadJSON = ""
    try 
    {
        if(($Name -and $IDPayload) -or ($IDPayload.ToLower() -eq "null"))
        {
            if($IDPayload.Contains($Name))
            {
                if($IDPayload -match '[{}]' )
                {
                    $IDPayloadJSON = ConvertFrom-Json -InputObject $IDPayload
                    $fullText = $IDPayloadJSON[0]
                    $returnValue = GetAzureIDValue -IDPayload $fullText.ID -Name $Name
                    #return $returnValue
                }
                else 
                {
                    $nameValCollection = $IDPayload.Split('/')
                    for($x=0;$x -le $nameValCollection.Count;$x++)
                    {
                        try
                        {
                            if($nameValCollection[$x].ToLower().Equals($Name.ToLower()))
                            {
                                $returnValue = $nameValCollection[$x+1]
                                break
                            }
                        }
                        catch 
                        {
                            #something went wrong
                            $temp = $_.Exception.Message
                        }
                    }
                }
                
            }
            else 
            {
                #Payload doesn't contain name value, return blank 
                $returnValue = ""  
            }
        }
    }
    catch 
    {
        $temp = $_.Exception.Message
    }
    return $returnValue
}
Function GetPublicIpInfo
{
    [cmdletbinding()]
    Param (
    [Microsoft.Azure.Commands.Network.Models.PSNetworkInterface]$Nic
    )
    $PublicIp = [PSCustomObject]@{
        Name = ""
        PublicIPVersion = ""
        PublicIPAllocationMethod = ""
        ResourceGroup = ""
        VMHostName = ""
        $PublicIpAddress = ""
    }
    #maybe test IPConfiguration for null
    $PublicIp.Name = GetAzureIDValue -Name "publicIPAddresses" -IDPayload $config[0].PublicIpAddress.Id     
    $pubIp = Get-AzureRmPublicIpAddress -Name $PublicIp.Name -ResourceGroupName $Nic.ResourceGroupName
    $PublicIp.Name = GetAzureIDValue -Name "publicIPAddresses" -IDPayload $config[0].PublicIpAddress.Id 
    $PublicIp.PublicIPAllocationMethod = $pubIp.PublicIpAllocationMethod
    $PublicIp.PublicIPVersion = $pubIp.PublicIpAddressVersion
    $PublicIp.ResourceGroup = $pubIp.ResourceGroupName
    $PublicIp.VMHostName = $localVMName
    $PublicIp.PublicIpAddress = $pubIp.IpAddress
    foreach($ip in $PublicIPList)
    {
        if($ip.name.Equals($pubIp.Name))
        {
            continue
        }
        $PublicIPList.Add($PublicIp)
    }
}

function PopulateVmList
{
    [cmdletbinding()]
    param(
        [System.Collections.ArrayList] $VMList,
        [System.Collections.ArrayList] $NICList
    )

    $localList1 = New-Object System.Collections.ArrayList
    foreach($vm in $VMList)
    {
        $VmInfoObj = [PSCustomObject]@{
            VMName = ""
            PrivateIP = ""
            VMEnabled = $false
            VMSize = ""
            IsWindows = $false
            IsLinux = $false
            Location = ""
            automaticUpdatesEnabled = $false
            PrivateIPVersion = ""
            PrivateIPAllocationMethod = ""
            ResourceGroup = ""
            Id = ""
            Subnet = ""
            PublicIPAddresses = ""
            Type = ""
            Nics = New-Object System.Collections.ArrayList
            NICName = ""
            IsPrimary = $false
            BootDiagnosticStorageUri = ""
            Publisher = ""
            Offer = ""
            Sku = ""
            Version = ""
        }

        if($vm.StorageProfile.ImageReference.Publisher)
        {
            $VmInfoObj.Publisher = $vm.StorageProfile.ImageReference.Publisher
            $VmInfoObj.Offer = $vm.StorageProfile.ImageReference.Offer
            $VmInfoObj.Sku = $vm.StorageProfile.ImageReference.Sku
            $VmInfoObj.Version = $vm.StorageProfile.ImageReference.Version
        }
        
        $VmInfoObj.Location = $vm.Location
        if($vm.BootDiagnostics.Enabled)
        {
            $VmInfoObj.Enabled = $true
            $VmInfoObj.BootDiagnosticStorageUri = $vm.DiagnosticProfile.BootDiagnostics.StorageUri
        }
        $VmInfoObj.VMSize = $vm.HardwareProfile.VmSize

        if($vm.OSProfile.WindowsConfiguration)
        {
            $VmInfoObj.IsWindows = $true
            $VmInfoObj.automaticUpdatesEnabled = $vm.OSProfile.WindowsConfiguration.EnableAutomaticUpdates
        }
        elseif($vm.LinuxConfiguration)
        {
            $VmVmInfoObjInfo.OSProfile.IsLinux = $true
        }
        else 
        {
            
        }

        $VmInfoObj.VMName = $vm.Name
        $VmInfoObj.Type = $vm.Type
        $VmInfoObj.Id = $vm.VmId
        $VmInfoObj.ResourceGroup = $vm.ResourceGroupName
        
        foreach($nic in $NICList)
        {
            try 
            {
                $vmName = GetAzureIDValue -IDPayload $nic.VirtualMachine.Id -Name "virtualMachines"
                if($vmName.Equals($VmInfoObj.VMName))
                {
                    #nic owned by VM
                    $VmInfoObj.Nics.Add($nic) | Out-Null
                }
            }
            catch {continue}
        }
        $localList1.Add($VmInfoObj) | Out-Null
    }#foreach
    return $localList1 # return list of custom objects
}
#endregion



####Begin Code - enter your code in the if statement below
#Variables - Add your values for the variables here, you can't leave the values blank
[string]    $LoginName =                   ""           #Azure username, something@something.onmicrosoft.com 
[string]    $SecurePasswordLocation =      ""           #Path and filename for the secure password file c:\Whatever\securePassword.txt
[string]    $LogFileNameAndPath =          ""           #If $enabledLogFile is true, the script will write to a log file in this path.  Include FileName, example c:\whatever\file.log
[bool]      $RunPasswordPrompt =           $true        #Uses Read-Host to prompt the user at the command prompt to enter password.  this will create the text file in $SecurePasswordLocation.
[bool]      $AzureForGovernment =          $false       #set to $true if running cmdlets against Microsoft azure for government
[bool]      $EnableLogFile =               $false       #If enabled a log file will be written to $LogFileNameAndPath.
[bool]      $ConnectToAzureAd =            $false       #This will connect using Connect-AzureAd instead of Connect-AzAccount

try 
{
    if($AzureForGovernment){$success = AzureLogin -RunPasswordPrompt $RunPasswordPrompt -SecurePasswordLocation $SecurePasswordLocation -LoginName $LoginName -AzureForGov $AzureForGovernment}
    else {$success = AzureLogin -RunPasswordPrompt $RunPasswordPrompt -SecurePasswordLocation $SecurePasswordLocation -LoginName $LoginName}

    if($success)
    {
        #Login Successful
        Write-Host "Login succeeded"
        #Add your Azure cmdlets here ###########################################
        #Get-AzVM

        #Get VMs and Nics
        $Nics = Get-AzNetworkInterface
        $VMs = Get-AzVM


        #after the below call have a list of custom VM objects with a Nics collection which has IP configurations
        $VMInfo = PopulateVmList -VMList $VMs -NICList $Nics # Adds VMName data to the object
        foreach($vm in $VMInfo)
        {
            "VMName:" + $vm.VMName
            "Num of Nics:$($vm.Nics.Count).  List of Private IP Addresses:"
            foreach($nic in $vm.Nics)
            {
                foreach($IpConfiguration in $nic.IpConfigurations)
                {
                    "`t" + $IpConfiguration.PrivateIpAddress 
                }
            }
            "Publisher:" +      $vm.Publisher
            "ResourceGroup:" +  $vm.ResourceGroup
            "Sku:" +            $vm.Sku
            "Type:" +           $vm.Type
            "Version:" +        $vm.Version
            "VMEnabled:" +      $vm.VMEnabled
            "VMSize:" +         $vm.VMSize
        }
        if(!($IgnoreDetatchedNics))
        {
            "Detached Nic Info"
            $localList = New-Object System.Collections.ArrayList
            foreach($dNic in $DetachedNics)
            {
                $dNicReport = [PSCustomObject]@{
    
                    NicName = ""
                    PrivateIpAddress = ""
                    PrivateIpVersion = ""
                }
                
                $dNicReport.NicName = $dNic.Name
                $dNicReport.PrivateIpVersion = $dNic.IpConfigurations[0].PrivateIpAddressVersion
                $dNicReport.PrivateIpAddress = $dNic.IpConfigurations[0].PrivateIpAddress
                $localList.Add($dNicReport) | Out-Null
            }
            $localList | Format-Table
        }


    }
    else{Write-Host "Login failed or no access"}
}
catch 
{
    #Login Failed with Error
    $_.Exception.Message
}
