#Requires -Version 5.1
<#
.NOTES
    Sensor Name  : device_is_virtual
    Data Type    : Boolean
    Version      : 1.0.0
    Architecture : Any (x86/x64)
    Context      : System
    Author       : Chase Bradley, Omnissa DEX team
    Last Modified: 2026-08-25
    Timeout      : < 2 seconds
    Requires     : nothing -- reads local firmware and registry state only

    True when this device is a virtual machine, false when it is physical hardware.

    NO VALUE (no sample recorded) means the question could not be answered: neither the
    firmware identity registry key nor WMI could be read. Any boolean there would be a
    guess, and false is the more damaging guess -- it silently adds a device to the
    physical population. See the fallback rules in GENERAL-SCRIPTS-SENSORS_RUNBOOK.md
    section 10.

    ---------------------------------------------------------------------------
    HOW IT DECIDES

    Four independent families of evidence. Any single hit means virtual; the device is
    only reported physical when all four come back clean AND at least one of them was
    actually readable.

      1. Firmware identity (SMBIOS), read from
         HKLM:\HARDWARE\DESCRIPTION\System\BIOS -- system manufacturer, product,
         family, version, SKU, baseboard, BIOS vendor and BIOS version.
      2. The same identity via Win32_ComputerSystem and Win32_BIOS. Same underlying
         SMBIOS data, but collected independently, so a device whose registry copy is
         missing or blank is still covered.
      3. ACPI table vendor IDs under HKLM:\HARDWARE\ACPI (DSDT / FADT / RSDT). These
         survive on hypervisors configured to mask their SMBIOS strings, which some
         hardened and anti-detection builds do.
      4. Guest-tool services and paravirtual drivers that are NOT shipped in-box by
         Windows -- VMware Tools, VirtualBox Guest Additions, Parallels Tools, Xen PV
         drivers, VirtIO -- plus the Hyper-V guest parameter key.

    Coverage: VMware (ESXi, Workstation, Fusion), Hyper-V, Azure, VirtualBox, QEMU,
    KVM, Proxmox, Xen, Citrix Hypervisor, Nutanix AHV, Parallels, Amazon EC2 (Nitro
    and Xen generations), Google Compute Engine, OpenStack, oVirt/RHV, bhyve,
    Firecracker, Cloud Hypervisor, Apple Virtualization, Virtual PC, plus a generic
    catch for hypervisors that identify themselves only as "Virtual ...".

    ---------------------------------------------------------------------------
    TWO TRAPS THIS DELIBERATELY AVOIDS

    Both were confirmed on a real VMware guest while writing this, and either one on
    its own is enough to make a naive detector wrong on a large fraction of a fleet.

    HypervisorPresent IS NOT USED, in either direction. Win32_ComputerSystem exposes
    it and it is the first thing most scripts reach for, but it answers "is a
    hypervisor running somewhere" rather than "am I a guest":

      - False positives: every modern Windows device with Virtualization-Based
        Security, Credential Guard, Core Isolation, WSL2, Windows Sandbox or the
        Hyper-V role reports True while being entirely physical. On a Windows 11
        fleet that is most of it.
      - False negatives: the VMware guest this sensor was developed on reports
        HypervisorPresent = FALSE. VMware does not surface the CPUID hypervisor bit
        to the guest unless nested virtualisation or VBS is enabled.

    THE vmic* AND Vmbus SERVICES ARE NOT EVIDENCE. vmicheartbeat, vmicvss,
    vmicshutdown, Vmbus, hvservice and hyperkbd all exist on stock Windows whether or
    not the device is a Hyper-V guest -- on the VMware guest used for development, all
    six were present. A detector keying on them reports every Windows machine as a
    Hyper-V VM. Hyper-V guests are identified here by
    HKLM:\SOFTWARE\Microsoft\Virtual Machine\Guest\Parameters, which is created by the
    integration components inside a guest and is absent on a Hyper-V host, and by the
    "Virtual Machine" SMBIOS product name.

    ---------------------------------------------------------------------------
    OTHER DESIGN NOTES

    Vendor tokens (vmware, qemu, xen, ...) are matched against firmware fields as well
    as identity fields. The generic tokens (virtual, hypervisor, emulated) are matched
    against IDENTITY fields only -- manufacturer, product, family, baseboard -- because
    a BIOS version string on physical hardware can legitimately mention virtualisation
    support and would otherwise produce a false positive.

    Disk device strings are deliberately not used. A mounted VHDX on a physical device
    presents as Ven_Msft&Prod_Virtual_Disk, and native VHD boot exists, so the signal
    reads as virtual on hardware that is not. Everything it would have caught is
    already covered by the firmware identity.

    A physical host running Hyper-V, VMware Workstation or VirtualBox reports FALSE,
    which is correct -- it is physical hardware. Nested guests report TRUE, since they
    see their immediate parent's firmware.

    New VMware builds do not say "VMware Virtual Platform". The development machine
    reported SystemProductName "VMware20,1" and BaseBoardProduct "VBSA". Matching on
    the vendor token rather than a model string is what keeps that working; detectors
    hard-coded to the legacy model strings miss every recent VMware guest.

.DISCLAIMER
    These scripts are provided "AS IS". It is the administrator's sole responsibility
    to test and validate scripts in a non-production environment before deployment.
    The author(s) accept no liability for damage, data loss, or unintended consequences.
    See LICENSE at https://github.com/omnissa-chase/DEXSolutionScripts/blob/main/LICENSE
#>

try {
    # -- Vendor tokens: safe against identity AND firmware fields --
    $VendorPatterns = @(
        'vmware'                            # VMware ESXi / Workstation / Fusion
        'virtualbox|innotek|\bvbox\b'       # Oracle VirtualBox
        '\bqemu\b|bochs|standard pc \('     # QEMU, Proxmox, Nutanix AHV
        '\bkvm\b'                           # KVM
        '\bxen\b|xenserver|hvm domu'        # Xen, Citrix Hypervisor, legacy EC2
        'parallels|\bprls\b'                # Parallels Desktop
        'amazon ec2|\bec2\b'                # AWS Nitro and Xen generations
        'google compute engine'             # Google Cloud
        'nutanix'                           # Nutanix AHV
        'openstack'                         # OpenStack Nova
        'ovirt|\brhev\b|red hat'            # oVirt / Red Hat Virtualization
        'apple virtualization'              # Apple Virtualization framework
        'bhyve'                             # FreeBSD bhyve
        'firecracker|cloud hypervisor'      # AWS Firecracker, Cloud Hypervisor
        'microsoft hv|hyper-v|vrtual'       # Hyper-V, incl. its VRTUAL ACPI OEM ID
    )

    # -- Generic tokens: identity fields ONLY, see header --
    $GenericPatterns = @(
        'virtual machine'
        'virtual platform'
        '\bvirtual\b'
        'hypervisor'
        'emulated|emulation'
    )

    $identity = New-Object System.Collections.Generic.List[string]
    $firmware = New-Object System.Collections.Generic.List[string]
    $readSomething = $false

    # -- 1. Firmware identity from the registry (fast, no WMI) --
    $bios = Get-ItemProperty -Path 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS' -ErrorAction SilentlyContinue
    if ($bios) {
        foreach ($name in @('SystemManufacturer', 'SystemProductName', 'SystemFamily',
                            'SystemVersion', 'SystemSKU', 'BaseBoardManufacturer',
                            'BaseBoardProduct', 'BaseBoardVersion')) {
            $v = [string]$bios.$name
            if (-not [string]::IsNullOrWhiteSpace($v)) { $identity.Add($v); $readSomething = $true }
        }
        foreach ($name in @('BIOSVendor', 'BIOSVersion')) {
            $v = [string]$bios.$name
            if (-not [string]::IsNullOrWhiteSpace($v)) { $firmware.Add($v); $readSomething = $true }
        }
    }

    # -- 2. The same identity via WMI, independently --
    # Costs about 25 ms and covers devices whose registry copy is blank or absent.
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
    if ($cs) {
        foreach ($v in @([string]$cs.Manufacturer, [string]$cs.Model)) {
            if (-not [string]::IsNullOrWhiteSpace($v)) { $identity.Add($v); $readSomething = $true }
        }
    }
    $wmiBios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue
    if ($wmiBios) {
        foreach ($v in @([string]$wmiBios.Manufacturer, [string]$wmiBios.Version,
                         [string]$wmiBios.SMBIOSBIOSVersion)) {
            if (-not [string]::IsNullOrWhiteSpace($v)) { $firmware.Add($v); $readSomething = $true }
        }
    }

    # -- 3. ACPI table vendor IDs --
    # Survives hypervisors configured to mask their SMBIOS strings.
    foreach ($table in @('DSDT', 'FADT', 'RSDT')) {
        $keys = Get-ChildItem -Path "HKLM:\HARDWARE\ACPI\$table" -ErrorAction SilentlyContinue
        foreach ($k in $keys) {
            # ACPI OEM IDs are fixed-width 6-character fields, padded with underscores:
            # VBOX__, PRLS__, BOCHS_. Underscore is a regex word character, so \bvbox\b
            # does NOT match VBOX__ -- strip the padding before matching rather than
            # weakening the word boundaries, which is what keeps 'xen' off 'Xeon'.
            $name = ([string]$k.PSChildName).TrimEnd('_').Trim()
            if (-not [string]::IsNullOrWhiteSpace($name)) {
                $firmware.Add($name)
                $readSomething = $true
            }
        }
    }

    # -- 4. Guest-only artifacts, each conclusive on its own --
    $guestArtifact = $false

    # Written by the Hyper-V integration components INSIDE a guest. Absent on a host
    # running the Hyper-V role, which is what makes it usable where the vmic*
    # services are not (see header).
    if (Test-Path -Path 'HKLM:\SOFTWARE\Microsoft\Virtual Machine\Guest\Parameters' -ErrorAction SilentlyContinue) {
        $guestArtifact = $true
    }

    if (-not $guestArtifact) {
        # Curated deliberately: every name here ships with a hypervisor's guest tools
        # or paravirtual driver set and NONE of them is in-box Windows. The in-box
        # Hyper-V integration services are excluded for exactly that reason.
        $guestServices = @(
            'VMTools', 'VGAuthService', 'vmvss', 'vmhgfs', 'vm3dservice', 'vmci'   # VMware
            'VBoxService', 'VBoxGuest', 'VBoxSF', 'VBoxMouse'                      # VirtualBox
            'prl_tools_service', 'prl_tools', 'prl_fs', 'prl_mouf'                 # Parallels
            'xenbus', 'xenvbd', 'xennet', 'xeniface', 'XenSvc'                     # Xen / Citrix PV
            'netkvm', 'viostor', 'vioscsi', 'vioserial', 'BalloonService'          # VirtIO
        )
        # One call, not one per name: Get-Service returns only the names that exist.
        $found = @(Get-Service -Name $guestServices -ErrorAction SilentlyContinue)
        if ($found.Count -gt 0) { $guestArtifact = $true; $readSomething = $true }
    }

    # -- Verdict --
    $isVirtual = $guestArtifact

    if (-not $isVirtual) {
        foreach ($value in @($identity + $firmware)) {
            foreach ($pattern in $VendorPatterns) {
                if ($value -match $pattern) { $isVirtual = $true; break }
            }
            if ($isVirtual) { break }
        }
    }

    if (-not $isVirtual) {
        foreach ($value in $identity) {
            foreach ($pattern in $GenericPatterns) {
                if ($value -match $pattern) { $isVirtual = $true; break }
            }
            if ($isVirtual) { break }
        }
    }

    if ($isVirtual) {
        Write-Output $true
        return
    }

    # Clean on every check, but only trustworthy if at least one check could run.
    if (-not $readSomething) { return }

    Write-Output $false
    return
}
catch {
    # No safe boolean fallback -- record no sample rather than a guess.
    return
}
