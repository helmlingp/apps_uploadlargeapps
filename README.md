# uploadlargeapps.ps1
This script ingests applications into Workspace ONE UEM using chunkupload or upload from link

When run without parameters, this script will prompt for Workspace ONE UEM API Server, credentials, API Key and OG Name. 

The script iterates through the current (script) folder for JSON files that provide the necessary Application information.
Each JSON file is based upon the JSON requirements for the /API/mam/apps/internal/application API call.
An additional element called "filepath" must be included with a value of the path and file name to upload. See the examples provided in this repo.

The Script also provides the ability to upload via link (URL). The link MUST expose the file (OneDrive & Google Drive do not do this).
