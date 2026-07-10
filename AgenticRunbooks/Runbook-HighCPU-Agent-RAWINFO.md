I need to build an Agentic AI runbook for troubleshooting a Windows machine that is experiencing High CPU usage.

The assumption is that the agent will be able to analyze these details through DEX information, then attempt resolution through building and running a quick action in Omnissa DEX.  Quick actions should allow the agent to - Install and Remove Apps, Install Profiles, Perform MDM commands, Run scripts.  If we need to build scripts to create resolutions ask me if that is ok before proceeding.

High CPU Utilization
High CPU Utiliaztion occurs when the CPU has more instructions to process than its speed and core count allow.  If a CPU has too many instructions, threads, jobs, applications to process that potentially could impact end user experience because the action the end user desires to use could had degraded performance.

Symptoms
Slow performance
UI hanging
Slow startup time
Slow shutdown time

Most Common Causes
The most common causes for High CPU utilization are as follows:
1) The Anti-Virus is currently runnin a scan, which is taking up many CPU cycles.  This typically happens when (A) the corporate Anti-Virus still relies on scans (modern AV do not but some still do), (B) the CPU has a low core count or is in the lowest tier or in an older generation, or (C) the Hard Drive is slow or older (modern solid state drives have a significantly lower impact to AV CPU use.)  The primary driver of the CPU usage is the high disk utilization of AV scans.

Resolution: Some AV solutions (Defender for instance) have performance profiles that Admins can apply.  File a ticket on the users behalf?

2) Windows Updates - another process that can hog CPU use.  Typically tied to both network and disk utilization.  Additionally bug in Windows updates, and how those updates interact with applicataions and drivers can cause issues as well.

Resolution: Validate disk space and network speed.  Check to see if there are any errors in the Event log that could indicate a cryptography issue is occuring.

3) High number of startup applications that don't need to be running.  Many times applicaitons will automatically add themselves to Windows startup when they don't need to be.

Resolution: Determine based off the type of applciation whether or not it is more efficient to disable (most productivity or non-security apps) can be disabled.  Don't touch services in this step only focus on the Windows Startup applications.

4) High RAM use - If applications take up too much of a machines memory then the machine will have to do more disk swapping, which could cause delays in CPU processes causing a queue.

Resolution: check to see if any application have high memory use.  If they do reference the high memory use run book.

5) A single application is causing this issue.  Most of the time if an application is causing the issue it is usually tied to a single application.  There can be multiple reasons for this though:
  Application with high CPU requirement - This is usually confined to ceative applications: Photoshop, Video encoding, developers, game devs or testers, sometimes databases.
  Resolution: Validate whether or not the application has high CPU requirement from the developer - if it does see if the application has performance tuning, or if the application should be running on the GPU instead.  
  
  Disk Bottleneck - The rootcause of this could be hard to determine.  This goes back to the AV/Windows Updates examples.  another process could be using up disk IO causing the current application to hang.  Need to look at active processes with high disk usage.
  Resolution - it may make sense to have the user save their current progress and have them restart the application.

  GPU Issues/Bottleneck - More an more applications rely on the GPU rather than the CPU. 
   Resolution: Update the GPU drivers to see if its a driver issue.

  Memory leak - If the application has a memory leak the memory use will have a runaway effect.  Check for high memory use applications and see if any of those have a history of crashing.  Mem leak apps will always crash (or crash the OS).  

  Resolution: If an app has a memory leak, check workspace one to see if an update is available.

  Network issues - if an application cannot access the network efficiently then the cycles will begin to queue, eventually creating a CPU buildup.  This can be caused by a host of issues.  The best way to determine this is to validate the applcations network calls to see if they are successful or not or if they have high response times.  The issue could be: slow connectivity, CRLs blocked on the corporate network, asyncronous routing, access point driver issue

  Cryptography issues




5) Too many applications open - If the user has too many applications that have active processes open then CPU could spike.  Should be pretty rare though since it would require the application to be actively running.  Might only occur in certain creativity occupations.

6) Requried BIOS updates - if there is a BIOS update required 