

## Variables: Script Name and Script Paths
[string]$scriptPath = $MyInvocation.MyCommand.Definition
[string]$scriptName = [IO.Path]::GetFileNameWithoutExtension($scriptPath)
[string]$scriptFileName = Split-Path -Path $scriptPath -Leaf
[string]$scriptRoot = Split-Path -Path $scriptPath -Parent
[string]$invokingScript = (Get-Variable -Name 'MyInvocation').Value.ScriptName

#  Get the invoking script directory
If ($invokingScript) {
	#  If this script was invoked by another script
	[string]$scriptParentPath = Split-Path -Path $invokingScript -Parent
}
Else {
	#  If this script was not invoked by another script, fall back to the directory one level above this script
	[string]$scriptParentPath = (Get-Item -LiteralPath $scriptRoot).Parent.FullName
}

# ============== Variables ============================
$LogFile = "$scriptParentPath\Logs\ddnsupdate-$(Get-Date -Format yyyyMMdd).log"
$ConfigDefault = "$scriptParentPath\configs\ddnspasswords.ini"
$Logger = ""


##*===============================================
##* FUNCTIONS
##*===============================================
## Send-Gmail - Send a gmail message
## By Rodney Fisk - xizdaqrian@gmail.com
## 2 / 13 / 2011

# Get command line arguments to fill in the fields
# Must be the first statement in the script
Function Send-Gmail{
    param(
        [Parameter(Mandatory = $true,
                        Position = 0,
                        ValueFromPipelineByPropertyName = $true)]
        [Alias('From')] # This is the name of the parameter e.g. -From user@mail.com
        [String]$EmailFrom, # This is the value [Don't forget the comma at the end!]

        [Parameter(Mandatory = $true,
                        Position = 1,
                        ValueFromPipelineByPropertyName = $true)]
        [Alias('To')]
        [String[]]$EmailTo,

        [Parameter(Mandatory = $true,
                        Position = 2,
                        ValueFromPipelineByPropertyName = $true)]
        [Alias( 'Subj' )]
        [String]$EmailSubj,

        [Parameter(Mandatory = $true,
                        Position = 3,
                        ValueFromPipelineByPropertyName = $true)]
        [Alias( 'Body' )]
        [String]$EmailBody,

        [Parameter(Mandatory = $false,
                        Position = 4,
                        ValueFromPipelineByPropertyName = $true)]
        [Alias( 'Attachment' )]
        [String[]]$EmailAttachments

    )

    # From Christian @ StackOverflow.com
    $SMTPServer = "smtp.gmail.com" 
    $SMTPClient = New-Object Net.Mail.SMTPClient( $SmtpServer, 587 )  
    $SMTPClient.EnableSSL = $true 
    $SMTPClient.Credentials = New-Object System.Net.NetworkCredential( "GMAIL_USERNAME", "GMAIL_PASSWORD" ); 

    # From Core @ StackOverflow.com
    $emailMessage = New-Object System.Net.Mail.MailMessage
    $emailMessage.From = $EmailFrom
    foreach ( $recipient in $EmailTo )
    {
        $emailMessage.To.Add( $recipient )
    }
    $emailMessage.Subject = $EmailSubj
    $emailMessage.Body = $EmailBody
    # Do we have any attachments?
    # If yes, then add them, if not, do nothing
    if ( $EmailAttachments.Count -ne $NULL ) 
    {
        $emailMessage.Attachments.Add()
    }
    $SMTPClient.Send( $emailMessage )
}

# Parse the content of an INI file, return a hash with values.
# Source: Artem Tikhomirov. http://stackoverflow.com/a/422529
Function Parse-IniFile ($file) {
    $ini = @{}
    switch -regex -file $file
    {
      "^\[(.+)\]$"
      {
        $section = $matches[1]
        $ini[$section] = @{}
      }
      "(.+)=(.+)"
      {
        $name,$value = $matches[1..2]
        $ini[$section][$name] = $value
      }
    }
    $ini
}
# Write a message to log.
function Log-Message ($MSG) {
	$script:Logger += "$(get-date -format u) $MSG`n"
	Write-Output $MSG
}

# Write an error to log.
function Log-Error ($MSG) {
	$script:Logger += "$(get-date -format u) ERROR`: $MSG`n"
	Write-Error "ERROR`: $MSG"
}

# Write contents of log to file.
function Flush-Log {
	Write-Output $script:Logger | Out-File $LogFile -Append
}

# Send an email with the contents of the log buffer.
# SMTP configuration and credentials are in the configuration dictionary.
function Email-Log ($config, $message) {
	$EmailFrom        = $config["EmailFrom"]
	$EmailTo          = $config["EmailTo"]
	$EmailSubject     = "DDNS log $(get-date -format u)"  
	  
	$SMTPServer       = $config["SMTPServer"]
	$SMTPPort         = $config["SMTPPort"]
	$SMTPAuthUsername = $config["SMTPAuthUsername"]
	$SMTPAuthPassword = $config["SMTPAuthPassword"]

	#$mailmessage = New-Object System.Net.Mail.MailMessage 
	#$mailmessage.From = $EmailFrom
	#$mailmessage.To.Add($EmailTo)
	#$mailmessage.Subject = $EmailSubject
	#$mailmessage.Body = $message

	#$SMTPClient = New-Object Net.Mail.SmtpClient($SmtpServer, $SMTPPort) 
	#$SMTPClient.EnableSsl = $true 
	#$SMTPClient.Credentials = New-Object System.Net.NetworkCredential("$SMTPAuthUsername", "$SMTPAuthPassword") 
	#$SMTPClient.Send($mailmessage)

    $credentials = new-object Management.Automation.PSCredential "$SMTPAuthUsername", ("$SMTPAuthPassword" | ConvertTo-SecureString -AsPlainText -Force)
    Send-MailMessage -From $EmailFrom  -to $EmailTo -Subject $EmailSubject `
    -Body $message -SmtpServer $SMTPServer -port $SMTPPort -UseSsl `
    -Credential $credentials
    Log-Message "EMAIL: sent email to $recipient"
}

function Get-WebClient ($config) {
	$client = New-Object System.Net.WebClient
	if ($config["ProxyEnabled"]) {
		$ProxyAddress  = $config["ProxyAddress"]
		$ProxyPort     = $config["ProxyPort"]
		$ProxyDomain   = $config["ProxyDomain"]
		$ProxyUser     = $config["ProxyUser"]
		$ProxyPassword = $config["ProxyPassword"]
		$proxy         = New-Object System.Net.WebProxy
		$proxy.Address = $ProxyAddress
		if ($ProxyPort -and $ProxyPort -ne 80) {
			$proxy.Address = "$ProxyAddress`:$ProxyPort"
		} else {
			$proxy.Address = $ProxyAddress
		}
		$account = New-Object System.Net.NetworkCredential($ProxyUser, $ProxyPassword, $ProxyDomain)
		$proxy.Credentials = $account
		$client.Proxy = $proxy
		
	}
	$client
}


Function Update-DDNS{
<#
.SYNOPSIS
    Update-DDNS.ps1 
.DESCRIPTION
    Update Dynamic DNS on Namecheap.com via HTTP GET request.
.EXAMPLE
    Update-DDNS.ps1 
.NOTES
    https://dynamicdns.park-your-domain.com/update?host=[host]&domain=[domain_name]&password=[ddns_password]&ip=[your_ip]
.LINK
	https://www.namecheap.com/support/knowledgebase/article.aspx/29/11/how-do-i-use-a-browser-to-dynamically-update-the-hosts-ip
#>

Param (
    [Parameter(Mandatory=$false,Position=1)]
    [string] $ConfigFile,
    [Parameter(Mandatory=$false,Position=2)]
    [boolean] $forceUpdate = $false
    )
Begin {
    Log-Message "START: Dynamic DNS Update Client Started"

    $usedefault = $false
    Try{
        Test-Path $ConfigFile -ErrorAction SilentlyContinue
        Log-Message "CONFIG: Configuration file parameter specified and found: $ConfigFile"
        $ConfigINI = $ConfigFile
    }
    Catch{
        If (Test-Path $ConfigDefault -ErrorAction SilentlyContinue){
            Log-Message "CONFIG: No config parameter found, using default configuration file: $ConfigDefault"
            $ConfigINI = $ConfigDefault
        }
        Else {
            Log-Message "CONFIG: No configuration file [$ConfigDefault] found, exiting script"
            exit 1
        }

    }

    # Load configuration:
    Log-Message "Parsing $ConfigINI"
    $config = Parse-IniFile ($ConfigINI)
    if ($config.Count -eq 0) {
	    Log-Error "The file $ConfigINI didn't have any valid settings"
	    exit 2
    }
}
Process{
    try {
	    
	    # Create a new web client
	    $client = Get-WebClient($config.Proxy)

	    # Get current public IP address
	    Log-Message "INFO: Retrieving the current public IP address"
	    $Pattern   = '\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}'
	    $global:CurrentIp = $client.DownloadString('http://myip.dnsomatic.com/')
	    Log-Message "INFO: Retrieving stored IP address"
	    $StoredIp  = [Environment]::GetEnvironmentVariable("PUBLIC_IP","User")
	    if (!($global:CurrentIp -match $Pattern)) {
		    Log-Error "A valid public IP address could not be retrieved"
		    exit 3
	    }
	    Log-Message "Stored IP: [$StoredIp] Retrieved IP: [$global:CurrentIp]"
	    # Compare current IP address with environment variable
        $compareIPs = Compare-Object $StoredIp $CurrentIp -IncludeEqual -ExcludeDifferent -ErrorAction SilentlyContinue   
	    if (($compareIPs) -and !$forceUpdate) {
		    Log-Message "INFO: IP has not changed since last run; no changes will be made"
	    }
        Else {
            [Environment]::SetEnvironmentVariable("PUBLIC_IP", $global:CurrentIp, "User")
            Log-Message "UPDATE: Stored IP address updated to: $global:CurrentIp"
    
            #Update DDNS for home network
            $OpenDNS = $config.OpenDNS
            $OpenDNSNetwork   = $OpenDNS["OpenDNSNetwork"]
		    $OpenDNSUsername  = $OpenDNS["OpenDNSUsername"]
		    $OpenDNSPassword  = $OpenDNS["OpenDNSPassword"]
		    $OpenDNSURL       = $OpenDNS["OpenDNSURL"]
            $OpenDNSToken     = $OpenDNS["OpenDNSToken"]
            Try{
                $client = New-Object System.Net.Webclient
                $client.Credentials = New-Object System.Net.NetworkCredential($OpenDNSUsername,$OpenDNSPassword)
                #$client.UploadString($OpenDNSURL,"/nic/update?hostname=$OpenDNSNetwork")
                $response = $client.UploadString($OpenDNSURL,"/nic/update?token=$OpenDNSToken&v=2&hostname=$OpenDNSNetwork")
                Log-Message "OPENDNS: Updated OpenDNS network:" $OpenDNSNetwork
            }
            Catch{
                Log-Message "ERROR: Unable to update OpenDNS network:" $OpenDNSNetwork
            }

            $Domains = $config.Domain
            # Return each hashtable key and value
            $Domains.Keys | % {
                $key = $_
                $keyval = $Domains.$key
                $keyval  
	            Log-Message "UPDATE: Setting IP address on domain registrar for [$key]"
                # spit up key entry to find subdomain
	            $DDNSSubdomain = $key.split(".")[0]
	            $DDNSDomain    = $key.split(".")[1] + "." + $key.split(".")[2]
	            $DDNSPassword  = $keyval
                #sent uri response to namecheap
	            $UpdateUrl     = "https://dynamicdns.park-your-domain.com/update?host=$DDNSSubdomain&domain=$DDNSDomain&password=$DDNSPassword&ip=$global:CurrentIp"
	            $UpdateDDNS    = $client.DownloadString($UpdateUrl)
	            #Log-Message "URL: $UpdateUrl"
                #Log-Message "$UpdateDDNS"
	            Log-Message "UPDATE: DDNS for [$key] Updated at namecheap.com"
	    
            }

            $Ports = $config.PublicIP
            $Ports.Keys | % {
                $key = $_
                $keyval = $Ports.$key
                $keyval
                If ($key -eq "PublicIP"){
                    Log-Message ""
	                Log-Message "UPDATE: Setting Public IP address to: http://$($global:CurrentIp):$($keyval)"
                }
                Else{
                    Log-Message ""
	                Log-Message "UPDATE: Setting Public IP address to: http://$($key):$($keyval)"
                }
            }

            Email-Log $config.Email $Logger

        }
        Log-Message "DONE: Update-DDNS script Finished"
    }
    catch [System.Exception] {
	    Log-Error $_.Exception.Message
	    exit 5
    } 
}
	End {Flush-Log}
}

##*===============================================
##* MAIN
##*===============================================
If ($args.Count -eq 0){
    Update-DDNS 
}
Elseif($args.Count -eq 2){
    Update-DDNS -ConfigFile $args[0] -forceUpdate $true
}
Else{
    Update-DDNS -ConfigFile $args[0]
}





