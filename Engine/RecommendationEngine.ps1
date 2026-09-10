#Requires -Version 5.1
<#
.SYNOPSIS
    Tetra Optimizer - Evidence-Based Recommendation Engine
.DESCRIPTION
    Converts a SystemAnalysisSnapshot into user-facing recommendations without
    executing, approving, deleting, disabling, or modifying anything.

    Recommendation V1 is intentionally conservative:
      - SystemCritical / CriticalProtected -> DoNotTouch
      - confirmed Duplicate -> DuplicateReview
      - cleanup candidate -> CleanupCandidate
      - Analyzer Recommended -> ProfileRecommendation
      - Analyzer Optional / uncertain evidence -> Review
      - Used / Analyzer Keep -> Keep

    No duplicate keep-path or delete-path is selected here. No cleanup item is
    declared safe to delete. Every potentially actionable result still requires
    explicit user approval in a future approval/execution layer.
#>
[CmdletBinding()]param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

function Get-TetraRecommendationStates {
    [CmdletBinding()][OutputType([string[]])]param()
    return @('Keep','Review','CleanupCandidate','DuplicateReview','DoNotTouch','ProfileRecommendation')
}

function Get-TetraRecommendationPropertyValue {
    param([object]$InputObject,[string]$Name,[object]$DefaultValue=$null)
    if($null -eq $InputObject){return $DefaultValue}
    $p=$InputObject.PSObject.Properties[$Name]
    if($null -eq $p -or $null -eq $p.Value){return $DefaultValue}
    return $p.Value
}

function New-TetraRecommendation {
    [CmdletBinding()][OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory=$true)][string]$Subject,
        [Parameter(Mandatory=$true)][ValidateSet('Keep','Review','CleanupCandidate','DuplicateReview','DoNotTouch','ProfileRecommendation')][string]$Recommendation,
        [Parameter(Mandatory=$true)][ValidateSet('Low','Medium','High')][string]$Confidence,
        [Parameter(Mandatory=$true)][string]$Reason,
        [string]$SourceSection='',
        [string]$Path='',
        [string]$KnowledgeBaseId='',
        [string]$Classification='Unknown',
        [string]$PolicyDecision='',
        [object]$Evidence=$null,
        [long]$PotentialReclaimBytes=0
    )
    $approvalRequired=@('CleanupCandidate','DuplicateReview','ProfileRecommendation') -contains $Recommendation
    return [PSCustomObject]@{
        RecordType='Recommendation'
        RecommendationId=[guid]::NewGuid().ToString()
        Subject=$Subject
        SourceSection=$SourceSection
        Path=$Path
        KnowledgeBaseId=$KnowledgeBaseId
        Classification=$Classification
        PolicyDecision=$PolicyDecision
        Recommendation=$Recommendation
        Confidence=$Confidence
        Reason=$Reason
        PotentialReclaimBytes=$PotentialReclaimBytes
        RequiresUserApproval=$approvalRequired
        ActionApproved=$false
        ExecutionRequested=$false
        KeepPath=''
        DeletePaths=@()
        Evidence=$Evidence
        ObservedUtc=(Get-Date).ToUniversalTime().ToString('o')
    }
}

function ConvertTo-TetraRecommendations {
    [CmdletBinding()][OutputType([PSCustomObject[]])]
    param([Parameter(Mandatory=$true)][PSCustomObject]$Analysis)

    if([string](Get-TetraRecommendationPropertyValue $Analysis 'RecordType' '') -ne 'SystemAnalysisSnapshot'){
        throw 'ConvertTo-TetraRecommendations: Analysis must be a SystemAnalysisSnapshot.'
    }

    $policyById=@{}
    foreach($decision in @(Get-TetraRecommendationPropertyValue $Analysis 'PolicyDecisions' @())){
        if($null -eq $decision){continue}
        $id=[string](Get-TetraRecommendationPropertyValue $decision 'KnowledgeBaseId' '')
        if(-not [string]::IsNullOrWhiteSpace($id)){$policyById[$id]=$decision}
    }

    $results=[System.Collections.Generic.List[PSCustomObject]]::new()
    foreach($finding in @(Get-TetraRecommendationPropertyValue $Analysis 'Findings' @())){
        if($null -eq $finding){continue}
        $subject=[string](Get-TetraRecommendationPropertyValue $finding 'Subject' 'Unknown subject')
        $section=[string](Get-TetraRecommendationPropertyValue $finding 'SourceSection' '')
        $path=[string](Get-TetraRecommendationPropertyValue $finding 'Path' '')
        $kbId=[string](Get-TetraRecommendationPropertyValue $finding 'KnowledgeBaseId' '')
        $classification=[string](Get-TetraRecommendationPropertyValue $finding 'Classification' 'Unknown')
        $confidence=[string](Get-TetraRecommendationPropertyValue $finding 'Confidence' 'Low')
        if(@('Low','Medium','High') -notcontains $confidence){$confidence='Low'}
        $findingReason=[string](Get-TetraRecommendationPropertyValue $finding 'Reason' 'Insufficient evidence.')
        $reclaim=0L;try{$reclaim=[long](Get-TetraRecommendationPropertyValue $finding 'PotentialReclaimBytes' 0)}catch{}

        $policyDecision=''
        $policyReason=''
        if(-not [string]::IsNullOrWhiteSpace($kbId) -and $policyById.ContainsKey($kbId)){
            $policyDecision=[string](Get-TetraRecommendationPropertyValue $policyById[$kbId] 'Decision' '')
            $policyReason=[string](Get-TetraRecommendationPropertyValue $policyById[$kbId] 'Reason' '')
        }

        $recommendation='Review'
        $reason=$findingReason

        # Hard safety floor first.
        if($classification -eq 'SystemCritical' -or $policyDecision -eq 'CriticalProtected'){
            $recommendation='DoNotTouch';$confidence='High'
            $reason='Protected or system-critical evidence requires preserving this component. No modification should be proposed.'
            if(-not [string]::IsNullOrWhiteSpace($policyReason)){$reason="$reason $policyReason"}
        }
        elseif($classification -eq 'Duplicate'){
            $recommendation='DuplicateReview';$confidence='High'
            $reason='Confirmed duplicate evidence exists. Review the exact paths before choosing which copy to keep; this layer makes no keep/delete decision.'
        }
        elseif($classification -eq 'PotentiallyUnnecessary'){
            $recommendation='CleanupCandidate'
            $reason="$findingReason Candidate status is not deletion approval; explicit review and approval are still required."
        }
        elseif($policyDecision -eq 'Recommended'){
            $recommendation='ProfileRecommendation'
            if($confidence -eq 'Low'){$confidence='Medium'}
            $reason=$policyReason
        }
        elseif($policyDecision -eq 'Optional'){
            $recommendation='Review'
            $reason=$policyReason
        }
        elseif($policyDecision -eq 'DoNotChange'){
            $recommendation='DoNotTouch'
            $reason=$policyReason
        }
        elseif($policyDecision -eq 'Keep'){
            $recommendation='Keep'
            $reason=$policyReason
        }
        elseif($classification -eq 'Used'){
            $recommendation='Keep'
            $reason='Current activity evidence supports keeping this component. No change is recommended from classification evidence alone.'
        }
        elseif(@('Unknown','RarelyUsed','Unused','Leftover') -contains $classification){
            $recommendation='Review'
            $reason="$findingReason No automatic removal or modification is recommended from this evidence alone."
        }

        $results.Add((New-TetraRecommendation -Subject $subject -Recommendation $recommendation -Confidence $confidence -Reason $reason -SourceSection $section -Path $path -KnowledgeBaseId $kbId -Classification $classification -PolicyDecision $policyDecision -Evidence $finding -PotentialReclaimBytes $reclaim))
    }
    return $results.ToArray()
}

function Invoke-TetraRecommendations {
    [CmdletBinding()][OutputType([PSCustomObject])]
    param([Parameter(Mandatory=$true)][PSCustomObject]$Analysis)

    if([string](Get-TetraRecommendationPropertyValue $Analysis 'RecordType' '') -ne 'SystemAnalysisSnapshot'){
        throw 'Invoke-TetraRecommendations: Analysis must be a SystemAnalysisSnapshot.'
    }
    $started=(Get-Date).ToUniversalTime()
    $recommendations=@(ConvertTo-TetraRecommendations -Analysis $Analysis)
    $completed=(Get-Date).ToUniversalTime()
    $counts=[PSCustomObject]@{
        Recommendations=$recommendations.Count
        Keep=@($recommendations|Where-Object{$_.Recommendation -eq 'Keep'}).Count
        Review=@($recommendations|Where-Object{$_.Recommendation -eq 'Review'}).Count
        CleanupCandidate=@($recommendations|Where-Object{$_.Recommendation -eq 'CleanupCandidate'}).Count
        DuplicateReview=@($recommendations|Where-Object{$_.Recommendation -eq 'DuplicateReview'}).Count
        DoNotTouch=@($recommendations|Where-Object{$_.Recommendation -eq 'DoNotTouch'}).Count
        ProfileRecommendation=@($recommendations|Where-Object{$_.Recommendation -eq 'ProfileRecommendation'}).Count
        ApprovalRequired=@($recommendations|Where-Object{$_.RequiresUserApproval -eq $true}).Count
    }
    $reclaim=0L
    foreach($item in $recommendations){try{$reclaim += [long]$item.PotentialReclaimBytes}catch{}}
    return [PSCustomObject]@{
        RecordType='RecommendationSnapshot'
        RecommendationRunId=[guid]::NewGuid().ToString()
        SourceAnalysisId=[string](Get-TetraRecommendationPropertyValue $Analysis 'AnalysisId' '')
        SourceScanId=[string](Get-TetraRecommendationPropertyValue $Analysis 'SourceScanId' '')
        Profile=[string](Get-TetraRecommendationPropertyValue $Analysis 'Profile' '')
        Status='Complete'
        IsReadOnly=$true
        StartedUtc=$started.ToString('o')
        CompletedUtc=$completed.ToString('o')
        DurationMs=[math]::Round(($completed-$started).TotalMilliseconds,2)
        PotentialReclaimBytes=$reclaim
        Counts=$counts
        Recommendations=$recommendations
    }
}

# Public: Get-TetraRecommendationStates, ConvertTo-TetraRecommendations, Invoke-TetraRecommendations
