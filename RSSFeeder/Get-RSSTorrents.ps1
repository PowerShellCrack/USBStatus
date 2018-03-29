<#
    Part 1:
    Get a list of all shows you want to monitor

    Part 2:
     - Create RSS feed acounts with showrss.info and zooqle.com
     - Add the shows you want to monitor to your account
     - Disable magnet download feature when possible
     - paste the feed url in the corresponding variable below

    Part 3
     - Download TVRename: http://www.tvrename.com/
     - Add the shows you want to monitor and give it a destination path
     - In Options-->Preference make sure Automatic Export-->Missing XML is enabled, get path for xml

    If the this scripts finds a torrent and downloads it, it will exit with a code of 3
    If the this scripts does not find a file that matches your missing shows, it will exit with a code of 2
    If the this script fails to download the torrent, it will exit with a code of 1
    
    Use the codes above to use other scripts if needed.

    Part 4 (optional)
     - follow guid http://justanotherpsblog.com/plex-automation/
     - Download SONARR: https://sonarr.tv/
     - Have it monitor your TV shows folders

#>
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

# DECLARE VARIABLES
#===============================================
[boolean]$Debug = $false

[string]$LogFile = "E:\Data\Processors\Logs\RSSTorrents-$(Get-Date -Format yyyyMMdd).log"
$DownloadTorrentPath = "E:\Data\Downloads\Torrents\files"
$ProcessedTorrentPath = "E:\Data\Downloads\Torrents\processed"
$FailedTorrentPath = "E:\Data\Downloads\Torrents\failed"
$MissingShowsXML = "E:\Data\Downloads\Torrents\showsmissing.xml"
$global:QueuedShowsList = "E:\Data\Downloads\Torrents\showsqueued.list"
$global:ShowsNotFoundList = "E:\Data\Downloads\Torrents\showsnotfound.list"
$ShowsNotFoundMaxCount = 20

[int]$downloadcnt = 0

[uri]$MissingShowsSONARR = 'http://localhost:8989/wanted/missing'

# RSS FEEDS
#==================
$RSSFeeds = 'https://zooqle.com/rss/tv/<YourRSSFeedLink>.rss',
'http://showrss.info/user/<YourRSSFeedLink>.rss?magnets=false&namespaces=false&name=null&quality=sd&re=null',
'https://eztv.ag/ezrss.xml'


$URLFeeds = 'https://thepiratebay.org/tv/latest/',
'https://thepiratebay.org/top/205'

$EZTVSearch = 'https://eztv.ag'
$EZTVApiURL = 'https://eztv.ag/api/get-torrents?imdb_id'

#https://piratebay.to/pub/rss/Category_2.rss.xml
[boolean]$searchEZTV = $true # Will auto search EZTV for torrent if no torrents are found in the above feeds
[boolean]$searchEZTVApi = $false # Will auto search EZTV for torrent if no torrents are found in the above feeds

[int]$FileSizeLimitBytes = 629145600

$userAgent = 'FireFox'

If (!(Test-Path $MissingShowsXML)){Exit 0}
#FUNCTIONS - DO NOT MODIFY BELOW
#====================================================================================================================

function Get-HrefMatches{
    param(
    ## The filename to parse
    [Parameter(Mandatory = $true)]
    [string] $content,
    
    ## The Regular Expression pattern with which to filter
    ## the returned URLs
    [string] $Pattern = "<\s*a\s*[^>]*?href\s*=\s*[`"']*([^`"'>]+)[^>]*?>"
)

    $returnMatches = new-object System.Collections.ArrayList

    ## Match the regular expression against the content, and
    ## add all trimmed matches to our return list
    $resultingMatches = [Regex]::Matches($content, $Pattern, "IgnoreCase")
    foreach($match in $resultingMatches)
    {
        $cleanedMatch = $match.Groups[1].Value.Trim()
        [void] $returnMatches.Add($cleanedMatch)
    }

    $returnMatches
}

Function Get-Hyperlinks {
    param(
    [Parameter(Mandatory = $true)]
    [string] $content,
    [string] $Pattern = "<A[^>]*?HREF\s*=\s*""([^""]+)""[^>]*?>([\s\S]*?)<\/A>"
    )
    $resultingMatches = [Regex]::Matches($content, $Pattern, "IgnoreCase")
    
    $returnMatches = @()
    foreach($match in $resultingMatches){
        $LinkObjects = New-Object -TypeName PSObject
        $LinkObjects | Add-Member -Type NoteProperty `
            -Name Text -Value $match.Groups[2].Value.Trim()
        $LinkObjects | Add-Member -Type NoteProperty `
            -Name Href -Value $match.Groups[1].Value.Trim()
        
        $returnMatches += $LinkObjects
    }
}

function Create-Url {
    [CmdletBinding()]
    param (
        #using parameter sets even though only one since we'll likely beef up this method to take other input types in future
        [Parameter(ParameterSetName='UriFormAction', Mandatory = $true)]
        [System.Uri]$Uri
        ,
        [Parameter(ParameterSetName='UriFormAction', Mandatory = $true)]
        [Microsoft.PowerShell.Commands.FormObject]$Form
    )
    process {  
        $builder = New-Object System.UriBuilder
        $builder.Scheme = $url.Scheme
        $builder.Host = $url.Host
        $builder.Port = $url.Port
        $builder.Path = $form.Action
        write-output $builder.ToString()
    }
}

Function Start-Log{
    param (
        [ValidateScript({ Split-Path $_ -Parent | Test-Path })]
        [string]$FilePath
    )
 
    try{
        if (!(Test-Path $FilePath))
        {
             ## Create the log file
             New-Item $FilePath -Type File | Out-Null
        }
 
        ## Set the global variable to be used as the FilePath for all subsequent Write-Log
        ## calls in this session
        $global:ScriptLogFilePath = $FilePath
    }
    catch{
        Write-Error $_.Exception.Message
    }
}

Function Write-Log {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message,
        
        [string]$CustomComponent,

        [Parameter()]
        [ValidateSet(0, 1, 2, 3, 4, 5)]
        [int]$ColorLevel = 1,
        [switch]$HostMsg,
        [switch]$NewLine

    )
    Switch ($ColorLevel)
        {
            0 {$fgColor = 'White'; $LogLevel = 1}
            1 {$fgColor = 'Gray'; $LogLevel = 1}
            2 {$fgColor = 'Yellow'; $LogLevel = 2}
            3 {$fgColor = 'Red'; $LogLevel = 3}
            4 {$fgColor = 'Cyan'; $LogLevel = 1}
            5 {$fgColor = 'Green'; $LogLevel = 1}
        }

    $TimeGenerated = "$(Get-Date -Format HH:mm:ss).$((Get-Date).Millisecond)+000"
    $Line = '<![LOG[{0}]LOG]!><time="{1}" date="{2}" component="{3}" context="" type="{4}" thread="" file="">'
    If ($CustomComponent){
        $LineFormat = $Message, $TimeGenerated, (Get-Date -Format MM-dd-yyyy), "$CustomComponent".toupper().Replace(" ","_"), $LogLevel
    }
    Else{
        $LineFormat = $Message, $TimeGenerated, (Get-Date -Format MM-dd-yyyy), "$($MyInvocation.ScriptName | Split-Path -Leaf):$($MyInvocation.ScriptLineNumber)", $LogLevel
    }
    $Line = $Line -f $LineFormat
    Add-Content -Value $Line -Path $ScriptLogFilePath -ErrorAction SilentlyContinue

    
    If($NewLine){$NLChar = "`n"}
    If ($HostMsg){
        Write-Host ($Message + $NLChar) -ForegroundColor $fgColor 
    }
}

function Compare-QueuedShows{
    param (
        [Parameter(Mandatory = $true)]
        [string]$byWhat
    )
    # get current saved list (created with each successfull download)
    #$date = Get-Date -Format yyyyMMdd
    $startdate = Get-Date
    $fullList = Get-ListContent $global:QueuedShowsList
    # compare it to what the next show is
    $downloading = 0
    0..5 | %{
      
      $changingDate = ($startdate.AddDays(-$_)).ToString("yyyyMMdd")
      $sectionFound = $fullList["$changingDate"]
      If($sectionFound){
          $Title = $byWhat
          $titleFound = $fullList["$changingDate"]["$Title"]
          If($titleFound){
            $downloading++
            Write-Log -Message "[$Title] was found in queued list under [$changingDate] section from torrent [$titleFound]" -CustomComponent "Section [$changingDate]" -ColorLevel 1 -NewLine -HostMsg 
          }
      }Else{
        Write-Log -Message "No section was found" -CustomComponent "Section [$changingDate]" -ColorLevel 1 -NewLine -HostMsg 
      }
    }

    If ($downloading -gt 0){
        return $true   
    }
    Else{
        Write-Log -Message "[$FullShowTitle] has not been found queued for downloading" -CustomComponent "Torrent" -ColorLevel 2 -NewLine -HostMsg
        return $false
    }
    <#If ($downloadinglist){
        Compare-Object $downloadinglist $FullShowTitle -IncludeEqual -passThru | Where-Object { $_.SideIndicator -eq '==' }
    }
    Else{
        return $false
    }
    #>
}

Function Download-WCTorrent($dns,$webAgent,$FileTitle,$FileUrl,$outFile){
    Write-Host "Downloading torrent file: '$FileUrl', destination '$outFile'" -ForegroundColor Green
    $wc = New-Object System.Net.WebClient
    $wc.UseDefaultCredentials = $true
    $wc.Headers.Add([System.Net.HttpRequestHeader]::UserAgent, [Microsoft.PowerShell.Commands.PSUserAgent]::$webAgent);
    $wc.DownloadFile($FileUrl,$outFile)
    Write-Log -Message "Successfully downloaded a torrent file for: '$FileTitle'" -CustomComponent "$dns Torrent" -ColorLevel 5 -NewLine -HostMsg
    $global:downloadcnt ++
    
    #add show to list
    $Category1 = @{"$FileTitle"="$FileUrl"}
    $NewINIContent = @{"$(Get-Date -Format yyyyMMdd)"=$Category1;}
    Out-ListContent -InputObject $NewINIContent -FilePath $global:QueuedShowsList -Append -NewLine
    #$FileTitle + "=" + $FileUrl | Out-File $global:QueuedShowsList -Append

    $global:failedcnt = 0
    Start-Sleep 5
    $wc.Dispose()
}

function Get-ListContent{
    <#
    $value = $iniContent[“386Enh"][“EGA80WOA.FON"]
    $iniContent[“386Enh"].Keys | %{$iniContent["386Enh"][$_]}
    #>
    [CmdletBinding()]  
    Param(  
        [ValidateNotNullOrEmpty()]  
        [Parameter(Mandatory=$True)]  
        [string]$FilePath
    )
    Begin{
        Write-Verbose "$($MyInvocation.MyCommand.Name):: Function started"
        $ini = @{}
    }
    Process{
        switch -regex -file $FilePath
        {
            "^\[(.+)\]" # Section
            {
                $section = $matches[1]
                $ini[$section] = @{}
                $CommentCount = 0
            }
            "^(;.*)$" # Comment
            {
                $value = $matches[1]
                $CommentCount = $CommentCount + 1
                $name = "Comment" + $CommentCount
                $ini[$section][$name] = $value
            } 
            "(.+?)\s*=(.*)" # Key
            {
                $name,$value = $matches[1..2]
                $ini[$section][$name] = $value
            }
        }
        return $ini
    }
    End{
        Write-Verbose "$($MyInvocation.MyCommand.Name):: Function ended"
    } 
}

function Out-ListContent{
    [CmdletBinding()]  
    Param(  
        [switch]$Append,

        [ValidateSet("Unicode","UTF7","UTF8","UTF32","ASCII","BigEndianUnicode","Default","OEM")]
        [Parameter()]
        [string]$Encoding = "Unicode",

        [ValidateNotNullOrEmpty()]  
        [Parameter(Mandatory=$True)]  
        [string]$FilePath,  
        
        [switch]$Force,
        
        [ValidateNotNullOrEmpty()]
        [Parameter(ValueFromPipeline=$True,Mandatory=$True)]
        [Hashtable]$InputObject,
        
        [switch]$Passthru,
        [switch]$NewLine
    )      
    Begin{
        Write-Verbose "$($MyInvocation.MyCommand.Name):: Function started"
    }     
    Process{ 
        if ($append) {$outfile = Get-Item $FilePath}  
        else {$outFile = New-Item -ItemType file -Path $Filepath -Force:$Force -ErrorAction SilentlyContinue}  
        if (!($outFile)) {Throw "Could not create File"}  
        foreach ($i in $InputObject.keys){
            if (!($($InputObject[$i].GetType().Name) -eq "Hashtable")){
                #No Sections
                Write-Verbose "$($MyInvocation.MyCommand.Name):: Writing key: $i"
                Add-Content -Path $outFile -Value "$i=$($InputObject[$i])" -NoNewline -Encoding $Encoding
            } 
            else {
                #Sections
                Write-Verbose "$($MyInvocation.MyCommand.Name):: Writing Section: [$i]" 
                $fullList = Get-ListContent $FilePath
                $sectionFound = $fullList[$i]

                #if section [] was not found add it
                
                If(!$sectionFound){
                    #Add-Content -Path $outFile -Value "" -Encoding $Encoding
                    Add-Content -Path $outFile -Value "[$i]" -Encoding $Encoding
                    }
                
                Foreach ($j in ($InputObject[$i].keys | Sort-Object)){
                    if ($j -match "^Comment[\d]+") {
                        Write-Verbose "$($MyInvocation.MyCommand.Name):: Writing comment: $j" 
                        Add-Content -Path $outFile -Value "$($InputObject[$i][$j])" -NoNewline -Encoding $Encoding 
                    } 
                    else {
                        Write-Verbose "$($MyInvocation.MyCommand.Name):: Writing key: $j" 
                        Add-Content -Path $outFile -Value "$j=$($InputObject[$i][$j])" -NoNewline -Encoding $Encoding 
                    }
                }
                If($NewLine){Add-Content -Path $outFile -Value "" -Encoding $Encoding}
            }
        }
        Write-Verbose "$($MyInvocation.MyCommand.Name):: Finished Writing to file: $path"
        If($PassThru){Return $outFile}
    }
    End{
        Write-Verbose "$($MyInvocation.MyCommand.Name):: Function ended"
    } 
}

<#
$Category1 = @{"The X-Files - S11E05 - Ghouli"="https://zoink.ch/torrent/Supergirl.S03E13.HDTV.x264-SVA[eztv].mkv.torrent"}
$Category2 = @{"Key1"="Value1";"Key2"="Value2"}
$NewINIContent = @{"$(Get-Date -Format yyyyMMdd)"=$Category1;}
$NewINIContent = @{"$(Get-Date -Format yyyyMMdd)"=$Category1;"Category2"=$Category2}
Out-ListContent -InputObject $NewINIContent -FilePath $global:QueuedShowsList
#>


function Remove-ListContent
{
    <#
    .SYNOPSIS
    Removes an entry/line/setting from an INI file.
    
    .DESCRIPTION
    A configuration file consists of sections, led by a `[section]` header and followed by `name = value` entries.  This function removes an entry in an INI file.  Something like this:

        [ui]
        username = Regina Spektor <regina@reginaspektor.com>

        [extensions]
        share = 
        extdiff =

    Names are not allowed to contains the equal sign, `=`.  Values can contain any character.  The INI file is parsed using `Split-Ini`.  [See its documentation for more examples.](Split-Ini.html)
    
    If the entry doesn't exist, does nothing.

    Be default, operates on the INI file case-insensitively. If your INI is case-sensitive, use the `-CaseSensitive` switch.

    .LINK
    Set-IniEntry

    .LINK
    Split-Ini

    .EXAMPLE
    Remove-IniEntry -Path C:\Projects\Carbon\StupidStupid.ini -Section rat -Name tails

    Removes the `tails` item in the `[rat]` section of the `C:\Projects\Carbon\StupidStupid.ini` file.

    .EXAMPLE
    Remove-IniEntry -Path C:\Users\me\npmrc -Name 'prefix' -CaseSensitive

    Demonstrates how to remove an INI entry in an INI file that is case-sensitive.
    #>
    [CmdletBinding(SupportsShouldProcess=$true)]
    param
    (
        [Parameter(Mandatory=$true)]
        [string]
        # The path to the INI file.
        $Path,
        [string]
        # The name of the INI entry to remove.
        $Name,
        [string]
        # The section of the INI where the entry should be set.
        $Section,
        [Switch]
        # Removes INI entries in a case-sensitive manner.
        $CaseSensitive
    )

    $settings = @{ }
    
    if( Test-Path $Path -PathType Leaf ){
        $settings = Split-ListContent -Path $Path -AsHashtable -CaseSensitive:$CaseSensitive
    }
    else{
        Write-Error ('INI file {0} not found.' -f $Path)
        return
    }
    $key = $Name
    if( $Section )
    {
        $key = '{0}.{1}' -f $Section,$Name
    }

    if( $settings.ContainsKey( $key ) )
    {
        $lines = New-Object 'Collections.ArrayList'
        Get-Content -Path $Path | ForEach-Object { [void] $lines.Add( $_ ) }
        $null = $lines.RemoveAt( ($settings[$key].LineNumber - 1) )
        if( $PSCmdlet.ShouldProcess( $Path, ('remove INI entry {0}' -f $key) ) )
        {
            if( $lines ){
                $lines | Set-Content -Path $Path
            }
            else{
                Clear-Content -Path $Path
            }
        }
    }
}


function Split-ListContent
{
    <#
    .SYNOPSIS
    Reads an INI file and returns its contents.
    
    .DESCRIPTION
    A configuration file consists of sections, led by a "[section]" header and followed by "name = value" entries:

        [spam]
        eggs=ham
        green=
           eggs
         
        [stars]
        sneetches = belly
         
    By default, the INI file will be returned as `Carbon.Ini.IniNode` objects for each name/value pair.  For example, given the INI file above, the following will be returned:
    
        Line FullName        Section Name      Value
        ---- --------        ------- ----      -----
           2 spam.eggs       spam    eggs      ham
           3 spam.green      spam    green     eggs
           7 stars.sneetches stars   sneetches belly
    
    It is sometimes useful to get a hashtable back of the name/values.  The `AsHashtable` switch will return a hashtable where the keys are the full names of the name/value pairs.  For example, given the INI file above, the following hashtable is returned:
    
        Name            Value
        ----            -----
        spam.eggs       Carbon.Ini.IniNode;
        spam.green      Carbon.Ini.IniNode;
        stars.sneetches Carbon.Ini.IniNode;
        }

    Each line of an INI file contains one entry. If the lines that follow are indented, they are treated as continuations of that entry. Leading whitespace is removed from values. Empty lines are skipped. Lines beginning with "#" or ";" are ignored and may be used to provide comments.

    Configuration keys can be set multiple times, in which case Split-Ini will use the value that was configured last. As an example:

        [spam]
        eggs=large
        ham=serrano
        eggs=small

    This would set the configuration key named "eggs" to "small".

    It is also possible to define a section multiple times. For example:

        [foo]
        eggs=large
        ham=serrano
        eggs=small

        [bar]
        eggs=ham
        green=
           eggs

        [foo]
        ham=prosciutto
        eggs=medium
        bread=toasted

    This would set the "eggs", "ham", and "bread" configuration keys of the "foo" section to "medium", "prosciutto", and "toasted", respectively. As you can see, the only thing that matters is the last value that was set for each of the configuration keys.

    Be default, operates on the INI file case-insensitively. If your INI is case-sensitive, use the `-CaseSensitive` switch.

    .LINK
    Set-IniEntry

    .LINK
    Remove-IniEntry

    .EXAMPLE
    Split-Ini -Path C:\Users\rspektor\mercurial.ini 

    Given this INI file:

        [ui]
        username = Regina Spektor <regina@reginaspektor.com>

        [extensions]
        share = 
        extdiff =

    `Split-Ini` returns the following objects to the pipeline:

        Line FullName           Section    Name     Value
        ---- --------           -------    ----     -----
           2 ui.username        ui         username Regina Spektor <regina@reginaspektor.com>
           5 extensions.share   extensions share    
           6 extensions.extdiff extensions extdiff  

    .EXAMPLE
    Split-Ini -Path C:\Users\rspektor\mercurial.ini -AsHashtable

    Given this INI file:

        [ui]
        username = Regina Spektor <regina@reginaspektor.com>

        [extensions]
        share = 
        extdiff =

    `Split-Ini` returns the following hashtable:

        @{
            ui.username = Carbon.Ini.IniNode (
                                FullName = 'ui.username';
                                Section = "ui";
                                Name = "username";
                                Value = "Regina Spektor <regina@reginaspektor.com>";
                                LineNumber = 2;
                            );
            extensions.share = Carbon.Ini.IniNode (
                                    FullName = 'extensions.share';
                                    Section = "extensions";
                                    Name = "share"
                                    Value = "";
                                    LineNumber = 5;
                                )
            extensions.extdiff = Carbon.Ini.IniNode (
                                       FullName = 'extensions.extdiff';
                                       Section = "extensions";
                                       Name = "extdiff";
                                       Value = "";
                                       LineNumber = 6;
                                  )
        }

    .EXAMPLE
    Split-Ini -Path C:\Users\rspektor\mercurial.ini -AsHashtable -CaseSensitive

    Demonstrates how to parse a case-sensitive INI file.

        Given this INI file:

        [ui]
        username = user@example.com
        USERNAME = user2example.com

        [UI]
        username = user3@example.com


    `Split-Ini -CaseSensitive` returns the following hashtable:

        @{
            ui.username = Carbon.Ini.IniNode (
                                FullName = 'ui.username';
                                Section = "ui";
                                Name = "username";
                                Value = "user@example.com";
                                LineNumber = 2;
                            );
            ui.USERNAME = Carbon.Ini.IniNode (
                                FullName = 'ui.USERNAME';
                                Section = "ui";
                                Name = "USERNAME";
                                Value = "user2@example.com";
                                LineNumber = 3;
                            );
            UI.username = Carbon.Ini.IniNode (
                                FullName = 'UI.username';
                                Section = "UI";
                                Name = "username";
                                Value = "user3@example.com";
                                LineNumber = 6;
                            );
        }

    #>
    [CmdletBinding(SupportsShouldProcess=$true)]
    param(
        [Parameter(Mandatory=$true,ParameterSetName='ByPath')]
        [string]
        # The path to the mercurial INI file to read.
        $Path,
        
        [Switch]
        # Pass each parsed setting down the pipeline instead of collecting them all into a hashtable.
        $AsHashtable,

        [Switch]
        # Parses the INI file in a case-sensitive manner.
        $CaseSensitive
    )

    if( -not (Test-Path $Path -PathType Leaf) ){
        Write-Error ("INI file '{0}' not found." -f $Path)
        return
    }
    
    $sectionName = ''
    $lineNum = 0
    $lastSetting = $null
    $settings = @{ }
    if( $CaseSensitive ){
        $settings = New-Object 'Collections.Hashtable'
    }
    
    Get-Content -Path $Path | ForEach-Object {
        
        $lineNum += 1
        
        if( -not $_ -or $_ -match '^[;#]' ){
            if( -not $AsHashtable -and $lastSetting ){
                $lastSetting
            }
            $lastSetting = $null
            return
        }
        
        if( $_ -match '^\[([^\]]+)\]' ){
            if( -not $AsHashtable -and $lastSetting ){
                $lastSetting
            }
            $lastSetting = $null
            $sectionName = $matches[1]
            Write-Debug "Parsed section [$sectionName]"
            return
        }
        
        if( $_ -match '^\s+(.*)$' -and $lastSetting ){
            $lastSetting.Value += "`n" + $matches[1]
            return
        }
        
        if( $_ -match '^([^=]*) ?= ?(.*)$' ){
            if( -not $AsHashtable -and $lastSetting ){
                $lastSetting
            }
            
            $name = $matches[1]
            $value = $matches[2]
            
            $name = $name.Trim()
            $value = $value.TrimStart()
            
            $setting = [pscustomobject]@{Section = $sectionName; Name = $name; Value = $value;LineNumber = $lineNum}
            #$setting = New-Object Carbon.Ini.IniNode $sectionName,$name,$value,$lineNum
            $settings[$setting.Section] = $setting
            $lastSetting = $setting
            Write-Debug "Parsed setting '$($setting.Section)'"
        }
    }
    
    if( $AsHashtable ){
        return $settings
    }
    else{
        if( $lastSetting ){
            $lastSetting
        }
    }
}

# PROCESS SHOWS
#====================================================================================================================
Add-Type -Assembly System.Web
Start-Log -FilePath $LogFile
Write-Log -Message "Parsing missing shows from '$MissingShowsXML'" -CustomComponent 'TVRename XML Export' -ColorLevel 0 -HostMsg

[xml]$tvXML = get-content $MissingShowsXML
$MissingShows = $tvXML.TVRename.MissingItems.MissingItem
$MissingSeasons = $tvXML.TVRename.MissingItems.MissingItem.Season
$MissingEpisode = $tvXML.TVRename.MissingItems.MissingItem.Episode

#trim the missing names to display on the title
# remove all duplicate entries
$missingNames = @()
Foreach ($missingShow in $MissingShows){
    $title = ($Missingshow.title).replace(":","").replace("'","").Split("(")[0].trim()
    $imdbID = $Missingshow.imdbid
    [int]$Season = $Missingshow.season
    [int]$Episode = $Missingshow.episode
    $EpisodeName = ($Missingshow.episodeName).replace("(","").replace(")","").trim()
    $titleES = "$title - S$($Season)E$($Episode)"
    $Searchable1 = ("$title " + "S" + $Missingshow.Season + "E" + $Missingshow.Episode).Replace(":","").Replace(".","").Replace(" ","-")
    $Searchable2 = $Searchable1.Replace("-",".")
    $Searchable3 = ("S" + $Missingshow.season + "E" + $Missingshow.episode)
    $FullTitle = ("$title - " + "S" + $Missingshow.season + "E" + $Missingshow.episode + " - $EpisodeName").Replace(":","").Replace(".","")

    $obj = New-Object PSobject
    $obj | Add-Member Noteproperty Title $title
    $obj | Add-Member Noteproperty ImdbId $imdbID
    $obj | Add-Member Noteproperty Season $Season 
    $obj | Add-Member Noteproperty Episode $Episode
    $obj | Add-Member Noteproperty EpisodeName $EpisodeName
    $obj | Add-Member Noteproperty TitleES $TitleES
    $obj | Add-Member Noteproperty Downloaded $False
    $obj | Add-Member Noteproperty SearchwithDash $Searchable1
    $obj | Add-Member Noteproperty SearchwithDot $Searchable2
    $obj | Add-Member Noteproperty SearchSeasonEpisode $Searchable3
    $obj | Add-Member Noteproperty FullTitle $FullTitle
    Write-Log -Message "Added missing show: '$FullTitle' to the 'Search List'" -CustomComponent 'Missing Show List'
    $missingNames += $obj
}
#$missingNames = $missingNames | select -uniq

Write-Host "Looking for missing episodes from shows:" -ForegroundColor Cyan
#Write-Host "$($missingNames | Out-String)"
Write-Host ($missingNames | Select Title,Season,Episode,EpisodeName | Sort-Object Title | Out-String)
start-sleep 2
#cls

$TextInfo = (Get-Culture).TextInfo

#====================================================================================================================
# RSS FEED MAIN
#====================================================================================================================
foreach ($Feed in $RSSFeeds){
    [uri]$URIFeed = $Feed

    $domainHost = $URIFeed.Authority -replace '^www\.'
    $domain = $domainHost.Split('.')[0]
    $domain = $TextInfo.ToTitleCase("$domain")

    Write-Log -Message "Retrieving all shows from: '$URIFeed'" -CustomComponent "$domain RSS FEED" -ColorLevel 2 -HostMsg
    #$page = Invoke-WebRequest $URIFeed -UserAgent [Microsoft.PowerShell.Commands.PSUserAgent]::$userAgent
    try {
        $page = Invoke-WebRequest $URIFeed -UserAgent [Microsoft.PowerShell.Commands.PSUserAgent]::$userAgent -TimeoutSec 240 -ErrorAction:Stop
    } 
    catch [Exception]{
        Write-Log -Message "Error: $($_.Exception.Message)" -CustomComponent "$domain Search" -ColorLevel 3 -HostMsg -NewLine
        continue
    }
    $content = $page.Content
    $rssxml = [XML]$content
    $rssxmltitles = $rssxml.rss.channel.item
    $rssNames = @()
    Foreach ($rssxmltitle in $rssxmltitles)
    {
        $parseShow = $true
        $parsedTitle = $rssxmltitle.Title
        write-host "Parsing show:" $parsedTitle
        
        $ParsebyRegex = $parsedTitle -split 'S(?<season>\d{1,2})E(?<episode>\d{1,2})'
        $ParsebySplit = $parsedTitle.Split("–")[0].Split("(")[0].trim()
        If ($ParsebyRegex -eq $ParsebySplit){$parseShow = $false}

        If (($ParsebyRegex -eq $rssxmltitle.Title) -and ($parseShow -eq $true)){
            $showtitle = ($rssxmltitle.Title).Split("–")[0].Split("(")[0].trim() 
            If($showtitle -ne $null){$parseShow = $true}
            $title = ($rssxmltitle.Title).Split("–")[0].Split("(")[0].trim()
            [int]$Season = "{0:D2}" -f ($rssxmltitle.Title).Split("–")[1].split("x")[0].trim()
            [int]$Episode = "{0:D2}" -f ($rssxmltitle.Title).Split("–")[1].split("x")[1].split(":")[0].trim()
            $titleES = "$showtitle - S$($Season)E$($Episode)"
        }

        If (($ParsebySplit -eq $rssxmltitle.Title) -and ($parseShow -eq $true)){
            $showtitle = $rssxmltitle.Title -split 'S(?<season>\d{1,2})E(?<episode>\d{1,2})'
            #$title = $showtitle[0].trim()
            $title = $showtitle[0].replace("."," ").trim()
            If($title -ne $null){$parseShow = $true}
            [int]$Season = "{0:D2}" -f $showtitle[1].trim()
            [int]$Episode = "{0:D2}" -f $showtitle[2].trim()
            $titleES = "$title - S$($Season)E$($Episode)"
        }

        If ($rssxmltitle.enclosure.url){
            $url = New-Object System.Uri($rssxmltitle.enclosure.url)
            $file = $url.Segments[-1]
            $filehash = $rssxmltitle.infoHash   
            $magnet = $rssxmltitle.magnetURI.'#cdata-section'
        } 
        Else{
            $file = $rssxmltitle.Torrent | select -expand infohash
            $url = "https://torrasave.download/torrent/$file.torrent" 
        }  

        If ($parseShow){
            $obj = New-Object PSobject
            $obj | Add-Member Noteproperty Parse $parsedTitle
            $obj | Add-Member Noteproperty Title $title
            $obj | Add-Member Noteproperty Season $Season 
            $obj | Add-Member Noteproperty Episode $Episode
            $obj | Add-Member Noteproperty TitleES $TitleES
            $obj | Add-Member Noteproperty URL $url
            $obj | Add-Member Noteproperty Torrent $File
            $obj | Add-Member Noteproperty Magnet $magnet
            Write-Log -Message "Added show: '$TitleES' to the '$domain Compare List'" -CustomComponent "$domain Show List"
            $rssNames += $obj
        } Else {
            Write-Log -Message "Unable to parse show: $showtitle" -CustomComponent "$domain Show List" -ColorLevel 2 -HostMsg -NewLine
        }
    }

    Write-Host "`nAvailable shows from RSS [$URIFeed] are:" -ForegroundColor Cyan
    Write-Host ($rssNames | Select Title,Season,Episode | Sort-Object Title | Out-String)
    start-sleep 2

    Write-Log -Message "Comparing '$domain Show List' shows with 'Missing Show List'" -CustomComponent "$domain Compare List" -ColorLevel 4 -HostMsg -NewLine
    $ComparedShows = Compare-Object $rssNames $missingNames -IncludeEqual -passThru -Property TitleES | Where-Object { $_.SideIndicator -eq '==' }
    If ($ComparedShows.count -gt 0){
        Write-Log -Message "Found $($ComparedShows.count) that might match, will process further" -CustomComponent "$domain Match Count" -ColorLevel 0 -HostMsg
        $ComparedShows | Foreach {
            [string]$Parsed = $_.Parse
            [string]$Title = $_.Title
            [int]$Season = $_.Season
            [int]$Episode = $_.Episode
            [string]$FullShowTitle = $_.TitleES

            [string]$TorrentURL = $_.URL
            [string]$TorrentFile = $_.Torrent
        
            $ProcessedTorrentFile = Join-Path -Path $ProcessedTorrentPath -ChildPath $TorrentFile
            $DownloadedTorrentFile = Join-Path -Path $DownloadTorrentPath -ChildPath $TorrentFile
            $FailedTorrentFile = Join-Path -Path $FailedTorrentPath -ChildPath $TorrentFile
        
            if (Compare-QueuedShows -byWhat "$FullShowTitle"){
                #Write-Log -Message "A Torrent for show '$FullShowTitle' is already scheduled to download" -CustomComponent "$domain Torrent" -ColorLevel 2 -HostMsg -NewLine
                Start-Sleep 2
            }
            Else{
                if ( (!(Test-Path $ProcessedTorrentFile)) -and (!(Test-Path $DownloadedTorrentFile)) -and (!(Test-Path $FailedTorrentFile)) ){
                    Write-Log -Message "Downloading Torrent [$TorrentFile] for '$FullShowTitle'" -CustomComponent "$domain Torrent"  -ColorLevel 2 -HostMsg -NewLine
                    Try{  
                        Download-WCTorrent $domain "$userAgent" "$FullShowTitle" $TorrentURL $DownloadedTorrentFile
                    }
                    catch [System.Net.WebException] {
                        $statusCode = [int]$_.Exception.Response.StatusCode
                        $html = $_.Exception.Response.StatusDescription

                        If ( ($statusCode -eq 404) -or ($_.Exception.Message -match "The remote name could not be resolved" ) ){
                            Write-Log -Message "Failed downloaded torrent from '$TorrentURL' for '$FullShowTitle'. Error Message: [$($_.Exception.Message)]. Error code: [$statusCode]" -CustomComponent "$domain Torrent" -ColorLevel 3 -HostMsg -NewLine
                            write-host "Adding to failed file path to be ignored..." -ForegroundColor Gray
                            New-Item $FailedTorrentFile -ErrorAction SilentlyContinue | Out-Null
                            Add-Content $FailedTorrentFile "$FullShowTitle, $TorrentURL, $statusCode"
                        }
                        Else{
                            $global:failedcnt ++
                            If ($global:failedcnt -eq 3){
                                Write-Log -Message "Failed 3 times to download file from '$TorrentURL' for '$FullShowTitle'. Error Message: [$($_.Exception.Message)]. Error code: [$statusCode]" -CustomComponent "$domain Torrent" -ColorLevel 3 -HostMsg
                                New-Item $FailedTorrentFile -ErrorAction SilentlyContinue | Out-Null
                                Add-Content $FailedTorrentFile "$FullShowTitle, $TorrentURL, $statusCode"
                                $global:failedcnt = 0
                            }
                            Else{
                                Write-Log -Message "Unable downloaded torrent from '$TorrentURL' for '$FullShowTitle'. Error Message: [$($_.Exception.Message)]" -CustomComponent "$domain Torrent" -ColorLevel 2 -HostMsg
                                write-host "`nRe-starting and will try to download it again..." -ForegroundColor Gray
                            }
                        }
                        Start-Sleep 5
                        exit 1
                    }
                }
                Else {
                    write-host "`nTorrent file '$TorrentFile' for show '$Title' was already downloaded" -ForegroundColor Gray
                    If (Test-Path $ProcessedTorrentFile){
                        Write-Log -Message "Torrent file '$TorrentFile' for show '$Title' was already downloaded and placed here: '$ProcessedTorrentFile'" -CustomComponent "$domain Torrent" -ColorLevel 2 -HostMsg -NewLine
                    }
                    If (Test-Path $DownloadedTorrentFile){
                        Write-Log -Message "Torrent file '$TorrentFile' for show '$Title' was already downloaded and placed here: '$DownloadedTorrentFile'" -CustomComponent "$domain Torrent" -ColorLevel 2 -HostMsg -NewLine
                    }
                    If (Test-Path $FailedTorrentFile){
                        Write-Log -Message "Torrent file '$TorrentFile' for show '$Title' was already downloaded and placed here: '$FailedTorrentFile'" -CustomComponent "$domain Torrent" -ColorLevel 2 -HostMsg -NewLine
                    }
                    write-host "`nMoving to the next show in the list..." -ForegroundColor Gray
                    Start-Sleep 2
                }
            }
        }
    }
    Else{
        Write-Log -Message "No shows found that match within this feed: $URIFeed" -CustomComponent "$domain Torrent" -ColorLevel 2 -HostMsg -NewLine
    }
}


#====================================================================================================================
# SEARCH EZTV
#====================================================================================================================
If (($global:downloadcnt -eq 0) -and ($searchEZTV -eq $true)){
    [Uri]$SearchURI = $EZTVSearch
    $domainHost = $SearchURI.Authority -replace '^www\.'
    $domain = $domainHost.Split('.')[0]
    $domain = $TextInfo.ToTitleCase("$domain")

    Write-Log -Message "Searching shows on website: '$domain'" -CustomComponent "$domain Search" -ColorLevel 4 -HostMsg -NewLine
    Foreach ($missingName in $missingNames){
        $searchquery = $null
        If (!$missingName.Downloaded){
            $FullShowTitle = $missingName.FullTitle
            $searchquery=$missingName.title
            $dotname=$searchquery.replace(" ",".")
            Write-Log -Message "Searching download links for '$FullShowTitle'" -CustomComponent "$domain Search" -ColorLevel 2 -HostMsg
            $searchQuery = "https://$domainHost/search/$searchquery" -replace " ","-"
            #$content = Invoke-WebRequest $searchQuery -UserAgent $userAgent
            try {
                $content = Invoke-WebRequest $searchQuery -UserAgent [Microsoft.PowerShell.Commands.PSUserAgent]::$userAgent -TimeoutSec 240 -ErrorAction:Stop
            } 
            catch [Exception]{
                Write-Log -Message "Error: $($_.Exception.Message)" -CustomComponent "$domain Search" -ColorLevel 3 -HostMsg -NewLine
                continue
            }
            $OuterContent = $content.AllElements | Where name -like "hover*"| Select -ExpandProperty outerHTML
            $Hyperlinks = @()
            $Filteredlinks = @()
            $Hyperlinks = Get-HrefMatches -content [string]$OuterContent
            Foreach ($link in $Hyperlinks){
                If ( ($link -match "$($missingName.SearchwithDash)") -or ($link -match "$($missingName.SearchwithDot)") -or ($link -match "$($missingName.SearchSeasonEpisode)") ){
                    If ($link -match ".torrent"){
                        $Filteredlinks += $link
                    }
                }  
            }

            Write-Log -Message "A total of $($Filteredlinks.count) links found for: $searchquery" -CustomComponent "$domain Search" -ColorLevel 1 -HostMsg -NewLine
            Foreach ($link in $Filteredlinks){
                #write-host "parsing hyperlink: $link" -ForegroundColor Yellow
                If ( ($link -like "*.torrent") -and ($link -like "*$dotname*") ){
                    
                    write-host "found torrent that matches $searchquery"
                    $file = [System.IO.Path]::GetFileName($link)
                    
                    #$obj = New-Object PSobject
                    #$obj | Add-Member Noteproperty URL $link
                    #$obj | Add-Member Noteproperty Torrent $file
                    #$searchLinks += $obj

                    $TorrentURL = $link
                    $TorrentFile = [System.IO.Path]::GetFileName($link)
                    $ProcessedTorrentFile = Join-Path -Path $ProcessedTorrentPath -ChildPath $TorrentFile
                    $DownloadedTorrentFile = Join-Path -Path $DownloadTorrentPath -ChildPath $TorrentFile
                    $FailedTorrentFile = Join-Path -Path $FailedTorrentPath -ChildPath $TorrentFile

                    if (Compare-QueuedShows -byWhat "$FullShowTitle"){
                        #Write-Log -Message "A Torrent for show '$FullShowTitle' is already scheduled to download" -CustomComponent "$domain Torrent" -ColorLevel 2 -HostMsg -NewLine
                        Start-Sleep 2
                    }
                    Else{
                        if ( (!(Test-Path $ProcessedTorrentFile)) -and (!(Test-Path $DownloadedTorrentFile)) -and (!(Test-Path $FailedTorrentFile)) ){
                            Write-Log -Message "Downloading Torrent [$TorrentFile] for '$FullShowTitle'" -CustomComponent "$domain Torrent" -ColorLevel 2 -HostMsg
                            Try{
                                Download-WCTorrent $domain "$userAgent" "$FullShowTitle" $TorrentURL $DownloadedTorrentFile
                            }
                            catch [System.Net.WebException] {
                                $statusCode = [int]$_.Exception.Response.StatusCode
                                $html = $_.Exception.Response.StatusDescription

                                If ( ($statusCode -eq 404) -or ($_.Exception.Message -match "The remote name could not be resolved" ) ){
                                    Write-Log -Message "Failed downloaded torrent from '$TorrentURL' for '$FullShowTitle'. Error Message: [$($_.Exception.Message)]. Error code: [$statusCode]" -CustomComponent "$domain Torrent" -ColorLevel 3 -HostMsg -NewLine
                                    write-host "`nAdding to failed file path to be ignored..." -ForegroundColor Gray
                                    New-Item $FailedTorrentFile -ErrorAction SilentlyContinue | Out-Null
                                    Add-Content $FailedTorrentFile "$FullShowTitle, $TorrentURL, $statusCode"
                                }
                                Else{
                                    $global:failedcnt ++
                                    If ($global:failedcnt -eq 3){
                                        Write-Log -Message "Failed 3 times to download file from '$TorrentURL' for '$FullShowTitle'. Error Message: [$($_.Exception.Message)]. Error code: [$statusCode]" -CustomComponent "$domain Torrent" -ColorLevel 3 -HostMsg -NewLine
                                        New-Item $FailedTorrentFile -ErrorAction SilentlyContinue | Out-Null
                                        Add-Content $FailedTorrentFile "$FullShowTitle, $TorrentURL, $statusCode"
                                        $global:failedcnt = 0
                                    }
                                    Else{
                                        Write-Log -Message "Unable downloaded torrent from '$TorrentURL' for '$FullShowTitle'. Error Message: [$($_.Exception.Message)]. Error code: [$statusCode]" -CustomComponent "$domain Torrent" -ColorLevel 3 -HostMsg -NewLine
                                        write-host "`nRe-starting and will try to download it again..." -ForegroundColor Gray
                                    }
                                }
                                Start-Sleep 5
                                exit 1
                            }
                        }
                        Else {
                            write-host "`nTorrent file '$TorrentFile' for show '$Title' was already downloaded" -ForegroundColor Gray
                            If (Test-Path $ProcessedTorrentFile){
                                Write-Log -Message "Torrent file '$TorrentFile' for show '$Title' was already downloaded and placed here: '$ProcessedTorrentFile'" -CustomComponent "$domain Torrent" -ColorLevel 2 -HostMsg -NewLine
                            }
                            If (Test-Path $DownloadedTorrentFile){
                                Write-Log -Message "Torrent file '$TorrentFile' for show '$Title' was already downloaded and placed here: '$DownloadedTorrentFile'" -CustomComponent "$domain Torrent" -ColorLevel 2 -HostMsg -NewLine
                                }
                            If (Test-Path $FailedTorrentFile){
                                Write-Log -Message "Torrent file '$TorrentFile' for show '$Title' was already downloaded and placed here: '$FailedTorrentFile'" -CustomComponent "$domain Torrent" -ColorLevel 2 -HostMsg -NewLine
                            }
                            write-host "`nMoving to the next show in the list..." -ForegroundColor Gray
                            Start-Sleep 2
                        }
                    }
                }
                Else{
                    Write-Log -Message "No shows found that match within this feed: $searchQuery" -CustomComponent "$domain Torrent" -ColorLevel 2 -HostMsg -NewLine
                } #end if links are torrents
            } #loop links found
        } # end if already downloaded
    } #loop missing names
} # end if search enabled

#====================================================================================================================
# EZTV API
#====================================================================================================================
If (($global:downloadcnt -eq 0) -and ($searchEZTVApi -eq $true)){
    Foreach ($missingName in $missingNames){
        $imdbID = $($missingName.ImdbId) -replace "tt", ""
        $eztvAPISearch = Invoke-RestMethod "$EZTVApiURL=$imdbID"
        If ($eztvAPISearch.torrents_count -gt 0){
            $FoundTorrents = $eztvAPISearch.torrents
            Foreach ($torrent in $FoundTorrents){  
               If ($torrent.size_bytes -le $FileSizeLimitBytes){
                    Write-Host $torrent.torrent_url 
               } 
            }
        }
    }

    #tt1811179
    #tt4158110

    $eztvAPISearch = Invoke-RestMethod "$EZTVApiURL=4158110"
    If ($eztvAPISearch.torrents_count -gt 0){
        $FoundTorrents = $eztvAPISearch.torrents
        Foreach ($torrent in $FoundTorrents){  
            If ($torrent.size_bytes -le $FileSizeLimitBytes){
                $showtitle = $torrent.filename -split 'S(?<season>\d{1,2})E(?<episode>\d{1,2})'
                If ($showtitle[1] -ne $null){
                    $title = $showtitle[0].trim()
                    [int]$Season = "{0:D2}" -f $showtitle[1].trim()
                    [int]$Episode = "{0:D2}" -f $showtitle[2].trim()
                    $titleES = $title + "S$($Season)E$($Episode)"
                    #$url = New-Object System.Uri($torrent.torrent_url)
                    $file = $torrent.torrent_url
                    $magnet = $torrent.magnet_url

                    $obj = New-Object PSobject
                    $obj | Add-Member Noteproperty Title $title
                    $obj | Add-Member Noteproperty Season $Season 
                    $obj | Add-Member Noteproperty Episode $Episode
                    $obj | Add-Member Noteproperty TitleES $TitleES
                    $obj | Add-Member Noteproperty URL $url
                    $obj | Add-Member Noteproperty Torrent $rssxmltitle.infoHash
                      Write-Log -Message "Added show: '$TitleES' to the '$domain Compare List'" -CustomComponent "$domain Show List"
                    $apiNames += $obj
                }

                $ComparedShows = Compare-Object $titleES $missingNames.SearchwithDot -IncludeEqual -passThru -Property TitleES | Where-Object { $_.SideIndicator -eq '==' }
                If ($ComparedShows.count -gt 0){
                    $ComparedShows | Foreach {

                        Write-Host $torrent.torrent_url 
                    }
                } 
            } 
        }
    }

}

#====================================================================================================================
# URL FEED  - MAIN
#====================================================================================================================
foreach ($Feed in $URLFeeds){
    [uri]$URLFeed = $Feed

    $domainHost = $URLFeed.Authority -replace '^www\.'
    $domain = $domainHost.Split('.')[0]
    $domain = $TextInfo.ToTitleCase("$domain")

    Write-Log -Message "Retrieving all shows from: '$URLFeed'" -CustomComponent "$domain RSS FEED" -ColorLevel 2 -HostMsg -NewLine
    try {
        $content = Invoke-WebRequest $searchQuery -UserAgent $userAgent -TimeoutSec 240 -ErrorAction:Stop
    } 
    catch [Exception]{
        Write-Log -Message "Error: $_.Exception.Message" -CustomComponent "$domain Search" -ColorLevel 3 -HostMsg -NewLine
        continue
    }
    $PBAY = $content.AllElements | Where href -like "magnet*"| Select -ExpandProperty outerHTML
    $Hyperlinks = @()
    $Filteredlinks = @()
    $Hyperlinks = Get-HrefMatches -content [string]$PBAY

}

#any files downloaded must have a torrent extension (rename them if needed)
Get-ChildItem -Path $DownloadTorrentPath -Exclude "*.torrent" | Where-Object{!$_.PsIsContainer} | Rename-Item -newname {$_.name + ".torrent"}

If ($global:downloadcnt -eq 0){
    Write-Log -Message "No files have been downloaded, beginning next process..." -ColorLevel 0 -HostMsg -NewLine
    Exit 2
}
Else{
    Write-Log -Message "A total of $global:downloadcnt torrent files have been downloaded queued, beginning next process..." -ColorLevel 5 -HostMsg -NewLine
    exit 3
}