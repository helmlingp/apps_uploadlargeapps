<# 
  .SYNOPSIS
    This script ingests applications into Workspace ONE UEM
  .DESCRIPTION
    When run without parameters, this script will prompt for Workspace ONE UEM API Server, credentials, API Key and OG Name. 
    The script then iterates through the current (script) folder for JSON files that provide the necessary Application information.
    Each JSON file is based upon the JSON requirements for the /API/mam/apps/internal/application API call.
    An additional element called "filepath" must be included with a value of the path and file name to upload. See the examples provided in this repo.
  .EXAMPLE
    .\uploadlargeapps.ps1 
        -Server https://asXXX.awmdm.com/ 
        -Username USERNAME
        -Password PASSWORD
        -ApiKey APIKEY
        -OGName OGNAME
  .PARAMETER Server
    Server URL for the Workspace ONE UEM API Server
  .PARAMETER UserName
    The Workspace ONE UEM API user name. This group must have rights to be able to create applications,against the REST API. 
  .PARAMETER Password
    The password that is used by the user specified in the username parameter
  .PARAMETER APIKey
    This is the REST API key that is generated in the Workspace ONE UEM Console.  You locate this key at All Settings -> Advanced -> API -> REST,
    and you will find the key in the API Key field.  If it is not there you may need override the settings and Enable API Access
  .PARAMETER OGName
    The OGName is the name of the Organization Group where the apps will be migrated. The script searches for matching OGName and will
    present a list to select from if multiple OGs are found. The API key and admin credentials need to be authenticated at this Organization Group.
    The shorcut to getting this value is to navigate to https://<YOUR HOST>/AirWatch/#/AirWatch/OrganizationGroup/Details.
    The ID you are redirected to appears in the URL (7 in the following example). https://<YOUR HOST>/AirWatch/#/AirWatch/OrganizationGroup/Details/Index/7

  .NOTES 
    Created:   	    February, 2021
    Created by:	    Phil Helmling, @philhelmling
    Organization:   VMware, Inc.
    Filename:       uploadlargeapps.ps1
    GitHub:         https://github.com/helmlingp/apps_uploadlargeapps
#>

param (
    [Parameter(Mandatory=$false)]
    [string]$Username,
    [Parameter(Mandatory=$false)]
    [string]$Password,
    [Parameter(Mandatory=$false)]
    [string]$OGName,
    [Parameter(Mandatory=$false)]
    [string]$Server,
    [Parameter(Mandatory=$false)]
    [string]$ApiKey
)
$Debug = $false
[string]$psver = $PSVersionTable.PSVersion
$PartSizeBytes = 10MB
$current_path = $PSScriptRoot;
if($PSScriptRoot -eq ""){
    #PSScriptRoot only popuates if the script is being run.  Default to default location if empty
    $current_path = ".";
}

Function Invoke-setupServerAuth {

  if ([string]::IsNullOrEmpty($script:Server)){
      $script:Server = Read-Host -Prompt 'Enter the Workspace ONE UEM Server Name'
      $private:Username = Read-Host -Prompt 'Enter the Username'
      $SecurePassword = Read-Host -Prompt 'Enter the Password' -AsSecureString
      $script:APIKey = Read-Host -Prompt 'Enter the API Key'
      $script:OGName = Read-Host -Prompt 'Enter the Organizational Group Name'
    
      #Convert the Password
      if($psver -lt 7){
        #Powershell 6 or below
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
        $Password = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
      } else {
        #Powershell 7 or above
        $Password = ConvertFrom-SecureString $SecurePassword -AsPlainText
      }
    }

  #Base64 Encode AW Username and Password
  $private:combined = $Username + ":" + $Password
  $private:encoding = [System.Text.Encoding]::ASCII.GetBytes($private:combined)
  $private:encoded = [Convert]::ToBase64String($private:encoding)
  $script:cred = "Basic $encoded"

  $combined = $Username + ":" + $Password
  $encoding = [System.Text.Encoding]::ASCII.GetBytes($combined)
  $encoded = [Convert]::ToBase64String($encoding)
  $cred = "Basic $encoded"
  if($Debug){ 
    Write-host `n"Server Auth" 
    write-host "WS1 Host: $script:Server"
    write-host "Base64 creds: $script:cred"
    write-host "APIKey: $script:APIKey"
    write-host "OG Name: $script:OGName"
  }
}

function Invoke-GetOG {
  param(
    [Parameter(Mandatory=$true)]
    [string]$OGName
  )
  #Search for the OG Name and return GroupUUID and GroupID attributes.
  #Present list if multiple OGs with those search characters and allow selection

  $url = "$script:server/API/system/groups/search?name=$OGName"
  $header = @{'aw-tenant-code' = $script:APIKey;'Authorization' = $script:cred;'accept' = 'application/json;version=2';'Content-Type' = 'application/json'}
  try {
    $OGSearch = Invoke-RestMethod -Method Get -Uri $url.ToString() -Headers $header
  }
  catch {
    throw "Server Authentication or Server Connection Failure $($_.Exception.Message)`n`n`tExiting"
  }

  $OGSearchOGs = $OGSearch.OrganizationGroups
  $OGSearchTotal = $OGSearch.TotalResults
  if ($OGSearchTotal -eq 1){
    $Choice = 0
  } elseif ($OGSearchTotal -gt 1) {
    $ValidChoices = 0..($OGSearchOGs.Count -1)
    $ValidChoices += 'Q'
    Write-Host "`nMultiple OGs found. Please select an OG from the list:" -ForegroundColor Yellow
    $Choice = ''
    while ([string]::IsNullOrEmpty($Choice)) {

      $i = 0
      foreach ($OG in $OGSearchOGs) {
        Write-Host ('{0}: {1}       {2}       {3}' -f $i, $OG.name, $OG.GroupId, $OG.Country)
        $i += 1
      }

      $Choice = Read-Host -Prompt 'Type the number that corresponds to the OG or Press "Q" to quit'
      if ($Choice -in $ValidChoices) {
        if ($Choice -eq 'Q'){
          Write-host " Exiting Script"
          exit
        } else {
          $Choice = $Choice
        }
      } else {
        [console]::Beep(1000, 300)
        Write-host ('    [ {0} ] is NOT a valid selection.' -f $Choice)
        Write-host '    Please try again ...'
        pause

        $Choice = ''
      }
    }
  }
  return $OGSearchOGs[$Choice]
}

function Get-App {
  param(
    [Parameter(Mandatory=$true)]
    [string]$appname,
    [Parameter(Mandatory=$true)]
    [string]$groupid
  )
  $appsearch = ""
  #Search to see if existing app so we can "Add Version"
  $url = "$script:server/API/mam/apps/search?applicationname=$appname&locationgroupid=$groupid&platform=WinRT"
  $header = @{'aw-tenant-code' = $script:APIKey;'Authorization' = $script:cred;'accept' = 'application/json';'Content-Type' = 'application/json'}
  try {
    $appSearch = Invoke-RestMethod -Method Get -Uri $url.ToString() -Headers $header
  }
  catch {
    throw "Server Authentication or Server Connection Failure $($_.Exception.Message)`n`n`tExiting"
  }

  return $appSearch.Application
}

function Invoke-ChunkandUpload {
  param(
    [Parameter(Mandatory=$true)]
    [string]$inFilePath
  )
  # get the original file size and calculate the
  # number of required parts:
  $originalFile = New-Object System.IO.FileInfo($inFilePath)
  $totalChunks = [int]($originalFile.Length / $PartSizeBytes) + 1
  #$digitCount = [int][Math]::Log10($totalChunks) + 1

  # read the original file and split into chunks:
  $reader = [IO.File]::OpenRead($inFilePath)
  $count = 1
  $buffer = New-Object Byte[] $PartSizeBytes
  $moreData = $true
  [string]$transaction_id = ""
  # read chunks until there is no more data
  while($moreData)
  {
      # read a chunk
      $bytesRead = $reader.Read($buffer, 0, $buffer.Length)
      
      Write-host "`n","Reading chunk $count of $totalChunks" -ForegroundColor White
      $output = $buffer

      # did we read less than the expected bytes?
      if ($bytesRead -ne $buffer.Length)
      {
          # yes, so there is no more data
          $moreData = $false
          # shrink the output array to the number of bytes actually read
          $output = New-Object Byte[] $bytesRead
          [Array]::Copy($buffer, $output, $bytesRead)
      }
      #convert to Base64
      [string]$B64String = [System.Convert]::ToBase64String($output, [System.Base64FormattingOptions]::None)
      
      # upload the chunk $output
      write-host " Uploading chunk $count" -ForegroundColor White
      $chunkproperties = @"
{
"TransactionId": "$transaction_id",
"ChunkData": "$B64String",
"ChunkSequenceNumber": $count,
"TotalApplicationSize": $filesize,
"ChunkSize": $bytesRead
}
"@
      write-host " TransID: $transaction_id ChunkSeqNum: $count ChunkSize: $bytesRead" -ForegroundColor White
      #convert from pseudo json back to json
      $chunkjson = Convertfrom-json -InputObject $chunkproperties
      $json = ConvertTo-Json -InputObject $chunkjson -Depth 100
      $url = "$script:Server/API/mam/apps/internal/uploadchunk"
      $header = @{'aw-tenant-code' = $script:APIKey;'Authorization' = $script:cred;'accept' = 'application/json';'Content-Type' = 'application/json'}
      try 
      {
        $response = Invoke-RestMethod -Method Post -Uri $url.ToString() -Headers $header -Body $json
      }
      catch
      {
          throw "Unable to upload file $($_.Exception.Message)`n`n`tExiting"
      }
      #get TRANSID & add to $chunkproperties
      $transaction_id = $response.TranscationId
      # increment the part counter
      ++$count
  }
  # done, close reader
  $reader.Close()
  #do I need to set the buffer and output variables to NULL also?
  return $transaction_id
}

Function Invoke-UploadfromLink{
  param(
    [Parameter(Mandatory=$true)]
    $ApplicationUrl,
    [Parameter(Mandatory=$true)]
    $filename,
    [Parameter(Mandatory=$true)]
    $groupid
  )
  $escdappLink = [uri]::EscapeDataString("$ApplicationUrl")
  $url = "$server/API/mam/blobs/uploadblob?fileName=$filename&organizationGroupId=$groupid&moduleType=Application&fileLink=$escdappLink&accessVia=Direct"
  $header = @{'aw-tenant-code' = $APIKey;'Authorization' = $cred;'accept' = 'application/json';'Content-Type' = 'multipart/form-data'}

  try {
    $createblobid = Invoke-RestMethod -Method Post -Uri $url.ToString() -Headers $header
    $blob_id = $createblobid.Value
    if($Debug){
      write-host "Created BlobId $blob_id for filename $filename" -ForegroundColor White
    }
  }
  catch {
    throw "Unable to create blob from upload link $($_.Exception.Message)"
  }
  return $blob_id

}

function Invoke-CreateApp{
  param(
    [Parameter(Mandatory=$true)]
    $appproperties
  )

  #$appjson = Convertfrom-json -InputObject $appProperties
  $json = ConvertTo-Json -InputObject $appproperties -Depth 100
  if($Debug){
    write-host $json
  }

  # Create App with BlobID
  $url = "$script:server/API/mam/apps/internal/application"
  $header = @{'aw-tenant-code' = $script:APIKey;'Authorization' = $script:cred;'accept' = 'application/json';'Content-Type' = 'application/json'}
  
  $createapp = Invoke-RestMethod -Method Post -Uri $url.ToString() -Headers $header -Body $json
  if($createapp.status -ne 200){
    write-host "Unable to create app from upload chunk $($createapp.Message)"
  }else{
    write-host "Created Internal App $appname" -ForegroundColor White
    return $createapp
  }
  
}

#Main
#Ensure we have connection details
Invoke-setupServerAuth

#Search for correct OG
$getOG = Invoke-GetOG -OGName $script:OGName
$groupuuid = $getOG.Uuid
$groupid = $getOG.Id

#Search for JSON files and upload using chunkupload, then create app using app/internal/application
$jsons = Get-ChildItem -Path "$current_path\*.json" -Recurse
foreach ($json in $jsons) {
  #read attributes from json and remove "filepath" element from in memory object
  
  $appproperties = Get-Content -Path $json -Raw | ConvertFrom-Json
  $appname = $appproperties.application_name
  $filePath = $appproperties.filepath
  $filename = $appproperties.file_name
  $inFilePath = "$filePath/$filename"
  $appproperties.PSObject.Properties.Remove('filepath')
  $appproperties.organization_group_uuid = $groupuuid

  $upload_via_link = $appproperties.upload_via_link
  $ApplicationUrl = $appproperties.ApplicationUrl
  $extn = ($filename).substring($($filename).length - 4, 4)

  #$extn = [IO.Path]::GetExtension($inFilePath)
  if($upload_via_link -eq $true -and $ApplicationUrl -and $extn -eq ".MSI"){
    #set Actual_file_version when uploading MSI via link
    $major_version = $appproperties.deployment_options.when_to_call_install_complete.criteria_list.app_criteria.major_version
    $minor_version = $appproperties.deployment_options.when_to_call_install_complete.criteria_list.app_criteria.minor_version
    $revision_number = $appproperties.deployment_options.when_to_call_install_complete.criteria_list.app_criteria.revision_number
    $build_number = $appproperties.deployment_options.when_to_call_install_complete.criteria_list.app_criteria.build_number
    $appversion = "$major_version.$minor_version.$build_number.$revision_number"
    $appproperties.actual_file_version = $appversion
  }elseif($extn -eq ".MSI"){
    #Build MSI version number from detection criteria as storing in ActualFileVersion within properties is not accepted by API if not uploaded by Link
    $major_version = $appproperties.deployment_options.when_to_call_install_complete.criteria_list.app_criteria.major_version
    $minor_version = $appproperties.deployment_options.when_to_call_install_complete.criteria_list.app_criteria.minor_version
    $revision_number = $appproperties.deployment_options.when_to_call_install_complete.criteria_list.app_criteria.revision_number
    $build_number = $appproperties.deployment_options.when_to_call_install_complete.criteria_list.app_criteria.build_number
    $appversion = "$major_version.$minor_version.$build_number.$revision_number"
    #remove version info etc from appproperties as it is dynamically obtained when uploading MSIs
    $appproperties.actual_file_version = ""
    $appproperties.app_uem_version = ""
    $appproperties.build_version = ""
  }elseif($extn -eq ".EXE" -or $extn -eq ".ZIP"){
    $appversion = $appproperties.actual_file_version
  }

  #check if existing app & version and get bundle_id from existing app
  #Don't upload the app if it already exists. 
  write-host "Searching for $appname with filename: $filename version: $appversion and extension: $extn" -ForegroundColor Green
  $appsearch = Get-App -appname "$appname" -groupid $groupid
  if($appsearch.Length -gt 0){
    #Refine to match extension
    $appsearchextn = $appsearch | Where-Object {($_.ApplicationFileName).substring($($_.ApplicationFileName).length - 4, 4) -eq $extn}
    
    #Refine to not match version and match extension
    $appsearchversionextn = $appsearch | Where-Object {$_.AppVersion -eq $appversion -AND ($_.ApplicationFileName).substring($($_.ApplicationFileName).length - 4, 4) -eq $extn}
    
    #Refine to match extension and not version
    $appsearchnotversionextn = $appsearch | Where-Object {$_.AppVersion -ne $appversion -AND ($_.ApplicationFileName).substring($($_.ApplicationFileName).length - 4, 4) -eq $extn}
  }
  
  if($appsearch.Length -eq 0){
    #Search by Name. If not in the list upload = true
    [bool]$upload = $true
  } 
  elseif($appsearchextn.Length -eq 0){
    #Search by File Extension. If not same extension upload = true
    [bool]$upload = $true
  }
  elseif($appsearchversionextn.Length -ne 0){
    #Search by Version and File Extension. If same extension and same version upload = false
    [bool]$upload = $false
  }
  elseif($appsearchnotversionextn.Length -ne 0) {
    #Search by Version and File Extension. If same extension and not same version upload = true
    [bool]$upload = $true
    #get Bundle_Id and set if not MSI
    if($extn -eq ".EXE" -or $extn -eq ".ZIP"){
      $bundle_id = ($appsearchnotversionextn | select-object ApplicationName,AppVersion,BundleId | Sort-Object @{E="AppVersion";Descending=$true})[0].BundleId
      $appproperties.bundle_id = $bundle_id
      $appproperties.upload_via_link = $true
    }
  }

  
  if($upload -eq $false){write-host "Application already exits, not uploading" -ForegroundColor Blue}
  elseif($upload -eq $true){
    
    if($upload_via_link -eq $true -and $ApplicationUrl){
      # Test if URL is an application file that can be downloaded
      $appURL = Invoke-WebRequest $ApplicationUrl -DisableKeepAlive -UseBasicParsing -Method Head
      $testappURL = $appURL | Where-Object { $_.status -ne 200 -OR $_.contentType -notmatch "application"}
      if(!$testappURL){write-host "Application installer files are not accessible, skipping" -ForegroundColor Red}
      else {
        #upload from link
        [string]$blob_id = Invoke-UploadfromLink -ApplicationUrl $ApplicationUrl -filename $filename -groupid $groupid
        $appproperties.blob_id = $blob_id
        #Set BundleId if new app
        if (!($bundle_id)){
          [String]$bundle_id = "0"
          $appproperties.bundle_id = $bundle_id
        }
        #create app
        Invoke-CreateApp -appproperties $appproperties
        if($Debug){
          write-host "Completed uploading $appname version $appversion","`n" -ForegroundColor Green
        }
      }
    } 
    else {
      #Test if inFilePath is accessible, otherwise skip with error
      $testinFilePath = Test-Path -Path $inFilePath -PathType leaf
    
      if(!$testinFilePath){
        write-host "Application files to upload are not accessible, skipping" -ForegroundColor Red
      }
      else {
        #upload in chunks
        write-host "Beginning Application Upload" -ForegroundColor Yellow
        [string]$transaction_id = Invoke-ChunkandUpload -inFilePath $inFilePath
        if($transaction_id){
          $appproperties.transaction_id = $transaction_id
        }
        #create app
        Invoke-CreateApp -appproperties $appproperties
        if($Debug){
          write-host "Completed uploading $appname version $actual_file_version","`n" -ForegroundColor Green
        }
      }
      
    }
    
    $appproperties = ""
    $appname = ""
    $filePath = ""
    $filename = ""
    $inFilePath = ""
    $bundle_id = ""
    $actual_file_version
    $appversion = ""
    $appsearch = ""
    $appsearchextn = ""
    $appsearchversionextn = ""
    $appsearchnotversionextn = ""
    $transaction_id = ""
    $ApplicationUrl = ""
    $upload_via_link = ""
  }
}