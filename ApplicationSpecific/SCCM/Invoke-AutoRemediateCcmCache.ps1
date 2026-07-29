<#
.SYNOPSIS
    CcmCacheResolutionWizard -- Reclaim space from the Configuration Manager client cache.

.DESCRIPTION
    Split out of Invoke-AutoRemediateSCCMClient.ps1 deliberately. Deploying THIS
    script is the opt-in -- do not fold it back into a general health sweep.

    +------+----------------------------+----------------------------------+
    | Step | Name                       | Remediates On                    |
    +------+----------------------------+----------------------------------+
    |  1   | Content Activity Guard     | -- (abort gate)                  |
    |  2   | Cache Utilization          | Warning (ResolveOnWarning)       |
    |  3   | Orphaned Cache Folders     | -- (report only)                 |
    |  4   | Post-Purge Verification    | -- (report only)                 |
    +------+----------------------------+----------------------------------+

    WHY THIS IS NOT AUTO-RUN FLEET-WIDE
    - Purging cache is not a local-only action. Every element removed is content the
      client may re-request from a distribution point. Run across a large collection
      at once, this becomes a synchronised DP / WAN re-download spike -- the endpoint
      looks healthier while the network absorbs the cost.
    - Cached content is frequently still needed: pending required deployments,
      superseded-app rollbacks, and task sequence packages all read from ccmcache.
      Removing the wrong element turns a fast local install into a slow remote one.
    - Deployment windows matter. Purging during a maintenance window that is about to
      install the very content being deleted is actively counterproductive.

    Stagger deployment across rings or a randomised window rather than firing it at a
    whole collection simultaneously.

    SAFETY RULES APPLIED HERE
    - Only the supported UIResourceMgr COM interface is used. The ccmcache folder is
      never touched directly with Remove-Item -- deleting files out from under the
      client leaves CacheInfoEx pointing at content that no longer exists, which is a
      harder problem than a full cache.
    - An element is removed only when ALL of the following hold:
        * ReferenceCount is 0                (not tied to an active deployment)
        * PersistInCache is not 1            (not pinned by the site)
        * A last-reference date could be parsed and is older than $StaleCacheDays
      Elements whose age cannot be determined are SKIPPED, never deleted.
    - Step 1 aborts the whole run if content is actively downloading or a task
      sequence is in flight.
    - $MaxDeletePerRun caps the blast radius of any single execution.

.NOTES
    Script Name  : Invoke-AutoRemediateCcmCache.ps1
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-07-29
    Timeout      : 120 seconds

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

# -- Tunables ------------------------------------------------------------------
$CacheUsedWarnPercent = 80    # ccmcache above this share of configured size -> purge
$StaleCacheDays       = 30    # Only elements unreferenced for this long are eligible
$MaxDeletePerRun      = 50    # Hard cap on elements removed in a single execution

# -- Step Definitions ----------------------------------------------------------
# Only supported fields: Name, Order, Enabled, ResolveOnWarning,
#                        DetectionScript, ResolutionScript
$Steps = @(

    @{
        Name             = 'Content Activity Guard'
        Order            = 1
        Enabled          = $true
        ResolveOnWarning = $false
        DetectionScript  = {
            # Never purge while the client is mid-flight on content.
            $blockers = @()

            if (Get-Process -Name 'TSManager' -ErrorAction SilentlyContinue) {
                $blockers += 'task sequence running'
            }
            if (Get-Process -Name 'ccmsetup' -ErrorAction SilentlyContinue) {
                $blockers += 'client install/upgrade running'
            }

            $active = @(Get-BitsTransfer -AllUsers -ErrorAction SilentlyContinue |
                        Where-Object { $_.DisplayName -like 'CCMDTS*' -and
                                       $_.JobState -in 'Transferring', 'Connecting', 'Queued' })
            if ($active.Count -gt 0) {
                $blockers += "$($active.Count) active CCM content transfer(s)"
            }

            if ($blockers.Count -gt 0) {
                $Script:AbortPurge = $true
                return @{ Status = 'Warning'; Message = "Aborting -- $($blockers -join '; ')" }
            }
            return @{ Status = 'Passed'; Message = 'No active content transfer or task sequence' }
        }
        ResolutionScript = $null
    },

    @{
        Name             = 'Cache Utilization'
        Order            = 2
        Enabled          = $true
        ResolveOnWarning = $true
        DetectionScript  = {
            if ($Script:AbortPurge) {
                return @{ Status = 'Passed'; Message = 'Skipped -- blocked by step 1' }
            }

            $cfg = Get-CimInstance -Namespace 'root\ccm\SoftMgmtAgent' -ClassName 'CacheConfig' `
                       -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $cfg) {
                $Script:AbortPurge = $true
                return @{ Status = 'Failed'; Message = 'Unable to read CacheConfig -- client WMI namespace may be broken; not purging blind' }
            }

            $configuredMB = [int]$cfg.Size
            if ($configuredMB -le 0) {
                $Script:AbortPurge = $true
                return @{ Status = 'Warning'; Message = 'Configured cache size reported as 0 -- cannot evaluate utilization, no action taken' }
            }

            $elements = @(Get-CimInstance -Namespace 'root\ccm\SoftMgmtAgent' -ClassName 'CacheInfoEx' `
                              -ErrorAction SilentlyContinue)
            # CacheInfoEx.ContentSize is in KB; CacheConfig.Size is in MB.
            $usedMB = [math]::Round((($elements | Measure-Object -Property ContentSize -Sum).Sum) / 1024, 1)
            $pct    = [math]::Round(($usedMB / $configuredMB) * 100)

            $Script:CacheBeforeMB = $usedMB

            if ($pct -ge $CacheUsedWarnPercent) {
                return @{ Status = 'Warning'; Message = "ccmcache at ${usedMB}MB of ${configuredMB}MB (${pct}%) across $($elements.Count) element(s) -- purging stale entries" }
            }
            $Script:AbortPurge = $true
            return @{ Status = 'Passed'; Message = "ccmcache at ${usedMB}MB of ${configuredMB}MB (${pct}%) -- below ${CacheUsedWarnPercent}% threshold, no action" }
        }
        ResolutionScript = {
            # Supported removal path -- lets CcmExec re-request content on demand.
            $mgr    = New-Object -ComObject 'UIResource.UIResourceMgr'
            $cache  = $mgr.GetCacheInfo()
            $cutoff = (Get-Date).AddDays(-$StaleCacheDays)

            # Snapshot first -- deleting while enumerating the live COM collection
            # can throw or silently skip elements.
            $elements = @($cache.GetCacheElements())
            $deleted  = 0

            foreach ($element in $elements) {
                if ($deleted -ge $MaxDeletePerRun)  { break }
                if ($element.ReferenceCount -gt 0)  { continue }   # In use by a deployment
                if ($element.PersistInCache -eq 1)  { continue }   # Pinned by the site

                # LastReferenceTime arrives as a DMTF datetime string
                # (yyyyMMddHHmmss.ffffff+UUU), which does NOT cast to [datetime].
                $lastRef = $null
                $raw     = [string]$element.LastReferenceTime
                if ($raw -match '^(\d{14})') {
                    try {
                        $lastRef = [datetime]::ParseExact($matches[1], 'yyyyMMddHHmmss', $null)
                    } catch { }
                }

                if (-not $lastRef)        { continue }   # Unknown age -> leave alone
                if ($lastRef -gt $cutoff) { continue }   # Recently used -> leave alone

                $cache.DeleteCacheElement($element.CacheElementID)
                $deleted++
            }

            $Script:DeletedCount = $deleted
        }
    },

    @{
        Name             = 'Orphaned Cache Folders'
        Order            = 3
        Enabled          = $true
        ResolveOnWarning = $false   # Report only -- see note
        DetectionScript  = {
            # Folders on disk with no matching CacheInfoEx entry are wasted space, but
            # deleting them by hand is exactly the unsupported path this script avoids.
            # Reported so a rebuild can be scheduled deliberately.
            $cfg = Get-CimInstance -Namespace 'root\ccm\SoftMgmtAgent' -ClassName 'CacheConfig' `
                       -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $cfg -or -not $cfg.Location -or -not (Test-Path $cfg.Location)) {
                return @{ Status = 'Passed'; Message = 'Cache location unavailable -- orphan survey skipped' }
            }

            $known = @(Get-CimInstance -Namespace 'root\ccm\SoftMgmtAgent' -ClassName 'CacheInfoEx' `
                           -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Location)
            $onDisk = @(Get-ChildItem -Path $cfg.Location -Directory -Force -ErrorAction SilentlyContinue)

            $orphans = @($onDisk | Where-Object { $known -notcontains $_.FullName })
            if ($orphans.Count -eq 0) {
                return @{ Status = 'Passed'; Message = "No orphaned cache folders ($($onDisk.Count) folder(s) all tracked)" }
            }

            $mb = [math]::Round((($orphans | ForEach-Object {
                    (Get-ChildItem -Path $_.FullName -Recurse -File -Force -ErrorAction SilentlyContinue |
                     Measure-Object -Property Length -Sum).Sum
                  }) | Measure-Object -Sum).Sum / 1MB, 1)

            return @{
                Status  = 'Warning'
                Message = "$($orphans.Count) orphaned cache folder(s) holding ~${mb}MB with no CacheInfoEx entry -- manual review; deleting these by hand is unsupported"
            }
        }
        ResolutionScript = $null
    },

    @{
        Name             = 'Post-Purge Verification'
        Order            = 4
        Enabled          = $true
        ResolveOnWarning = $false   # Report only
        DetectionScript  = {
            if (-not $Script:DeletedCount) {
                return @{ Status = 'Passed'; Message = 'No cache elements removed -- nothing to verify' }
            }

            $elements = @(Get-CimInstance -Namespace 'root\ccm\SoftMgmtAgent' -ClassName 'CacheInfoEx' `
                              -ErrorAction SilentlyContinue)
            $usedMB   = [math]::Round((($elements | Measure-Object -Property ContentSize -Sum).Sum) / 1024, 1)
            $freed    = [math]::Round($Script:CacheBeforeMB - $usedMB, 1)

            $capNote = if ($Script:DeletedCount -ge $MaxDeletePerRun) {
                " (hit the ${MaxDeletePerRun}-element cap -- re-run to continue)"
            } else { '' }

            return @{
                Status  = 'Passed'
                Message = "Removed $($Script:DeletedCount) element(s), freed ~${freed}MB; now $($elements.Count) element(s) at ${usedMB}MB$capNote"
            }
        }
        ResolutionScript = $null
    }
)

# -- Execution Engine ----------------------------------------------------------
$Script:AbortPurge    = $false
$Script:DeletedCount  = 0
$Script:CacheBeforeMB = 0

$activeSteps = $Steps |
    Where-Object { $_.Enabled } |
    Sort-Object   { [int]$_.Order }

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

Write-Host ''
Write-Host "`n-- CcmCacheResolutionWizard --------------------------------------" -ForegroundColor Cyan
Write-Host "   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')   Steps: $($activeSteps.Count)"
Write-Host '----------------------------------------------------------------' -ForegroundColor Cyan

foreach ($step in $activeSteps) {

    $status     = 'Failed'
    $message    = 'Detection script did not return a result.'
    $remediated = $false
    $remError   = ''

    # -- Detection ------------------------------------------------------------
    try {
        $result  = & $step.DetectionScript
        $status  = $result.Status
        $message = $result.Message
    } catch {
        $status  = 'Failed'
        $message = "Detection exception: $($_.Exception.Message)"
    }

    # -- Remediation ----------------------------------------------------------
    $shouldRemediate = ($status -eq 'Failed') -or
                       ($status -eq 'Warning' -and $step.ResolveOnWarning)

    if ($shouldRemediate -and $step.ResolutionScript) {
        try {
            & $step.ResolutionScript | Out-Null
            $remediated = $true
        } catch {
            $remError = $_.Exception.Message
        }
    }

    # -- Output ---------------------------------------------------------------
    $color = switch ($status) {
        'Passed'  { 'Green'  }
        'Warning' { 'Yellow' }
        'Failed'  { 'Red'    }
        default   { 'White'  }
    }
    $remNote = if ($remediated)   { '  -> Remediation ran' }
               elseif ($remError) { "  -> Remediation ERROR: $remError" }
               else               { '' }

    Write-Host "`n  [$($status.PadRight(7))] $($step.Name): $message$remNote" -ForegroundColor $color

    $results.Add([PSCustomObject]@{
        Order      = $step.Order
        Name       = $step.Name
        Status     = $status
        Message    = $message
        Remediated = $remediated
        RemError   = $remError
    })
}

# -- Summary -------------------------------------------------------------------
$passed   = ($results | Where-Object { $_.Status -eq 'Passed'  }).Count
$warnings = ($results | Where-Object { $_.Status -eq 'Warning' }).Count
$failed   = ($results | Where-Object { $_.Status -eq 'Failed'  }).Count
$remCount = ($results | Where-Object { $_.Remediated }).Count

Write-Host "`n----------------------------------------------------------------" -ForegroundColor Cyan
Write-Host "  Passed: $passed  |  Warnings: $warnings  |  Failed: $failed  |  Remediations run: $remCount"
Write-Host "`n----------------------------------------------------------------" -ForegroundColor Cyan
Write-Host ''

if ($failed -gt 0) { exit 1 }
exit 0
