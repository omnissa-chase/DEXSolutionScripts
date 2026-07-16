I need to build an Agentic AI runbook for troubleshooting a Windows machine that is experiencing High memory usage.

The assumption is that the agent will be able to analyze these details through DEX information, then attempt resolution through building and running a quick action in Omnissa DEX.  Quick actions should allow the agent to - Install and Remove Apps, Install Profiles, Perform MDM commands, Run scripts.  If we need to build scripts to create resolutions ask me if that is ok before proceeding.

High Memory Utilization
High Memory Utiliaztion occurs when the current set of applications or processes that are currently open exceed the memory threshold that triggers excessive Memory swap.  

Symptoms
Sudden slowness 

Most Common Causes
The most common causes for High CPU utilization are as follows:
1) A single application having high memory use.  
  1) The application requires a high amount of memory
  2) The application will utilize high amounts of memory by default to increase performance (Chrome pre-2024)
  
  3) The application relies on GPU processesing and the current machine uses onboard / integrated GPU and uses the actual memory as GPU memory.  Alternatively the application should be using the GPU but is instead using integrated/non-hardware enabled graphics.
  *Resolution: Validate whether or not the machine has a GPU.  If it does ensure that all the correct Windows display settings are enabled and if they aren't enable them.  Also check on the installation date of the GPU driver and determine if it is potentially out of date or needs an update.  Last step would be to have the user/IT validate that the application specific GPU settings are correct.*

2) Too many applications open
  1) Windows startup has an unessecary amount of startup applications
  2) 

3) 
