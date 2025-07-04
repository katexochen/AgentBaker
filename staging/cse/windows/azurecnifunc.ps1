function Install-VnetPlugins
{
    Param(
        [Parameter(Mandatory = $true)][string]
        $AzureCNIConfDir,
        [Parameter(Mandatory = $true)][string]
        $AzureCNIBinDir,
        [Parameter(Mandatory = $true)][string]
        $VNetCNIPluginsURL
    )
    Logs-To-Event -TaskName "AKS.WindowsCSE.InstallVnetPlugins" -TaskMessage "Start to install Azure VNet plugins. VnetCNIPluginsURL: $global:VNetCNIPluginsURL"

    # Create CNI directories.
    Create-Directory -FullPath $AzureCNIBinDir -DirectoryUsage "storing Azure CNI binaries"
    Create-Directory -FullPath $AzureCNIConfDir -DirectoryUsage "storing Azure CNI configuration"

    # Download Azure VNET CNI plugins.
    # Mirror from https://github.com/Azure/azure-container-networking/releases
    $zipfile = [Io.path]::Combine("$AzureCNIDir", "azure-vnet.zip")
    DownloadFileOverHttp -Url $VNetCNIPluginsURL -DestinationPath $zipfile -ExitCode $global:WINDOWS_CSE_ERROR_DOWNLOAD_CNI_PACKAGE
    Expand-Archive -path $zipfile -DestinationPath $AzureCNIBinDir
    del $zipfile

    # Windows does not need a separate CNI loopback plugin because the Windows
    # kernel automatically creates a loopback interface for each network namespace.
    # Copy CNI network config file and set bridge mode.
    move $AzureCNIBinDir/*.conflist $AzureCNIConfDir
}

function Set-AzureCNIConfig
{
    Param(
        [Parameter(Mandatory = $true)][string]
        $AzureCNIConfDir,
        [Parameter(Mandatory = $true)][string]
        $KubeDnsSearchPath,
        [Parameter(Mandatory = $true)][string]
        $KubeClusterCIDR,
        [Parameter(Mandatory = $true)][string]
        $KubeServiceCIDR,
        [Parameter(Mandatory = $true)][string]
        $VNetCIDR,
        [Parameter(Mandatory = $true)][bool]
        $IsDualStackEnabled,
        [Parameter(Mandatory = $false)][bool]
        $IsAzureCNIOverlayEnabled
    )
    Logs-To-Event -TaskName "AKS.WindowsCSE.SetAzureCNIConfig" -TaskMessage "Start to set Azure CNI config. IsDualStackEnabled: $global:IsDualStackEnabled, IsAzureCNIOverlayEnabled: $global:IsAzureCNIOverlayEnabled, IsDisableWindowsOutboundNat: $global:IsDisableWindowsOutboundNat, CiliumDataplaneEnabled: $global:CiliumDataplaneEnabled, IsIMDSRestrictionEnabled: $global:IsIMDSRestrictionEnabled"

    $fileName = [Io.path]::Combine("$AzureCNIConfDir", "10-azure.conflist")
    $configJson = Get-Content $fileName | ConvertFrom-Json
    $configJson.plugins.dns.Nameservers[0] = $KubeDnsServiceIp
    $configJson.plugins.dns.Search[0] = $KubeDnsSearchPath

    if (Test-Path variable:global:CiliumDataplaneEnabled)
    {
        if ($global:CiliumDataplaneEnabled)
        {
            $configJson.plugins.ipam.type = "azure-cns"
        }
    }

    if ($global:IsDisableWindowsOutboundNat)
    {
        # Replace OutBoundNAT with LoopbackDSR for IMDS acess if AKS cluster disabled Windows OutBoundNAT.
        # The Azure Instance Metadata Service (IMDS) provides information about currently running virtual machine instances.
        # IMDS is a REST API that's available at a well-known, non-routable IP address (169.254.169.254)
        # Details: https://docs.microsoft.com/en-us/azure/virtual-machines/windows/instance-metadata-service?tabs=windows#known-issues-and-faq
        $valueObj = [PSCustomObject]@{
            Type = 'LoopbackDSR'
            IPAddress = '169.254.169.254'
        }
        $jsonContent = [PSCustomObject]@{
            Name = 'EndpointPolicy'
            Value = $valueObj
        }

        # $configJson.plugins[0].AdditionalArgs[0] is OutboundNAT.
        Write-Log "Replace OutBoundNAT with LoopbackDSR for IMDS acess."
        $configJson.plugins[0].AdditionalArgs[0] = $jsonContent

        # Update the corresponding system regkey for DisableWindowsOutboundNat feature.
        $osVersion = Get-WindowsVersion
        if ($osVersion -eq "1809")
        {
            Write-Log "Update RegKey to disable the incompatible HNSControlFlag (0x10) for feature DisableWindowsOutboundNat"
            $hnsControlFlag = 0x10
            $currentValue = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\hns\State" -Name HNSControlFlag -ErrorAction Ignore)
            if (![string]::IsNullOrEmpty($currentValue))
            {
                Write-Log "The current value of HNSControlFlag is $currentValue"
                # Set the bit to 0 if the bit is 1
                if ([int]$currentValue.HNSControlFlag -band $hnsControlFlag)
                {
                    $hnsControlFlag = ([int]$currentValue.HNSControlFlag -bxor $hnsControlFlag)
                    Write-Log "HNSControlFlag is updated to $hnsControlFlag to clear the bit 0x10"
                    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\hns\State" -Name HNSControlFlag -Type DWORD -Value $hnsControlFlag
                }
            }
            else
            {
                # Set 0 to disable all features under HNSControlFlag (0x10 defaults enable)
                Write-Log "HNSControlFlag is set to 0 to clear the bit 0x10"
                Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\hns\State" -Name HNSControlFlag -Type DWORD -Value 0
            }
        }
        elseif ($osVersion -eq "ltsc2022")
        {
            Write-Log "SourcePortPreservationForHostPort is set to 0"
            Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\hns\State" -Name SourcePortPreservationForHostPort -Type DWORD -Value 0
        }
    }
    else
    {
        # Fill in DNS information for kubernetes.
        $exceptionAddresses = @()
        if ($IsDualStackEnabled)
        {
            $subnetsToPass = $KubeClusterCIDR -split ","
            foreach ($subnet in $subnetsToPass)
            {
                $exceptionAddresses += $subnet
            }
        }
        else
        {
            $exceptionAddresses += $KubeClusterCIDR
        }

        if (!$IsAzureCNIOverlayEnabled)
        {
            $vnetCIDRs = $VNetCIDR -split ","
            foreach ($cidr in $vnetCIDRs)
            {
                $exceptionAddresses += $cidr
            }
        }

        $osVersion = Get-WindowsVersion
        if ($osVersion -eq "1809")
        {
            # In WS2019 and below rules in the exception list are generated by dropping the prefix lenght and removing duplicate rules.
            # If multiple execptions are specified with different ranges we should only include the broadest range for each address.
            # This issue has been addressed in 19h1+ builds

            $processedExceptions = GetBroadestRangesForEachAddress $exceptionAddresses
            Write-Log "Filtering CNI config exception list values to work around WS2019 issue processing rules. Original exception list: $exceptionAddresses, processed exception list: $processedExceptions"
            $configJson.plugins.AdditionalArgs[0].Value.ExceptionList = $processedExceptions
        }
        else
        {
            if ($IsDualStackEnabled)
            {
                $ipv4Cidrs = @()
                $ipv6Cidrs = @()
                foreach ($cidr in $exceptionAddresses)
                {
                    # this is the pwsh way of strings.Count(s, ":") >= 2
                    if (($cidr -split ":").Count -ge 3)
                    {
                        $ipv6Cidrs += $cidr
                    }
                    else
                    {
                        $ipv4Cidrs += $cidr
                    }
                }

                # we just assume the first entry in additional Args is the exception
                # list for IPv4 and then append a new EnpointPolicy for IPv6. We
                # probably shouldn't hard code the first one like this and just build
                # 2 EndpointPolicies and append to the AdditionalArgs.
                $configJson.plugins.AdditionalArgs[0].Value.ExceptionList = $ipv4Cidrs

                $outboundException = [PSCustomObject]@{
                    Name = 'EndpointPolicy'
                    Value = [PSCustomObject]@{
                        Type = 'OutBoundNAT'
                        ExceptionList = $ipv6Cidrs
                    }
                }
                $configJson.plugins[0].AdditionalArgs += $outboundException
            }
            else
            {
                $configJson.plugins.AdditionalArgs[0].Value.ExceptionList = $exceptionAddresses
            }
        }
    }

    # Set the SDNRemoteArpMacAddress RegKey for HNS when AzureCNI is enabled
    Write-Log "Setting SDNRemoteArpMacAddress to 12-34-56-78-9a-bc for HNS"
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\hns\State" -Name SDNRemoteArpMacAddress -Value "12-34-56-78-9a-bc"
    # Restart hns service if it is exsting and running, to make the system regkey changes effective.
    $hnsServiceName = 'hns'
    $hnsService = Get-Service -Name $hnsServiceName -ErrorAction SilentlyContinue
    if ($hnsService -and $hnsService.Status -eq 'Running')
    {
        Write-Log "HNS service is already running. Restart HNS."
        Restart-Service -Name $hnsServiceName
    }
    Write-Log "Done configuring HNS"

    if ( $global:KubeproxyFeatureGates.Contains("WinDSR=true"))
    {
        Write-Log "Setting enableLoopbackDSR in Azure CNI conflist for WinDSR"
        # Add {enableLoopbackDSR:true} if windowsSettings exists, otherwise, add {windowsSettings:{enableLoopbackDSR:true}}
        if (Get-Member -InputObject $configJson.plugins[0] -name "windowsSettings" -Membertype Properties)
        {
            $configJson.plugins[0].windowsSettings | Add-Member -Name "enableLoopbackDSR" -Value $True -MemberType NoteProperty
        }
        else
        {
            $jsonContent = [PSCustomObject]@{
                'enableLoopbackDSR' = $True
            }
            $configJson.plugins[0] | Add-Member -Name "windowsSettings" -Value $jsonContent -MemberType NoteProperty
        }

        # $configJson.plugins[0].AdditionalArgs[1] is ROUTE. Remove ROUTE if WinDSR is enabled.
        $configJson.plugins[0].AdditionalArgs = @($configJson.plugins[0].AdditionalArgs | Where-Object { $_ -ne $configJson.plugins[0].AdditionalArgs[1] })
    }
    else
    {
        if ($IsDualStackEnabled)
        {
            $configJson.plugins[0]|Add-Member -Name "ipv6Mode" -Value "ipv6nat" -MemberType NoteProperty
            $serviceCidr = $KubeServiceCIDR -split ","
            $configJson.plugins[0].AdditionalArgs[1].Value.DestinationPrefix = $serviceCidr[0]
            $valueObj = [PSCustomObject]@{
                Type = 'ROUTE'
                DestinationPrefix = $serviceCidr[1]
                NeedEncap = $True
            }

            $jsonContent = [PSCustomObject]@{
                Name = 'EndpointPolicy'
                Value = $valueObj
            }
            $configJson.plugins[0].AdditionalArgs += $jsonContent
        }
        else
        {
            $configJson.plugins[0].AdditionalArgs[1].Value.DestinationPrefix = $KubeServiceCIDR
        }
    }

    if ($global:IsIMDSRestrictionEnabled)
    {
        $aclRuleBlockIMDS = [PSCustomObject]@{
            Type = 'ACL'
            Protocols = '6'
            Action = 'Block'
            Direction = 'Out'
            RemoteAddresses = '169.254.169.254/32'
            RemotePorts = '80'
            Priority = 200
            RuleType = 'Switch'
        }
        $jsonContent = [PSCustomObject]@{
            Name = 'EndpointPolicy'
            Value = $aclRuleBlockIMDS
        }
        $configJson.plugins[0].AdditionalArgs += $jsonContent
    }
    $aclRule1 = [PSCustomObject]@{
        Type = 'ACL'
        Protocols = '6'
        Action = 'Block'
        Direction = 'Out'
        RemoteAddresses = '168.63.129.16/32'
        RemotePorts = '80'
        Priority = 200
        RuleType = 'Switch'
    }
    $aclRule2 = [PSCustomObject]@{
        Type = 'ACL'
        Protocols = '6'
        Action = 'Block'
        Direction = 'Out'
        RemoteAddresses = '168.63.129.16/32'
        RemotePorts = '32526'
        Priority = 200
        RuleType = 'Switch'
    }
    $aclRule3 = [PSCustomObject]@{
        Type = 'ACL'
        Action = 'Allow'
        Direction = 'In'
        Priority = 65500
    }
    $aclRule4 = [PSCustomObject]@{
        Type = 'ACL'
        Action = 'Allow'
        Direction = 'Out'
        Priority = 65500
    }
    $jsonContent = [PSCustomObject]@{
        Name = 'EndpointPolicy'
        Value = $aclRule1
    }
    $configJson.plugins[0].AdditionalArgs += $jsonContent
    $jsonContent = [PSCustomObject]@{
        Name = 'EndpointPolicy'
        Value = $aclRule2
    }
    $configJson.plugins[0].AdditionalArgs += $jsonContent
    $jsonContent = [PSCustomObject]@{
        Name = 'EndpointPolicy'
        Value = $aclRule3
    }
    $configJson.plugins[0].AdditionalArgs += $jsonContent
    $jsonContent = [PSCustomObject]@{
        Name = 'EndpointPolicy'
        Value = $aclRule4
    }
    $configJson.plugins[0].AdditionalArgs += $jsonContent

    $configJson | ConvertTo-Json -depth 20 | Out-File -encoding ASCII -filepath $fileName
}

function GetBroadestRangesForEachAddress
{
    param([string[]] $values)

    # Create a map of range values to IP addresses
    $map = @{ }

    foreach ($value in $Values)
    {
        if ($value -match '([0-9\.]+)\/([0-9]+)')
        {
            if (!$map.contains($matches[1]))
            {
                $map.Add($matches[1], @())
            }

            $map[$matches[1]] += [int]$matches[2]
        }
    }

    # For each IP address select the range with the lagest scope (smallest value)
    $returnValues = @()
    foreach ($ip in $map.Keys)
    {
        $range = $map[$ip] | Sort-Object | Select-Object -First 1

        $returnValues += $ip + "/" + $range
    }

    # prefix $returnValues with common to ensure single values get returned as an array otherwise invalid json may be generated
    return ,$returnValues
}

function GetSubnetPrefix
{
    Param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string] $Token,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string] $SubnetId,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string] $ResourceManagerEndpoint,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string] $NetworkAPIVersion
    )

    $uri = "$( $ResourceManagerEndpoint )$( $SubnetId )?api-version=$NetworkAPIVersion"
    $headers = @{ Authorization = "Bearer $Token" }

    try
    {
        $response = Retry-Command -Command "Invoke-RestMethod" -Args @{ Uri = $uri; Method = "Get"; ContentType = "application/json"; Headers = $headers } -Retries 5 -RetryDelaySeconds 10
    }
    catch
    {
        Set-ExitCode -ExitCode $global:WINDOWS_CSE_ERROR_GET_SUBNET_PREFIX -ErrorMessage "Error getting subnet prefix. Error: $_"
    }

    $response.properties.addressPrefix
}

function GenerateAzureStackCNIConfig
{
    Param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string] $TenantId,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string] $SubscriptionId,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string] $AADClientId,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string] $AADClientSecret,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string] $ResourceGroup,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string] $NetworkAPIVersion,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string] $AzureEnvironmentFilePath,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string] $IdentitySystem,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string] $KubeDir

    )
    Logs-To-Event -TaskName "AKS.WindowsCSE.GenerateAzureStackCNIConfig" -TaskMessage "Start to generate Azure Stack CNI config"

    $networkInterfacesFile = "$KubeDir\network-interfaces.json"
    $azureCNIConfigFile = "$KubeDir\interfaces.json"
    $azureEnvironment = Get-Content $AzureEnvironmentFilePath | ConvertFrom-Json

    Write-Log "------------------------------------------------------------------------"
    Write-Log "Parameters"
    Write-Log "------------------------------------------------------------------------"
    Write-Log "TenantId:                  $TenantId"
    Write-Log "SubscriptionId:            $SubscriptionId"
    Write-Log "AADClientId:               ..."
    Write-Log "AADClientSecret:           ..."
    Write-Log "ResourceGroup:             $ResourceGroup"
    Write-Log "NetworkAPIVersion:         $NetworkAPIVersion"
    Write-Log "ServiceManagementEndpoint: $( $azureEnvironment.serviceManagementEndpoint )"
    Write-Log "ActiveDirectoryEndpoint:   $( $azureEnvironment.activeDirectoryEndpoint )"
    Write-Log "ResourceManagerEndpoint:   $( $azureEnvironment.resourceManagerEndpoint )"
    Write-Log "------------------------------------------------------------------------"
    Write-Log "Variables"
    Write-Log "------------------------------------------------------------------------"
    Write-Log "azureCNIConfigFile: $azureCNIConfigFile"
    Write-Log "networkInterfacesFile: $networkInterfacesFile"
    Write-Log "------------------------------------------------------------------------"

    Write-Log "Generating token for Azure Resource Manager"

    $tokenURL = ""
    if ($IdentitySystem -ieq "adfs")
    {
        $tokenURL = "$( $azureEnvironment.activeDirectoryEndpoint )adfs/oauth2/token"
    }
    else
    {
        $tokenURL = "$( $azureEnvironment.activeDirectoryEndpoint )$TenantId/oauth2/token"
    }

    Add-Type -AssemblyName System.Web
    $encodedSecret = [System.Web.HttpUtility]::UrlEncode($AADClientSecret)

    $body = "grant_type=client_credentials&client_id=$AADClientId&client_secret=$encodedSecret&resource=$( $azureEnvironment.serviceManagementEndpoint )"
    $args = @{ Uri = $tokenURL; Method = "Post"; Body = $body; ContentType = 'application/x-www-form-urlencoded' }
    try
    {
        $tokenResponse = Retry-Command -Command "Invoke-RestMethod" -Args $args -Retries 5 -RetryDelaySeconds 10
    }
    catch
    {
        Set-ExitCode -ExitCode $global:WINDOWS_CSE_ERROR_GENERATE_TOKEN_FOR_ARM -ErrorMessage "Error generating token for Azure Resource Manager. Error: $_"
    }

    $token = $tokenResponse | Select-Object -ExpandProperty access_token

    Write-Log "Fetching network interface configuration for node"

    $interfacesUri = "$( $azureEnvironment.resourceManagerEndpoint )subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Network/networkInterfaces?api-version=$NetworkAPIVersion"
    $headers = @{ Authorization = "Bearer $token" }
    $args = @{ Uri = $interfacesUri; Method = "Get"; ContentType = "application/json"; Headers = $headers; OutFile = $networkInterfacesFile }
    try
    {
        Retry-Command -Command "Invoke-RestMethod" -Args $args -Retries 5 -RetryDelaySeconds 10
    }
    catch
    {
        Set-ExitCode -ExitCode $global:WINDOWS_CSE_ERROR_NETWORK_INTERFACES_NOT_EXIST -ErrorMessage "Error fetching network interface configuration for node. Error: $_"
    }

    Write-Log "Generating Azure CNI interface file"

    $localNics = Get-NetAdapter | Select-Object -ExpandProperty MacAddress | ForEach-Object { $_ -replace "-", "" }

    $sdnNics = Get-Content $networkInterfacesFile `
        | ConvertFrom-Json `
        | Select-Object -ExpandProperty value `
        | Where-Object { $localNics.Contains($_.properties.macAddress) } `
        | Where-Object { $_.properties.ipConfigurations.Count -gt 0 }

    $interfaces = @{
        Interfaces = @( $sdnNics | ForEach-Object {
            @{
                MacAddress = $_.properties.macAddress
                IsPrimary = $_.properties.primary
                IPSubnets = @(@{
                    Prefix = GetSubnetPrefix `
                            -Token $token `
                            -SubnetId $_.properties.ipConfigurations[0].properties.subnet.id `
                            -NetworkAPIVersion $NetworkAPIVersion `
                            -ResourceManagerEndpoint $( $azureEnvironment.resourceManagerEndpoint )
                    IPAddresses = $_.properties.ipConfigurations | ForEach-Object {
                        @{
                            Address = $_.properties.privateIPAddress
                            IsPrimary = $_.properties.primary
                        }
                    }
                })
            }
        })
    }

    ConvertTo-Json $interfaces -Depth 6 | Out-File -FilePath $azureCNIConfigFile -Encoding ascii

    Set-ItemProperty -Path $azureCNIConfigFile -Name IsReadOnly -Value $true
}


function GetIpv4AddressFromParsedContent
{
    param (
        [Parameter(Mandatory = $true)]
        $ParsedContent
    )

    if ($ParsedContent[0].ipv4 -and $ParsedContent[0].ipv4.ipAddress -and $ParsedContent[0].ipv4.ipAddress.Count -gt 0)
    {
        return $ParsedContent[0].ipv4.ipAddress[0].privateIpAddress
    }
    else
    {
        return $null
    }
}

function GetIpv6AddressFromParsedContent
{
    param (
        [Parameter(Mandatory = $true)]
        $ParsedContent
    )

    if ($ParsedContent[0].ipv6 -and $ParsedContent[0].ipv6.ipAddress -and $ParsedContent[0].ipv6.ipAddress.Count -gt 0)
    {
        return $ParsedContent[0].ipv6.ipAddress[0].privateIpAddress
    }
    else
    {
        return $null
    }
}

function GetMetadataContent
{
    # try every second for 2 minutes to get the metadata content
    $Retries = 120
    $RetryDelaySeconds = 1

    for ($i = 0; $i -lt $Retries; $i++) {
        try
        {
            $MetadataContent = Invoke-WebRequest -UseBasicParsing -Uri "http://169.254.169.254/metadata/instance/network/interface?api-version=2021-02-01" -Headers @{ "metadata" = "true" } -TimeoutSec 10 -ErrorAction Stop
            $ParsedContent = $MetadataContent.Content | ConvertFrom-Json
            $ipv4Address = GetIpv4AddressFromParsedContent -ParsedContent $ParsedContent
            if (-not $ipv4Address)
            {
                Write-Log "Failed to retrieve IPv4 address from metadata. Will retry in $RetryDelaySeconds seconds. Attempt $( $i + 1 ) of $Retries."
                if ($i -lt ($Retries - 1))
                {
                    Start-Sleep -Seconds $RetryDelaySeconds
                }
            }
            else
            {
                return $ParsedContent
            }
        }
        catch
        {
            Write-Log "Failed to connect to metadata service: $( $_.Exception.Message ). Will retry in $RetryDelaySeconds seconds. Attempt $( $i + 1 ) of $Retries."
            if ($i -lt ($Retries - 1))
            {
                Start-Sleep -Seconds $RetryDelaySeconds
            }
        }
    }

    Write-Host "Failed to retrieve IPv4 address from metadata after $Retries attempts."
    throw "No IPv4 address found in metadata."
}

function New-ExternalHnsNetwork
{
    param (
        [Parameter(Mandatory = $true)][bool]
        $IsDualStackEnabled
    )
    Logs-To-Event -TaskName "AKS.WindowsCSE.NewExternalHnsNetwork" -TaskMessage "Start to create new external hns network"

    $ParsedContent = GetMetadataContent
    if (-not $ParsedContent)
    {
        Write-Log "Failed to retrieve metadata content."
        exit 1
    }

    $ipv4Address = GetIpv4AddressFromParsedContent -ParsedContent $ParsedContent
    if (-not $ipv4Address)
    {
        Write-Log "Failed to retrieve IPv4 address from metadata."
        throw "No IPv4 address found in metadata."
    }

    Write-Log "Got node IPv4 address: $( $ipv4Address )"
    $nodeIPs = @($ipv4Address)

    if ($IsDualStackEnabled)
    {
        $ipv6Address = GetIpv6AddressFromParsedContent -ParsedContent $ParsedContent
        if ($ipv6Address)
        {
            Write-Log "Get node IPv6 address a: $( $ipv6Address )"
            $nodeIPs += $ipv6Address
        }
        else
        {
            Set-ExitCode -ExitCode $global:WINDOWS_CSE_ERROR_GET_NODE_IPV6_IP -ErrorMessage "Failed to get node IPv6 IP address"
        }
    }

    # we need the default gateway interface to create the external network
    $netIP = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue -ErrorVariable netIPErr -IpAddress $ipv4Address
    if (!$netIP)
    {
        Set-ExitCode -ExitCode $global:WINDOWS_CSE_ERROR_NETWORK_ADAPTER_NOT_EXIST -ErrorMessage "Failed to find any network adaptor with default gateway"
    }

    $na = get-netadapter -ifindex $netIP.ifIndex
    if (!$na)
    {
        Set-ExitCode -ExitCode $global:WINDOWS_CSE_ERROR_NETWORK_ADAPTER_NOT_EXIST -ErrorMessage "Could not find default gateway interface. Please check the network configuration."
    }

    Write-Log "Configuring node ip for kubelet"
    # https://github.com/kubernetes/kubernetes/pull/121028
    if (([version]$global:KubeBinariesVersion).CompareTo([version]("1.29.0")) -ge 0)
    {
        Logs-To-Event -TaskName "AKS.WindowsCSE.UpdateKubeClusterConfig" -TaskMessage "Start to update KubeCluster Config. NodeIPs: $nodeIPs"

        try
        {
            $clusterConfiguration = ConvertFrom-Json ((Get-Content $global:KubeClusterConfigPath -ErrorAction Stop) | Out-String)
            $clusterConfiguration.Kubernetes.Kubelet.ConfigArgs += "--node-ip=$( $nodeIPs -join ',' )"
            $clusterConfiguration | ConvertTo-Json -Depth 10 | Out-File -FilePath $global:KubeClusterConfigPath
        }
        catch
        {
            Set-ExitCode -ExitCode $global:WINDOWS_CSE_ERROR_UPDATING_KUBE_CLUSTER_CONFIG -ErrorMessage "Failed in updating kube cluster config. Error: $_"
        }
    }

    $adapterName = $na.Name
    $externalNetwork = "ext"

    Write-Log "Creating new HNS network `"${externalNetwork}`""
    Write-Log "Using adapter $adapterName with IP address $ipv4Address"

    $stopWatch = New-Object System.Diagnostics.Stopwatch
    $stopWatch.Start()

    # Fixme : use a smallest range possible, that will not collide with any pod space
    if ($IsDualStackEnabled)
    {
        New-HNSNetwork -Type $global:NetworkMode -AddressPrefix @("192.168.255.0/30", "192:168:255::0/127") -Gateway @("192.168.255.1", "192:168:255::1") -AdapterName $adapterName -Name $externalNetwork -Verbose
    }
    else
    {
        New-HNSNetwork -Type $global:NetworkMode -AddressPrefix "192.168.255.0/30" -Gateway "192.168.255.1" -AdapterName $adapterName -Name $externalNetwork -Verbose
    }
    # Wait for the switch to be created and the ip address to be assigned.
    for ($i = 0; $i -lt 60; $i++) {
        $mgmtIPAfterNetworkCreate = Get-NetIPAddress $ipv4Address -ErrorAction SilentlyContinue
        if ($mgmtIPAfterNetworkCreate)
        {
            break
        }
        Start-Sleep -Milliseconds 500
    }

    $stopWatch.Stop()
    if (-not $mgmtIPAfterNetworkCreate)
    {
        Set-ExitCode -ExitCode $global:WINDOWS_CSE_ERROR_MANAGEMENT_IP_NOT_EXIST -ErrorMessage "Failed to find $ipv4Address after creating $externalNetwork network"
    }

    write-log $mgmtIPAfterNetworkCreate

    Write-Log "It took $( $StopWatch.Elapsed.Seconds ) seconds to create the $externalNetwork network."

    Write-Log "Log network adapter info after creating $externalNetwork network"
    Get-NetIPConfiguration -AllCompartments -ErrorAction Ignore

    $dnsServers = Get-DnsClientServerAddress -ErrorAction Ignore
    if ($dnsServers)
    {
        Write-Log "DNS Servers are: $( $dnsServers.ServerAddresses )"
    }
}

function Get-HnsPsm1
{
    Param(
        [Parameter(Mandatory = $true)][string]
        $HNSModule
    )
    Logs-To-Event "ASK.WindowsCSE.GetAndImportHNSModule" -TaskMessage "Start to get and import hns module. NetworkPlugin: $global:NetworkPlugin"

    # HNSModule is C:\k\hns.v2.psm1 when container runtime is Containerd
    $fileName = [IO.Path]::GetFileName($HNSModule)
    # Get-LogCollectionScripts will copy hns module file to C:\k\debug
    $sourceFile = [IO.Path]::Combine('C:\k\debug\', $fileName)
    try
    {
        Write-Log "Copying $sourceFile to $HNSModule."
        Copy-Item -Path $sourceFile -Destination "$HNSModule"
    }
    catch
    {
        Set-ExitCode -ExitCode $global:WINDOWS_CSE_ERROR_DOWNLOAD_HNS_MODULE -ErrorMessage "Failed to copy $sourceFile to $HNSModule. Error: $_"
    }
}
