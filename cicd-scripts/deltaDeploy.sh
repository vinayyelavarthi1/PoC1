#!/bin/bash -x
################################################################################
#  Build scripted-delta-package.xml based off git diff
#      1. Get git diff from current/compare branch to 'prod/org'/master
#      2. Read config file to map file to package xml entry
#      3. Loop through git diff and match to config map
#      4. Output to scripted package xml and vlocity yaml
#
#  Arguments:
#   -m {branchName} : master branch to use
#   -c {branchName} : compare branch to use
#   -x {commitHash} {commitHash} : compare two commit hash codes
#   -l {logLevel}   : log level to use, 0 debug, 1 info
#   -v {bool}       : set option to skip vlocity components, true/false
#
#  Author: Chance Cannon, 02/23/2024
#  Change Log:
#    APPDEV-535 csc Initial Write
#    SFPRODSUP-208 10-01-2024 csc Add logic to skip vlocity cmpts
#
################################################################################
#globals
declare -A configArray
declare -A typesMembersArray
declare -A typesMembersCountArray
declare -A vlocityMembersArray
declare -A vlocityMembersCountArray
vlocityComp=0
#overridable via argument
compareBranch=""
commitA=""
commitB=""
masterBranch="origin org/prod"
logLevel=1
skipVlocity="false"
#files to use
branchPackageXmlFile="./manifest/package.xml"
deltaPackageXmlFile="./manifest/scripted-delta-package.xml"
branchVlocityYamlFile="./manifest/vlocity.yaml"
deltaVlocityYamlFile="./manifest/scripted-delta-pc.yaml"
branchDiffFile="./cicd-scripts/gitDiff.tmp"
branchDiffSortedFile="./cicd-scripts/gitDiffSorted.tmp"
branchDiffUnsortedFile="./cicd-scripts/gitDiffUnsorted.tmp"
deltaIgnoreFile="./cicd-scripts/deltaIgnoreFiles.txt"
deltaIgnoreSortedFile="./cicd-scripts/deltaIgnoreFilesSorted.txt"
configFile="./cicd-scripts/deltaDeployConfigSorted.txt"
#holds and tracks package xml entries and changes
packageXmlContents=""
vlocityYamlContents=""
memberEntry=""
memberEntryPrev=""
directoryName=""
directoryNamePrev=""
typesName=""
typesNamePrev=""
#reusable xml/yaml tags
typesTag="     <types>\n"
typesTagEnd="     </types>\n"
memberTag="          <members>"
memberTagEnd="</members>\n"
nameTag="          <name>"
nameTagEnd="</name>\n"
yamlLineStart="  - "
yamlLineEnd="\n"
#
#functions
#
function LogMessage(){
    #log a message
    echo "$1"
}
function IgnoreFile(){
    #allow components to be skipped
    LogMessage "Ignoring difference found in file [$1]."
}
function CheckGitResponse(){
    #allow components to be skipped
    if [[ $1 -ne 0 ]]; then
        if [[ "$commitA" == "" && "$commitB" == "" ]]; then
            LogMessage "Git diff failed using branch as master [$masterBranch], please verify network and branch access."
        else
            LogMessage "Git diff failed using commits [$commitA] and [$commitB] to get vlocity, please verify network and branch access."
        fi
        exit 1;
    fi
}
############################################################
# Concat a given file to string array by 'types name'
#inputs: 
# arg1 : member entry/api name to use in package.xml/pc.yaml
# arg2 : type name, used as the 'component' to which a given member is identified as
function AddEntryToMemberArray(){
    #add new entry for this type to member list
    member=$1
    typesName="$2"
    if [ $vlocityComp -eq 1 ]; then
        if [[ "${typesName}" == "CalculationMatrix" || "${typesName}" == "CalculationProcedure" || "${typesName}" == "DataRaptor" ||
              "${typesName}" == "ManualQueue" || "${typesName}" == "PriceList" || "${typesName}" == "Pricebook2" ]]; then 
            member=`echo $member | tr "-" " "`
        fi
        if [[ ${vlocityMembersArray[$typesName]} =~ $member ]]; then
            LogMessage "Entry already present, type:[$typesName] member:[${member}]."
        else
            vlocityMembersArray[$typesName]="${vlocityMembersArray[$typesName]}${yamlLineStart}${typesName}/${member}${yamlLineEnd}"
        fi
    else
        if [[ ${typesMembersArray[$typesName]} =~ $member ]]; then
            LogMessage "Entry already present, type:[$typesName] member:[${member}]."
        else
            typesMembersArray[$typesName]="${typesMembersArray[$typesName]}${memberTag}${member}${memberTagEnd}"
        fi
    fi
    if [ $logLevel -gt 0 ]; then
        LogMessage "Added entry to member array, type:[$typesName] member:[${member}]."
    fi
}
############################################################
# Add a given file to xml/yaml output as proper member name
#inputs: 
# arg1 : string to add to end of existing xml/yaml output
function AddToManifest(){
    #concat package xml contents into string
    if [ $vlocityComp -eq 1 ]; then
        vlocityYamlContents="${vlocityYamlContents}$1"
    else 
        packageXmlContents="${packageXmlContents}$1"
    fi
}
###########################################################
# Retrieve the xml/yaml entry for given file by filename
#inputs: 
# arg1 : filenameToParse
function IdentifyMemberFromFileName(){
    #lookup member name by file name
    IFS='.' read -ra ENTRY <<< "$1"
    if [[ "${#ENTRY[@]}" == "4" ]]; then
        member="${ENTRY[0]}.${ENTRY[1]}"
    else
        member="${ENTRY[0]}"
    fi
    memberEntry=$member
    if [ $logLevel -eq 0 ]; then
        LogMessage "IdentifiedFromFile [$memberEntry], type [$typesName]."
    fi
}
############################################################
# Retrieve the xml/yaml entry for given file by inspecting
#inputs: 
# arg1 : changedFileToSearch
# arg2 : searchPatternToFindApiEntry
#this only works for items to be used in package.xml
function IdentifyMemberFromFileInspectionByFullname(){
    #look up member name(s) by looking into file
    for result in `/bin/grep -A1 "$1" "$2" | /bin/grep "fullName"`
    do
        IFS='>' read -ra ENTRY <<< "$result"
        resultEntry="${ENTRY[1]}"
        IFS="<" read -ra ENTRY2 <<< "$resultEntry"
        pkgXmlName="${ENTRY2[0]}"
        IFS='.' read -ra FILE <<< "$2"
        filename="${FILE[4]}"
        IFS='.' read -ra OBJENTRY <<< "$filename"
        pkgXmlObject="${OBJENTRY[0]}"
        memberEntry="$pkgXmlObject.$pkgXmlName"
        AddEntryToMemberArray "$memberEntry" "$typesName"
        if [ $logLevel -eq 0 ]; then
            LogMessage "IdentifiedFromFileInspection [$memberEntry], type [$typesName]."
        fi
    done;
}
############################################################
#                           main                           #
############################################################
POSITIONAL_ARGS=()
while [[ $# -gt 0 ]]; do
  case $1 in
    -x|--compareCommits)
      commitA="$2"
      commitB="$3"
      shift # past argument
      shift # past value1
      shift # past value2
      ;;
    -m|--branchAsMaster)
      masterBranch="$2"
      shift # past argument
      shift # past value
      ;;
    -c|--branchToCompare)
      compareBranch="$2"
      shift # past argument
      shift # past value
      ;;
    -l|--logLevel)
      logLevel="$2"
      shift # past argument
      shift # past value
      ;;
    -v|--skipvlocity)
      skipVlocity="$2"
      shift # past argument
      ;;
    -h|--help)
      echo "./deltaDeploy.sh <-m|--branchAsMaster> 'branchName' <-c|--branchToCompare> 'branchName' <-l|--logLevel> <0|1> <-v|--skipvlocity> <true|false(default)>"
      exit 1;
      ;;
    --default)
      DEFAULT=YES
      shift # past argument
      ;;
    -*|--*)
      echo "Unknown option $1"
      exit 1
      ;;
    *)
      POSITIONAL_ARGS+=("$1") # save positional arg
      shift # past argument
      ;;
  esac
done
set -- "${POSITIONAL_ARGS[@]}" # restore positional parameters
LogMessage "`/bin/date` Preparing to bulid package xml based on git diff..."
if [ ! -f $configFile ]; then
    LogMessage "The config file [$configFile] was not found and is required."
    exit 1;
fi
if [[ "$commitA" == "" && "$commitB" == "" ]]; then 
    LogMessage "Using git branch as master [$masterBranch]"
else 
    LogMessage "Using git branch commits [$commitA] and [$commitB]"
fi
git fetch origin ${masterBranch} &> /dev/null
#switch to user supplied branch.
if [[ "$compareBranch" != "" ]]; then
    git checkout $compareBranch
else
    git checkout ${BITBUCKET_BRANCH}
fi
#check sf changes
if [[ "$commitA" == "" && "$commitB" == "" ]]; then 
    git diff --name-only --diff-filter=d "origin/${masterBranch}" -- force-app/main/default > $branchDiffUnsortedFile
    CheckGitResponse $?
else
    git diff --name-only --diff-filter=d $commitA $commitB -- force-app/main/default > $branchDiffUnsortedFile
    CheckGitResponse $?
fi
#check vlocity changes
if [[ "$skipVlocity" == "false" ]]; then
  if [[ "$commitA" == "" && "$commitB" == "" ]]; then 
    git diff --name-only --diff-filter=d "origin/${masterBranch}" -- vlocity >> $branchDiffUnsortedFile
    CheckGitResponse $?
  else
    git diff --name-only --diff-filter=d $commitA $commitB -- vlocity > $branchDiffUnsortedFile
    CheckGitResponse $?
  fi
fi
cat $branchDiffUnsortedFile | grep -v "SampleInput" | sort -u > $branchDiffSortedFile
#Ignore any specific files listed in scripts config files,
#comm -23 removes where there are matches, so filename entry must match git repo.
#files must be sorted for the command to work
cat $deltaIgnoreFile | sort > $deltaIgnoreSortedFile
comm -23 $branchDiffSortedFile $deltaIgnoreSortedFile > $branchDiffFile
#new lines the separator
IFS=$'\n'
packageXmlContents="`cat $branchPackageXmlFile | sed -n '1p;2p'`\n"
vlocityYamlContents="`cat $branchVlocityYamlFile | sed -n '1p;2p;3p;4p;5p'`\n"
#read in config to array of file structure match patterns.
for configEntry in `/bin/cat $configFile`
do
    IFS="|" read -ra CONFIGENTRY <<< "$configEntry"
    typesName="${CONFIGENTRY[0]}"
    matchPattern="${CONFIGENTRY[1]}"
    configArray[$matchPattern]="$typesName"
done;
for gitDiffItem in `/bin/cat $branchDiffFile`
do
    export vlocityComp=0
    #break filename apart to identify the member entry for package xml
    IFS='/' read -ra FILEPATH <<< "$gitDiffItem"
    if [ "${FILEPATH[0]}" == "vlocity" ]; then
        typesPath="${FILEPATH[1]}"
        export vlocityComp=1;
    else
        typesPath="${FILEPATH[3]}"
        export vlocityComp=0;
    fi
    typesName="${configArray[$typesPath]}"
    #check for special cases
    #check path of entry, for CustomObjects (file under objects folder), add extra package xml entry
    if [[ "$typesPath" == "objects" ]]; then
        subTypesPath="${FILEPATH[5]}"
        subTypesName="${configArray[$subTypesPath]}"
    else
        subTypesName=""
    fi
    if [[ $typesName == "CustomLabels" ]]; then
        #custom labels are all stored in one file and support a wildcard
        #memberEntry="*"
        memberEntry="CustomLabels"
    elif [[ $typesName == "Dashboard" || $typesName == "EmailTemplate" || $typesName == "Report" || $typesName == "Document" ]]; then
        #requires directory member entry along with member (file) itself.
        IdentifyMemberFromFileName "${FILEPATH[4]}"
        directoryName="${memberEntry}"
        #check if filename exists on diff result
        if [[ "${FILEPATH[5]}" == "" ]]; then
            memberEntry=""
        else
            IdentifyMemberFromFileName "${directoryName}/${FILEPATH[5]}"
        fi
    else
        if [[ $vlocityComp -eq 1 ]]; then 
            IdentifyMemberFromFileName "${FILEPATH[2]}"
        else
            IdentifyMemberFromFileName "${FILEPATH[4]}"
        fi
    fi
    #####end of special patterns, add new above.
    #add directory entry, identified in special cases, like reports
    #if [[ "$directoryName" != "$directoryNamePrev" ]]; then
    #    AddEntryToMemberArray "$directoryName" "$typesName"
    #    directoryNamePrev=$directoryName
    #fi
    #track when we've found a new entry to process
    if [[ ["$memberEntry" != "$memberEntryPrev" && "$memberEntry" != ""] || "$typesNamePrev" != "$typesName" ]]; then
        AddEntryToMemberArray "$memberEntry" "$typesName"
        memberEntryPrev="$memberEntry"
        typesNamePrev="$typesName"
    fi
    #check if we found a secondary entry requirement
    if [[ $subTypesName != "" ]]; then
        objectName="${FILEPATH[4]}"
        IdentifyMemberFromFileName "${FILEPATH[6]}"
        subName="${memberEntry}"
        AddEntryToMemberArray "$objectName.$subName" "$subTypesName"
    fi
    #workflows contain numerous entries inside the files.
    if [[ $typesName == "Workflow" ]]; then
        typesName="WorkflowAlert"
        IdentifyMemberFromFileInspectionByFullname "<alerts>" "$gitDiffItem"
        typesName="WorkflowFieldUpdate"
        IdentifyMemberFromFileInspectionByFullname "<labels>" "$gitDiffItem"
        typesName="WorkflowOutboundMessage"
        IdentifyMemberFromFileInspectionByFullname "<outboundMessages>" "$gitDiffItem"
        typesName="WorkflowRule"
        IdentifyMemberFromFileInspectionByFullname "<rules>" "$gitDiffItem"
        typesName="WorkflowTask"
        IdentifyMemberFromFileInspectionByFullname "<tasks>" "$gitDiffItem"
        #reset typesName
        typesName="Workflow"
    fi
done;
#loop through our configured components and add to manifest
for configItem in `/bin/cat $configFile`
do
    export vlocityComp=0
    IFS='|' read -ra CONFIG <<< $configItem
    configCriteria="${CONFIG[2]}"
    if [[ "$configCriteria" == "SkipComponent" || "$configCriteria" == "VlocitySkipComponent" ]]; then
        IgnoreFile "${CONFIG[0]}"
        continue;
    fi
    typesName="${CONFIG[0]}"
    if [[ "$configCriteria" == "VlocityFilename" || "$configCriteria" == "VlocityDirectory" ||
          "$configCriteria" == "VlocityDirectorySpaceForDash" ]]; then
        export vlocityComp=1
        memberLines="${vlocityMembersArray[$typesName]}"
        if [[ "$memberLines" == "" ]]; then
            continue;
        fi
	if [[ "$skipVlocity" == "false" || "$skipVlocity" == "0" ]]; then        
	    AddToManifest "${memberLines}"
        fi
    else 
        export vlocityComp=0
        memberLines="${typesMembersArray[$typesName]}"
        if [[ "$memberLines" == "" ]]; then
            continue;
        fi
        AddToManifest "${typesTag}"
        AddToManifest "${memberLines}"
        AddToManifest "${nameTag}${typesName}${nameTagEnd}"
        AddToManifest "${typesTagEnd}"
    fi
done;
#get last two lines, apiVersion, and end tag for package xml
packageXmlContents="${packageXmlContents}`tail -2 $branchPackageXmlFile`"
echo -e "$packageXmlContents" > $deltaPackageXmlFile;
echo -e "$vlocityYamlContents" > $deltaVlocityYamlFile;
cat $deltaPackageXmlFile
cat $deltaVlocityYamlFile
#remove temp files
rm -f ./scripts/bash/*.tmp
LogMessage "`/bin/date` Finished processing diff and building delta package xml.  Thanks for all the fish!"
#switch back to previous branch?
if [[ "$compareBranch" != "" ]]; then
    git switch -
fi
